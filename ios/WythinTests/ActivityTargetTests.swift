import XCTest
import SwiftData
@testable import Wythin

final class ActivityTargetTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    func testBeginStoresTarget() {
        let ctx = makeContext()
        let entry = ActivityLogging.begin(type: .meditation, subtype: "Vipassana",
                                          customName: nil, targetMinutes: 15, context: ctx)
        XCTAssertEqual(entry.targetMinutes, 15)
        XCTAssertTrue(entry.isActive)
    }

    func testBeginWithoutTargetLeavesItNil() {
        let ctx = makeContext()
        let entry = ActivityLogging.begin(type: .walk, subtype: nil,
                                          customName: nil, targetMinutes: nil, context: ctx)
        XCTAssertNil(entry.targetMinutes)
    }

    func testLogPastNeverSetsATarget() {
        // A retrospective entry has a real duration; a target is meaningless.
        let ctx = makeContext()
        let start = Date()
        ActivityLogging.logPast(type: .meal, subtype: "Lunch", customName: nil,
                                start: start, end: start.addingTimeInterval(1800),
                                context: ctx, client: NoopInsightClient())
        let all = try! ctx.fetch(FetchDescriptor<ActivityLog>())
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all[0].targetMinutes)
    }
}

/// Insight client that never returns — logPast fires generation in a detached
/// Task we don't await, so this just has to not make a network call.
/// InsightAPIClient (APIClient.swift:406) declares exactly these two methods.
private struct NoopInsightClient: InsightAPIClient {
    struct Stop: Error {}
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse { throw Stop() }
    func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse { throw Stop() }
}
