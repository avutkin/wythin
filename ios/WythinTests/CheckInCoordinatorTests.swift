import XCTest
import SwiftData
import UserNotifications
@testable import Wythin

/// The coordinator against a real in-memory store, a fake notification
/// centre and a clock the test moves. Each case is a day in the life.
@MainActor
final class CheckInCoordinatorTests: XCTestCase {

    private final class FakeNotifier: CheckInNotifying {
        var status: UNAuthorizationStatus = .authorized
        var scheduled: [Date] = []
        var cancelCount = 0
        var clearCount = 0
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func requestAuthorization() async -> Bool { status = .authorized; return true }
        func schedule(fireAt: Date, now: Date) async { scheduled.append(fireAt) }
        func cancelPending() { cancelCount += 1 }
        func clearDelivered() { clearCount += 1 }
    }

    private final class RecordingClient: FeltStateAPIClient, @unchecked Sendable {
        var payloads: [FeltStateUploadPayload] = []
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            payloads.append(payload)
        }
    }

    private final class Clock { var now: Date; init(_ now: Date) { self.now = now } }

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    private var container: ModelContainer!
    private var notifier: FakeNotifier!
    private var client: RecordingClient!
    private var clock: Clock!
    private var defaults: UserDefaults!
    private let watermarkKey = "feltStateLogs.lastUploadedTimestamp"

    override func setUp() {
        super.setUp()
        let schema = Schema([FeltStateLog.self, HRVSample.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        notifier = FakeNotifier()
        client = RecordingClient()
        clock = Clock(at(2026, 9, 14, 8, 2))
        defaults = UserDefaults(suiteName: "CheckInCoordinatorTests")!
        defaults.removePersistentDomain(forName: "CheckInCoordinatorTests")
        UserDefaults.standard.removeObject(forKey: watermarkKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: watermarkKey)
        super.tearDown()
    }

    private func makeCoordinator() -> CheckInCoordinator {
        let clock = self.clock!
        return CheckInCoordinator(container: container, notifier: notifier, client: client,
                                  userID: "u", defaults: defaults, calendar: cal, clock: { clock.now })
    }

    private func addSample(at date: Date) {
        container.mainContext.insert(HRVSample(cloudTs: date, meanBPM: 60, rmssd: 40, sdnn: nil, pnn50: nil,
                                               lfHF: nil, rsaMs: nil, coherence: nil, cbi: nil, breathBPM: nil,
                                               dfa1: nil, rcmse: nil, pip: nil, dc: nil, vti: nil))
        try? container.mainContext.save()
    }

    private func fetchLogs() -> [FeltStateLog] {
        (try? container.mainContext.fetch(FetchDescriptor<FeltStateLog>())) ?? []
    }

    // MARK: Previous day

    func testTheMorningReviewShowsOnceWhenYesterdayHadStrapData() {
        addSample(at: at(2026, 9, 13, 15, 0))
        let c = makeCoordinator()
        c.canPresent = true
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented, .previousDay(dayKey: "2026-09-13"))

        c.skipPresented()
        XCTAssertNil(c.presented)
        c.appDidBecomeActive()
        XCTAssertNil(c.presented, "once a day, skipped or not")
    }

    func testNoReviewWithoutStrapDataYesterday() {
        addSample(at: at(2026, 9, 12, 15, 0))   // the day before yesterday only
        let c = makeCoordinator()
        c.canPresent = true
        c.appDidBecomeActive()
        XCTAssertNil(c.presented)
    }

    func testNothingIsPresentedUntilTheGateOpens() {
        addSample(at: at(2026, 9, 13, 15, 0))
        let c = makeCoordinator()
        c.appDidBecomeActive()
        XCTAssertNil(c.presented, "onboarding or the cloud notice is up")
        c.canPresent = true
        XCTAssertEqual(c.presented, .previousDay(dayKey: "2026-09-13"))
    }

    func testAnsweringTheReviewWritesARowAboutYesterdayAndUploadsIt() async {
        addSample(at: at(2026, 9, 13, 15, 0))
        let c = makeCoordinator()
        c.canPresent = true
        c.appDidBecomeActive()
        var draft = FeltStateDraft.empty
        draft.sleep = 35
        draft.focus = 60

        c.save(draft, for: .previousDay(dayKey: "2026-09-13"))

        XCTAssertNil(c.presented)
        let logs = fetchLogs()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.kind, "previous_day")
        XCTAssertEqual(logs.first?.dayKey, "2026-09-13")
        XCTAssertEqual(logs.first?.sleep, 35)
        XCTAssertNil(logs.first?.mood)
        XCTAssertEqual(logs.first?.timestamp, clock.now, "saved now, not back-dated")
        // The flush is a Task; give it a turn.
        for _ in 0..<20 where client.payloads.isEmpty { await Task.yield() }
        XCTAssertEqual(client.payloads.count, 1)
        XCTAssertEqual(client.payloads.first?.kind, "previous_day")
    }

    // MARK: Moment

    func testAWearSchedulesTheAskWithTheOSTenToFifteenMinutesIn() async {
        let c = makeCoordinator()
        c.canPresent = true
        let worn = at(2026, 9, 14, 14, 24)
        c.strapPolled(connected: true, wornSince: worn, now: worn.addingTimeInterval(5), isForeground: false)
        for _ in 0..<20 where notifier.scheduled.isEmpty { await Task.yield() }

        XCTAssertEqual(notifier.scheduled.count, 1)
        let fireAt = notifier.scheduled[0]
        XCTAssertGreaterThanOrEqual(fireAt, worn.addingTimeInterval(10 * 60))
        XCTAssertLessThanOrEqual(fireAt, worn.addingTimeInterval(15 * 60))

        // Later polls of the same wear do not schedule again.
        c.strapPolled(connected: true, wornSince: worn, now: worn.addingTimeInterval(60), isForeground: false)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(notifier.scheduled.count, 1)
    }

    func testWithoutPermissionNothingIsHandedToTheOSButTheForegroundPollStillAsks() async {
        notifier.status = .denied
        let c = makeCoordinator()
        c.canPresent = true
        let worn = at(2026, 9, 14, 14, 24)
        c.strapPolled(connected: true, wornSince: worn, now: worn.addingTimeInterval(5), isForeground: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(notifier.scheduled.isEmpty)
        XCTAssertNil(c.presented)

        clock.now = worn.addingTimeInterval(16 * 60)
        c.strapPolled(connected: true, wornSince: worn, now: clock.now, isForeground: true)
        guard case .moment(_, let wornMinutes)? = c.presented else {
            return XCTFail("expected the moment sheet, got \(String(describing: c.presented))")
        }
        XCTAssertEqual(wornMinutes ?? 0, 16, accuracy: 0.01)
    }

    func testStrapOffBeforeTheAskCancelsItAndTheNextWearAsksAgain() async {
        let c = makeCoordinator()
        c.canPresent = true
        let worn = at(2026, 9, 14, 14, 24)
        c.strapPolled(connected: true, wornSince: worn, now: worn.addingTimeInterval(5), isForeground: false)
        for _ in 0..<20 where notifier.scheduled.isEmpty { await Task.yield() }

        c.strapPolled(connected: false, wornSince: nil, now: worn.addingTimeInterval(3 * 60), isForeground: false)
        XCTAssertEqual(notifier.cancelCount, 1)

        let again = at(2026, 9, 14, 16, 0)
        c.strapPolled(connected: true, wornSince: again, now: again.addingTimeInterval(5), isForeground: false)
        for _ in 0..<20 where notifier.scheduled.count < 2 { await Task.yield() }
        XCTAssertEqual(notifier.scheduled.count, 2)
    }

    func testAnAskOpenedWithinTheHourIsPresentedAndAnHourLaterIsDropped() async {
        let c = makeCoordinator()
        c.canPresent = true
        let worn = at(2026, 9, 14, 14, 24)
        c.strapPolled(connected: true, wornSince: worn, now: worn.addingTimeInterval(5), isForeground: false)
        for _ in 0..<20 where notifier.scheduled.isEmpty { await Task.yield() }
        let fireAt = notifier.scheduled[0]

        // The person opens the app twenty minutes after the banner.
        clock.now = fireAt.addingTimeInterval(20 * 60)
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented?.kind, .moment)
        XCTAssertEqual(notifier.clearCount, 1, "the delivered banner is cleared once answered for")

        // A second coordinator (a relaunch) two hours on finds the ask stale.
        c.skipPresented()
        defaults.removePersistentDomain(forName: "CheckInCoordinatorTests")
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-14"
        ledger.momentFireAt = fireAt
        ledger.save(to: defaults)
        clock.now = fireAt.addingTimeInterval(2 * 60 * 60)
        let later = makeCoordinator()
        later.canPresent = true
        later.appDidBecomeActive()
        XCTAssertNil(later.presented)
        XCTAssertEqual(notifier.clearCount, 2)
    }

    func testTheReviewGoesFirstAndTheMomentFollowsIt() {
        addSample(at: at(2026, 9, 13, 15, 0))
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-14"
        ledger.momentFireAt = at(2026, 9, 14, 7, 50)
        ledger.save(to: defaults)
        let c = makeCoordinator()          // 08:02: both due
        c.canPresent = true
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented, .previousDay(dayKey: "2026-09-13"))
        c.skipPresented()
        XCTAssertEqual(c.presented?.kind, .moment)
    }

    func testTheLedgerSurvivesARelaunch() {
        let c = makeCoordinator()
        c.canPresent = true
        let worn = at(2026, 9, 14, 14, 24)
        c.strapPolled(connected: true, wornSince: worn, now: worn.addingTimeInterval(5), isForeground: false)
        let reloaded = CheckInLedger.load(from: defaults)
        XCTAssertEqual(reloaded.momentAskedDayKey, "2026-09-14")
        XCTAssertNotNil(reloaded.momentFireAt)
    }
}
