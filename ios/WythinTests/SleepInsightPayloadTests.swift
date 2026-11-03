import XCTest
@testable import Wythin

/// What one night looks like on the way to the model.
///
/// The payload is the whole of what the read is built from, so every claim the
/// read can make has to be traceable to a field here — and every field has to
/// mean what its name says, because nothing downstream can check it.
final class SleepInsightPayloadTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 1_755_000_000)

    /// A night of `count` ticks 30 s apart, with Pulse falling linearly from
    /// `hrFrom` to `hrTo` so the two halves are unambiguously different.
    private func points(count: Int,
                        hrFrom: Float = 62,
                        hrTo: Float = 54,
                        position: BodyPosition? = nil) -> [MetricsHistoryPoint] {
        (0..<count).map { i in
            let t = Float(i) / Float(max(1, count - 1))
            return MetricsHistoryPoint(
                anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                meanBPM: hrFrom + (hrTo - hrFrom) * t,
                vti: 3.6, dc: 7, pip: 40, dfa1: 1.0,
                breathBPM: 13, motion: 5, bodyPosition: position,
                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    /// Ticks 30 s apart holding each position for the given number of ticks.
    private func positioned(_ spec: [(BodyPosition?, Int)]) -> [MetricsHistoryPoint] {
        var out: [MetricsHistoryPoint] = []
        var i = 0
        for (pos, count) in spec {
            for _ in 0..<count {
                out.append(MetricsHistoryPoint(
                    anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                    meanBPM: 58, vti: 3.6, dc: 7, pip: 40, dfa1: 1.0,
                    breathBPM: 13, motion: 5, bodyPosition: pos,
                    signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2))
                i += 1
            }
        }
        return out
    }

    private func night(_ pts: [MetricsHistoryPoint]) -> PreparedNight {
        PreparedNight(points: pts)
    }

    private func entry(asleep: Int? = 400, hours: Double = 8) -> ActivityLog {
        let log = ActivityLog(activityType: ActivityType.sleep.rawValue,
                              startedAt: start,
                              endedAt: start.addingTimeInterval(hours * 3600),
                              isManual: false)
        log.sleepAsleepMinutes = asleep
        return log
    }

    // MARK: - When there is nothing to read

    func testANightStillRunningProducesNoPayload() {
        let log = entry()
        log.endedAt = nil
        XCTAssertNil(SleepInsightPayload(entry: log, night: night(points(count: 60))))
    }

    func testAWindowWithNoMeasuredSleepProducesNoPayload() {
        // Not a thin night — an absent one. Asking for a read on it returns a
        // confident paragraph about nothing.
        XCTAssertNil(SleepInsightPayload(entry: entry(asleep: 0),
                                         night: night(points(count: 60))))
    }

    // MARK: - The shape of the night

    func testCarriesTheDurationPairNotJustTimeAsleep() {
        // The gap between them IS the time awake, which is the disclosure the
        // whole night screen exists to make.
        let p = SleepInsightPayload(entry: entry(), night: night(points(count: 60)))
        XCTAssertEqual(p?.sleep.asleepMin, 400)
        XCTAssertEqual(p?.sleep.inBedMin, 480)
    }

    func testModeIsSleep() {
        XCTAssertEqual(SleepInsightPayload(entry: entry(),
                                           night: night(points(count: 60)))?.mode, "sleep")
    }

    func testUnmeasuredSectionsAreAbsentRatherThanZero() {
        // A section with no input has not been measured, and the app refuses
        // to print 0 for it. Sending 0 would hand the model that verdict.
        let log = entry()
        log.sleepTiming = 80
        let p = SleepInsightPayload(entry: log, night: night(points(count: 60)))
        XCTAssertEqual(p?.sleep.sectionScores?["Timing"], 80)
        XCTAssertNil(p?.sleep.sectionScores?["Continuity"])
    }

    func testSectionScoresAreAbsentWhenNoneWereMeasured() {
        XCTAssertNil(SleepInsightPayload(entry: entry(),
                                         night: night(points(count: 60)))?.sleep.sectionScores)
    }

    // MARK: - The arc, which is the whole point

    func testEachMetricTravelsAsTwoHalvesNotOneAverage() {
        // A night average is one number for eight hours: the same 58 bpm covers
        // a night that settled and one that never did.
        let p = SleepInsightPayload(entry: entry(), night: night(points(count: 120)))
        let pulse = p?.sleep.arcs?["hr"]
        XCTAssertNotNil(pulse?.firstHalf)
        XCTAssertNotNil(pulse?.secondHalf)
        XCTAssertGreaterThan(pulse!.firstHalf!, pulse!.secondHalf!,
                             "Pulse fell through this night; the halves must show it")
    }

    func testArcKeysAreTheWireNamesTheServerKnows() {
        let p = SleepInsightPayload(entry: entry(), night: night(points(count: 120)))
        let keys = Set((p?.sleep.arcs ?? [:]).keys)
        // The same keys the macro read already sends, so one vocabulary
        // reaches the model from both screens.
        XCTAssertTrue(keys.contains("hr"))
        XCTAssertTrue(keys.contains("dc"))
        XCTAssertTrue(keys.contains("pip"))
        XCTAssertFalse(keys.contains("Pulse"), "the display label is not the wire name")
    }

    func testTheLowestPulseIsCarriedWithTheHourItHappened() {
        let p = SleepInsightPayload(entry: entry(), night: night(points(count: 120)))
        XCTAssertNotNil(p?.sleep.lowestHR)
        XCTAssertNotNil(p?.sleep.lowestHRAt)
        XCTAssertLessThan(p!.sleep.lowestHR!, 62, "the low is below where the night started")
    }

    // MARK: - Position, stated either way

    func testANightThatPredatesPositionSaysSoRatherThanSendingNothing() {
        // Absent positions plus no flag would read to the model as "never on
        // their back" — a claim the sensor never made.
        let p = SleepInsightPayload(entry: entry(), night: night(points(count: 120)))
        XCTAssertEqual(p?.sleep.positionRecorded, false)
        XCTAssertNil(p?.sleep.positions)
    }

    func testANightWithPositionSendsTheMinutesPerPosition() {
        // 80 ticks x 30 s supine, then 40 on the left.
        let p = SleepInsightPayload(entry: entry(),
                                    night: night(positioned([(.supine, 80), (.leftSide, 40)])))
        XCTAssertEqual(p?.sleep.positionRecorded, true)
        // Longest first: the read leads with whichever dominated the night.
        XCTAssertEqual(p?.sleep.positions?.first?.position, "Supine")
        XCTAssertEqual(p?.sleep.positions?.count, 2)
    }

    // MARK: - Wire format

    func testEncodesToTheSnakeCaseKeysTheServerReads() throws {
        let p = try XCTUnwrap(SleepInsightPayload(entry: entry(),
                                                  night: night(points(count: 120))))
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(p), encoding: .utf8))
        for key in ["\"mode\"", "\"sleep\"", "\"asleep_min\"", "\"in_bed_min\"",
                    "\"position_recorded\"", "\"lowest_hr_at\"", "\"first_half\""] {
            XCTAssertTrue(json.contains(key), "missing \(key)")
        }
        XCTAssertFalse(json.contains("\"asleepMin\""), "camelCase would not decode server-side")
    }
}
