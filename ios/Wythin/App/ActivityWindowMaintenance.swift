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

    init(container: ModelContainer, work: @escaping Work = { container in
        let context = ModelContext(container)
        context.autosaveEnabled = false
        ActivityLog.migrate(context: context)
        ActivityLog.backfillMissingWindows(context: context)
    }) {
        self.container = container
        self.work = work
    }

    @discardableResult
    func request() -> Task<Void, Never> {
        pending = true
        if let task { return task }
        let task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            while self.pending {
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
