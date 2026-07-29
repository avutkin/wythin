import XCTest
@testable import Wythin

final class AnchorDetectorTests: XCTestCase {

    /// Builds `minutes` of still, clean ticks starting at `hour` on a fixed day.
    /// `spacing` is the tick interval — 2 s is foreground, 30 s is background.
    private func stillPoints(minutes: Double,
                             hour: Int,
                             motion: Float? = 5,
                             hr: Float = 60,
                             vti: Float = 3.6,
                             spacing: Double = 2) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20)
        comps.hour = hour
        let start = cal.date(from: comps)!
        let count = Int((minutes * 60) / spacing)
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * spacing),
                                meanBPM: hr, vti: vti, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    func testFindsCleanMorningWindow() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.lnRMSSD ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001)
        XCTAssertNotNil(a?.dc)
        XCTAssertFalse(a?.late ?? true)
        XCTAssertEqual(a?.confidence, .high)
    }

    func testRejectsWindowShorterThanMinimum() {
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 2, hour: 7)))
    }

    func testDropsDCOnShortWindow() {
        let a = AnchorDetector.detect(stillPoints(minutes: 4, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertNil(a?.dc, "DC needs a 5-minute window")
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testRejectsMotion() {
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 6, hour: 7, motion: 120)))
    }

    func testFallsBackToHRStabilityWhenMotionUnknown() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7, motion: nil))
        XCTAssertNotNil(a)
        XCTAssertFalse(a?.motionKnown ?? true)
        XCTAssertEqual(a?.confidence, .low)
    }

    func testAfternoonOnlyWindowIsLate() {
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 15))
        XCTAssertNotNil(a)
        XCTAssertTrue(a?.late ?? false)
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testPrefersMorningWindowOverLaterOne() {
        let points = stillPoints(minutes: 6, hour: 8) + stillPoints(minutes: 20, hour: 16)
        let a = AnchorDetector.detect(points)
        XCTAssertEqual(Calendar.current.component(.hour, from: a?.startedAt ?? .distantPast), 8)
    }

    func testRejectsImplausibleBreathingRate() {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<180).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 30, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertNil(AnchorDetector.detect(points))
    }

    // MARK: - Cadence

    func testFindsAnchorInBackgroundCadenceData() {
        // 30 s ticks are what the app records whenever it is not foregrounded.
        let a = AnchorDetector.detect(stillPoints(minutes: 10, hour: 7, spacing: 30))
        XCTAssertNotNil(a, "a 10-minute rest recorded at 30 s ticks must anchor")
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(a?.confidence, .high)
    }

    func testStirringBreaksTheRun() {
        // Six clean minutes, then movement, then six more. Neither half is
        // rejected, but they are two rests — and the mover must not be medianed in.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let moving = (0..<30).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(360 + Double(i) * 2),
                                meanBPM: 95, vti: 2.4, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 400,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let after = (0..<180).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(420 + Double(i) * 2),
                                meanBPM: 75, vti: 3.0, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(stillPoints(minutes: 6, hour: 7) + moving + after)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001,
                       "the first rest is the anchor; the 75 bpm stretch is a separate run")
    }

    func testRejectsRunWithTooFewSamples() {
        // 4 minutes at 60 s ticks is 4 samples — long enough in wall-clock, but a
        // median over four points is not a median.
        XCTAssertNil(AnchorDetector.detect(stillPoints(minutes: 4, hour: 7, spacing: 60)))
    }

    func testLongOutageSplitsEvenWithNothingRejected() {
        // App killed for 20 minutes: no samples at all in the hole, so nothing is
        // rejected — the ceiling is what stops the two sides being merged.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let before = (0..<60).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let after = (0..<60).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(1320 + Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        XCTAssertNil(AnchorDetector.detect(before + after),
                     "two 2-minute halves across a 20-minute outage are not one 24-minute rest")
    }

    // MARK: - Legacy rows

    /// Builds a clean 10-minute morning run with the quality fields set
    /// individually, so rows that predate a field can be simulated.
    private func legacyPoints(signalQuality: Float?,
                              rrInvalidRate: Float?,
                              ecgQualityTier: Int?) -> [MetricsHistoryPoint] {
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        return (0..<300).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 2),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: signalQuality,
                                rrInvalidRate: rrInvalidRate,
                                ecgQualityTier: ecgQualityTier)
        }
    }

    func testAcceptsRowsCarryingOnlySignalQuality() {
        let a = AnchorDetector.detect(
            legacyPoints(signalQuality: 0.98, rrInvalidRate: nil, ecgQualityTier: 2))
        XCTAssertNotNil(a, "signalQuality is 1 - rrInvalidRate; one of the two is enough")
    }

    func testRejectsRowsWhoseOnlyQualitySignalIsBad() {
        // signalQuality 0.80 means a 20% invalid rate — over the 5% ceiling.
        XCTAssertNil(AnchorDetector.detect(
            legacyPoints(signalQuality: 0.80, rrInvalidRate: nil, ecgQualityTier: 2)))
    }

    func testRejectsRowsWithNoQualitySignalAtAll() {
        XCTAssertNil(AnchorDetector.detect(
            legacyPoints(signalQuality: nil, rrInvalidRate: nil, ecgQualityTier: 2)))
    }

    func testAbsentECGTierAnchorsAtLowConfidence() {
        let a = AnchorDetector.detect(
            legacyPoints(signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: nil))
        XCTAssertNotNil(a, "an absent tier means the row predates the field, not a poor ECG")
        XCTAssertEqual(a?.confidence, .low, "and it is paid for in confidence")
    }

    func testPoorECGTierIsStillRejected() {
        XCTAssertNil(AnchorDetector.detect(
            legacyPoints(signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 0)))
    }

    // MARK: - Window standardisation

    func testAnchorsOnTheFirstFiveMinutesOfALongRest() {
        // Five minutes at 60 bpm, then twenty-five more at 80. Still throughout —
        // one run — but only the standardised head may reach the median.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<900).map { i -> MetricsHistoryPoint in
            let t = Double(i) * 2
            return MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(t),
                                       meanBPM: t <= 300 ? 60 : 80,
                                       vti: t <= 300 ? 3.6 : 3.0,
                                       dc: 7.5, pip: 42, dfa1: 1.0,
                                       breathBPM: 13, motion: 5,
                                       signalQuality: 0.98, rrInvalidRate: 0.01,
                                       ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(points)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001,
                       "the 80 bpm tail is outside the 300 s window")
        XCTAssertEqual(a?.lnRMSSD ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(a?.durationSec ?? 0, 1798, accuracy: 1,
                       "durationSec still reports the whole rest, not the window")
        XCTAssertNotNil(a?.dc, "DC gates on the run length, not the window")
        XCTAssertEqual(a?.confidence, .high)
    }

    func testShortRestStillUsesEverythingItHas() {
        // Under 300 s there is no tail to trim — behaviour is unchanged.
        let a = AnchorDetector.detect(stillPoints(minutes: 4, hour: 7))
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.durationSec ?? 0, 238, accuracy: 1)
        XCTAssertNil(a?.dc)
        XCTAssertEqual(a?.confidence, .medium)
    }

    func testConfidenceDescribesTheWindowNotTheWholeRun() {
        // Motion is unknown for the leading 300 s but known for the tail. HR
        // stays constant throughout so the run clears the gates on the
        // HR-stability fallback either way — this isolates confidence, not
        // acceptance. The reading must still read as motion-unverified,
        // because that is genuinely true of the span the medians came from.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<300).map { i -> MetricsHistoryPoint in
            let t = Double(i) * 2
            return MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(t),
                                       meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                       breathBPM: 13, motion: t <= 300 ? nil : 5,
                                       signalQuality: 0.98, rrInvalidRate: 0.01,
                                       ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(points)
        XCTAssertNotNil(a)
        XCTAssertFalse(a?.motionKnown ?? true)
        XCTAssertEqual(a?.confidence, .low)
    }

    func testRunGatesJudgeTheWindowNotTheWholeRun() {
        // The discriminating case `testConfidenceDescribesTheWindowNotTheWholeRun`
        // cannot make: motion is unknown across the leading 300 s *and* HR drifts
        // 60→75 there (SD ≈ 4.3, over `hrStabilitySD`), while the tail has motion
        // and a flat HR. Judged on the window the run is unusable. Judged on the
        // whole run it passes on the tail's motion alone — so this fails the
        // moment `passesRunGates` is handed the run again.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let points = (0..<900).map { i -> MetricsHistoryPoint in
            let t = Double(i) * 2
            return MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(t),
                                       meanBPM: t < 300 ? Float(60 + 15 * t / 300) : 60,
                                       vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                       breathBPM: 13, motion: t < 300 ? nil : 5,
                                       signalQuality: 0.98, rrInvalidRate: 0.01,
                                       ecgQualityTier: 2)
        }
        XCTAssertNil(AnchorDetector.detect(points),
                     "stillness was never verified over the span the medians come from")
    }

    // MARK: - Run selection

    func testSparseLeadingWindowDisqualifiesItsRunNotTheDay() {
        // 07:00: eight samples ~70 s apart. Long enough and numerous enough as a
        // run, but only five land inside the 300 s window, so no median can be
        // taken from it. 08:00: a dense ten-minute rest. The sparse run must be
        // skipped — checking the window only inside `reading` made the first
        // qualifying run's failure fatal for the whole day.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let sparse = (0..<8).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 70),
                                meanBPM: 90, vti: 2.4, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(sparse + stillPoints(minutes: 10, hour: 8, spacing: 30))
        XCTAssertNotNil(a, "a sparse head disqualifies its own run, not the morning")
        XCTAssertEqual(a?.restingHR ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(cal.component(.hour, from: a?.startedAt ?? .distantPast), 8)
    }

    func testBackgroundCadenceStirBreaksTheRun() {
        // Two and a half still minutes at 30 s ticks, ninety seconds of movement
        // — only two rejected samples at that cadence, which is *within*
        // `maxRejectedInGap` — then a long clean rest. Counted in samples alone
        // the two halves merge into one "rest" whose median straddles the
        // movement; the wall-clock bound is what keeps them apart.
        let cal = Calendar.current
        var comps = DateComponents(year: 2026, month: 7, day: 20); comps.hour = 7
        let start = cal.date(from: comps)!
        let head = (0..<6).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(Double(i) * 30),
                                meanBPM: 60, vti: 3.6, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let moving = [180.0, 210.0].map { t in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(t),
                                meanBPM: 110, vti: 2.0, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 400,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let tail = (0..<24).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: start.addingTimeInterval(240 + Double(i) * 30),
                                meanBPM: 75, vti: 3.0, dc: 7.5, pip: 42, dfa1: 1.0,
                                breathBPM: 13, motion: 5,
                                signalQuality: 0.98, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
        let a = AnchorDetector.detect(head + moving + tail)
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.startedAt, start.addingTimeInterval(240),
                       "the 150 s head cannot anchor on its own, and must not be merged in")
        XCTAssertEqual(a?.restingHR ?? 0, 75, accuracy: 0.001)
    }

}
