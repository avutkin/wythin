import XCTest
@testable import Wythin

final class PayloadBuilderTests: XCTestCase {

    func testMetricTrendPayloadMapsAllFields() {
        let trend = MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        let payload = MetricTrendPayload(from: trend)
        XCTAssertEqual(payload.start, 60)
        XCTAssertEqual(payload.end, 70)
        XCTAssertEqual(payload.min, 55)
        XCTAssertEqual(payload.max, 75)
        XCTAssertEqual(payload.mean, 65)
        XCTAssertEqual(payload.direction, "rising")
    }

    func testLiveStateInsightPayloadMapsModeWindowAndMetrics() {
        let trends: [String: MetricTrend] = [
            "hr": MetricTrend(start: 60, end: 70, min: 55, max: 75, mean: 65, direction: "rising")
        ]
        let payload = LiveStateInsightPayload(windowMinutes: 10, trends: trends)
        XCTAssertEqual(payload.mode, "live_state")
        XCTAssertEqual(payload.windowMinutes, 10)
        XCTAssertEqual(payload.metrics["hr"]?.direction, "rising")
        XCTAssertEqual(payload.metrics["hr"]?.mean, 65)
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
