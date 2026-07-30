import XCTest
@testable import Wythin

/// The nudge engine cannot read `tickHistory` — that is appended only in
/// foreground (AppEnvironment.swift:367-369) — so it keeps its own short buffer,
/// filled on every tick in both modes.
final class NudgeSampleBufferTests: XCTestCase {

    private func valid(at t: Date, bpm: Float = 70) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: t, meanBPM: bpm, rmssd: 40, sdnn: 50)
    }

    /// Fails MetricsQualityFilter: SDNN collapses near zero when the strap is off.
    private func strapOff(at t: Date) -> MetricsHistoryPoint {
        MetricsHistoryPoint(timestamp: t, meanBPM: 70, rmssd: 40, sdnn: 1)
    }

    // MARK: Quality gating

    func testStoresAValidPoint() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        buffer.append(valid(at: now), now: now)
        XCTAssertEqual(buffer.points.count, 1)
    }

    func testRejectsAPointThatFailsTheQualityFilter() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        buffer.append(strapOff(at: now), now: now)
        XCTAssertTrue(buffer.points.isEmpty)
    }

    // MARK: Retention

    func testDropsPointsOlderThanTheRetentionWindow() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        // 46 minutes old — one minute past the 45-minute retention.
        buffer.append(valid(at: now.addingTimeInterval(-46 * 60)), now: now.addingTimeInterval(-46 * 60))
        buffer.append(valid(at: now), now: now)
        XCTAssertEqual(buffer.points.count, 1)
        XCTAssertEqual(buffer.points.first?.timestamp, now)
    }

    func testKeepsPointsInsideTheRetentionWindow() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        buffer.append(valid(at: now.addingTimeInterval(-44 * 60)), now: now.addingTimeInterval(-44 * 60))
        buffer.append(valid(at: now), now: now)
        XCTAssertEqual(buffer.points.count, 2)
    }

    // MARK: Capacity guard

    /// Retention normally bounds the buffer well below capacity (45 min at the
    /// 2s foreground cadence is 1350 points). The cap is a guard against
    /// degenerate timestamps, so it is tested with clock-stuck input.
    func testNeverGrowsUnboundedWhenTimestampsDoNotAdvance() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        for _ in 0..<(NudgeSampleBuffer.capacity + NudgeSampleBuffer.trimBatch + 50) {
            buffer.append(valid(at: now), now: now)
        }
        XCTAssertLessThanOrEqual(buffer.points.count,
                                 NudgeSampleBuffer.capacity + NudgeSampleBuffer.trimBatch)
    }

    // MARK: Gaps

    func testReportsAGapWhenSamplesAreFurtherApartThanTheGapLimit() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        buffer.append(valid(at: now.addingTimeInterval(-600)), now: now.addingTimeInterval(-600))
        buffer.append(valid(at: now), now: now)          // 10-minute hole
        XCTAssertTrue(buffer.hasGap(inLast: 1800, now: now))
    }

    func testReportsNoGapAtTheBackgroundCadence() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        for i in stride(from: 60, through: 1, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 30)
            buffer.append(valid(at: t), now: t)
        }
        XCTAssertFalse(buffer.hasGap(inLast: 1800, now: now))
    }

    /// An old gap that has scrolled out of the lookback must not keep firing.
    func testIgnoresAGapOutsideTheLookback() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        buffer.append(valid(at: now.addingTimeInterval(-2400)), now: now.addingTimeInterval(-2400))
        for i in stride(from: 40, through: 1, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 30)
            buffer.append(valid(at: t), now: t)
        }
        // The 30-minute hole sits before the 10-minute lookback.
        XCTAssertFalse(buffer.hasGap(inLast: 600, now: now))
    }

    // MARK: Cadence

    func testMedianCadenceReflectsTheBackgroundTickRate() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        for i in stride(from: 20, through: 1, by: -1) {
            let t = now.addingTimeInterval(-Double(i) * 30)
            buffer.append(valid(at: t), now: t)
        }
        XCTAssertEqual(buffer.medianCadenceSeconds ?? 0, 30, accuracy: 0.01)
    }

    func testMedianCadenceIsNilWithTooFewPoints() {
        var buffer = NudgeSampleBuffer()
        let now = Date()
        buffer.append(valid(at: now), now: now)
        XCTAssertNil(buffer.medianCadenceSeconds)
    }

    /// The engine derives its minimum-point bar from observed cadence rather than
    /// hardcoding it, so the same rules work at 2s and 30s.
    func testRequiredPointsScalesWithCadence() {
        XCTAssertEqual(NudgeSampleBuffer.requiredPoints(windowMinutes: 30, cadenceSeconds: 30), 36)
        XCTAssertEqual(NudgeSampleBuffer.requiredPoints(windowMinutes: 10, cadenceSeconds: 30), 12)
        XCTAssertEqual(NudgeSampleBuffer.requiredPoints(windowMinutes: 30, cadenceSeconds: 2), 540)
    }

    func testRequiredPointsHasAFloor() {
        XCTAssertEqual(NudgeSampleBuffer.requiredPoints(windowMinutes: 1, cadenceSeconds: 30), 6)
    }
}
