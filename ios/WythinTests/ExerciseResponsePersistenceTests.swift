import XCTest
import SwiftData
@testable import Wythin

final class ExerciseResponsePersistenceTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self, HRVSample.self, HRVSession.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private let start = Date(timeIntervalSince1970: 1_000_000)

    /// An empty tick carrying only a timestamp.
    ///
    /// `HRVSample` has a single initialiser, `init(from: MetricsTick)`, and
    /// `MetricsTick` defaults only three of its fields — so this spells the rest
    /// out once here rather than adding a test-only initialiser to a core model.
    /// Every value the tests care about is assigned on the sample afterwards.
    private func emptyTick(_ ts: Date) -> MetricsTick {
        MetricsTick(timestamp: ts,
                    meanBPM: nil, sdnn: nil, rmssd: nil, pnn50: nil, vti: nil,
                    ulfPower: nil, vlfPower: nil, lfPower: nil, hfPower: nil, lfHF: nil,
                    rsaMs: nil, rsaIdx: nil,
                    breathBPM: nil, breathHz: nil, regularity: nil,
                    coherenceScore: nil, cbi: nil,
                    dfa1: nil, signalQuality: nil,
                    ecgQuality: nil,
                    rcmse: nil, pip: nil, ials: nil, dc: nil,
                    breathPhases: nil,
                    psdFreqs: nil, psdValues: nil,
                    coherenceFreqs: nil, coherenceValues: nil)
    }

    /// A synthetic session: five minutes before at rest, thirty minutes of work
    /// where HR climbs and DC falls with it, then ten minutes of partial
    /// recovery. Samples every 30 s, matching the background tick cadence.
    @discardableResult
    private func seed(_ ctx: ModelContext, quality: Float = 0.95) -> Date {
        let end = start.addingTimeInterval(30 * 60)

        func add(_ date: Date, hr: Float, dc: Float, dfa1: Float, motion: Float) {
            let s = HRVSample(from: emptyTick(date))
            s.meanBPM = hr
            s.dc = dc
            s.dfa1 = dfa1
            s.motion = motion
            // MetricsQualityFilter gates every window in this app on sdnn > 5,
            // rmssd > 3 and a cross-field RMSSD/meanRR plausibility check. A
            // fixture that omits sdnn is silently discarded in full, so these
            // are set to plausible companions of dc rather than left nil.
            s.rmssd = dc * 4
            s.sdnn  = dc * 6
            s.signalQuality = quality
            ctx.insert(s)
        }

        // Before: 5 min at rest.
        for i in stride(from: -300.0, to: 0, by: 30) {
            add(start.addingTimeInterval(i), hr: 58, dc: 9.0, dfa1: 1.10, motion: 4)
        }
        // During: HR 100 → 160, DC 6.0 → 1.2, a1 0.95 → 0.55 (never severe).
        let steps = Int(30 * 60 / 30)
        for i in 0..<steps {
            let f = Double(i) / Double(steps - 1)
            add(start.addingTimeInterval(Double(i) * 30),
                hr: Float(100 + 60 * f),
                dc: Float(6.0 - 4.8 * f),
                dfa1: Float(0.95 - 0.40 * f),
                motion: Float(40 + 20 * f))
        }
        // After: 10 min recovering to roughly 40% of the pre-session DC.
        for i in stride(from: 0.0, through: 600, by: 30) {
            add(end.addingTimeInterval(i), hr: 90, dc: 3.6, dfa1: 0.85, motion: 5)
        }
        try? ctx.save()
        return end
    }

    // MARK: - Activating entries

    func testFinishedExerciseGetsALoadAndASlope() throws {
        let ctx = makeContext()
        let end = seed(ctx)

        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeHRVWindows(context: ctx)
        entry.computeExerciseResponse(context: ctx)

        XCTAssertNotNil(entry.exerciseLoad)
        XCTAssertGreaterThan(entry.exerciseLoad!, 0, "30 min of real work must carry load")

        XCTAssertNotNil(entry.vsiSlopePer10)
        XCTAssertLessThan(entry.vsiSlopePer10!, 0,
                          "DC falls as HR rises, so the slope must be negative")

        let domainTotal = (entry.domainModerateSec ?? 0)
            + (entry.domainHeavySec ?? 0)
            + (entry.domainSevereSec ?? 0)
        XCTAssertEqual(domainTotal, 30 * 60, accuracy: 60,
                       "domain seconds must account for the during-window")
    }

    func testIntervalsClaimsAnExternalWorkSignal() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)
        XCTAssertTrue(entry.hasExternalWorkSignal)
    }

    func testPowerLiftingClaimsNoExternalWorkSignal() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Power Lifting",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)
        XCTAssertFalse(entry.hasExternalWorkSignal,
                       "chest motion does not measure barbell work")
        XCTAssertNil(entry.efficiencySlope)
    }

    func testMergedWalkEntryIsScoredAsExercise() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Walk", activitySubtype: "Hiking",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)
        XCTAssertNotNil(entry.exerciseLoad, "a legacy Walk row must score as exercise")
    }

    // MARK: - Restorative entries are untouched

    func testRestorativeEntryGetsNoExerciseFields() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Meditation", activitySubtype: "Vipassana",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)

        XCTAssertNil(entry.exerciseLoad)
        XCTAssertNil(entry.vsiSlopePer10)
        XCTAssertNil(entry.domainModerateSec)
        XCTAssertFalse(entry.hasExternalWorkSignal)
    }

    func testRestorativeImpactDeltaStillWorks() throws {
        // The old model must be completely undisturbed.
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Meditation", startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeHRVWindows(context: ctx)
        entry.computeExerciseResponse(context: ctx)
        XCTAssertNotNil(entry.impactDeltaPct)
    }

    // MARK: - Guards

    func testUnfinishedEntryIsSkipped() throws {
        let ctx = makeContext()
        seed(ctx)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)
        XCTAssertNil(entry.exerciseLoad, "an active session has no response yet")
    }

    // MARK: - Scores ranked against same-subtype history

    func testScoreIsWithheldUntilThereIsHistoryToRankAgainst() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)

        XCTAssertNotNil(entry.vsiSlopePer10, "the slope itself exists")
        XCTAssertNil(entry.suppressionScore,
                     "but one session cannot be ranked, so no score is invented")
        XCTAssertEqual(entry.scoreHistoryCount, 0)
    }

    func testScoreAppearsOnceThreePeersExist() throws {
        let ctx = makeContext()
        let end = seed(ctx)

        // Three earlier Intervals sessions with slopes to rank against.
        for i in 1...3 {
            let peer = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                   startedAt: start.addingTimeInterval(Double(-i) * 86_400),
                                   endedAt: end.addingTimeInterval(Double(-i) * 86_400))
            peer.vsiSlopePer10 = -0.30 - Double(i) * 0.02
            ctx.insert(peer)
        }
        try? ctx.save()

        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)

        XCTAssertEqual(entry.scoreHistoryCount, 3)
        XCTAssertNotNil(entry.suppressionScore)
    }

    func testPeersOfADifferentSubtypeDoNotCount() throws {
        // A yoga session tells you nothing about the cost of an interval set.
        let ctx = makeContext()
        let end = seed(ctx)
        for i in 1...3 {
            let peer = ActivityLog(activityType: "Exercise", activitySubtype: "Yoga",
                                   startedAt: start.addingTimeInterval(Double(-i) * 86_400),
                                   endedAt: end.addingTimeInterval(Double(-i) * 86_400))
            peer.vsiSlopePer10 = -0.30
            ctx.insert(peer)
        }
        try? ctx.save()

        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)

        XCTAssertEqual(entry.scoreHistoryCount, 0)
        XCTAssertNil(entry.suppressionScore)
    }

    func testEfficiencyScoreIsNeverSetWithoutAnExternalSignal() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        for i in 1...3 {
            let peer = ActivityLog(activityType: "Exercise", activitySubtype: "Power Lifting",
                                   startedAt: start.addingTimeInterval(Double(-i) * 86_400),
                                   endedAt: end.addingTimeInterval(Double(-i) * 86_400))
            peer.efficiencySlope = -0.30
            peer.vsiSlopePer10   = -0.28   // so suppression has peers to rank against
            ctx.insert(peer)
        }
        try? ctx.save()

        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Power Lifting",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        entry.computeExerciseResponse(context: ctx)

        XCTAssertNil(entry.efficiencyScore,
                     "no mechanical denominator means no score, however much history exists")
        XCTAssertNotNil(entry.suppressionScore,
                        "suppression still ranks — it normalises by heart rate")
    }

    func testBackfillFillsEveryFieldAddedSinceTheLastBump() throws {
        // The failure this guards: a stored field is added, the backfill version
        // is not bumped, and every already-logged session keeps showing stale
        // storage while the code reads as though it were correct.
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)
        try? ctx.save()

        // Simulate an entry written under an older version: windows present,
        // exercise response never computed.
        entry.computeHRVWindows(context: ctx)
        entry.exerciseLoad = nil
        entry.halfRecoveryMinutes = nil
        entry.afterTailDC = nil
        try? ctx.save()

        UserDefaults.standard.set(0, forKey: "activityBackfillVersion")
        ActivityLog.backfillMissingWindows(context: ctx)

        XCTAssertNotNil(entry.exerciseLoad, "Load must be rebuilt by the backfill")
        XCTAssertNotNil(entry.afterTailDC, "the recovery tail must be rebuilt")
        XCTAssertNotNil(entry.recoveryObservedMinutes,
                        "recovery timing must be rebuilt, not left to a future session")
    }

    func testRecomputeIsIdempotent() throws {
        let ctx = makeContext()
        let end = seed(ctx)
        let entry = ActivityLog(activityType: "Exercise", activitySubtype: "Intervals",
                                startedAt: start, endedAt: end)
        ctx.insert(entry)

        entry.computeExerciseResponse(context: ctx)
        let load = entry.exerciseLoad
        let slope = entry.vsiSlopePer10

        entry.computeExerciseResponse(context: ctx)
        XCTAssertEqual(entry.exerciseLoad!, load!, accuracy: 0.0001)
        XCTAssertEqual(entry.vsiSlopePer10!, slope!, accuracy: 0.0001)
    }
}
