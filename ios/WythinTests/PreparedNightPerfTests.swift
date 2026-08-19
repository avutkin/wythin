import XCTest
@testable import Wythin

/// How long the night screen's off-thread work actually takes, at the size the
/// phone really produces: ten hours at the two-second foreground cadence.
final class PreparedNightPerfTests: XCTestCase {

    private func bigNight() -> [MetricsHistoryPoint] {
        let start = Date(timeIntervalSince1970: 1_755_000_000)
        return (0..<18_000).map { i in
            let t = Double(i)
            return MetricsHistoryPoint(
                anchorTestTimestamp: start.addingTimeInterval(t * 2),
                meanBPM: 52 + Float((i / 900) % 5),
                vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                breathBPM: 13 + Float(i % 3) * 0.4,
                motion: Float(i % 97 == 0 ? 30 : 5),
                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
        }
    }

    func testPreparingATenHourNightIsFastEnoughToNotStallTheScreen() {
        let points = bigNight()
        let t0 = CFAbsoluteTimeGetCurrent()
        let prepared = PreparedNight(points: points)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print("⏱  PreparedNight over \(points.count) samples: \(Int(elapsed * 1000)) ms")

        XCTAssertEqual(prepared.stages.count, points.count)
        // This was 2.7 s before the hot spots came out — `medianInterval`
        // being re-sorted once per run per smoothing pass inside `classify`,
        // and the depth smoother reading its window out of a dictionary. Both
        // are O(n) now and one night costs ~130 ms on the simulator. The bar is
        // set well above that but far below the old number, so a regression
        // back into either shape fails here rather than on the phone.
        XCTAssertLessThan(elapsed, 1.0, "preparing one night must not take seconds")
    }

    func testWhereTheTimeActuallyGoes() {
        let points = bigNight()
        func time(_ name: String, _ body: () -> Void) {
            let t = CFAbsoluteTimeGetCurrent(); body()
            print("⏱  \(name): \(Int((CFAbsoluteTimeGetCurrent() - t) * 1000)) ms")
        }
        time("classify (coarse)") { _ = SleepStages.classify(points) }
        time("detailed (full)")   { _ = SleepStages.detailed(points) }
        time("medianInterval")    { _ = SleepStages.medianInterval(points) }
        time("breathing spread")  { _ = SleepBreathing.spread(points) }
        let stages = SleepStages.detailed(points)
        time("markN1")            { _ = SleepStages.markN1(stages, points: points) }
    }

    /// The shape the screen used to have: staging recomputed once per access,
    /// and the legend asks nine times per render pass. Kept as a guard because
    /// the cost is what made the app unusable, not the correctness.
    func testTheOldPerRenderShapeWouldStillBeAffordable() {
        let points = bigNight()
        let t0 = CFAbsoluteTimeGetCurrent()
        for _ in 0..<7 { _ = SleepStages.detailed(points) }
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print("⏱  7 staging passes: \(Int(elapsed * 1000)) ms")
        XCTAssertLessThan(elapsed, 5.0)
    }
}
