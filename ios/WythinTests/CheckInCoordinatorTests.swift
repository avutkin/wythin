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
        var pendingFireAt: Date?
        var suspendNextSchedule = false
        var scheduleContinuation: CheckedContinuation<Void, Never>?
        func authorizationStatus() async -> UNAuthorizationStatus { status }
        func requestAuthorization() async -> Bool { status = .authorized; return true }
        func schedule(fireAt: Date, now: Date) async {
            if suspendNextSchedule {
                suspendNextSchedule = false
                await withCheckedContinuation { scheduleContinuation = $0 }
            }
            scheduled.append(fireAt)
            pendingFireAt = fireAt
        }
        func cancelPending() { cancelCount += 1; pendingFireAt = nil }
        func clearDelivered() { clearCount += 1 }
    }

    private final class RecordingClient: FeltStateAPIClient, @unchecked Sendable {
        let baseURL = URL(string: "https://checkin-tests.example")!
        var payloads: [FeltStateUploadPayload] = []
        var shouldFail = false
        struct Offline: Error {}
        func uploadFeltStateLog(_ payload: FeltStateUploadPayload, userID: String) async throws {
            payloads.append(payload)
            if shouldFail { throw Offline() }
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

    private func makeCoordinator(saveContext: ((ModelContext) throws -> Void)? = nil) -> CheckInCoordinator {
        let clock = self.clock!
        return CheckInCoordinator(container: container, notifier: notifier, client: client,
                                  userID: "u", defaults: defaults, calendar: cal,
                                  saveContext: saveContext ?? { try $0.save() }, clock: { clock.now })
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

    // MARK: Recovery without another answer

    private func addSavedAnswer() -> FeltStateLog {
        let log = FeltStateLog(timestamp: clock.now.addingTimeInterval(-3600), kind: "moment",
                               focus: 65, energy: nil, stress: nil, mood: nil, anxiety: nil,
                               sleep: nil, dayKey: "2026-09-14", timezone: "America/Los_Angeles",
                               wornMinutes: 12, stateKey: nil)
        container.mainContext.insert(log)
        try! container.mainContext.save()
        return log
    }

    private func allowScheduledUpload() async {
        for _ in 0..<100 { await Task.yield() }
    }

    func testReturningToForegroundRetriesSavedAnswersWithoutAnotherAnswer() async {
        let log = addSavedAnswer()
        let c = makeCoordinator()
        client.shouldFail = true
        c.appDidBecomeActive()
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.map(\.id), [log.id.uuidString])

        client.shouldFail = false
        c.appDidBecomeActive()
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.map(\.id), [log.id.uuidString, log.id.uuidString])
        XCTAssertEqual(fetchLogs().count, 1, "retry must keep the original answer")
    }

    func testForegroundPollRetriesAfterNetworkRecoveryEvenWithoutAStrap() async {
        let log = addSavedAnswer()
        let c = makeCoordinator()
        client.shouldFail = true
        c.appDidBecomeActive()
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.count, 1)

        client.shouldFail = false
        let start = clock.now
        clock.now = start.addingTimeInterval(59)
        c.strapPolled(connected: false, wornSince: nil, now: clock.now, isForeground: true)
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.count, 1, "do not retry every five-second poll")

        clock.now = start.addingTimeInterval(60)
        c.strapPolled(connected: false, wornSince: nil, now: clock.now, isForeground: false)
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.count, 1, "the periodic retry is foreground-only")

        c.strapPolled(connected: false, wornSince: nil, now: clock.now, isForeground: true)
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.map(\.id), [log.id.uuidString, log.id.uuidString])
    }

    func testCloudSyncOffKeepsAnswerLocalUntilSyncIsEnabled() async {
        defaults.set(false, forKey: "cloudSyncEnabled")
        let c = makeCoordinator()
        var draft = FeltStateDraft.empty
        draft.energy = 72
        c.save(draft, for: .moment(fireAt: clock.now, wornMinutes: 12))
        await c.flushPendingAnswers()
        await allowScheduledUpload()
        XCTAssertEqual(fetchLogs().count, 1)
        XCTAssertTrue(client.payloads.isEmpty, "cloud-off answers must stay on the phone")

        defaults.set(true, forKey: "cloudSyncEnabled")
        c.requestSync()
        await allowScheduledUpload()
        XCTAssertEqual(client.payloads.count, 1)
        XCTAssertEqual(client.payloads.first?.energy, 72)
    }

    func testFailedLocalSaveKeepsTheSheetAndRetrySavesOnlyOneAnswer() async {
        struct DiskFailure: Error {}
        var shouldFailSave = true
        let c = makeCoordinator { context in
            if shouldFailSave { throw DiskFailure() }
            try context.save()
        }
        let prompt = CheckInPrompt.previousDay(dayKey: "2026-09-13")
        c.presented = prompt
        var draft = FeltStateDraft.empty
        draft.sleep = 35
        draft.focus = 60

        c.save(draft, for: prompt)
        await allowScheduledUpload()
        XCTAssertEqual(c.presented, prompt, "failed save must leave the draft on screen")
        XCTAssertNotNil(c.saveError)
        XCTAssertTrue(fetchLogs().isEmpty, "failed inserted row must not enter the upload queue")
        XCTAssertTrue(client.payloads.isEmpty)

        shouldFailSave = false
        c.save(draft, for: prompt)
        await allowScheduledUpload()
        XCTAssertNil(c.presented)
        XCTAssertNil(c.saveError)
        let logs = fetchLogs()
        XCTAssertEqual(logs.count, 1, "retry must not leave a duplicate answer")
        XCTAssertEqual(logs.first?.sleep, 35)
        XCTAssertEqual(logs.first?.focus, 60)
        XCTAssertEqual(client.payloads.count, 1)
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

    func testTheReviewAndMomentAreSeparatedByAFullHourEvenWhenSkipped() {
        addSample(at: at(2026, 9, 13, 15, 0))
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-14"
        ledger.momentFireAt = at(2026, 9, 14, 8, 30)
        ledger.save(to: defaults)
        let c = makeCoordinator()          // 08:02: review due before the moment
        c.canPresent = true
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented, .previousDay(dayKey: "2026-09-13"))
        c.skipPresented()
        XCTAssertNil(c.presented)
        let skippedAt = clock.now
        clock.now = skippedAt.addingTimeInterval(3599)
        c.appDidBecomeActive()
        XCTAssertNil(c.presented)
        clock.now = skippedAt.addingTimeInterval(3600)
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented?.kind, .moment)
    }

    func testExistingRecentAnswerBlocksTheReviewUntilAFullHourPasses() {
        let saved = addSavedAnswer()
        saved.timestamp = clock.now.addingTimeInterval(-300)
        try! container.mainContext.save()
        addSample(at: at(2026, 9, 13, 15, 0))
        let c = makeCoordinator()
        c.canPresent = true
        XCTAssertNil(c.presented)
        clock.now = saved.timestamp.addingTimeInterval(3599)
        c.appDidBecomeActive()
        XCTAssertNil(c.presented)
        clock.now = saved.timestamp.addingTimeInterval(3600)
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented?.kind, .previousDay)
    }

    func testUnfinishedOnboardingCannotScheduleASystemCheckIn() async {
        let c = makeCoordinator()
        let worn = clock.now.addingTimeInterval(-900)
        c.strapPolled(connected: true, wornSince: worn, now: clock.now, isForeground: false)
        await allowScheduledUpload()
        XCTAssertTrue(notifier.scheduled.isEmpty)
    }

    func testLegacyOnboardingAnswerGetsOneConservativeHourWithoutInventingACheckIn() {
        var profile = ClientProfile()
        profile.state.stress = 0
        ClientProfileStore(defaults: defaults).save(profile)
        addSample(at: at(2026, 9, 13, 15, 0))
        let start = clock.now
        let c = makeCoordinator()
        c.canPresent = true
        XCTAssertNil(c.presented)
        XCTAssertTrue(fetchLogs().isEmpty)
        clock.now = start.addingTimeInterval(3599)
        let relaunched = makeCoordinator()
        relaunched.canPresent = true
        XCTAssertNil(relaunched.presented)
        clock.now = start.addingTimeInterval(3600)
        relaunched.appDidBecomeActive()
        XCTAssertEqual(relaunched.presented?.kind, .previousDay)
    }

    func testOnboardingAnswerIsSeparateAndPostponesTheFirstMomentAcrossRelaunch() async {
        let c = makeCoordinator()
        let answeredAt = clock.now
        c.recordOnboardingAnswer()
        XCTAssertTrue(fetchLogs().isEmpty, "baseline must not become a 0–100 check-in")
        clock.now = answeredAt.addingTimeInterval(300)
        let relaunched = makeCoordinator()
        relaunched.canPresent = true
        relaunched.strapPolled(connected: true, wornSince: answeredAt, now: clock.now, isForeground: true)
        await allowScheduledUpload()
        XCTAssertNil(relaunched.presented)
        guard let fire = notifier.pendingFireAt else { return XCTFail("expected deferred notification") }
        XCTAssertGreaterThanOrEqual(fire, at(2026, 9, 14, 9, 2))
        clock.now = answeredAt.addingTimeInterval(3599)
        relaunched.appDidBecomeActive()
        XCTAssertNil(relaunched.presented)
        clock.now = fire
        relaunched.appDidBecomeActive()
        XCTAssertEqual(relaunched.presented?.kind, .moment)
    }

    func testAnsweringLaterRestartsTheHourAndDefersNotificationUntilAfterCompletion() async {
        addSample(at: at(2026, 9, 13, 15, 0))
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-14"
        ledger.momentFireAt = at(2026, 9, 14, 8, 30)
        ledger.save(to: defaults)
        let c = makeCoordinator()
        c.canPresent = true
        await allowScheduledUpload()
        XCTAssertEqual(c.presented?.kind, .previousDay)
        XCTAssertNil(notifier.pendingFireAt, "do not send another survey while this one is open")
        clock.now = at(2026, 9, 14, 8, 20)
        var draft = FeltStateDraft.empty
        draft.sleep = 35
        c.save(draft, for: .previousDay(dayKey: "2026-09-13"))
        await allowScheduledUpload()
        XCTAssertEqual(notifier.pendingFireAt, at(2026, 9, 14, 9, 20))
        clock.now = at(2026, 9, 14, 9, 20).addingTimeInterval(-1)
        c.appDidBecomeActive()
        XCTAssertNil(c.presented)
        clock.now = at(2026, 9, 14, 9, 20)
        c.appDidBecomeActive()
        XCTAssertEqual(c.presented?.kind, .moment)
    }

    func testDueMomentNotificationOpensItsOwnSurveyAndDefersTheReview() {
        addSample(at: at(2026, 9, 13, 15, 0))
        var ledger = CheckInLedger()
        ledger.momentAskedDayKey = "2026-09-14"
        ledger.momentFireAt = at(2026, 9, 14, 8, 0)
        ledger.save(to: defaults)
        let c = makeCoordinator() // open two minutes after the banner
        c.canPresent = true
        XCTAssertEqual(c.presented?.kind, .moment)
        c.skipPresented()
        XCTAssertNil(c.presented)
        clock.now = at(2026, 9, 14, 9, 1).addingTimeInterval(59)
        c.strapPolled(connected: false, wornSince: nil, now: clock.now, isForeground: true)
        XCTAssertNil(c.presented)
        clock.now = at(2026, 9, 14, 9, 2)
        c.strapPolled(connected: false, wornSince: nil, now: clock.now, isForeground: true)
        XCTAssertEqual(c.presented?.kind, .previousDay)
    }

    func testNotificationAlreadyBeingAddedCannotRestoreAnEarlyPromptAfterCooldownChanges() async {
        let c = makeCoordinator()
        c.canPresent = true
        notifier.suspendNextSchedule = true
        c.strapPolled(connected: true, wornSince: clock.now, now: clock.now, isForeground: false)
        for _ in 0..<100 where notifier.scheduleContinuation == nil { await Task.yield() }
        guard let continuation = notifier.scheduleContinuation else { return XCTFail("notification add did not start") }
        clock.now = at(2026, 9, 14, 8, 10)
        c.recordOnboardingAnswer()
        continuation.resume()
        await allowScheduledUpload()
        XCTAssertEqual(notifier.pendingFireAt, at(2026, 9, 14, 9, 10))
    }

    func testStaleMomentCannotBeEnqueuedByADelayedNotificationAdd() async {
        let c = makeCoordinator()
        c.canPresent = true
        notifier.suspendNextSchedule = true
        c.strapPolled(connected: true, wornSince: clock.now, now: clock.now, isForeground: false)
        for _ in 0..<100 where notifier.scheduleContinuation == nil { await Task.yield() }
        guard let continuation = notifier.scheduleContinuation else { return XCTFail("notification add did not start") }
        clock.now = at(2026, 9, 14, 10, 0)
        c.appDidBecomeActive()
        XCTAssertNil(c.presented)
        continuation.resume()
        await allowScheduledUpload()
        XCTAssertNil(notifier.pendingFireAt)
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
