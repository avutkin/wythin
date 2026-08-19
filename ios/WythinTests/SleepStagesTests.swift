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
        stretch(minutes: min, from: from, motion: 6, hr: 56, coherence: 0.72, lfHF: 2.0, sdnn: 105)
    }
    private func awake(_ min: Double, from: Double) -> [MetricsHistoryPoint] {
        stretch(minutes: min, from: from, motion: 180, hr: 66, coherence: 0.5, lfHF: 3.0, sdnn: 70)
    }

    func testTellsTheQuietHalfOfANightFromTheActiveHalf() {
        // A structured night, because that is the only thing the question can
        // be asked of. Classification is relative to the recording's own
        // medians — measured against a real night, the published absolutes do
        // not transfer at all — so a flat stretch has no quiet and active
        // halves to find, and inventing them would be noise.
        var points = quiet(45, from: 0)
        points += active(45, from: 45)
        points += quiet(45, from: 90)
        let stages = SleepStages.classify(points)

        let firstQuiet = stages[0..<90]
        let middle = stages[90..<180]
        XCTAssertTrue(firstQuiet.allSatisfy { $0 == .quiet },
                      "high coherence with low LF/HF and low SDNN is the quiet signature")
        XCTAssertTrue(middle.allSatisfy { $0 == .active },
                      "coherence collapses and variability rises — still asleep, not quiet")
    }

    func testMovementInsideANightReadsAsAwake() {
        // Wake is a departure from this recording's own stillness, not a fixed
        // level: measured asleep motion is about 4 mg and awake about 13, so an
        // absolute gate taken from the literature (100 mg) never fires at all.
        var points = quiet(60, from: 0)
        points += awake(20, from: 60)
        points += quiet(60, from: 80)
        let stages = SleepStages.classify(points)

        XCTAssertTrue(stages[120..<160].allSatisfy { $0 == .wake })
        XCTAssertFalse(stages[0..<120].contains(.wake), "the quiet hour before it is not wake")
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
