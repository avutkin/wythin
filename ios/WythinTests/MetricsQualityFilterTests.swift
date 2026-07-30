import XCTest
@testable import Wythin

/// Covers `MetricsQualityFilter.isValid`, in particular the RMSSD/mean-BPM
/// plausibility check added alongside these tests. See that type's doc for
/// the production incident that motivated it: dropped/duplicated beats on
/// the chest strap produced RMSSD ~150 ms at HR ~165 bpm, which every
/// pre-existing per-field check let through.
final class MetricsQualityFilterTests: XCTestCase {

    private func point(sdnn: Float? = 50, rmssd: Float?, meanBPM: Float?) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: Date(), meanBPM: meanBPM, rmssd: rmssd, sdnn: sdnn)
    }

    // MARK: RMSSD/HR plausibility — the artifact this check exists for

    /// 2026-07-28: RMSSD held at 150 ms while HR ran 163–167 bpm for seven
    /// straight hours. meanRR at 165 bpm is ~364 ms, so ratio = 150/364 ≈
    /// 0.41 — well past the 0.30 ceiling. Passes all three pre-existing
    /// per-field checks (150 > 3, 165 is within 35...210) in isolation.
    func testJuly28ArtifactIsRejected() {
        XCTAssertFalse(MetricsQualityFilter.isValid(point(rmssd: 150, meanBPM: 165)))
    }

    /// 2026-07-25 05:00 UTC: the same signature, RMSSD 137 at HR 165.5.
    /// meanRR ≈ 362.5 ms, ratio ≈ 0.378 — also past 0.30.
    func testJuly25ArtifactIsRejected() {
        XCTAssertFalse(MetricsQualityFilter.isValid(point(rmssd: 137, meanBPM: 165.5)))
    }

    /// Normal rest: RMSSD 26 at HR 60. meanRR = 1000 ms, ratio = 0.026 — well
    /// under the ceiling. This is the guard against over-rejecting: it
    /// matters more than the rejection cases above, because a false
    /// rejection here silently deletes real data at all ten call sites.
    func testNormalRestIsAccepted() {
        XCTAssertTrue(MetricsQualityFilter.isValid(point(rmssd: 26, meanBPM: 60)))
    }

    /// High-HRV resonance breathing: RMSSD 150 at HR 55. meanRR ≈ 1090.9 ms,
    /// ratio ≈ 0.1375 — genuinely high HRV, not an artifact, and must pass
    /// despite sharing the same raw RMSSD value as the 28 July artifact.
    func testHighHRVResonanceBreathingIsAccepted() {
        XCTAssertTrue(MetricsQualityFilter.isValid(point(rmssd: 150, meanBPM: 55)))
    }

    /// Athlete at rest: RMSSD 100 at HR 50. meanRR = 1200 ms, ratio ≈ 0.083.
    func testAthleteAtRestIsAccepted() {
        XCTAssertTrue(MetricsQualityFilter.isValid(point(rmssd: 100, meanBPM: 50)))
    }

    // MARK: pre-existing per-field checks, unchanged

    func testLowSDNNIsStillRejected() {
        XCTAssertFalse(MetricsQualityFilter.isValid(point(sdnn: 5.0, rmssd: 26, meanBPM: 60)))
    }

    func testLowRMSSDIsStillRejected() {
        XCTAssertFalse(MetricsQualityFilter.isValid(point(rmssd: 3.0, meanBPM: 60)))
    }

    func testOutOfRangeBPMIsStillRejected() {
        XCTAssertFalse(MetricsQualityFilter.isValid(point(rmssd: 26, meanBPM: 34.9)))
        XCTAssertFalse(MetricsQualityFilter.isValid(point(rmssd: 26, meanBPM: 210.1)))
    }

    // MARK: missing data

    /// A nil `meanBPM` must be rejected outright — not just skipped by the
    /// new check — and must never reach the `60_000 / meanBPM` division.
    func testNilMeanBPMIsRejectedWithoutCrashing() {
        XCTAssertFalse(MetricsQualityFilter.isValid(point(rmssd: 26, meanBPM: nil)))
    }
}
