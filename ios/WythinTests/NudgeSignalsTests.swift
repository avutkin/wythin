import XCTest
@testable import Wythin

/// The numeric evidence bundle every trigger reads. Two windows (30-min slow,
/// 10-min fast) plus change-in-personal-SD-units for the baselined metrics.
final class NudgeSignalsTests: XCTestCase {

    private let cadence: Double = 30       // background tick

    /// `n` is large by default so the shrinkage prior has washed out and the dz
    /// arithmetic below is readable. The prior's own behaviour is covered in
    /// AnchorBaselineTests.
    private func baseline(lnSD: Float = 0.2, dcSD: Float = 1.0,
                          restingHR: Float = 58, n: Int = 200) -> AnchorBaseline {
        AnchorBaseline(
            lnRMSSD:    BaselineStat(mean: 3.8, sd: lnSD, n: n),
            restingHR:  BaselineStat(mean: restingHR, sd: 3, n: n),
            dc:         BaselineStat(mean: 7.0, sd: dcSD, n: n),
            pip:        BaselineStat(mean: 55, sd: 6, n: n),
            dfa1Median: 1.0,
            cv7:        nil,
            cv7Stat:    nil,
            medianHour: 8,
            anchorCount: n,
            hourMatched: true,
            provisional: false)
    }

    /// 60 points, 30s apart, spanning exactly the 30-minute slow window.
    /// `lnRMSSD(i)` supplies ln(RMSSD) per index so tests can shape the series.
    private func buffer(now: Date,
                        lnRMSSD: (Int) -> Float = { _ in 3.8 },
                        dc: (Int) -> Float? = { _ in 7.0 },
                        dfa1: (Int) -> Float? = { _ in 1.0 },
                        motion: (Int) -> Float? = { _ in 5 },
                        rsa: (Int) -> Float? = { _ in 35 },
                        hr: (Int) -> Float = { _ in 62 },
                        quality: (Int) -> Float? = { _ in 0.98 },
                        count: Int = 60) -> NudgeSampleBuffer {
        var b = NudgeSampleBuffer()
        for i in 0..<count {
            let t = now.addingTimeInterval(-Double(count - i) * cadence)
            b.append(MetricsHistoryPoint(
                timestamp: t,
                meanBPM: hr(i),
                rmssd: exp(lnRMSSD(i)),
                rsaMs: rsa(i),
                sdnn: 50,
                coherence: 0.55,
                breathBPM: 14,
                dfa1: dfa1(i),
                dc: dc(i),
                motion: motion(i),
                signalQuality: quality(i),
                ecgQualityTier: 2), now: t)
        }
        return b
    }

    // MARK: Warm-up and gaps

    func testReturnsNilBeforeTheWindowHasFilled() {
        let now = Date()
        let b = buffer(now: now, count: 10)
        XCTAssertNil(NudgeSignals.derive(from: b, baseline: baseline(), now: now))
    }

    func testReturnsNilWhenTheWindowContainsAGap() {
        let now = Date()
        var b = NudgeSampleBuffer()
        // 30 points, then a 10-minute hole, then 30 more.
        for i in 0..<30 {
            let t = now.addingTimeInterval(-1800 + Double(i) * 30)
            b.append(MetricsHistoryPoint(timestamp: t, meanBPM: 62, rmssd: 44, sdnn: 50), now: t)
        }
        for i in 0..<30 {
            let t = now.addingTimeInterval(-300 + Double(i) * 10)
            b.append(MetricsHistoryPoint(timestamp: t, meanBPM: 62, rmssd: 44, sdnn: 50), now: t)
        }
        XCTAssertNil(NudgeSignals.derive(from: b, baseline: baseline(), now: now))
    }

    func testDerivesWhenTheWindowIsFullAndContinuous() {
        let now = Date()
        XCTAssertNotNil(NudgeSignals.derive(from: buffer(now: now), baseline: baseline(), now: now))
    }

    // MARK: Personal-SD change

    /// dzSlow is the change across the window in the person's own SD units, so
    /// the anchor-vs-live offset cancels. Here ln(RMSSD) steps 4.0 → 3.6 across
    /// a baseline SD of 0.2, which is exactly −2 SD of change.
    func testDzLnRMSSDMeasuresChangeInPersonalSDUnits() {
        let now = Date()
        let b = buffer(now: now, lnRMSSD: { i in
            if i < 12 { return 4.0 }        // first bucket
            if i >= 48 { return 3.6 }       // last bucket
            return 3.8
        })
        let s = NudgeSignals.derive(from: b, baseline: baseline(lnSD: 0.2), now: now)
        XCTAssertEqual(s?.dzLnRMSSD ?? 0, -2.0, accuracy: 0.02)
    }

    /// The same physiological change must read as a larger deviation for a
    /// person whose own day-to-day spread is tighter.
    func testDzScalesWithTheBaselineSpread() {
        let now = Date()
        let shape: (Int) -> Float = { i in i < 12 ? 4.0 : (i >= 48 ? 3.6 : 3.8) }
        let tight = NudgeSignals.derive(from: buffer(now: now, lnRMSSD: shape),
                                        baseline: baseline(lnSD: 0.1), now: now)
        let wide  = NudgeSignals.derive(from: buffer(now: now, lnRMSSD: shape),
                                        baseline: baseline(lnSD: 0.4), now: now)
        let tightDz = tight?.dzLnRMSSD ?? 0
        let wideDz  = wide?.dzLnRMSSD ?? 0
        XCTAssertLessThan(tightDz, wideDz)                 // both negative
        XCTAssertGreaterThan(abs(tightDz), abs(wideDz) * 2)
    }

    /// A provisional baseline (few anchors) still yields a dz — the prior
    /// carries it — but the widened SD makes it deliberately conservative.
    func testProvisionalBaselineYieldsAMoreConservativeDz() {
        let now = Date()
        let shape: (Int) -> Float = { i in i < 12 ? 4.0 : (i >= 48 ? 3.6 : 3.8) }
        let early = NudgeSignals.derive(from: buffer(now: now, lnRMSSD: shape),
                                        baseline: baseline(n: 2), now: now)
        let firm  = NudgeSignals.derive(from: buffer(now: now, lnRMSSD: shape),
                                        baseline: baseline(n: 200), now: now)
        XCTAssertNotNil(early?.dzLnRMSSD)
        XCTAssertLessThan(abs(early?.dzLnRMSSD ?? 0), abs(firm?.dzLnRMSSD ?? 0))
    }

    func testDzIsNilWithoutABaseline() {
        let now = Date()
        let s = NudgeSignals.derive(from: buffer(now: now), baseline: nil, now: now)
        XCTAssertNil(s?.dzLnRMSSD)
    }

    func testDzDCFollowsTheDCBaseline() {
        let now = Date()
        let b = buffer(now: now, dc: { i in i < 12 ? 8.0 : (i >= 48 ? 6.0 : 7.0) })
        let s = NudgeSignals.derive(from: b, baseline: baseline(dcSD: 1.0), now: now)
        XCTAssertEqual(s?.dzDC ?? 0, -2.0, accuracy: 0.02)
    }

    // MARK: Derived series

    /// The dial the chart draws is 100 × 40/(RMSSD+40) — see AutonomicCompute.
    /// A falling RMSSD must therefore read as a rising balance.
    func testBalanceRisesAsRMSSDFalls() {
        let now = Date()
        let b = buffer(now: now, lnRMSSD: { i in i < 30 ? log(50) : log(20) })
        let s = NudgeSignals.derive(from: b, baseline: baseline(), now: now)
        XCTAssertEqual(s?.slowBalance?.direction, "rising")
        // RMSSD 20 → 100 × 40/60 = 66.7
        XCTAssertEqual(s?.slowBalance?.end ?? 0, 66.7, accuracy: 0.5)
    }

    func testMotionTrendIsAvailableOnBothWindows() {
        let now = Date()
        let s = NudgeSignals.derive(from: buffer(now: now, motion: { _ in 12 }),
                                    baseline: baseline(), now: now)
        XCTAssertEqual(s?.slowMotion?.max ?? 0, 12, accuracy: 0.01)
        XCTAssertEqual(s?.fastMotion?.max ?? 0, 12, accuracy: 0.01)
    }

    func testFastWindowSeesOnlyTheLastTenMinutes() {
        let now = Date()
        // HR 60 for the first 20 min, 90 for the last 10.
        let b = buffer(now: now, hr: { i in i < 40 ? 60 : 90 })
        let s = NudgeSignals.derive(from: b, baseline: baseline(), now: now)
        XCTAssertEqual(s?.fast["hr"]?.mean ?? 0, 90, accuracy: 0.5)
        XCTAssertEqual(s?.slow["hr"]?.mean ?? 0, 70, accuracy: 0.5)
    }

    // MARK: Signal cleanliness

    func testSignalIsCleanWhenEveryPointPassesTheAnchorGates() {
        let now = Date()
        let s = NudgeSignals.derive(from: buffer(now: now), baseline: baseline(), now: now)
        XCTAssertEqual(s?.slowSignalClean, true)
    }

    /// F1 claims the user is in a great state; that must not be derivable from a
    /// noisy read, so one bad point is enough to disqualify the window.
    func testSignalIsNotCleanWhenAnyPointIsBelowTheQualityGate() {
        let now = Date()
        let b = buffer(now: now, quality: { i in i == 30 ? 0.7 : 0.98 })
        let s = NudgeSignals.derive(from: b, baseline: baseline(), now: now)
        XCTAssertEqual(s?.slowSignalClean, false)
    }
}
