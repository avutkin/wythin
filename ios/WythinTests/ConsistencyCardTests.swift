import XCTest
@testable import Wythin

/// `ConsistencyCard.wearDisplayValue` is the pure presentation rule behind
/// the WEAR row's 6M coverage signal (see `ConsistencyCard.swift`). It is a
/// free `static` function of `(bucket, period)` specifically so it can be
/// exercised here without going through SwiftUI rendering — this codebase
/// has no view test target, and none is added for this.
final class ConsistencyCardTests: XCTestCase {

    private func bucket(wearHours: Double, wearDayCount: Int) -> ConsistencySummary.Bucket {
        let start = Date(timeIntervalSince1970: 0)
        let end   = start.addingTimeInterval(86_400 * 30)
        return ConsistencySummary.Bucket(
            bucket:          TrackBucket(start: start, end: end, label: "JUN"),
            practiceMinutes: 0,
            wearHours:       wearHours,
            hasData:         wearDayCount > 0,
            wearDayCount:    wearDayCount)
    }

    /// A 6M month built on fewer worn days than
    /// `TrackSeriesBuilder.minDaysPerMonthBucket` must not plot its true,
    /// misleadingly-solid mean — three days at 14h/day is suppressed to 0,
    /// the row's own existing "no real value" signal (see `row(...)`'s
    /// floor-stub handling), matching how the charts above it suppress the
    /// same sparse month instead of drawing it as representative.
    func testSparse6MonthBucketIsSuppressed() {
        let b = bucket(wearHours: 14, wearDayCount: TrackSeriesBuilder.minDaysPerMonthBucket - 1)
        XCTAssertEqual(ConsistencyCard.wearDisplayValue(b, period: .sixMonth), 0, accuracy: 0.001)
    }

    /// A 6M month with at least the minimum worn days is plotted at its true
    /// mean, unaffected by the coverage rule.
    func testWellCovered6MonthBucketIsUnaffected() {
        let b = bucket(wearHours: 14, wearDayCount: TrackSeriesBuilder.minDaysPerMonthBucket)
        XCTAssertEqual(ConsistencyCard.wearDisplayValue(b, period: .sixMonth), 14, accuracy: 0.001)
    }

    /// W and M buckets are a single day each, so `wearDayCount` there is
    /// always 0 or 1 — below the 6M threshold. Without the period gate this
    /// rule would suppress every single-day bucket in the row; confirms it
    /// does not.
    func testWeekBucketIsNeverSuppressedRegardlessOfDayCount() {
        let b = bucket(wearHours: 8, wearDayCount: 1)
        XCTAssertEqual(ConsistencyCard.wearDisplayValue(b, period: .week), 8, accuracy: 0.001)
    }

    /// Same guard, for M.
    func testMonthBucketIsNeverSuppressedRegardlessOfDayCount() {
        let b = bucket(wearHours: 8, wearDayCount: 1)
        XCTAssertEqual(ConsistencyCard.wearDisplayValue(b, period: .month), 8, accuracy: 0.001)
    }
}
