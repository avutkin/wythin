import XCTest
@testable import Wythin

final class TrendShapeComputeTests: XCTestCase {

    func testPlateau() {
        XCTAssertEqual(TrendShapeCompute.classify([70, 70.2, 69.9, 70.1, 70]), .plateau)
    }

    func testSteadyFall() {
        XCTAssertEqual(TrendShapeCompute.classify([74, 72.8, 70.2, 68.9, 68.4]), .steadyFall)
    }

    func testSteadyRise() {
        XCTAssertEqual(TrendShapeCompute.classify([60, 63, 66, 70, 74]), .steadyRise)
    }

    func testSpikeAndRecover() {
        XCTAssertEqual(TrendShapeCompute.classify([60, 70, 85, 68, 61]), .spikeAndRecover)
    }

    func testDipAndRecover() {
        XCTAssertEqual(TrendShapeCompute.classify([80, 70, 55, 72, 79]), .dipAndRecover)
    }

    func testOscillating() {
        XCTAssertEqual(TrendShapeCompute.classify([60, 75, 61, 76, 60]), .oscillating)
    }

    func testVolatilityBands() {
        XCTAssertEqual(TrendShapeCompute.volatility([70, 70.1, 70, 70.1, 70]), "low")
        XCTAssertEqual(TrendShapeCompute.volatility([60, 75, 61, 76, 60]), "high")
    }

    func testTooFewBucketsIsPlateau() {
        XCTAssertEqual(TrendShapeCompute.classify([70]), .plateau)
    }
}
