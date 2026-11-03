import XCTest
@testable import Wythin

/// One measurement, one name, everywhere.
///
/// The bug these exist to stop is invisible to every other test in the suite,
/// because each screen was internally consistent: Live titled its RMSSD card
/// "Calm Power", while the Activities grid called RMSSD "Energy Reserve" and
/// gave the name "Calm Power" to `ln RMSSD` in a tile of its own. So the same
/// session read as two different measures depending on which tab you were
/// standing in, and the log twin — `log(RMSSD)`, which carries nothing RMSSD
/// does not — was what made a second name necessary at all.
final class MetricNamingTests: XCTestCase {

    func testEveryNameNamesExactlyOneMeasure() {
        let labels = activityMetricDefs.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count,
                       "two metrics share a label: \(labels)")

        let measures = activityMetricDefs.map(\.metric)
        XCTAssertEqual(Set(measures).count, measures.count,
                       "one measure is showing up under two names: \(labels)")
    }

    /// `vti` is `log(rmssd)` — a transform, not a second measurement. Naming it
    /// separately is what produced the collision, so it must stay unnamed.
    func testRMSSDIsCalmPowerAndTheLogTwinIsNotShown() {
        XCTAssertEqual(metricDef(.rmssd).label, "Calm Power")
        XCTAssertEqual(metricDef(.rmssd).techLabel, "RMSSD")
        XCTAssertEqual(metricDef(.rmssd).unit, "ms")
        XCTAssertFalse(activityMetricDefs.contains { $0.metric == .vti },
                       "ln RMSSD is back on screen under a name of its own")
        XCTAssertFalse(activityMetricDefs.contains { $0.label == "Energy Reserve" },
                       "the retired name is back")
    }

    /// Every name the user reads on a card or tile is one of these — the Live
    /// tiles, the Live charts, the Activities grid, the Activities charts and
    /// the Track charts all read this table rather than typing their own.
    func testTheRegistryCoversExactlyTheMetricsWithATile() {
        XCTAssertEqual(activityMetricDefs.map(\.metric),
                       [.dc, .rcmse, .pip, .dfa1, .stressBalance, .breathBPM, .rsa, .rmssd, .hr],
                       "the tiled metrics, in LiveMetric declaration order")
    }

    /// `metricDef(_:)` is what the Live surfaces call instead of typing a
    /// title, so every tiled metric must resolve.
    func testEveryTiledMetricResolvesToItsDef() {
        for def in activityMetricDefs {
            XCTAssertEqual(metricDef(def.metric).label, def.label)
        }
    }

    /// The WHY list under the live state names the same metrics the charts
    /// above it do. It read "RECOVERY" for RMSSD while the card directly
    /// beneath said CALM POWER.
    func testTheWhyListNamesRMSSDTheWayItsCardDoes() {
        XCTAssertEqual(LiveMetric.rmssd.displayName, metricDef(.rmssd).label.lowercased())
    }

    /// Two rows of that list cannot carry the same word: `rmssd` and `vti` are
    /// the same measurement and both pull on the state, so if they ever share
    /// a display name the list prints one name twice with two different bars.
    func testNoTwoLiveMetricsShareADisplayName() {
        let names = LiveMetric.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "duplicate display name in \(names)")
    }

    /// Benefit direction is single-sourced too — a metric that reads as an
    /// improvement on Live must read as one in the session detail.
    func testDirectionsAgreeBetweenLiveAndTheRegistry() {
        for def in activityMetricDefs {
            XCTAssertEqual(LiveDayComparison.direction(for: def.metric), def.direction,
                           "\(def.label) improves in one direction on Live and the other in Activities")
        }
    }
}
