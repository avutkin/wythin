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

    // MARK: - MacroTrendPayload

    func testMacroTrendPayloadEncodesSnakeCaseKeys() throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let range = TrackRangeBuilder.range(period: .week, offset: 0, today: today)
        let spec  = TrackMetrics.all.first { $0.def.label == "Inner Noise" }!

        let series = TrackSeries(
            bars: [], average: 52, deltaPct: 9, reference: 57,
            referenceIsPersonal: true,
            betterCount: 6, presentCount: 7,
            referenceLines: [],
            summary: "6 of 7 days better than your baseline.")

        let payload = MacroTrendPayload(period: .week, rangeLabel: range.label,
                                        series: [(spec, series)])
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)) as! [String: Any]

        XCTAssertEqual(json["mode"] as? String, "macro_trend")
        XCTAssertEqual(json["period"] as? String, "week")
        XCTAssertNotNil(json["range_label"])

        let trends = json["trends"] as! [String: [String: Any]]
        let pip = try XCTUnwrap(trends["pip"])
        XCTAssertEqual(pip["avg"] as? Double, 52)
        XCTAssertEqual(pip["baseline"] as? Double, 57)
        XCTAssertEqual(pip["delta_pct"] as? Double, 9)
        XCTAssertEqual(pip["days_above"] as? Int, 6)
        XCTAssertEqual(pip["days_total"] as? Int, 7)
        XCTAssertEqual(pip["direction"] as? String, "lower")
        XCTAssertEqual(pip["baseline_is_personal"] as? Bool, true)
    }

    /// When the person doesn't yet have enough of their own history,
    /// `TrackSeriesBuilder.baseline` falls back to a generic physiological
    /// norm and marks `referenceIsPersonal` false. That flag must cross the
    /// wire so the server never narrates a generic norm as personal history.
    func testMacroTrendPayloadEncodesBaselineIsPersonalFalse() throws {
        let spec = TrackMetrics.all.first { $0.def.label == "Inner Noise" }!
        let series = TrackSeries(
            bars: [], average: 52, deltaPct: 9, reference: 55,
            referenceIsPersonal: false,
            betterCount: 3, presentCount: 6,
            referenceLines: [],
            summary: "3 of 6 days better than typical.")

        let payload = MacroTrendPayload(period: .week, rangeLabel: "X",
                                        series: [(spec, series)])
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(payload)) as! [String: Any]
        let trends = json["trends"] as! [String: [String: Any]]
        let pip = try XCTUnwrap(trends["pip"])
        XCTAssertEqual(pip["baseline_is_personal"] as? Bool, false)
    }

    func testMacroTrendPayloadSkipsMetricsWithNoAverage() throws {
        let empty = TrackSeries(bars: [], average: nil, deltaPct: nil, reference: 8,
                                referenceIsPersonal: false,
                                betterCount: 0, presentCount: 0,
                                referenceLines: [],
                                summary: "No data this period.")
        let payload = MacroTrendPayload(
            period: .week, rangeLabel: "X",
            series: [(TrackMetrics.all[0], empty)])
        XCTAssertTrue(payload.trends.isEmpty)
    }

    func testMacroTrendDirectionStrings() throws {
        func direction(_ label: String) -> String? {
            let spec = TrackMetrics.all.first { $0.def.label == label }!
            let s = TrackSeries(bars: [], average: 1, deltaPct: nil, reference: 1,
                                referenceIsPersonal: false,
                                betterCount: 0, presentCount: 1, referenceLines: [], summary: "")
            return MacroTrendPayload(period: .week, rangeLabel: "X",
                                     series: [(spec, s)]).trends[spec.trendKey]?.direction
        }
        XCTAssertEqual(direction("Vagal Tone"), "higher")
        XCTAssertEqual(direction("Inner Noise"), "lower")
        XCTAssertEqual(direction("Harmony"), "target")
    }
}
