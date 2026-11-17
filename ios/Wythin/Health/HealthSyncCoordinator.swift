import Foundation
import Observation
import SwiftData

@MainActor @Observable final class HealthSyncCoordinator {
    static let shared = HealthSyncCoordinator()
    private(set) var enabled = false
    private(set) var cloudEnabled = false
    private(set) var isWorking = false
    private(set) var status = "Not connected"
    private(set) var lastError: String?
    private(set) var entries: [HealthEntry] = []
    private(set) var pendingCount = 0
    private(set) var lastSync: Date?
    private(set) var pendingDeletion = false
    var isInForeground = false
    var available: Bool { source.available }

    @ObservationIgnored private let source: any HealthSource
    @ObservationIgnored private var store: HealthRepository?
    @ObservationIgnored private var opening: Task<HealthRepository, Error>?
    @ObservationIgnored private var projectorTask: Task<HealthActivityProjector, Never>?
    @ObservationIgnored private var injectedCloud: (any HealthCloudTransport)?
    @ObservationIgnored private let credentials: any HealthCredentialStorage
    @ObservationIgnored private var cloudWorking = false
    @ObservationIgnored private var followup: Task<Void, Never>?
    @ObservationIgnored private var observersStarted = false
    @ObservationIgnored private var loadingSamples = Set<UUID>()
    @ObservationIgnored private var syncWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored private var queuedImportOnly = true
    @ObservationIgnored private var cloudFollowup: Task<Void, Never>?
    @ObservationIgnored private var cloudRequested = false

    init(source: any HealthSource = HealthKitSource(), repository: HealthRepository? = nil, cloud: (any HealthCloudTransport)? = nil, credentialStore: any HealthCredentialStorage = HealthCredentialStore()) {
        self.source = source; store = repository; injectedCloud = cloud; credentials = credentialStore
    }

    var serverURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "serverURL") ?? "") ?? URL(string: "https://api.77.42.73.250.sslip.io")!
    }
    private func repository() async throws -> HealthRepository {
        if let store { return store }
        if opening == nil { opening = Task.detached { try HealthRepository() } }
        let result = try await opening!.value; store = result; return result
    }
    func attach(container: ModelContainer) {
        projectorTask = Task.detached { HealthActivityProjector(modelContainer: container) }
        Task { await bootstrap() }
    }
    /// Called by didFinishLaunching, before any Settings view has appeared.
    func installObserversAtLaunch() {
        if UserDefaults.standard.bool(forKey: "health.integrationEnabled") { startObservers() }
        Task { await bootstrap() }
    }
    private func startObservers() {
        guard !observersStarted else { return }; observersStarted = true
        source.startObserving { [weak self] in
            // Observer completion waits for durable local work, never for the network.
            await self?.synchronize(importOnly: true)
        }
    }
    private func bootstrap() async {
        do {
            let repo = try await repository(), s = try await repo.state()
            enabled = s.enabled; cloudEnabled = s.cloudConsent
            if s.enabled { startObservers() }
            try await refreshView(repo)
            await synchronize()
        } catch { lastError = "Apple Health storage could not be opened. Your existing history is unchanged." }
    }
    func connect() async {
        guard available else { lastError = "Apple Health is unavailable on this device."; return }
        do {
            let repo = try await repository()
            guard !(try await repo.state()).pendingPurge else { lastError = "Finish the pending cloud deletion before reconnecting."; return }
            try await source.requestAuthorization()
            try await repo.setEnabled(true)
            UserDefaults.standard.set(true, forKey: "health.integrationEnabled")
            enabled = true; lastError = nil; startObservers()
            await synchronize()
        } catch { lastError = "The Apple Health connection could not be completed. Try again from this screen." }
    }
    func disconnect() async {
        do {
            let repo = try await repository(); try await repo.setEnabled(false)
            source.stopObserving(); observersStarted = false; followup?.cancel()
            UserDefaults.standard.set(false, forKey: "health.integrationEnabled")
            enabled = false; status = "Disconnected · saved history remains"
        } catch { lastError = "Could not save the connection setting." }
    }
    func setCloudEnabled(_ on: Bool) async {
        do {
            let repo = try await repository(), old = try await repo.state()
            if on, let previous = old.cloudServer, previous != serverURL.absoluteString, old.connectionId != nil {
                lastError = "Delete or finish syncing the existing Health archive before changing its server."; return
            }
            try await repo.setCloudConsent(on, server: serverURL.absoluteString); cloudEnabled = on
            if on { await synchronize() }
            else { await drainCloud(repo) }
        } catch { lastError = "The cloud setting is saved locally. The server update will be retried when available." }
    }
    func synchronize(importOnly: Bool = false) async {
        if isWorking {
            // A notification can arrive after its type was queried. Complete it only
            // after another durable delta pass, rather than silently losing it.
            queuedImportOnly = queuedImportOnly && importOnly
            await withCheckedContinuation { syncWaiters.append($0) }
            return
        }
        isWorking = true
        defer {
            isWorking = false
            if !syncWaiters.isEmpty {
                let waiters = syncWaiters, onlyImport = queuedImportOnly
                syncWaiters = []; queuedImportOnly = true
                Task {
                    await self.synchronize(importOnly: onlyImport)
                    waiters.forEach { $0.resume() }
                }
            }
        }
        do {
            let repo = try await repository(), initial = try await repo.state()
            enabled = initial.enabled; cloudEnabled = initial.cloudConsent
            if initial.pendingPurge {
                if !importOnly { await drainCloud(repo) }
                try await refreshView(repo); return
            }
            guard initial.enabled else { try await refreshView(repo); return }
            status = initial.historyComplete ? "Checking for updates…" : "Importing available history…"
            lastError = nil
            let deadline = Date.now.addingTimeInterval(isInForeground ? 12 : 5)
            var moreWork = false
            let page = try await source.workoutPage(anchor: initial.anchors["workouts"])
            try await repo.applyWorkouts(page, expectedEpoch: initial.connectionEpoch)
            moreWork = page.hasMore
            // Context jobs are persisted with each workout, so interrupted historical imports resume.
            let pending = try await repo.entries().filter { !$0.deleted && !$0.contextPending.isEmpty }
            contextLoop: for entry in pending {
                for metric in entry.contextPending {
                    if Date.now >= deadline { moreWork = true; break contextLoop }
                    let latest = try await repo.state()
                    guard latest.enabled, !latest.pendingPurge, latest.connectionEpoch == initial.connectionEpoch else { return }
                    let samples = try await source.samples(metric: metric, start: entry.workout.startedAt.addingTimeInterval(-300), end: entry.workout.endedAt.addingTimeInterval(600))
                    try await repo.applySamples(HealthSamplePage(samples: samples, deletedIDs: [], nextAnchor: nil, hasMore: false), metric: metric, updateAnchor: false, expectedEpoch: initial.connectionEpoch)
                    try await repo.finishContext(workout: entry.workout.id, metric: metric)
                }
            }
            // Catch late additions and deletions even for years-old activities.
            for metric in HealthMetric.allCases {
                if Date.now >= deadline { moreWork = true; break }
                let current = try await repo.state()
                guard current.enabled, !current.pendingPurge, current.connectionEpoch == initial.connectionEpoch else { return }
                let delta = try await source.samplePage(metric: metric, anchor: current.anchors[metric.rawValue])
                try await repo.applySamples(delta, metric: metric, expectedEpoch: initial.connectionEpoch)
                moreWork = moreWork || delta.hasMore
            }
            try await repo.refreshAnalyses()
            let refreshedEntries = try await repo.entries()
            moreWork = moreWork || refreshedEntries.contains { !$0.deleted && $0.needsAnalysis }
            try await repo.markSynced(); try await refreshView(repo)
            status = entries.filter({ !$0.deleted }).isEmpty ? "No accessible workouts yet. Check the data selected in Health." : (moreWork ? "Importing available history…" : "Up to date")
            if importOnly { Task { await self.drainCloud(repo) } }
            else { await drainCloud(repo) }
            if moreWork && isInForeground {
                followup?.cancel()
                followup = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    await self?.synchronize()
                }
            }
        } catch {
            lastError = "Apple Health could not be read right now. Unlock your iPhone and try again. Saved data will be retried."
            status = "Waiting to retry"
        }
    }

    func deleteImportedData() async {
        do {
            let repo = try await repository(); try await repo.beginPurge()
            HealthActivityLinks().removeAll()
            source.stopObserving(); observersStarted = false; followup?.cancel()
            UserDefaults.standard.set(false, forKey: "health.integrationEnabled")
            enabled = false; cloudEnabled = false
            try await refreshView(repo); await drainCloud(repo)
        } catch { lastError = "Deletion is not complete. Reopen this screen to retry." }
    }
    /// General "delete my cloud data" also deletes this independent namespace.
    /// A durable pending delete retains the credential while offline.
    func deleteForGeneralDataRemoval() async throws {
        let repo = try await repository()
        try await repo.beginPurge(retainingLocal: true)
        try await refreshView(repo); await drainCloud(repo)
        if try await repo.state().pendingPurge { throw HealthStoreError.connectionMissing }
    }
    func hide(_ id: UUID) async {
        do { let repo = try await repository(); try await repo.hideWorkout(id); try await refreshView(repo); await drainCloud(repo) }
        catch { lastError = "Could not remove this imported workout." }
    }
    func annotate(_ id: UUID, title: String?, notes: String?) async {
        do { let repo = try await repository(); try await repo.annotate(id, title: title, notes: notes); lastError = nil; try await refreshView(repo); await drainCloud(repo) }
        catch HealthStoreError.annotationTooLong { lastError = "Use at most 200 characters for the title and 10,000 for notes. Nothing was saved." }
        catch { lastError = "Could not save the workout note." }
    }
    func samples(for workout: HealthWorkout) async -> [HealthSample] {
        let job = UUID()
        var repo: HealthRepository?
        do {
            let store = try await repository(); repo = store
            let local = try await store.samples(for: workout)
            guard local.isEmpty, !loadingSamples.contains(workout.id) else { return local }
            let state = try await store.state()
            guard state.enabled, state.cloudConsent, !state.pendingPurge,
                  UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true,
                  let url = state.cloudServer.flatMap(URL.init(string:)), let identity = try credentials.load(server: url) else { return local }
            loadingSamples.insert(workout.id)
            defer { loadingSamples.remove(workout.id) }
            var cursor: String?, complete = true
            repeat {
                try Task.checkCancellation()
                let current = try await store.state()
                guard canTransfer(current), current.connectionEpoch == state.connectionEpoch,
                      current.connectionId == state.connectionId, current.localGeneration == state.localGeneration else { break }
                let page = try await cloud(url).detail(externalId: workout.id, credential: identity.credential, cursor: cursor)
                let valid = try await store.stageCloudSamples(page.samples, job: job)
                complete = complete && valid
                cursor = page.nextSamplesCursor
                if cursor == nil && complete { try await store.publishCloudSamples(job: job, workoutId: workout.id, epoch: state.connectionEpoch, generation: state.localGeneration, connectionId: state.connectionId) }
            } while cursor != nil
            try await store.discardCloudSamples(job: job)
            return try await store.samples(for: workout)
        } catch {
            if let repo { try? await repo.discardCloudSamples(job: job) }
            if !(error is CancellationError) { lastError = "Measurements could not be restored yet. Reopen this activity when online." }
            return []
        }
    }
    private func cloud(_ url: URL) -> any HealthCloudTransport { injectedCloud ?? HealthCloudClient(baseURL: url) }

    private func drainCloud(_ repo: HealthRepository) async {
        guard !cloudWorking else { cloudRequested = true; return }; cloudWorking = true
        defer {
            cloudWorking = false
            if cloudRequested {
                cloudRequested = false
                scheduleCloud(repo, after: 0.25)
            }
        }
        do {
            var s = try await repo.state()
            let url = s.cloudServer.flatMap(URL.init(string:)) ?? serverURL
            if s.pendingPurge {
                if let credential = try credentials.load(server: url) {
                    let epoch = try await cloud(url).purge(epoch: s.connectionEpoch, credential: credential.credential)
                    try await repo.finishPurge(epoch: epoch)
                    try credentials.remove(server: url)
                } else {
                    guard s.connectionId == nil else { throw HealthStoreError.connectionMissing }
                    try await repo.finishPurge(epoch: s.connectionEpoch + 1)
                }
                pendingDeletion = false; status = "Imported data deleted"; lastError = nil; return
            }
            if s.pausePending, let connection = s.connectionId, let identity = try credentials.load(server: url) {
                try await cloud(url).pause(connectionId: connection, credential: identity.credential)
                try await repo.completeCloudPause()
            }
            guard s.enabled, s.cloudConsent, s.cloudServer == serverURL.absoluteString else { return }
            guard !s.cloudAuthBlocked else { return }
            // The app-wide cloud switch remains an additional consent gate.
            guard UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true else { return }
            if let retryAfter = s.retryAfter, retryAfter > .now { return }
            var identity = try credentials.load(server: url)
            if identity == nil {
                var created = try await cloud(url).enroll()
                created.streamId = s.streamId
                try credentials.save(created, server: url); identity = created
            }
            guard let identity else { return }
            if let streamId = identity.streamId { try await repo.adoptWriterStream(streamId) }
            s = try await repo.state()
            guard canTransfer(s) else { return }
            let connection = try await cloud(url).connect(streamId: s.streamId, credential: identity.credential)
            try await repo.bindConnection(id: connection.connectionId, epoch: connection.connectionEpoch, expectedSequence: connection.expectedSequence)
            s = try await repo.state()
            guard canTransfer(s) else { return }
            let page = try await cloud(url).restore(cursor: s.restoreCursor, credential: identity.credential)
            try await repo.mergeRestored(page.items, cursor: page.nextCursor, expectedEpoch: s.connectionEpoch)
            // Finish authoritative restore first: it can contain tombstones or saved
            // annotations for workouts just reimported after a reinstall.
            if page.hasMore { try await refreshView(repo); scheduleCloud(repo, after: 0.25); return }
            var sentAny = false
            for _ in 0..<8 {
                guard let data = try await repo.prepareBatch() else { break }
                guard canTransfer(try await repo.state()) else { return }
                let ack = try await cloud(url).send(batch: data, credential: identity.credential)
                try await repo.acknowledge(batchId: ack.batchId, sequence: ack.sequence, epoch: ack.connectionEpoch, serverRevision: ack.serverRevision)
                sentAny = true
            }
            s = try await repo.state()
            guard canTransfer(s) else { return }
            try await refreshView(repo)
            if sentAny || pendingCount > 0 { scheduleCloud(repo, after: 0.25) }
        } catch {
            let s = try? await repo.state()
            if let error = error as? HealthCloudError, [401, 403].contains(error.status) {
                try? await repo.blockCloudAuthentication()
                lastError = "Health cloud access was rejected. Uploading is paused; your local data remains saved."
                return
            }
            let delay = min(3600.0, pow(2, Double(min(s?.retryCount ?? 0, 8))) * 5) + Double.random(in: 0...3)
            let serverDelay = (error as? HealthCloudError)?.retryAfter ?? 0
            try? await repo.scheduleRetry(after: max(delay, serverDelay))
            scheduleCloud(repo, after: max(delay, serverDelay))
            lastError = s?.pendingPurge == true ? "Deleted from this iPhone. Cloud deletion is pending; reconnect to finish." : "Saved on this iPhone. Cloud sync will retry when available."
        }
    }
    private func scheduleCloud(_ repo: HealthRepository, after delay: TimeInterval) {
        cloudFollowup?.cancel()
        cloudFollowup = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.drainCloud(repo)
        }
    }
    private func canTransfer(_ state: HealthLocalState) -> Bool {
        state.enabled && state.cloudConsent && !state.pendingPurge && state.cloudServer == serverURL.absoluteString &&
        (UserDefaults.standard.object(forKey: "cloudSyncEnabled") as? Bool ?? true)
    }
    private func refreshView(_ repo: HealthRepository) async throws {
        entries = try await repo.entries(); pendingCount = try await repo.pendingCount()
        let s = try await repo.state(); enabled = s.enabled; cloudEnabled = s.cloudConsent; lastSync = s.lastSuccess; pendingDeletion = s.pendingPurge
        if s.pendingPurge { status = "Cloud deletion pending" }
        if let projectorTask { try await projectorTask.value.project(entries) }
    }
}
