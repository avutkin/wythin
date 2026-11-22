import Foundation
import SwiftData

/// Launch and foreground events only enqueue work. A detached worker owns its
/// SwiftData context; migration and ongoing repair never overlap each other.
@MainActor
final class ActivityWindowMaintenance {
    typealias Work = @Sendable (ModelContainer) throws -> Void
    private let container: ModelContainer
    private let work: Work
    private var task: Task<Void, Never>?
    private var pending = false
    private var editsWaiting = 0

    init(container: ModelContainer, work: @escaping Work = { container in
        let context = ModelContext(container)
        context.autosaveEnabled = false
        ActivityLog.migrate(context: context)
        ActivityLog.backfillMissingWindows(context: context)
    }) {
        self.container = container
        self.work = work
    }

    /// A user edit must follow the worker that read the old interval. Awaiting
    /// it keeps the UI responsive; pause follow-up passes until edits finish.
    func performEdit(_ edit: @MainActor () async -> Void) async {
        editsWaiting += 1
        if let task { await task.value }
        await edit()
        editsWaiting -= 1
        if editsWaiting == 0 && pending { request() }
    }

    @discardableResult
    func request() -> Task<Void, Never> {
        pending = true
        if let task { return task }
        guard editsWaiting == 0 else { return Task {} }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            while self.pending && self.editsWaiting == 0 {
                self.pending = false
                let container = self.container, work = self.work
                let result = await Task.detached(priority: .utility) {
                    Result { try autoreleasepool { try work(container) } }
                }.value
                if case .failure(let error) = result {
                    BLEDiag.log("ACTIVITY maintenance failed code=\((error as NSError).code); retry on next request")
                }
            }
        }
        self.task = task
        return task
    }
}
