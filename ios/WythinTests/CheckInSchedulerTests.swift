import XCTest
@testable import Wythin

/// The pure timing rules behind the two prompts. Every case here is a real
/// day: the phone's loops only run while the strap keeps the process alive,
/// so what these decide is what gets handed to the OS to fire later.
final class CheckInSchedulerTests: XCTestCase {

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private let noJitter: (ClosedRange<TimeInterval>) -> TimeInterval = { $0.lowerBound }
    private let maxJitter: (ClosedRange<TimeInterval>) -> TimeInterval = { $0.upperBound }

    // MARK: Day keys

    func testDayKeyIsZeroPadded() {
        XCTAssertEqual(CheckInDayKey.string(for: at(2026, 9, 3, 14, 0), calendar: cal), "2026-09-03")
    }

    func testDayKeyFollowsTheCalendarsZoneNotUTC() {
        // 23:30 in Los Angeles is already the next day in UTC.
        XCTAssertEqual(CheckInDayKey.string(for: at(2026, 9, 13, 23, 30), calendar: cal), "2026-09-13")
    }

    func testYesterdayRangeCoversTheWholeLocalDay() {
        let range = CheckInDayKey.yesterdayRange(now: at(2026, 9, 14, 8, 2), calendar: cal)
        XCTAssertEqual(range.lowerBound, at(2026, 9, 13, 0, 0))
        XCTAssertEqual(range.upperBound, at(2026, 9, 14, 0, 0))
    }

    // MARK: Moment fire time

    func testFiresBetweenTenAndFifteenMinutesAfterTheStrapWentOn() {
        let worn = at(2026, 9, 13, 14, 24)
        let now = at(2026, 9, 13, 14, 25)
        let lo = CheckInScheduler.momentFireTime(wornSince: worn, now: now, ledger: .init(), calendar: cal, random: noJitter)
        let hi = CheckInScheduler.momentFireTime(wornSince: worn, now: now, ledger: .init(), calendar: cal, random: maxJitter)
        XCTAssertEqual(lo, at(2026, 9, 13, 14, 34))
        XCTAssertEqual(hi, at(2026, 9, 13, 14, 39))
    }

    func testAlreadyAskedTodayNeverFiresAgain() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        let fire = CheckInScheduler.momentFireTime(wornSince: at(2026, 9, 13, 14, 0), now: at(2026, 9, 13, 14, 1),
                                                   ledger: ledger, calendar: cal, random: noJitter)
        XCTAssertNil(fire)
    }

    func testALateEveningWearWaitsForTheMorningWindow() {
        // Strap on at 23:00: nothing fires that night...
        let worn = at(2026, 9, 13, 23, 0)
        XCTAssertNil(CheckInScheduler.momentFireTime(wornSince: worn, now: at(2026, 9, 13, 23, 12),
                                                     ledger: .init(), calendar: cal, random: noJitter))
        // ...and the same wear, still on at 07:59, is asked at 08:00–08:05.
        let morning = CheckInScheduler.momentFireTime(wornSince: worn, now: at(2026, 9, 14, 7, 59),
                                                      ledger: .init(), calendar: cal, random: maxJitter)
        XCTAssertEqual(morning, at(2026, 9, 14, 8, 5))
    }

    func testAWearThatCannotReachTheWindowBeforeItClosesIsNotAsked() {
        // 20:52 + 10 min = 21:02, past the 21:00 close.
        XCTAssertNil(CheckInScheduler.momentFireTime(wornSince: at(2026, 9, 13, 20, 52), now: at(2026, 9, 13, 20, 53),
                                                     ledger: .init(), calendar: cal, random: noJitter))
    }

    func testAWearJustInsideTheWindowIsAsked() {
        let fire = CheckInScheduler.momentFireTime(wornSince: at(2026, 9, 13, 20, 40), now: at(2026, 9, 13, 20, 41),
                                                   ledger: .init(), calendar: cal, random: noJitter)
        XCTAssertEqual(fire, at(2026, 9, 13, 20, 50))
    }

    func testYesterdaysAskDoesNotBlockToday() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-12"
        ledger.momentFireAt = at(2026, 9, 12, 14, 30)
        let fire = CheckInScheduler.momentFireTime(wornSince: at(2026, 9, 13, 9, 0), now: at(2026, 9, 13, 9, 1),
                                                   ledger: ledger, calendar: cal, random: noJitter)
        XCTAssertEqual(fire, at(2026, 9, 13, 9, 10))
    }

    func testAWearCrossingMidnightAsksOnceForTheNewDay() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"        // asked yesterday afternoon
        ledger.momentFireAt = at(2026, 9, 13, 14, 30)
        let worn = at(2026, 9, 13, 14, 0)              // strap never came off
        let fire = CheckInScheduler.momentFireTime(wornSince: worn, now: at(2026, 9, 14, 7, 30),
                                                   ledger: ledger, calendar: cal, random: noJitter)
        XCTAssertEqual(fire, at(2026, 9, 14, 8, 0))
    }

    // MARK: What to do when the fire time has come

    func testNothingIsDueBeforeTheFireTime() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        XCTAssertEqual(CheckInScheduler.momentDue(now: at(2026, 9, 13, 14, 33), ledger: ledger, calendar: cal), .notYet)
    }

    func testTheAskIsDueFromTheFireTimeForAnHour() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        XCTAssertEqual(CheckInScheduler.momentDue(now: at(2026, 9, 13, 14, 34), ledger: ledger, calendar: cal), .present)
        XCTAssertEqual(CheckInScheduler.momentDue(now: at(2026, 9, 13, 15, 33), ledger: ledger, calendar: cal), .present)
    }

    func testAnHourLaterTheAskIsStale() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        XCTAssertEqual(CheckInScheduler.momentDue(now: at(2026, 9, 13, 15, 35), ledger: ledger, calendar: cal), .stale)
    }

    func testAnAskAlreadyPresentedTodayIsNotDueAgain() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        ledger.momentPresentedDayKey = "2026-09-13"
        XCTAssertEqual(CheckInScheduler.momentDue(now: at(2026, 9, 13, 14, 40), ledger: ledger, calendar: cal), .notYet)
    }

    func testNothingScheduledMeansNothingDue() {
        XCTAssertEqual(CheckInScheduler.momentDue(now: at(2026, 9, 13, 14, 40), ledger: .init(), calendar: cal), .notYet)
    }

    // MARK: Strap off before the fire time

    func testStrapOffBeforeTheFireTimeCancelsTheAsk() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        XCTAssertTrue(CheckInScheduler.shouldCancelOnStrapOff(now: at(2026, 9, 13, 14, 30), ledger: ledger))
        let cleared = CheckInScheduler.cancelled(ledger)
        XCTAssertNil(cleared.momentAskedDayKey)
        XCTAssertNil(cleared.momentFireAt)
    }

    func testStrapOffAfterTheFireTimeKeepsTheDayAsAsked() {
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        XCTAssertFalse(CheckInScheduler.shouldCancelOnStrapOff(now: at(2026, 9, 13, 14, 35), ledger: ledger))
    }

    // MARK: Previous-day review

    func testThePreviousDayIsDueOnceOnTheFirstOpenWhenYesterdayHadData() {
        let now = at(2026, 9, 14, 8, 2)
        XCTAssertEqual(CheckInScheduler.previousDayDue(now: now, ledger: .init(), hadStrapDataYesterday: true, calendar: cal),
                       "2026-09-13")
        var shown = CheckInLedger()
        shown.previousDayShownDayKey = "2026-09-14"
        XCTAssertNil(CheckInScheduler.previousDayDue(now: now, ledger: shown, hadStrapDataYesterday: true, calendar: cal))
    }

    func testThePreviousDayIsNotAskedWhenYesterdayHadNoStrapData() {
        XCTAssertNil(CheckInScheduler.previousDayDue(now: at(2026, 9, 14, 8, 2), ledger: .init(),
                                                     hadStrapDataYesterday: false, calendar: cal))
    }

    func testAReviewShownYesterdayIsDueAgainToday() {
        var ledger = CheckInLedger()
        ledger.previousDayShownDayKey = "2026-09-13"
        XCTAssertEqual(CheckInScheduler.previousDayDue(now: at(2026, 9, 14, 8, 2), ledger: ledger,
                                                       hadStrapDataYesterday: true, calendar: cal), "2026-09-13")
    }

    // MARK: Ledger persistence

    func testTheLedgerRoundTripsThroughItsDefaultsKey() {
        let defaults = UserDefaults(suiteName: "CheckInSchedulerTests")!
        defaults.removePersistentDomain(forName: "CheckInSchedulerTests")
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-13"
        ledger.momentFireAt = at(2026, 9, 13, 14, 34)
        ledger.previousDayShownDayKey = "2026-09-13"
        ledger.save(to: defaults)
        XCTAssertEqual(CheckInLedger.load(from: defaults), ledger)
        XCTAssertEqual(CheckInLedger.load(from: UserDefaults(suiteName: "CheckInSchedulerTests.empty")!), CheckInLedger())
    }
}
