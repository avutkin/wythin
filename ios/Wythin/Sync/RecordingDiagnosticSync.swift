import CryptoKit
import Foundation
import UIKit

@MainActor
final class RecordingDiagnosticSync {
    static let sessionIdentifier = "com.wythin.recording-diagnostics-upload"
    static var active: RecordingDiagnosticSync?
    static var pendingBackgroundCompletionHandler: (() -> Void)?

    private let request: URLRequest
    private let namespace: String
    private let directory: URL
    private let defaults: UserDefaults
    private let now: () -> Date
    private let background: Bool
    private let session: URLSession
    private let delegate: RecordingDiagnosticSessionDelegate
    private let fallbackInstallationID = UUID()
    private var queue: RecordingDiagnosticOutbox?
    private var identity: RecordingDiagnosticOutbox.Identity?
    private var sequence = 0
    private var inventoryRequested = false
    private var restoredTasks: [URLSessionTask]?
    private var reconciled = false
    private var currentTask: URLSessionTask?
    private var completions: [RecordingDiagnosticSessionDelegate.Completion] = []
    private var retryTimer: Timer?
    private var unlockObserver: NSObjectProtocol?
    private var backgroundHandlers: [() -> Void] = []
    private var finishedBackgroundEvents = false
    private var deletionInProgress = false
    private var discardedThroughSequence = 0
    private var deletionCancellation: (taskIDs: Set<Int>, continuation: CheckedContinuation<Void, Never>)?

    var onReady: (() -> Void)?
    var onCollectionStateChanged: (() -> Void)?
    var installationID: UUID { identity?.installationID ?? fallbackInstallationID }
    let launchID = UUID()
    var launchSequence: Int { identity?.launchSequence ?? 0 }
    var droppedReports: Int { queue?.droppedReports ?? 0 }

    private var enabled: Bool { defaults.object(forKey: "cloudSyncEnabled") as? Bool ?? true }
    private var eraseKey: String { "recordingDiagnosticsPendingRemoval.\(namespace)" }
    private var mustErase: Bool { !enabled || defaults.bool(forKey: eraseKey) }
    var canCollect: Bool { !deletionInProgress && !mustErase }

    init(client: APIClient, userID: String, defaults: UserDefaults = .standard,
         directory: URL? = nil, configuration: URLSessionConfiguration? = nil,
         now: @escaping () -> Date = Date.init,
         sessionFactory: ((URLSessionConfiguration, URLSessionDelegate) -> URLSession)? = nil) {
        request = client.recordingDiagnosticUploadRequest(userID: userID)
        // Include an unambiguous account delimiter and the entire endpoint,
        // including its base path and port. Never put the account in filenames.
        let scope = "\(userID.utf8.count):\(userID)\(request.url?.absoluteString ?? "")"
        namespace = SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RecordingDiagnostics", isDirectory: true)
        self.directory = base.appendingPathComponent(namespace, isDirectory: true)
        self.defaults = defaults
        self.now = now
        background = configuration == nil || configuration?.identifier != nil

        let delegate = RecordingDiagnosticSessionDelegate()
        let configuration = configuration ?? Self.backgroundConfiguration()
        self.delegate = delegate
        session = sessionFactory?(configuration, delegate)
            ?? URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        delegate.owner = self
        if configuration.identifier == Self.sessionIdentifier {
            Self.active = self
            if let handler = Self.pendingBackgroundCompletionHandler {
                backgroundHandlers.append(handler)
                Self.pendingBackgroundCompletionHandler = nil
            }
        }

        // Reporter startup needs identity before the asynchronous system
        // inventory returns. The launch increment must be durable first.
        try? openQueue()
    }

    deinit {
        if let unlockObserver { NotificationCenter.default.removeObserver(unlockObserver) }
        retryTimer?.invalidate()
        if !background { session.invalidateAndCancel() }
    }

    static func backgroundConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    func nextSequence() -> Int {
        guard canCollect, identity != nil, sequence < 9_007_199_254_740_991 else { return 0 }
        sequence += 1
        return sequence
    }

    func start() {
        if unlockObserver == nil {
            unlockObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.advance() }
            }
        }
        if !inventoryRequested {
            inventoryRequested = true
            session.getAllTasks { [weak self] tasks in
                Task { @MainActor in
                    guard let self else { return }
                    self.restoredTasks = tasks
                    self.advance()
                }
            }
        }
        advance()
    }

    func submit(event: RecordingDiagnosticEvent) {
        guard canCollect else { return }
        defer { start() }
        do {
            try openQueue()
            try eraseIfRequired()
            guard event.installationId == installationID, event.launchId == launchID,
                  event.launchSequence == launchSequence, event.sequence > discardedThroughSequence else { return }
            // No unstructured Task before persistence. Lifecycle reports are
            // already queued when the caller returns to UIKit.
            try queue?.enqueue(event, at: now())
        } catch {
            reportStorageError(error)
        }
    }

    func setEnabled(_ value: Bool) {
        // Remember a pending erase even if disabling and re-enabling both
        // happen while file protection prevents durable cleanup.
        if !value { defaults.set(true, forKey: eraseKey) }
        defaults.set(value, forKey: "cloudSyncEnabled")
        start()
        onCollectionStateChanged?()
    }

    /// Quiesce this installation's diagnostics before any server deletion.
    /// System task cancellation cannot retract bytes already sent to the server.
    func withCloudDataDeletion(_ operation: () async throws -> Void) async throws {
        guard !deletionInProgress else { throw CocoaError(.userCancelled) }
        deletionInProgress = true
        discardedThroughSequence = sequence
        defaults.set(true, forKey: eraseKey)
        onCollectionStateChanged?()
        defer {
            completions.removeAll()
            deletionInProgress = false
            start()
            onCollectionStateChanged?()
        }
        await cancelTransfersForDeletion()
        try openQueue()
        try eraseIfRequired()
        finishBackgroundWakeIfReady()
        try await operation()
    }

    private func cancelTransfersForDeletion() async {
        let knownTasks = (restoredTasks ?? []) + (currentTask.map { [$0] } ?? [])
        for task in knownTasks { task.cancel() }
        currentTask = nil

        // Inventory the session even before startup reconciliation has run.
        let tasks = knownTasks + (await session.allTasks)
        await withCheckedContinuation { continuation in
            let taskIDs = Set(tasks.filter { $0.state != .completed }.map(\.taskIdentifier))
            deletionCancellation = (taskIDs, continuation)
            for task in tasks { task.cancel() }
            advance()
        }
    }

    func handleBackgroundEvents(completionHandler: @escaping () -> Void) {
        backgroundHandlers.append(completionHandler)
        start()
    }

    private func openQueue() throws {
        guard queue == nil else { return }
        let opened = try RecordingDiagnosticOutbox(root: directory)
        let identity = try opened.beginLaunch()
        queue = opened
        self.identity = identity
        if onReady != nil {
            Task { @MainActor [weak self] in self?.onReady?() }
        }
    }

    private func eraseIfRequired() throws {
        guard mustErase else { return }
        currentTask?.cancel()
        currentTask = nil
        restoredTasks?.forEach { $0.cancel() }
        completions.removeAll()
        if let queue {
            try queue.clear()
            defaults.removeObject(forKey: eraseKey)
        }
    }

    fileprivate func advance() {
        retryTimer?.invalidate()
        retryTimer = nil
        let pendingErase = defaults.bool(forKey: eraseKey)
        defer {
            if pendingErase, canCollect { onCollectionStateChanged?() }
        }
        let events = delegate.takeEvents()
        completions.append(contentsOf: events.completions)
        finishedBackgroundEvents = finishedBackgroundEvents || events.finished
        if deletionInProgress {
            restoredTasks?.forEach { $0.cancel() }
            if let cancellation = deletionCancellation,
               cancellation.taskIDs.isSubset(of: Set(completions.map(\.taskIdentifier))) {
                deletionCancellation = nil
                cancellation.continuation.resume()
            }
            if !pendingErase { finishBackgroundWakeIfReady() }
            return
        }
        // Cancellation does not depend on reading protected files. Filter
        // restored task scope even when this account's outbox is inaccessible.
        if mustErase {
            currentTask?.cancel()
            currentTask = nil
        }
        if let restoredTasks {
            for task in restoredTasks where mustErase || task.taskDescription?.hasPrefix(namespace + ":") != true {
                task.cancel()
            }
        }

        do {
            try openQueue()
            try eraseIfRequired()
            guard let queue else { return }
            if let restoredTasks {
                restore(restoredTasks, queue: queue)
                self.restoredTasks = nil
                reconciled = true
            }
            guard reconciled else { return }

            // A restored task can finish before getAllTasks returns (and then
            // be absent from the inventory). Match its durable transfer token.
            while let completion = completions.first {
                try apply(completion, to: queue)
                completions.removeFirst()
            }
            try queue.finishDiscards()
            if enabled { try scheduleUpload(queue) }
            finishBackgroundWakeIfReady()
        } catch {
            reportStorageError(error)
            scheduleWake(after: 30)
        }
    }

    private func restore(_ tasks: [URLSessionTask], queue: RecordingDiagnosticOutbox) {
        let description = queue.currentBatch.flatMap(\.transferID).map(taskDescription)
        for task in tasks {
            guard !mustErase, let description, task.taskDescription == description,
                  currentTask == nil, task.state == .running || task.state == .suspended else {
                task.cancel()
                continue
            }
            currentTask = task
            if task.state == .suspended { task.resume() }
        }
    }

    private func scheduleUpload(_ queue: RecordingDiagnosticOutbox) throws {
        guard currentTask == nil, let batch = try queue.nextBatch(at: now()) else { return }
        let delay = batch.notBefore.timeIntervalSince(now())
        if !background && delay > 0 {
            scheduleWake(after: delay)
            return
        }
        let token = try queue.registerTransfer(batch)
        let task = session.uploadTask(with: request, fromFile: queue.payloadURL(batch))
        task.taskDescription = taskDescription(token)
        if delay > 0 { task.earliestBeginDate = batch.notBefore }
        currentTask = task
        task.resume()
    }

    private func apply(_ completion: RecordingDiagnosticSessionDelegate.Completion,
                       to queue: RecordingDiagnosticOutbox) throws {
        guard enabled, let batch = queue.currentBatch, let token = batch.transferID,
              completion.description == taskDescription(token),
              currentTask == nil || currentTask?.taskIdentifier == completion.taskIdentifier else { return }
        currentTask = nil

        if let endpoint = request.url, let response = completion.response, response.url == endpoint {
            if [400, 409, 413, 422].contains(response.statusCode) {
                try queue.resolve(batch, dropped: true)
                return
            }
            if completion.succeeded, (200..<300).contains(response.statusCode),
               let reportIDs = completion.acceptedIDs,
               reportIDs.count == batch.eventIDs.count, Set(reportIDs) == Set(batch.eventIDs) {
                try queue.resolve(batch, dropped: false)
                return
            }
        }
        try queue.retry(batch, at: now())
    }

    private func taskDescription(_ transferID: UUID) -> String { "\(namespace):\(transferID.uuidString)" }

    private func scheduleWake(after interval: TimeInterval) {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, interval), repeats: false) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }

    private func finishBackgroundWakeIfReady() {
        guard finishedBackgroundEvents, !backgroundHandlers.isEmpty else { return }
        finishedBackgroundEvents = false
        let handlers = backgroundHandlers
        backgroundHandlers.removeAll()
        for handler in handlers { handler() }
    }

    private func reportStorageError(_ error: Error) {
        BLEDiag.log("RECORDING_DIAGNOSTICS storage_error code=\(RecordingDiagnosticEvent.errorCode(error))")
    }
}

/// The serial URLSession delegate queues results before dispatching to the
/// main actor, so finish-events cannot overtake preceding task completions.
private final class RecordingDiagnosticSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Completion {
        let taskIdentifier: Int
        let description: String?
        let response: HTTPURLResponse?
        let succeeded: Bool
        let acceptedIDs: [UUID]?
    }

    private struct Receipt: Decodable {
        let acceptedIDs: [UUID]
        enum CodingKeys: String, CodingKey { case acceptedIDs = "accepted_ids" }
    }

    private enum Body {
        case data(Data)
        case oversized
    }

    weak var owner: RecordingDiagnosticSync?
    private let lock = NSLock()
    private var bodies: [Int: Body] = [:]
    private var completions: [Completion] = []
    private var finished = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            let key = dataTask.taskIdentifier
            switch bodies.removeValue(forKey: key) ?? .data(Data()) {
            case .data(var body) where body.count + data.count <= 8192:
                body.append(data)
                bodies[key] = .data(body)
            default:
                bodies[key] = .oversized
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock {
            var accepted: [UUID]?
            if case .data(let data) = bodies.removeValue(forKey: task.taskIdentifier) {
                accepted = (try? JSONDecoder().decode(Receipt.self, from: data))?.acceptedIDs
            }
            completions.append(Completion(taskIdentifier: task.taskIdentifier, description: task.taskDescription,
                                          response: task.response as? HTTPURLResponse,
                                          succeeded: error == nil, acceptedIDs: accepted))
        }
        notifyOwner()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.withLock { finished = true }
        notifyOwner()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func takeEvents() -> (completions: [Completion], finished: Bool) {
        lock.withLock {
            let result = (completions, finished)
            completions.removeAll()
            finished = false
            return result
        }
    }

    private func notifyOwner() {
        Task { @MainActor [weak self] in self?.owner?.advance() }
    }
}
