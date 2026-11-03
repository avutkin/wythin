import XCTest
@testable import Wythin

final class ActivityRestoreTests: XCTestCase {

    /// Built by decoding the wire JSON rather than by calling the memberwise
    /// init, so these tests also pin the server's field names.
    private func payload(id: String = UUID().uuidString,
                         started: String = "2026-08-09T18:20:00Z",
                         ended: String? = "2026-08-09T18:53:00Z") -> ActivityUploadPayload {
        let endedJSON = ended.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"id":"\(id)","activity_type":"Exercise","activity_subtype":"Powerlifting",
         "custom_name":null,"started_at":"\(started)","ended_at":\(endedJSON),
         "is_manual":false,"impact_delta_pct":null,"notes":"note",
         "before_hr":62,"during_hr":132,"after_hr":84,
         "before_rmssd":42,"during_rmssd":6,"after_rmssd":21,
         "before_dc":16,"during_dc":3.2,"after_dc":9.8}
        """
        return try! JSONDecoder().decode(ActivityUploadPayload.self,
                                         from: Data(json.utf8))
    }

    func testAServerRowComesBackAsAnEntry() {
        let entry = ActivityRestore.make(from: payload())
        XCTAssertEqual(entry?.activityType, "Exercise")
        XCTAssertEqual(entry?.activitySubtype, "Powerlifting")
        XCTAssertEqual(entry?.beforeHR, 62)
        XCTAssertEqual(entry?.afterDC, 9.8)
        XCTAssertNotNil(entry?.endedAt)
    }

    func testIdentityIsPreservedSoAReuploadUpsertsRatherThanDuplicating() {
        let id = UUID()
        XCTAssertEqual(ActivityRestore.make(from: payload(id: id.uuidString))?.id, id)
    }

    func testBothISOShapesTheServerSendsAreAccepted() {
        // Some rows carry fractional seconds and some do not; dropping either
        // would silently lose half the history.
        XCTAssertNotNil(ActivityRestore.iso("2026-08-09T18:20:00Z"))
        XCTAssertNotNil(ActivityRestore.iso("2026-08-09T18:20:00.123Z"))
    }

    func testARowWithNoStartTimeIsSkippedRatherThanGuessed() {
        XCTAssertNil(ActivityRestore.make(from: payload(started: "not a date")))
    }

    func testAnUnfinishedRowStillRestores() {
        let entry = ActivityRestore.make(from: payload(ended: nil))
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.endedAt)
    }

    func testDerivedFieldsAreLeftForTheBackfillToRecompute() {
        // The server holds window averages only. A restored session must be
        // scored by this build's arithmetic, not by whatever produced it.
        let entry = ActivityRestore.make(from: payload())
        XCTAssertNil(entry?.exerciseLoad)
        XCTAssertNil(entry?.suppressionScore)
        XCTAssertNil(entry?.readinessScore)
    }

    // MARK: - Nights

    private static let nightJSON = """
    {"id":"1C5B6A2E-0000-4000-8000-000000000001","activity_type":"Sleep","activity_subtype":null,
     "custom_name":null,"started_at":"2026-08-09T23:00:00Z","ended_at":"2026-08-10T06:52:00Z",
     "is_manual":false,"impact_delta_pct":null,"notes":null,
     "before_hr":58,"during_hr":52,"after_hr":60,
     "sleep":{"score":72,"arithmetic":"72 = 25%·65 + 25%·80","stage_summary":"6h 02m quiet · 1h 20m active · 0h 30m awake",
              "asleep_min":442,"in_bed_min":472,"regularity":81,"algorithm_version":13,"read_text":null,
              "sections":{"timing":65,"duration":80,"continuity":null,"autonomic":75,"breathing":70},
              "stages":{"wake":30,"rem":90,"n1":40,"n2":240,"n3":72},
              "parts":{"duration":[{"label":"Against your need","value":-3600,"display":"1h 0m short","worstLabel":"2h30m short","bestLabel":"met","worst":-9000,"best":0,"score":60,"weight":1}]},
              "quiet_rmssd":41.5,"quiet_dc":7.9,
              "wake_bouts":3,"longest_unbroken_min":210,"longest_wake_min":12,
              "lowest_hr":47,"lowest_hr_at":"2026-08-10T03:10:00Z","position_recorded":true,
              "positions":[{"position":"Left side","minutes":250}],
              "position_bands":[{"position":"Left side","start":"2026-08-09T23:00:00Z","end":"2026-08-10T03:10:00Z"}],
              "stage_runs":[{"stage":"n2","start":"2026-08-09T23:00:00Z","end":"2026-08-10T00:00:00Z"}]}}
    """

    func testANightComesBackWithItsScoreSectionsAndDetail() {
        let p = try! JSONDecoder().decode(ActivityUploadPayload.self, from: Data(Self.nightJSON.utf8))
        guard let entry = ActivityRestore.make(from: p) else { return XCTFail("no entry") }
        XCTAssertEqual(entry.sleepScore, 72)
        XCTAssertEqual(entry.sleepAsleepMinutes, 442)
        XCTAssertEqual(entry.sleepTiming, 65)
        XCTAssertNil(entry.sleepContinuity, "an absent section stays absent, never 0")
        XCTAssertEqual(entry.sleepDeepMinutes, 72)
        XCTAssertEqual(entry.sleepAlgorithmVersion, 13,
                       "restored with its version, or the recorder purges it and cannot rebuild it")
        let parts = SleepScore.parts(fromJSON: entry.sleepPartsJSON)
        XCTAssertEqual(parts[.duration]?.first?.label, "Against your need", "the working comes back with the night")
        XCTAssertEqual(entry.sleepQuietDC, 7.9)
        let detail = SleepNightDetail(json: entry.sleepDetailJSON)
        XCTAssertEqual(detail?.wakeBouts, 3)
        XCTAssertEqual(detail?.positions.first?.position, "Left side")
        XCTAssertEqual(detail?.stageRuns.first?.stage, "n2")
    }

    func testOnlyANightCarriesASleepBlockOnTheWayUp() throws {
        let sit = ActivityLog(activityType: "Meditation", startedAt: .now)
        sit.endedAt = .now
        let night = ActivityLog(activityType: ActivityType.sleep.rawValue, startedAt: .now.addingTimeInterval(-8 * 3600))
        night.endedAt = .now
        night.sleepScore = 64
        night.sleepAlgorithmVersion = SleepThresholds.algorithmVersion
        night.sleepDetailJSON = SleepNightDetail(
            wakeBouts: 2, longestUnbrokenMin: 180, longestWakeMin: 9, lowestHR: 49, lowestHRAt: nil,
            positionRecorded: false, positions: [], positionBands: [], stageRuns: []).json

        let enc = JSONEncoder()
        let sitJSON = String(decoding: try enc.encode(ActivityUploadPayload(from: sit)), as: UTF8.self)
        let nightJSON = String(decoding: try enc.encode(ActivityUploadPayload(from: night)), as: UTF8.self)
        XCTAssertFalse(sitJSON.contains("\"score\""), "a practice has no night")
        XCTAssertTrue(nightJSON.contains("\"score\":64"))
        XCTAssertTrue(nightJSON.contains("\"in_bed_min\":480"))
        XCTAssertTrue(nightJSON.contains("\"wake_bouts\":2"))
        XCTAssertTrue(nightJSON.contains("\"position_recorded\":false"))
    }

    /// Every upload names the phone's zone, so the dashboard can show the
    /// activity in the clock it happened in rather than the viewer's.
    func testEveryUploadNamesThePhonesTimeZone() throws {
        let sit = ActivityLog(activityType: "Meditation", startedAt: .now)
        let enc = JSONEncoder(); enc.outputFormatting = .withoutEscapingSlashes
        let json = String(decoding: try enc.encode(ActivityUploadPayload(from: sit)), as: UTF8.self)
        XCTAssertTrue(json.contains("\"timezone\":\"\(TimeZone.current.identifier)\""), json)
        XCTAssertFalse(TimeZone.current.identifier.isEmpty)

        // A row the server holds from before zones were sent comes back
        // without one, and restore must still read it.
        let old = Data(#"{"id":"A","activity_type":"Meditation","started_at":"2026-01-01T00:00:00Z","is_manual":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ActivityUploadPayload.self, from: old).timezone)
    }
}
