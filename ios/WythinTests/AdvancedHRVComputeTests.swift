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

    // MARK: Heart Rate Asymmetry (Guzik's Index)

    /// A perfectly alternating series: every deceleration is matched by an
    /// acceleration of the same size, so decelerations own exactly half the
    /// short-term variance. This is the definition of the 50 % midpoint, and
    /// the whole chart is read as distance from it.
    func testGuzikIndexIsFiftyForAPerfectlySymmetricSeries() {
        // 401 values → 400 differences, exactly 200 up and 200 down. An even
        // count matters: 400 values would leave 399 differences and read
        // 50.125 %, which is correct arithmetic on a lopsided fixture.
        let rr = (0..<401).map { $0 % 2 == 0 ? 800 : 810 }
        let gi = try! XCTUnwrap(AdvancedHRVCompute.computeHRA(rrMs: rr))
        XCTAssertEqual(gi, 50, accuracy: 0.001)
    }

    /// One big deceleration paid back by three small accelerations: the
    /// slowing side contributes 900 of the 1200 total squared variance, so
    /// Guzik's index must read 75 %. Pins the direction of the ratio — the
    /// easy mistake is to divide by the accelerations and invert the meaning.
    func testGuzikIndexRisesWhenDecelerationsCarryTheVariance() {
        // Closed with a trailing 800 so the differences form exactly 100
        // complete +30/-10/-10/-10 groups: 900 of every 1200 squared units.
        var rr: [Int] = []
        for _ in 0..<100 { rr.append(contentsOf: [800, 830, 820, 810]) }
        rr.append(800)
        let gi = try! XCTUnwrap(AdvancedHRVCompute.computeHRA(rrMs: rr))
        XCTAssertEqual(gi, 75, accuracy: 0.001)
    }

    /// Asymmetry is a distribution statistic — a handful of beats cannot
    /// support one, so it reports nothing rather than a number built on ten
    /// intervals.
    func testHRAReturnsNilBelowItsMinimum() {
        XCTAssertNil(AdvancedHRVCompute.computeHRA(rrMs: Array(repeating: 800, count: 20)))
    }

    // MARK: Rhythm Stability (PSS)

    /// `pss` was the third fragmentation index and the engine dropped it, the
    /// same way it dropped AC: `computeHRF` returns pip, ials AND pss, and
    /// only the first two were ever read. Both new values must ride the tick.
    func testEngineKeepsHRAAndFragmentationOnTheTick() {
        let rr = restingRR(count: 400)
        let tick = MetricsEngine.compute(from: DataSnapshot(ecg: [], accZ: [], accXYZ: [],
                                                            rr: rr, bpm: []))
        XCTAssertNotNil(tick.hra, "the engine must forward Heart Rate Asymmetry")
        XCTAssertNotNil(tick.pss, "the engine must forward PSS, not discard it")
    }

    /// 2 h and 24 h read the store, not live ticks, so both values only reach
    /// their charts if they survive `HRVSample`.
    func testHRAAndPSSSurviveTheRoundTripThroughTheStore() {
        let rr = restingRR(count: 400)
        let tick = MetricsEngine.compute(from: DataSnapshot(ecg: [], accZ: [], accXYZ: [],
                                                            rr: rr, bpm: []))
        let restored = MetricsHistoryPoint(from: HRVSample(from: tick))
        XCTAssertEqual(restored.hra ?? .nan, try! XCTUnwrap(tick.hra), accuracy: 0.0001)
        XCTAssertEqual(restored.pss ?? .nan, try! XCTUnwrap(tick.pss), accuracy: 0.0001)
    }

    /// PSS counts fragmentation — higher is worse. The chart is named for
    /// stability and must therefore rise as the rhythm steadies, so the flip
    /// lives in one place and is pinned here rather than repeated in the card.
    func testRhythmStabilityIsTheInverseOfFragmentation() {
        let point = MetricsHistoryPoint(timestamp: Date(), pss: 62)
        XCTAssertEqual(point.rhythmStability ?? .nan, 38, accuracy: 0.0001)
    }

    /// No reading is not a reading of zero — a missing PSS must leave a gap.
    func testRhythmStabilityIsNilWhenFragmentationIsMissing() {
        XCTAssertNil(MetricsHistoryPoint(timestamp: Date()).rhythmStability)
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

    // MARK: - QT delineation
    //
    // The app has never located a heartbeat: RR arrives ready-made from the
    // strap's HR characteristic, and `ECGQualityCompute` only ever asked
    // statistical questions of the waveform. QT needs the beat itself, so
    // these tests are built on a synthetic ECG whose QT is known by
    // construction — the only way to know the delineator is right rather than
    // merely self-consistent.

    /// One synthetic beat, laid down on a flat baseline at `fs` Hz.
    ///
    /// Q onset sits 40 ms before R and the T wave is a raised cosine that
    /// returns exactly to baseline at `tEndMs` after R, so the true QT is
    /// 40 + tEndMs by construction rather than by measurement.
    private func syntheticECG(beats: Int, rrMs: Double, tEndMs: Double,
                              fs: Double = 130) -> [Float] {
        let n = Int(Double(beats) * rrMs / 1000 * fs)
        var out = [Float](repeating: 0, count: n)
        let spb = rrMs / 1000 * fs
        for b in 0..<beats {
            let r = Int(Double(b) * spb + spb / 2)
            // QRS: a sharp spike with a small Q dip 40 ms ahead of R.
            let q = r - Int(0.040 * fs)
            for k in q..<r where k >= 0 && k < n {
                let f = Double(k - q) / Double(max(r - q, 1))
                out[k] += Float(-120 * sin(.pi * f))          // Q trough
            }
            for k in (r - 2)...(r + 2) where k >= 0 && k < n {
                out[k] += Float(1000 * (1 - abs(Double(k - r)) / 3))   // R peak
            }
            // T wave: raised cosine from 40% to 100% of the QT tail, so it
            // reaches baseline exactly at tEndMs and nowhere earlier.
            let tS = r + Int(0.40 * tEndMs / 1000 * fs)
            let tE = r + Int(tEndMs / 1000 * fs)
            for k in tS..<tE where k >= 0 && k < n {
                let f = Double(k - tS) / Double(max(tE - tS, 1))
                out[k] += Float(220 * (1 - cos(2 * .pi * f)) / 2)
            }
        }
        return out
    }

    /// The delineator must recover a QT it was never told.
    ///
    /// It reads slightly *short*, and that is the tangent method working as
    /// designed rather than a defect: the tangent at the T wave's steepest
    /// descent crosses baseline before a smooth T wave has actually flattened,
    /// so measured QT sits a few samples under the constructed one. The bias
    /// is asserted in both size and direction, because a method that
    /// overshot would be a different bug wearing the same error bar.
    ///
    /// It matters little for what this feeds. QTVI normalises QT variance by
    /// mean QT squared, so an offset shared by every beat very nearly cancels
    /// — the beat-to-beat precision pinned by the test below is what counts.
    func testDelineatorRecoversAKnownQTSlightlyShort() {
        let ecg = syntheticECG(beats: 12, rrMs: 900, tEndMs: 320)
        let beats = AdvancedHRVCompute.delineateQT(ecg: ecg, fs: 130)
        XCTAssertGreaterThanOrEqual(beats.count, 8, "should find most of 12 beats")
        let qt = beats.map { Double($0.qtMs) }
        let mean = qt.reduce(0, +) / Double(qt.count)
        // True QT is 40 ms (Q→R) + 320 ms (R→T end) = 360 ms.
        XCTAssertLessThan(mean, 360, "the tangent method reads T end early")
        XCTAssertEqual(mean, 360, accuracy: 30, "but only by a few samples at 130 Hz")
    }

    /// A longer QT must read longer. Absolute accuracy is bounded by the
    /// sample grid, but the ordering has to survive it or the chart is noise.
    func testDelineatorSeparatesALongQTFromAShortOne() {
        let short = AdvancedHRVCompute.delineateQT(
            ecg: syntheticECG(beats: 12, rrMs: 900, tEndMs: 280), fs: 130)
        let long  = AdvancedHRVCompute.delineateQT(
            ecg: syntheticECG(beats: 12, rrMs: 900, tEndMs: 380), fs: 130)
        func mean(_ b: [QTBeat]) -> Double {
            b.map { Double($0.qtMs) }.reduce(0, +) / Double(b.count)
        }
        XCTAssertGreaterThan(mean(long) - mean(short), 70,
                             "a 100 ms difference must survive delineation")
    }

    /// Flat line, noise, an off-body strap: no beats, and therefore no QT.
    /// Reporting a number here is how a dead sensor becomes a health reading.
    func testDelineatorFindsNothingInAFlatLine() {
        XCTAssertTrue(AdvancedHRVCompute.delineateQT(
            ecg: [Float](repeating: 0, count: 1300), fs: 130).isEmpty)
    }

    // MARK: - QT Variability Index

    /// Berger's QTVI is a ratio of *normalised* variabilities, so a recording
    /// where QT and HR wobble in equal proportion sits at 0 by construction.
    /// This pins the formula, which is the part easiest to get subtly wrong.
    func testQTVIIsZeroWhenQTAndHeartRateVaryInEqualProportion() {
        // QT: mean 400, SD 40 → CV 0.1.  RR: mean 900, SD 90 → CV 0.1.
        let qt = [360.0, 440.0, 360.0, 440.0].map(Float.init)
        let rr = [810.0, 990.0, 810.0, 990.0].map(Float.init)
        let v = try! XCTUnwrap(AdvancedHRVCompute.qtvi(qtMs: qt, rrMs: rr))
        XCTAssertEqual(v, 0, accuracy: 0.05)
    }

    /// QT wobbling more than heart rate does is the abnormal direction, and
    /// must push the index positive.
    func testQTVIRisesWhenQTIsUnstableAgainstASteadyHeartRate() {
        let qt = [340.0, 460.0, 340.0, 460.0].map(Float.init)
        let rr = [895.0, 905.0, 895.0, 905.0].map(Float.init)
        let v = try! XCTUnwrap(AdvancedHRVCompute.qtvi(qtMs: qt, rrMs: rr))
        XCTAssertGreaterThan(v, 0.5)
    }

    /// A heart with no QT variation at all cannot be placed on a log ratio.
    func testQTVIIsNilWhenThereIsNoQTVariationToSpeakOf() {
        XCTAssertNil(AdvancedHRVCompute.qtvi(
            qtMs: [Float](repeating: 400, count: 8),
            rrMs: [Float](repeating: 900, count: 8)))
    }

    // MARK: - QT Tracker

    /// The buffer holds 10 s and the tick fires every 2 s, so eight seconds of
    /// every window has already been counted. Feeding the same window twice
    /// must not double the series — without the dedup, a still subject would
    /// look like they had five times the beats they have.
    func testTrackerDoesNotCountAnOverlappingWindowTwice() {
        let tracker = QTTracker()
        let ecg = syntheticECG(beats: 12, rrMs: 900, tEndMs: 320)
        let t0 = Date(timeIntervalSince1970: 1_750_000_000)

        tracker.update(ecg: ecg, fs: 130, windowEnd: t0)
        let afterFirst = tracker.beatCountForTesting
        XCTAssertGreaterThanOrEqual(afterFirst, 8)

        // Same window, same instant — every beat is one already held.
        tracker.update(ecg: ecg, fs: 130, windowEnd: t0)
        XCTAssertEqual(tracker.beatCountForTesting, afterFirst,
                       "re-feeding an identical window must add nothing")
    }

    /// Advancing the clock by a real 2 s step should admit the beats that
    /// genuinely are new, and only those.
    func testTrackerAccumulatesAcrossSuccessiveWindows() {
        let tracker = QTTracker()
        let ecg = syntheticECG(beats: 12, rrMs: 900, tEndMs: 320)
        var t = Date(timeIntervalSince1970: 1_750_000_000)

        tracker.update(ecg: ecg, fs: 130, windowEnd: t)
        let first = tracker.beatCountForTesting
        for _ in 0..<10 {
            t = t.addingTimeInterval(2)
            tracker.update(ecg: ecg, fs: 130, windowEnd: t)
        }
        let after = tracker.beatCountForTesting
        XCTAssertGreaterThan(after, first, "new beats must accumulate")
        // 10 steps × 2 s at 900 ms per beat is ~22 further beats, not 120.
        XCTAssertLessThan(after, first + 40, "overlap must not be double-counted")
    }

    /// Below Berger's beat count there is no index — a QTVI built on eleven
    /// beats would be a number the data cannot support.
    func testTrackerReportsNothingUntilItHasEnoughBeats() {
        let tracker = QTTracker()
        let ecg = syntheticECG(beats: 12, rrMs: 900, tEndMs: 320)
        XCTAssertNil(tracker.update(ecg: ecg, fs: 130,
                                    windowEnd: Date(timeIntervalSince1970: 1_750_000_000)))
    }

    /// A dropped connection makes the next beat discontinuous with the last,
    /// so the series cannot span the gap.
    func testResetClearsTheSeries() {
        let tracker = QTTracker()
        let ecg = syntheticECG(beats: 12, rrMs: 900, tEndMs: 320)
        tracker.update(ecg: ecg, fs: 130, windowEnd: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertGreaterThan(tracker.beatCountForTesting, 0)
        tracker.reset()
        XCTAssertEqual(tracker.beatCountForTesting, 0)
    }
}
