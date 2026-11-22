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
    @ObservationIgnored private let load: @MainActor () async throws -> Value
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private let notifications: NotificationCenter

    init(notifications: NotificationCenter = .default,
         load: @escaping @MainActor () async throws -> Value) {
        self.notifications = notifications
        self.load = load
        unlockObserver = notifications.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.error != nil else { return }
                self.start()
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
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoading = false; self.task = nil }
            do { self.value = try await self.load() }
            catch {
                self.error = error
                let ns = error as NSError
                BLEDiag.log("STARTUP store open failed code=\(ns.code)")
            }
        }
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
