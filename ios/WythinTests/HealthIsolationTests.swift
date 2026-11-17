import XCTest
import SwiftData
@testable import Wythin

final class HealthIsolationTests: XCTestCase {
    @MainActor func testImportedActivitiesNeverEnterAutomaticAIQueue() throws {
        let container = try ModelContainer(for: ActivityLog.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let imported = ActivityLog(activityType: "Exercise", startedAt: .now.addingTimeInterval(-120), endedAt: .now)
        imported.origin = "apple_health"; imported.externalWorkoutID = UUID().uuidString
        let manual = ActivityLog(activityType: "Exercise", startedAt: .now.addingTimeInterval(-600), endedAt: .now.addingTimeInterval(-300))
        context.insert(imported); context.insert(manual); try context.save()
        let pending = InsightGenerator.pendingActivities(context: context, limit: 1)
        XCTAssertEqual(pending.map(\.id), [manual.id])
    }
    @MainActor func testHealthOriginPersistsWithoutChangingExistingActivityFields() throws {
        let container = try ModelContainer(for: ActivityLog.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let manual = ActivityLog(activityType: "Exercise", startedAt: .now, endedAt: .now, isManual: true)
        manual.notes = "Keep this"; manual.beforeRMSSD = 42
        let imported = ActivityLog(activityType: "Exercise", startedAt: .now, endedAt: .now, isManual: true)
        imported.origin = "apple_health"; imported.externalWorkoutID = UUID().uuidString
        context.insert(manual); context.insert(imported); try context.save()
        let reloaded = try ModelContext(container).fetch(FetchDescriptor<ActivityLog>())
        XCTAssertEqual(reloaded.filter(\.isHealthImported).count, 1)
        XCTAssertEqual(reloaded.first { !$0.isHealthImported }?.notes, "Keep this")
        XCTAssertEqual(reloaded.first { !$0.isHealthImported }?.beforeRMSSD, 42)
    }
}
