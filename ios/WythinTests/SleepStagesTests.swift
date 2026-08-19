import XCTest
@testable import Wythin

final class SleepStagesTests: XCTestCase {

    /// One stretch of ticks with the autonomic signature of a given state.
    /// The discriminators are the ones §6 of the research found actually
    /// separate the states on a cardiac signal: RR↔breath coherence, LF/HF and
    /// SDNN for quiet-vs-active, motion and heart rate for wake.
    private func stretch(minutes: Double,
                         from offsetMin: Double,
                         motion: Float,
                         hr: Float,
                         coherence: Float,
                         lfHF: Float,
                         sdnn: Float,
                         spacing: Double = 30) -> [MetricsHistoryPoint] {
        var comps = DateComponents(year: 2026, month: 7, day: 20)
        comps.hour = 23
        let base = Calendar.current.date(from: comps)!.addingTimeInterval(offsetMin * 60)
        let count = Int((minutes * 60) / spacing)
        return (0..<count).map { i in
            MetricsHistoryPoint(anchorTestTimestamp: base.addingTimeInterval(Double(i) * spacing),
                                meanBPM: hr, vti: 3.9, dc: 8, pip: 45, dfa1: 1.0,
                                breathBPM: 13, motion: motion,
                                signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2,
                                coherence: coherence, sdnn: sdnn, lfHF: lfHF)
        }
    }

    private func quiet(_ min: Double, from: Double) -> [MetricsHistoryPoint] {
        stretch(minutes: min, from: from, motion: 4, hr: 50, coherence: 0.94, lfHF: 0.5, sdnn: 54)
    }
    private func active(_ min: Double, from: Double) -> [MetricsHistoryPoint] {
        stretch(minutes: min, from: from, motion: 12, hr: 56, coherence: 0.72, lfHF: 2.0, sdnn: 105)
    }
    private func awake(_ min: Double, from: Double) -> [MetricsHistoryPoint] {
        stretch(minutes: min, from: from, motion: 180, hr: 66, coherence: 0.5, lfHF: 3.0, sdnn: 70)
    }

    func testStillHighCoherenceStretchReadsAsQuietSleep() {
        let stages = SleepStages.classify(quiet(60, from: 0))
        XCTAssertEqual(stages.count, 120)
        XCTAssertTrue(stages.allSatisfy { $0 == .quiet },
                      "high coherence, low LF/HF and low SDNN is the deep-sleep signature")
    }

    func testMovingElevatedStretchReadsAsAwake() {
        let stages = SleepStages.classify(awake(20, from: 0))
        XCTAssertTrue(stages.allSatisfy { $0 == .wake })
    }

    func testLowCoherenceHighVariabilityStretchReadsAsActiveSleep() {
        let stages = SleepStages.classify(active(30, from: 0))
        XCTAssertTrue(stages.allSatisfy { $0 == .active },
                      "REM-like: coherence collapses, LF/HF and SDNN rise, but still asleep")
    }

    func testAbsorbsSingleTickSpikesIntoTheSurroundingStage() {
        // One 30-second twitch inside an hour of quiet sleep is a turn, not a
        // wake bout. Left raw, per-sample labels shatter a night into confetti.
        var points = quiet(30, from: 0)
        points += awake(0.5, from: 30)      // exactly one tick
        points += quiet(30, from: 30.5)
        let stages = SleepStages.classify(points)

        XCTAssertFalse(stages.contains(.wake),
                       "an isolated tick cannot outvote the hour around it")
    }

    func testKeepsAGenuineWakeBout() {
        // Ten minutes of movement IS a wake bout and must survive smoothing.
        var points = quiet(30, from: 0)
        points += awake(10, from: 30)
        points += quiet(30, from: 40)
        let stages = SleepStages.classify(points)

        let wakeTicks = stages.filter { $0 == .wake }.count
        XCTAssertGreaterThan(wakeTicks, 12, "10 min at 30 s ticks is 20 samples")
    }
}
