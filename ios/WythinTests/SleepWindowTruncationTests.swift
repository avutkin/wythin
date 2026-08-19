import XCTest
import SwiftData
@testable import Wythin

/// A night is an order of magnitude longer than any activity this app was built
/// for, and the window fetch was sized for the short case. A fixed limit does
/// not fail loudly — it silently drops the tail of the night, and every window
/// average computed from it is quietly wrong.
final class SleepWindowTruncationTests: XCTestCase {

    private var container: ModelContainer!

    override func setUp() {
        super.setUp()
        let schema = Schema([HRVSample.self, HRVSession.self, DailyAnchor.self, ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() { container = nil; super.tearDown() }

    func testEightHourNightAtForegroundCadenceIsNotTruncated() {
        let ctx = ModelContext(container)

        // 8 h at the 2 s foreground cadence is 14,400 samples — past the old
        // 10,000 ceiling, so the last ~2.8 h of the night vanished.
        let start = Date(timeIntervalSince1970: 1_753_000_000)
        let hours = 8.0
        let spacing = 2.0
        let count = Int(hours * 3600 / spacing)

        // Heart rate climbs steadily, so a truncated fetch shows a lower mean
        // than the whole night does — the assertion has something to bite on.
        for i in 0..<count {
            let s = HRVSample(anchorTestTimestamp: start.addingTimeInterval(Double(i) * spacing),
                              meanBPM: 50 + Float(i) / Float(count) * 20,
                              vti: 3.9, rmssd: 49, sdnn: 58, dc: 8, pip: 45, dfa1: 1.0,
                              breathBPM: 13, motion: 6,
                              signalQuality: 0.97, rrInvalidRate: 0.01, ecgQualityTier: 2)
            ctx.insert(s)
        }

        let log = ActivityLog(activityType: "Sleep", startedAt: start)
        log.endedAt = start.addingTimeInterval(hours * 3600)
        ctx.insert(log)
        log.computeHRVWindows(context: ctx)

        guard let during = log.duringHR else {
            return XCTFail("the night produced no during-window average at all")
        }
        // Whole night averages ~60; truncated at 10,000 samples it averages ~57.
        XCTAssertEqual(during, 60, accuracy: 1.0,
                       "the during-window mean must cover the whole night, not its first 5.5 hours")
    }
}
