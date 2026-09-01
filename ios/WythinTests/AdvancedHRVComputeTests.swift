import XCTest
@testable import Wythin

/// Deceleration Capacity (PRSA) — the gates that decide whether a tick can
/// produce a DC value at all.
///
/// These exist because DC was arriving ~16 minutes into a session while every
/// other advanced metric (RCMSE, PIP) computed from the same RR buffer within
/// a minute or two. Both causes were in the gates, not the PRSA maths.
final class AdvancedHRVComputeTests: XCTestCase {

    /// A resting RR series with realistic respiratory sinus arrhythmia: a
    /// ~5 s breath cycle swinging RR ±12 % around `base`, which is well
    /// inside anything a cleaner should consider an artifact.
    private func restingRR(count: Int, base: Double = 860, swingPct: Double = 0.12,
                           beatsPerBreath: Double = 6) -> [Int] {
        (0..<count).map { i in
            Int((base * (1 + swingPct * sin(2 * .pi * Double(i) / beatsPerBreath))).rounded())
        }
    }

    // MARK: The deadlock

    /// A single level shift — standing up, a sigh, a run of ectopy — must not
    /// silence the cleaner for the rest of the buffer.
    ///
    /// The filter compared each beat against `clean.last`, the last *accepted*
    /// value, and left that anchor untouched when it rejected one. So once the
    /// true RR level moved more than the threshold away from the last accepted
    /// beat, every subsequent beat was rejected too, and the anchor never
    /// advanced to catch up: the series died at the shift and stayed dead
    /// until that segment aged out of the 1200-beat ring buffer — about
    /// sixteen minutes at rest, which is exactly the delay that was showing up
    /// on the Live chart.
    func testCleanerSurvivesALevelShift() {
        // 200 beats at ~860 ms, then 200 at ~610 ms — a 29 % drop, larger than
        // the old 20 % successive-difference threshold.
        let rr = restingRR(count: 200, base: 860) + restingRR(count: 200, base: 610)
        let kept = AdvancedHRVCompute.cleanRRForPRSA(rr)

        // The old filter kept the first 200 and then nothing at all.
        XCTAssertGreaterThan(kept.count, 300,
                             "the cleaner stopped accepting beats after the level shift")
    }

    /// The everyday case: a clean resting series with normal RSA must survive
    /// essentially intact. A successive-difference rule tight enough to fight
    /// artifacts also eats real RSA, which is why `HRVCompute.cleanRR` does not
    /// use one.
    func testCleanerKeepsOrdinaryRestingBeats() {
        let rr = restingRR(count: 400)
        let kept = AdvancedHRVCompute.cleanRRForPRSA(rr)
        XCTAssertGreaterThan(Double(kept.count) / 400.0, 0.95,
                             "normal RSA is being discarded as artifact")
    }

    /// Implausible beats must still go — the fix must not turn the cleaner
    /// into a pass-through.
    func testCleanerStillDropsImplausibleBeats() {
        var rr = restingRR(count: 200)
        rr.insert(120, at: 50)     // far too short to be a beat
        rr.insert(4000, at: 100)   // far too long
        let kept = AdvancedHRVCompute.cleanRRForPRSA(rr)
        XCTAssertFalse(kept.contains(120))
        XCTAssertFalse(kept.contains(4000))
    }

    // MARK: The minimum that isn't

    /// `dcMinIntervals` has to be a count at which DC can actually be
    /// produced. PRSA only takes anchors from `L ..< n - L`, so a series of
    /// exactly `dcMinIntervals` offers `dcMinIntervals - 2L` interior
    /// positions, and roughly half of those are decelerations. At the old
    /// value of 150 that is 22 interior positions and ~11 deceleration
    /// anchors — below the 20 the function itself demands, so the stated
    /// minimum could never yield a value however clean the data.
    func testStatedMinimumCanActuallyProduceAValue() {
        let rr = restingRR(count: AdvancedHRVCompute.dcMinIntervals)
        XCTAssertNotNil(AdvancedHRVCompute.computeDC(rrMs: rr),
                        "dcMinIntervals promises a value it cannot deliver")
    }

    /// And one beat below it must still refuse, so the minimum means something.
    func testBelowTheMinimumStillReturnsNil() {
        let rr = restingRR(count: AdvancedHRVCompute.dcMinIntervals - 1)
        XCTAssertNil(AdvancedHRVCompute.computeDC(rrMs: rr))
    }

    /// DC is positive for a resting series — a sanity check that the fix did
    /// not change what PRSA actually measures.
    ///
    /// Sign only. The fixture is a pure sinusoid, and PRSA's whole purpose is
    /// to sum a periodic component coherently across anchors, so it reports a
    /// far larger amplitude here than any real recording would: a magnitude
    /// bound on this input would be pinning the fixture's cleanliness, not the
    /// product's behaviour.
    func testRestingSeriesYieldsPositiveDC() {
        let result = AdvancedHRVCompute.computeDC(rrMs: restingRR(count: 400))
        let dc = try! XCTUnwrap(result).dc
        XCTAssertGreaterThan(dc, 0, "DC > 0 is the normal resting case")
    }

    // MARK: Acceleration Capacity

    /// AC is DC's mirror: PRSA anchored on the beats where the heart *sped
    /// up*, so it is negative wherever DC is positive. The Live chart plots
    /// its magnitude, and that flip is only correct while the raw sign stays
    /// negative — so the convention is pinned here rather than assumed.
    ///
    /// Sign only, for the same reason as the DC test above.
    func testRestingSeriesYieldsNegativeAC() {
        let result = AdvancedHRVCompute.computeDC(rrMs: restingRR(count: 400))
        let ac = try! XCTUnwrap(result).ac
        XCTAssertLessThan(ac, 0, "AC < 0 is the normal resting case — it mirrors DC")
    }

    /// AC was computed and thrown away: `MetricsEngine` took `dcResult.dc` and
    /// dropped `.ac` on the floor, so no chart could ever draw it. The tick is
    /// the first link in the chain to the Live chart.
    func testEngineKeepsACOnTheTick() {
        let rr = restingRR(count: 400)
        let tick = MetricsEngine.compute(from: DataSnapshot(ecg: [], accZ: [], accXYZ: [],
                                                            rr: rr, bpm: []))
        let ac = try! XCTUnwrap(tick.ac, "the engine must forward AC, not discard it")
        XCTAssertLessThan(ac, 0)
    }

    /// The 30 m window reads live ticks, but 2 h and 24 h read the store — so
    /// AC only reaches the chart if it survives the round trip through
    /// `HRVSample`. Persisted as an optional attribute, so old stores migrate.
    func testACSurvivesTheRoundTripThroughTheStore() {
        let rr = restingRR(count: 400)
        let tick = MetricsEngine.compute(from: DataSnapshot(ecg: [], accZ: [], accXYZ: [],
                                                            rr: rr, bpm: []))
        let restored = MetricsHistoryPoint(from: HRVSample(from: tick))
        XCTAssertEqual(restored.ac ?? .nan, try! XCTUnwrap(tick.ac), accuracy: 0.0001)
    }

    /// The chart draws AC as a magnitude — higher means a stronger
    /// acceleration — while the stored value keeps the true negative sign the
    /// literature reports. `activationCapacity` is the one place that flip
    /// happens, so the Live card cannot drift from Track or the raw data.
    func testActivationCapacityIsChartedAsMagnitude() {
        let point = MetricsHistoryPoint(timestamp: Date(), ac: -6.2)
        XCTAssertEqual(point.activationCapacity ?? .nan, 6.2, accuracy: 0.0001)
    }

    /// No reading is not a reading of zero: a nil AC must leave a gap in the
    /// line, not plant a point on the axis.
    func testActivationCapacityIsNilWhenACIsMissing() {
        XCTAssertNil(MetricsHistoryPoint(timestamp: Date()).activationCapacity)
    }
}
