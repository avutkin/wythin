import Foundation
import Observation
import SwiftData
import SwiftUI
import UIKit

/// An open failure is not proof of an incompatible store. In particular, a
/// protected device or full disk must never cause history to be set aside.
enum AppStoreBootstrap {
    static var schema: Schema {
        Schema([HRVSession.self, HRVSample.self, ResonanceResult.self, TrainSession.self,
                ActivityLog.self, DailyAnchor.self, UsageEventLog.self, FeltStateLog.self,
                SleepWindowOverride.self])
    }

    static func configuration() -> ModelConfiguration {
        ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
    }

    static func open(configuration: ModelConfiguration,
                     makeContainer: (ModelConfiguration) throws -> ModelContainer = {
                         try ModelContainer(for: schema, configurations: [$0])
                     }) throws -> ModelContainer {
        try makeContainer(configuration)
    }

    static func load(configuration: ModelConfiguration? = nil) async throws -> ModelContainer {
        try await Task.detached(priority: .userInitiated) {
            try open(configuration: configuration ?? self.configuration())
        }.value
    }
}

/// Begins from App.init, not View.task: background restoration may never
/// create a visible scene. A failed attempt is retryable; success is terminal.
@MainActor @Observable
final class AppStartup<Value> {
    private(set) var value: Value?
    private(set) var error: Error?
    private(set) var isLoading = false
    @ObservationIgnored private var allowance = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var unlockedDuringAttempt = false
    @ObservationIgnored private let load: @MainActor () async throws -> Value
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private let backgroundEvents: StartupBackgroundEvents
    @ObservationIgnored private let beginAllowance: (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier
    @ObservationIgnored private let endAllowance: (UIBackgroundTaskIdentifier) -> Void

    init(notifications: NotificationCenter = .default,
         backgroundEvents: StartupBackgroundEvents? = nil,
         beginAllowance: @escaping (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
             UIApplication.shared.beginBackgroundTask(withName: "Open saved recordings", expirationHandler: $0)
         },
         endAllowance: @escaping (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) },
         load: @escaping @MainActor () async throws -> Value) {
        self.notifications = notifications
        self.backgroundEvents = backgroundEvents ?? StartupBackgroundEvents()
        self.beginAllowance = beginAllowance
        self.endAllowance = endAllowance
        self.load = load
        unlockObserver = notifications.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isLoading { self.unlockedDuringAttempt = true }
                else if self.error != nil { self.start() }
            }
        }
    }

    deinit {
        if let unlockObserver { notifications.removeObserver(unlockObserver) }
        task?.cancel()
    }

    func start() {
        guard value == nil, task == nil else { return }
        isLoading = true
        error = nil
        unlockedDuringAttempt = false
        backgroundEvents.beginAttempt()
        // Acquire before the first suspension: BLE restoration must not depend
        // on a visible scene or a fast database open. UIKit bounds this lease.
        allowance = beginAllowance { [weak self] in
            guard let self else { return }
            self.finishAllowance()
            self.backgroundEvents.failAttempt()
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isLoading = false
                self.task = nil
                self.finishAllowance()
                if self.error != nil && self.unlockedDuringAttempt { self.start() }
            }
            do {
                self.value = try await self.load()
                self.backgroundEvents.succeedAttempt()
            }
            catch {
                self.error = error
                self.backgroundEvents.failAttempt()
                let ns = error as NSError
                BLEDiag.log("STARTUP store open failed code=\(ns.code)")
            }
        }
    }
    private func finishAllowance() {
        let identifier = allowance
        allowance = .invalid
        if identifier != .invalid { endAllowance(identifier) }
    }
}

struct StartupUnavailableView: View {
    let retry: () -> Void

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 36)).foregroundStyle(Theme.accent)
                Text("Your saved data couldn't be opened")
                    .font(.headline).multilineTextAlignment(.center)
                Text("Your recordings haven't been removed. Unlock your iPhone, check that it has free storage, and try again.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again", action: retry)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            .padding(28)
        }
        .preferredColorScheme(.dark)
    }
}

/// Owns only OS wake completion callbacks, never upload files or acknowledgments.
@MainActor
final class StartupBackgroundEvents {
    static let shared = StartupBackgroundEvents()
    private var unavailable = false
    private var pending: [UUID: () -> Void] = [:]

    func beginAttempt() { unavailable = false }
    func succeedAttempt() { unavailable = false }
    func failAttempt() {
        unavailable = true
        let callbacks = Array(pending.values)
        pending.removeAll()
        callbacks.forEach { $0() }
    }

    func receive(completion: @escaping () -> Void, route: (@escaping () -> Void) -> Void) {
        guard !unavailable else { completion(); return }
        let id = UUID()
        pending[id] = completion
        route { [weak self] in
            self?.pending.removeValue(forKey: id)?()
        }
    }
}

@MainActor
struct StartupSceneDelivery {
    private var lastEnvironment: ObjectIdentifier?
    private var lastPhase: ScenePhase?

    mutating func shouldDeliver(_ phase: ScenePhase, to environment: AnyObject) -> Bool {
        let identity = ObjectIdentifier(environment)
        guard lastEnvironment != identity || lastPhase != phase else { return false }
        lastEnvironment = identity
        lastPhase = phase
        return true
    }
}

/// Owns optional UI preparation, not recording. Cancellation retains ownership
/// until an uncancellable store read drains; re-entry cannot double peak memory.
@MainActor
final class ForegroundPreparation {
    private var foreground = false
    private var completed = false
    private var generation = 0
    private var task: Task<Void, Never>?
    private let operation: @MainActor () async -> Void

    init(operation: @escaping @MainActor () async -> Void) { self.operation = operation }
    deinit { task?.cancel() }

    func setForeground(_ value: Bool) {
        foreground = value
        if !value { task?.cancel() }
        else { startIfNeeded() }
    }

    func invalidate() {
        completed = false
        generation += 1
        task?.cancel()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard foreground, !completed, task == nil else { return }
        let generation = generation
        task = Task { [weak self] in
            guard let self else { return }
            if !Task.isCancelled { await self.operation() }
            if !Task.isCancelled, self.foreground, self.generation == generation {
                self.completed = true
            }
            self.task = nil
            self.startIfNeeded()
        }
    }
}
