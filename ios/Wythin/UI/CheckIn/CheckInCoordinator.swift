import Foundation
import SwiftData
import UserNotifications

/// Which sheet is up.
enum CheckInPrompt: Identifiable, Equatable {
    /// Asked while the strap is on. `wornMinutes` is how long it had been on
    /// when the sheet came up, for the row.
    case moment(fireAt: Date, wornMinutes: Double?)
    /// Asked on the first open of a day; `dayKey` is yesterday.
    case previousDay(dayKey: String)

    var id: String {
        switch self {
        case .moment:                  return "moment"
        case .previousDay(let dayKey): return "previous_day:\(dayKey)"
        }
    }

    var kind: CheckInKind {
        switch self {
        case .moment:      return .moment
        case .previousDay: return .previousDay
        }
    }
}

/// Decides when each prompt is shown, shows it, and saves the answer.
///
/// Owned by `AppEnvironment`. Fed from the same 5-second loop that already
/// watches the strap (`strapPolled`) and from every return to the
/// foreground (`appDidBecomeActive`). The rules themselves are in
/// `CheckInScheduler`; this class holds the ledger, the notification centre
/// and the model container, and is the one place that turns a decision into
/// a sheet or a row.
@MainActor
@Observable
final class CheckInCoordinator {

    /// The sheet to show, if any. `ContentView` binds a `.sheet(item:)` to it.
    var presented: CheckInPrompt?
    /// Whether a sheet may go up right now: onboarding is done and no other
    /// sheet (the cloud-sync notice) is on screen. A second sheet on the same
    /// view fails silently, so nothing is presented until this is true.
    var canPresent = false {
        didSet { if canPresent, !oldValue { evaluate(now: clock()) } }
    }
    /// The sheet offers a one-line "remind me when the app is closed" while
    /// notification permission has never been asked for.
    private(set) var needsNotificationOptIn = false

    private let container: ModelContainer
    private let notifier: CheckInNotifying
    private let client: FeltStateAPIClient
    private let userID: String
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let calendar: Calendar

    private var ledger: CheckInLedger {
        didSet { ledger.save(to: defaults) }
    }
    private var wornSince: Date?

    init(container: ModelContainer, notifier: CheckInNotifying, client: FeltStateAPIClient,
         userID: String, defaults: UserDefaults = .standard, calendar: Calendar = .current,
         clock: @escaping () -> Date = { .now }) {
        self.container = container
        self.notifier = notifier
        self.client = client
        self.userID = userID
        self.defaults = defaults
        self.calendar = calendar
        self.clock = clock
        self.ledger = CheckInLedger.load(from: defaults)
    }

    // MARK: Inputs

    /// Called every few seconds by the strap-watching loop in `AppEnvironment`.
    /// `wornSince` is when the current wear began, nil when the strap is off.
    func strapPolled(connected: Bool, wornSince: Date?, now: Date, isForeground: Bool) {
        self.wornSince = connected ? wornSince : nil
        guard connected, let wornSince else {
            // Off before the ask fired: the day has not been asked after all.
            if CheckInScheduler.shouldCancelOnStrapOff(now: now, ledger: ledger) {
                notifier.cancelPending()
                ledger = CheckInScheduler.cancelled(ledger)
            }
            return
        }
        if let fireAt = CheckInScheduler.momentFireTime(wornSince: wornSince, now: now, ledger: ledger,
                                                        calendar: calendar) {
            ledger.momentAskedDayKey = CheckInDayKey.string(for: now, calendar: calendar)
            ledger.momentFireAt = fireAt
            // Hand it to the OS now: the process is unlikely to be awake at
            // fireAt. Without permission there is nothing to hand over; the
            // foreground poll still presents the sheet when the time comes.
            Task {
                if await notifier.authorizationStatus() == .authorized {
                    await notifier.schedule(fireAt: fireAt, now: now)
                }
            }
        }
        if isForeground { evaluate(now: now) }
    }

    /// Called on launch and on every return to the foreground — including the
    /// one a notification tap causes.
    func appDidBecomeActive(now: Date? = nil) {
        evaluate(now: now ?? clock())
    }

    // MARK: Outputs

    func save(_ draft: FeltStateDraft, for prompt: CheckInPrompt, now: Date? = nil) {
        let now = now ?? clock()
        let context = container.mainContext
        let log: FeltStateLog
        switch prompt {
        case .moment(_, let wornMinutes):
            log = draft.makeLog(kind: .moment, dayKey: CheckInDayKey.string(for: now, calendar: calendar),
                                wornMinutes: wornMinutes, now: now)
        case .previousDay(let dayKey):
            log = draft.makeLog(kind: .previousDay, dayKey: dayKey, wornMinutes: nil, now: now)
        }
        context.insert(log)
        try? context.save()
        presented = nil
        let client = self.client, userID = self.userID
        Task { await FeltStateLogUploader(client: client, userID: userID).flushPending(context: context) }
        evaluate(now: now)
    }

    /// Skip, or a swipe-down. The day stays marked as shown.
    func skipPresented() {
        presented = nil
        evaluate(now: clock())
    }

    func allowNotifications() {
        Task {
            _ = await notifier.requestAuthorization()
            needsNotificationOptIn = false
        }
    }

    // MARK: Decision

    private func evaluate(now: Date) {
        guard canPresent, presented == nil else { return }
        let todayKey = CheckInDayKey.string(for: now, calendar: calendar)

        // The previous-day review goes first; the moment waits its turn.
        if ledger.previousDayShownDayKey != todayKey,
           let yesterdayKey = CheckInScheduler.previousDayDue(
                now: now, ledger: ledger,
                hadStrapDataYesterday: hadStrapData(yesterdayOf: now), calendar: calendar) {
            ledger.previousDayShownDayKey = todayKey
            present(.previousDay(dayKey: yesterdayKey))
            return
        }

        switch CheckInScheduler.momentDue(now: now, ledger: ledger, calendar: calendar) {
        case .notYet:
            break
        case .stale:
            ledger.momentPresentedDayKey = todayKey
            notifier.clearDelivered()
        case .present:
            ledger.momentPresentedDayKey = todayKey
            notifier.clearDelivered()
            let worn = wornSince.map { now.timeIntervalSince($0) / 60 }
            present(.moment(fireAt: ledger.momentFireAt ?? now, wornMinutes: worn))
        }
    }

    private func present(_ prompt: CheckInPrompt) {
        presented = prompt
        Task {
            needsNotificationOptIn = await notifier.authorizationStatus() == .notDetermined
        }
    }

    private func hadStrapData(yesterdayOf now: Date) -> Bool {
        let range = CheckInDayKey.yesterdayRange(now: now, calendar: calendar)
        let start = range.lowerBound, end = range.upperBound
        let descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= start && $0.timestamp < end })
        return ((try? container.mainContext.fetchCount(descriptor)) ?? 0) > 0
    }
}
