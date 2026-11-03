import XCTest
import SwiftData
@testable import Wythin

/// Breath Rate as the ninth named metric, and the card printing a measured
/// percentage instead of a ceiling.
///
/// The card had said "8/9 improved" under eight tiles for as long as the legend
/// existed: the ninth slot was reserved for the one measure on the screen a
/// person can move on purpose, and nothing filled it. The same card printed
/// ">+100%" twice — a marker where a number belongs, indistinguishable to a
/// reader from a measurement, and unable to tell a doubling from an eightfold
/// rise.
final class BreathRateMetricTests: XCTestCase {

    // MARK: - The ninth metric

    func testBreathRateIsInTheRegistryUnderOneName() {
        let def = metricDef(.breathBPM)
        XCTAssertEqual(def.label, "Breath Rate")
        XCTAssertEqual(def.unit, "br/min")
        XCTAssertEqual(def.direction, .lower,
                       "slower breathing is the improvement; the tile colours by this")
    }

    /// The legend has always said nine. It is a count of the table, so the
    /// table has to be nine long or the card contradicts itself.
    func testTheCardsDenominatorMatchesTheTable() {
        XCTAssertEqual(activityMetricDefs.count, 9)
    }

    /// Live reads its tiles straight off the same table, so a metric joining it
    /// joins the Live grid too — the check that the Live tile exists at all.
    func testBreathRateResolvesForTheLiveTile() {
        XCTAssertTrue(activityMetricDefs.contains { $0.metric == .breathBPM })
        XCTAssertEqual(LiveDayComparison.direction(for: .breathBPM),
                       metricDef(.breathBPM).direction,
                       "Live and Activities must agree on which way Breath Rate improves")
    }

    /// The def's keypaths have to land on the fields `computeHRVWindows` fills,
    /// or the tile shows a dash beside a stored number.
    func testTheDefReadsTheStoredWindowAverages() {
        let e = ActivityLog(activityType: "Meditation")
        e.beforeBreath = 14
        e.duringBreath = 6.5
        e.afterBreath  = 9

        let def = metricDef(.breathBPM)
        XCTAssertEqual(e[keyPath: def.beforeKey], 14)
        XCTAssertEqual(e[keyPath: def.duringKey], 6.5)

        // Benefit-signed: breathing fell, so the change is positive.
        let uplift = def.rawBenefitDelta(current: 6.5, base: 14)
        XCTAssertNotNil(uplift)
        XCTAssertGreaterThan(uplift!, 0)
        XCTAssertEqual(uplift!, (14 - 6.5) / 14 * 100, accuracy: 0.001)
    }

    func testBreathRateJoinsTheCardsReadings() {
        let e = ActivityLog(activityType: "Meditation")
        e.beforeBreath = 14
        e.duringBreath = 7
        e.afterBreath  = 10

        let reading = ActivityLogRow(entry: e).readings.first { $0.label == "Breath Rate" }
        XCTAssertNotNil(reading, "Breath Rate has no row in the card's grid")
        XCTAssertEqual(reading?.durPct ?? 0, 50, accuracy: 0.001)
        XCTAssertEqual(reading?.aftPct ?? 0, (14 - 10) / 14 * 100, accuracy: 0.001)
    }

    // MARK: - Stored window averages

    func testComputeHRVWindowsStoresBreathRateForEachWindow() {
        let schema = Schema([ActivityLog.self, HRVSample.self, HRVSession.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let ctx    = ModelContext(try! ModelContainer(for: schema, configurations: [config]))

        let start = Date(timeIntervalSince1970: 2_000_000)
        let end   = start.addingTimeInterval(20 * 60)

        func add(_ date: Date, breath: Float) {
            let s = HRVSample(from: MetricsTick(
                timestamp: date,
                meanBPM: 62, sdnn: nil, rmssd: nil, pnn50: nil, vti: nil,
                ulfPower: nil, vlfPower: nil, lfPower: nil, hfPower: nil, lfHF: nil,
                rsaMs: nil, rsaIdx: nil,
                breathBPM: breath, breathHz: nil, regularity: nil,
                coherenceScore: nil, cbi: nil,
                dfa1: nil, signalQuality: nil,
                ecgQuality: nil,
                rcmse: nil, pip: nil, ials: nil, dc: nil,
                breathPhases: nil,
                psdFreqs: nil, psdValues: nil,
                coherenceFreqs: nil, coherenceValues: nil))
            // MetricsQualityFilter gates every window on sdnn/rmssd being
            // plausible against meanBPM; a fixture without them is discarded
            // whole and the assertions below would pass on an empty average.
            s.rmssd = 45
            s.sdnn  = 60
            s.signalQuality = 0.95
            ctx.insert(s)
        }

        // Five minutes before at 14, twenty during at 6, ten after at 9.
        for i in 0..<10  { add(start.addingTimeInterval(-300 + Double(i) * 30), breath: 14) }
        for i in 0..<40  { add(start.addingTimeInterval(Double(i) * 30), breath: 6) }
        for i in 1...20  { add(end.addingTimeInterval(Double(i) * 30), breath: 9) }

        let e = ActivityLog(activityType: "Meditation", startedAt: start, endedAt: end)
        ctx.insert(e)
        e.computeHRVWindows(context: ctx)

        XCTAssertEqual(e.beforeBreath ?? 0, 14, accuracy: 0.01)
        XCTAssertEqual(e.duringBreath ?? 0, 6,  accuracy: 0.01)
        XCTAssertEqual(e.afterBreath  ?? 0, 9,  accuracy: 0.01)
    }

    /// A session recorded before the field existed has no breath rate, and must
    /// say so rather than borrowing a neighbour's number.
    func testASessionWithoutBreathRateReportsItMissing() {
        let e = ActivityLog(activityType: "Meditation")
        e.beforeHR = 70; e.duringHR = 63

        let reading = ActivityLogRow(entry: e).readings.first { $0.label == "Breath Rate" }
        XCTAssertNil(reading?.durPct)
        XCTAssertEqual(reading?.durValue, "—")
        XCTAssertTrue(e.impactCoverage.missing.contains { $0.label == "Breath Rate" })
    }

    // MARK: - The percentage is the measurement

    /// The card's own numbers, not the ±100 % bound the multi-metric mean uses.
    func testTheCardPrintsChangesBeyondAHundredPercent() {
        let e = ActivityLog(activityType: "Meditation")
        e.beforeDC = 5;  e.duringDC = 20      // +300 %
        e.beforeHR = 60; e.afterHR  = 45      // +25 % benefit-signed

        let readings = ActivityLogRow(entry: e).readings
        let dc = readings.first { $0.label == "Vagal Tone" }
        XCTAssertEqual(dc?.durPct ?? 0, 300, accuracy: 0.001,
                       "a fourfold rise has to read as a fourfold rise")

        let hr = readings.first { $0.label == "Pulse" }
        XCTAssertEqual(hr?.aftPct ?? 0, 25, accuracy: 0.001)
    }

    /// The bound still guards the mean it was written for — removing it from
    /// the display must not have removed it from `impactDeltaPct`.
    func testTheMeanKeepsItsBound() {
        let def = metricDef(.dc)
        XCTAssertEqual(def.benefitDelta(current: 20, base: 5), ActivityMetricDef.deltaBound)
        XCTAssertEqual(def.rawBenefitDelta(current: 20, base: 5)!, 300, accuracy: 0.001)
    }

    /// Switching the card to raw percentages must not move any score: credit
    /// per metric already tops out at +20 %, so everything past it was always
    /// worth the same.
    func testTheScoreIsUnchangedByUncappingTheDisplay() {
        let clamped = RestorativeScore.score(during: [100, 30, 12], after: [100, 20, 5])
        let raw     = RestorativeScore.score(during: [742, 30, 12], after: [1_310, 20, 5])
        XCTAssertEqual(clamped, raw)
    }
}
