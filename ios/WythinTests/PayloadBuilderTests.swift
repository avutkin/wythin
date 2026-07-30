import XCTest
@testable import Wythin

final class PayloadBuilderTests: XCTestCase {

    func testMetricTrendPayloadMapsAllFields() {
        let trend = MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65,
                                direction: "rising", dayMean: 64,
                                buckets: [60, 63, 66, 68, 70], slopePct: 16.7,
                                volatility: "moderate", shape: "steady-rise")
        let payload = MetricTrendPayload(from: trend)
        XCTAssertEqual(payload.now, 70)
        XCTAssertEqual(payload.min, 55)
        XCTAssertEqual(payload.max, 75)
        XCTAssertEqual(payload.buckets, [60, 63, 66, 68, 70])
        XCTAssertEqual(payload.slopePct ?? 0, 16.7, accuracy: 0.01)
        XCTAssertEqual(payload.volatility, "moderate")
        XCTAssertEqual(payload.shape, "steady-rise")
    }

    func testLiveStateInsightPayloadMapsModeWindowAndMetrics() {
        let trends: [String: MetricTrend] = [
            "hr": MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        ]
        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
        XCTAssertEqual(payload.mode, "live_state")
        XCTAssertEqual(payload.windowMinutes, 10)
        XCTAssertEqual(payload.metrics["hr"]?.now, 70)
        XCTAssertEqual(payload.metrics["hr"]?.max, 75)
    }

    func testTokenCreatedDecodesSnakeCase() throws {
        let json = """
        {"token":"wyth_pat_abc","id":"11111111-1111-1111-1111-111111111111","name":"iPhone","created_at":"2026-07-27T01:00:00Z"}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(TokenCreated.self, from: json)
        XCTAssertEqual(t.token, "wyth_pat_abc")
        XCTAssertEqual(t.id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(t.name, "iPhone")
        XCTAssertEqual(t.createdAt, "2026-07-27T01:00:00Z")
    }

    func testTokenInfoDecodesNullsAndSnakeCase() throws {
        let json = """
        [{"id":"22222222-2222-2222-2222-222222222222","name":null,"created_at":"2026-07-27T01:00:00Z","last_used_at":null}]
        """.data(using: .utf8)!
        let list = try JSONDecoder().decode([TokenInfo].self, from: json)
        XCTAssertEqual(list.count, 1)
        XCTAssertNil(list[0].name)
        XCTAssertNil(list[0].lastUsedAt)
        XCTAssertEqual(list[0].createdAt, "2026-07-27T01:00:00Z")
    }

    func testClaudeCommandString() {
        let url = URL(string: "https://api.example.com")!
        let cmd = MCPSetup.claudeCommand(serverURL: url, token: "wyth_pat_xyz")
        XCTAssertEqual(cmd, "claude mcp add --transport http wythin https://api.example.com/mcp --header \"Authorization: Bearer wyth_pat_xyz\"")
    }

    func testClaudeCommandStripsTrailingSlash() {
        let url = URL(string: "https://api.example.com/")!
        let cmd = MCPSetup.claudeCommand(serverURL: url, token: "t")
        XCTAssertTrue(cmd.contains("https://api.example.com/mcp"))
        XCTAssertFalse(cmd.contains(".com//mcp"))
    }
}

// MARK: - Day Potential + bucketed live state

extension PayloadBuilderTests {

    func testLiveStatePayloadOmitsDayMean() throws {
        let trend = MetricTrend(start: 70, end: 68, min: 67, max: 74, mean: 70,
                                direction: "falling", dayMean: 71,
                                buckets: [74, 72, 70, 69, 68], slopePct: -8.1,
                                volatility: "low", shape: "steady-fall")
        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: ["hr": trend])
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("day_mean"), "day_mean must not cross the network")
        XCTAssertTrue(json.contains("buckets"))
        XCTAssertTrue(json.contains("steady-fall"))
    }

    func testDayPotentialPayloadEncodesScoreAndStreak() throws {
        let payload = DayPotentialPayload(
            score: 72, band: "good",
            anchorHour: 7.2, anchorDurationMin: 5, late: false, confidence: "high",
            components: ["recovery_capacity": MetricComponentPayload(z: 0.8, level: "top of usual")],
            modifiers: ["fragmentation": 0],
            baselineAnchors: 41, baselineTarget: 7, baselineSufficient: true,
            provisional: false,
            recent: [64, 58, 61, 66, 69, 70, 72],
            streakCurrent: 4, streakBest: 6, graceUsed: false)
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"mode\":\"day_potential\""))
        XCTAssertTrue(json.contains("\"score\":72"))
        XCTAssertTrue(json.contains("streak_current"))
    }

    /// The server branches on this to decide whether it may claim norms, so it
    /// has to survive encoding under the snake_case key the API expects.
    func testDayPotentialPayloadEncodesProvisional() throws {
        let payload = DayPotentialPayload(
            score: 61, band: "good",
            anchorHour: 7.2, anchorDurationMin: 5, late: false, confidence: "high",
            components: [:], modifiers: [:],
            baselineAnchors: 3, baselineTarget: 7, baselineSufficient: false,
            provisional: true,
            recent: [58, 61],
            streakCurrent: 3, streakBest: 3, graceUsed: false)
        let json = String(data: try JSONEncoder().encode(payload), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"provisional\":true"))
        XCTAssertTrue(json.contains("\"baseline_sufficient\":false"))
    }
}
