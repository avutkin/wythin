import XCTest
@testable import Wythin

final class HeartRateZonesTests: XCTestCase {

    private let start = Date(timeIntervalSince1970: 5000)
    private func t(_ o: TimeInterval) -> Date { start.addingTimeInterval(o) }

    // MARK: - Boundaries

    func testEachBoundaryFallsInTheHigherZone() {
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 0.00), .z1)
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 0.59), .z1)
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 0.60), .z2)
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 0.70), .z3)
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 0.80), .z4)
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 0.90), .z5)
        XCTAssertEqual(HeartRateZones.zone(hrReserve: 1.00), .z5)
    }

    // MARK: - Time in zone

    func testSecondsAccumulatePerZone() {
        let s: [(date: Date, hrReserve: Double)] = [
            (t(0),   0.50),   // Z1 for 60 s
            (t(60),  0.65),   // Z2 for 60 s
            (t(120), 0.85),   // Z4 for 60 s
            (t(180), 0.95),   // Z5 — last sample carries no forward time
        ]
        let split = HeartRateZones.split(samples: s)
        XCTAssertEqual(split[.z1] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(split[.z2] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(split[.z4] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(split[.z5] ?? 0, 0, accuracy: 0.001)
        XCTAssertNil(split[.z3])
    }

    func testLongGapsAreDroppedLikeEverywhereElse() {
        // Must match Load and the domain split, or the three disagree about how
        // long the session was.
        let s: [(date: Date, hrReserve: Double)] = [(t(0), 0.7), (t(2400), 0.7)]
        XCTAssertTrue(HeartRateZones.split(samples: s).isEmpty)
    }

    func testASingleSampleHasNoDuration() {
        XCTAssertTrue(HeartRateZones.split(samples: [(t(0), 0.8)]).isEmpty)
    }

    func testOrderDoesNotMatter() {
        let s: [(date: Date, hrReserve: Double)] = [
            (t(120), 0.85), (t(0), 0.50), (t(60), 0.65),
        ]
        let split = HeartRateZones.split(samples: s)
        XCTAssertEqual(split[.z1] ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(split[.z2] ?? 0, 60, accuracy: 0.001)
    }

    // MARK: - Polarisation

    func testPolarisationSplitsEasyMiddleAndHard() {
        let split: [HeartRateZone: TimeInterval] = [.z1: 300, .z2: 300, .z3: 200, .z4: 100, .z5: 100]
        let p = HeartRateZones.polarisation(split)!
        XCTAssertEqual(p.easy,   0.6, accuracy: 0.001)
        XCTAssertEqual(p.middle, 0.2, accuracy: 0.001)
        XCTAssertEqual(p.hard,   0.2, accuracy: 0.001)
    }

    func testTheThreeSharesSumToOne() {
        let split: [HeartRateZone: TimeInterval] = [.z2: 700, .z3: 150, .z5: 150]
        let p = HeartRateZones.polarisation(split)!
        XCTAssertEqual(p.easy + p.middle + p.hard, 1.0, accuracy: 0.001)
    }

    func testAnEmptySplitHasNoPolarisation() {
        XCTAssertNil(HeartRateZones.polarisation([:]))
    }

    // MARK: - Labels

    func testEveryZoneIsNamedInPlainWords() {
        for z in HeartRateZone.allCases {
            XCTAssertFalse(z.label.isEmpty)
            XCTAssertEqual(z.shortLabel, "Z\(z.rawValue)")
        }
    }
}
