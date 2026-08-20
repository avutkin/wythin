import XCTest
import SwiftData
@testable import Wythin

final class InsightGeneratorTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private struct StubError: Error {}

    private final class FakeClient: InsightAPIClient, @unchecked Sendable {
        let result: Result<InsightResponse, Error>
        /// Which mode was actually asked for. A night sent down the activity
        /// path would still "succeed", so success is not evidence of routing.
        private(set) var activityCalls = 0
        private(set) var sleepCalls = 0
        private(set) var lastNight: SleepInsightPayload?

        init(result: Result<InsightResponse, Error>) { self.result = result }

        func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
            activityCalls += 1
            return try result.get()
        }
        func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse {
            try result.get()
        }
        func generateSleepInsight(_ payload: SleepInsightPayload) async throws -> InsightResponse {
            sleepCalls += 1
            lastNight = payload
            return try result.get()
        }
    }

    @MainActor
    func testGenerateSetsInsightTextOnSuccess() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let generator = InsightGenerator(client: FakeClient(result: .success(InsightResponse(text: "Nice recovery."))))
        await generator.generate(for: entry, context: context)

        XCTAssertEqual(entry.insightText, "Nice recovery.")
    }

    @MainActor
    func testGenerateLeavesInsightTextNilOnFailure() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let generator = InsightGenerator(client: FakeClient(result: .failure(StubError())))
        await generator.generate(for: entry, context: context)

        XCTAssertNil(entry.insightText)
    }

    @MainActor
    func testFlushPendingGeneratesForAllPendingActivities() async {
        let context = makeContext()
        let a = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        let b = ActivityLog(activityType: "Walk",
                             startedAt: .now.addingTimeInterval(60),
                             endedAt: .now.addingTimeInterval(90), isManual: true)
        context.insert(a)
        context.insert(b)

        let generator = InsightGenerator(client: FakeClient(result: .success(InsightResponse(text: "Solid."))))
        await generator.flushPending(context: context)

        XCTAssertEqual(a.insightText, "Solid.")
        XCTAssertEqual(b.insightText, "Solid.")
    }

    @MainActor
    func testPendingActivitiesFiltersEndedAndMissingInsight() {
        let context = makeContext()

        let notEnded = ActivityLog(activityType: "Walk", startedAt: .now, isManual: false)
        let alreadyInsighted = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        alreadyInsighted.insightText = "Already have one."
        let pending = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)

        context.insert(notEnded)
        context.insert(alreadyInsighted)
        context.insert(pending)

        let result = InsightGenerator.pendingActivities(context: context)

        XCTAssertEqual(result.map(\.id), [pending.id])
    }

    @MainActor
    func testPendingActivitiesOrdersMostRecentFirstAndCaps() {
        let context = makeContext()
        let base = Date()
        var entries: [ActivityLog] = []
        for i in 0..<12 {
            let entry = ActivityLog(activityType: "Walk",
                                     startedAt: base.addingTimeInterval(TimeInterval(i) * 60),
                                     endedAt: base.addingTimeInterval(TimeInterval(i) * 60 + 30),
                                     isManual: true)
            context.insert(entry)
            entries.append(entry)
        }

        let result = InsightGenerator.pendingActivities(context: context, limit: 10)

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first?.id, entries.last?.id)
    }

    // MARK: - Sleep is not an activity

    /// A night has no before / during / after — it is not a session someone
    /// started. Sent down the activity path it produced a confident paragraph
    /// from an all-nil payload, burned an API call, and stored the result in
    /// the same field the night read needs. It has its own mode; the sweep must
    /// leave it alone.

    @MainActor
    func testFlushPendingSkipsSleepNights() async {
        let context = makeContext()
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: .now, endedAt: .now, isManual: false)
        context.insert(night)

        let client = FakeClient(result: .success(InsightResponse(text: "Solid.")))
        await InsightGenerator(client: client).flushPending(context: context)

        XCTAssertEqual(client.activityCalls, 0, "a night must never go down the activity path")
        XCTAssertNil(night.insightText)
    }

    @MainActor
    func testPendingActivitiesExcludesSleep() {
        let context = makeContext()
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: .now, endedAt: .now, isManual: false)
        let walk = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(night)
        context.insert(walk)

        let pending = InsightGenerator.pendingActivities(context: context)

        XCTAssertEqual(pending.map(\.activityType), ["Walk"])
    }

    @MainActor
    func testGenerateForNightUsesTheSleepMode() async {
        let context = makeContext()
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: .now.addingTimeInterval(-8 * 3600),
                                endedAt: .now, isManual: false)
        night.sleepAsleepMinutes = 400
        context.insert(night)

        let client = FakeClient(result: .success(InsightResponse(text: "A broken night.")))
        await InsightGenerator(client: client)
            .generate(for: night, night: PreparedNight(points: []), context: context)

        XCTAssertEqual(client.sleepCalls, 1)
        XCTAssertEqual(client.activityCalls, 0)
        XCTAssertEqual(night.sleepReadText, "A broken night.")
        XCTAssertEqual(client.lastNight?.mode, "sleep")
    }

    @MainActor
    func testGenerateForNightSkipsANightWithNoMeasuredSleep() async {
        let context = makeContext()
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: .now.addingTimeInterval(-8 * 3600),
                                endedAt: .now, isManual: false)
        night.sleepAsleepMinutes = 0
        context.insert(night)

        let client = FakeClient(result: .success(InsightResponse(text: "x")))
        await InsightGenerator(client: client)
            .generate(for: night, night: PreparedNight(points: []), context: context)

        XCTAssertEqual(client.sleepCalls, 0, "an empty window is not a night to narrate")
        XCTAssertNil(night.sleepReadText)
    }

    /// Every night already on a device carries an `insightText` written by the
    /// activity prompt from an all-nil payload, because the sweep used to pick
    /// nights up. It is not a read of the night and must not be treated as one.
    @MainActor
    func testAStaleActivityEraInsightDoesNotCountAsTheNightRead() async {
        let context = makeContext()
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: .now.addingTimeInterval(-8 * 3600),
                                endedAt: .now, isManual: false)
        night.sleepAsleepMinutes = 400
        night.insightText = "Solid session — your RSA improved nicely."
        context.insert(night)

        let client = FakeClient(result: .success(InsightResponse(text: "A broken night.")))
        await InsightGenerator(client: client)
            .generate(for: night, night: PreparedNight(points: []), context: context)

        XCTAssertEqual(client.sleepCalls, 1, "the stale text must not suppress the real read")
        XCTAssertEqual(night.sleepReadText, "A broken night.")
    }

    @MainActor
    func testGenerateForNightDoesNotClobberAnExistingRead() async {
        let context = makeContext()
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue,
                                startedAt: .now.addingTimeInterval(-8 * 3600),
                                endedAt: .now, isManual: false)
        night.sleepAsleepMinutes = 400
        night.sleepReadText = "already read"
        context.insert(night)

        let client = FakeClient(result: .success(InsightResponse(text: "new")))
        await InsightGenerator(client: client)
            .generate(for: night, night: PreparedNight(points: []), context: context)

        XCTAssertEqual(night.sleepReadText, "already read")
    }
}
