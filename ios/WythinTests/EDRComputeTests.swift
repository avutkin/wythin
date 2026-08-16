import XCTest
@testable import Wythin

final class EDRComputeTests: XCTestCase {

    /// Synthetic tachogram: mean 800 ms RR, sinusoidally modulated at the
    /// given breathing rate. Beat times accumulate from the RR values
    /// themselves, as in a real recording.
    private func tachogram(brPerMin: Float, seconds: Float = 120,
                           depthMs: Float = 40) -> [Int] {
        var rr: [Int] = []
        var t: Float = 0
        let hz = brPerMin / 60
        while t < seconds {
            let ms = 800 + depthMs * sin(2 * .pi * hz * t)
            rr.append(Int(ms))
            t += ms / 1000
        }
        return rr
    }

    func testRecoversModulationRates() {
        for target: Float in [12, 18, 24] {
            let bpm = EDRCompute.computeRate(rrMs: tachogram(brPerMin: target))
            XCTAssertNotNil(bpm, "no rate at \(target) br/min")
            // One bin at rrFS 4 Hz / nperseg 256 is 0.94 br/min.
            XCTAssertEqual(bpm ?? 0, target, accuracy: 1.0,
                           "expected \(target), got \(String(describing: bpm))")
        }
    }

    /// A pure 0.1 Hz oscillation is indistinguishable from the Mayer wave —
    /// the accept band floors at 0.15 Hz precisely so this yields nil, not a
    /// confident 6 br/min.
    func testMayerWaveYieldsNilNotSix() {
        XCTAssertNil(EDRCompute.computeRate(rrMs: tachogram(brPerMin: 6)))
    }

    func testTooFewBeatsYieldsNil() {
        let short = Array(tachogram(brPerMin: 15).prefix(EDRCompute.minBeats - 1))
        XCTAssertNil(EDRCompute.computeRate(rrMs: short))
    }

    /// An unmodulated tachogram has no respiratory line to find.
    func testFlatTachogramYieldsNil() {
        XCTAssertNil(EDRCompute.computeRate(rrMs: tachogram(brPerMin: 15, depthMs: 0)))
    }
}
