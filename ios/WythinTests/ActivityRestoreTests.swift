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
}
