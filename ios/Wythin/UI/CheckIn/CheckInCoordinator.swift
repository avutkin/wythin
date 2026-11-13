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
        didSet {
            if canPresent, !oldValue {
                evaluate(now: clock())
                schedulePendingNotification(now: clock())
            } else if !canPresent, oldValue {
                invalidateNotification()
            }
        }
    }
    /// The sheet offers a one-line "remind me when the app is closed" while
    /// notification permission has never been asked for.
    private(set) var needsNotificationOptIn = false
    /// A failed local save leaves the sheet (and its draft) in place for retry.
    private(set) var saveError: String?

    private let container: ModelContainer
    private let notifier: CheckInNotifying
    private let uploader: FeltStateLogUploader
    private let saveContext: (ModelContext) throws -> Void
    private let defaults: UserDefaults
    private let clock: () -> Date
    private let calendar: Calendar

    private var ledger: CheckInLedger {
        didSet { ledger.save(to: defaults) }
    }
    private var wornSince: Date?
    private var lastSyncAttemptAt: Date?
    private let syncRetryInterval: TimeInterval = 60
    private var notificationRevision = 0
    private var notificationTask: Task<Void, Never>?

    init(container: ModelContainer, notifier: CheckInNotifying, client: FeltStateAPIClient,
         userID: String, defaults: UserDefaults = .standard, calendar: Calendar = .current,
         saveContext: @escaping (ModelContext) throws -> Void = { try $0.save() },
         clock: @escaping () -> Date = { .now }) {
        self.container = container
        self.notifier = notifier
        self.uploader = FeltStateLogUploader(client: client, userID: userID, defaults: defaults)
        self.saveContext = saveContext
        self.defaults = defaults
        self.calendar = calendar
        self.clock = clock
        var ledger = CheckInLedger.load(from: defaults)
        if ledger.nextPromptAllowedAt == nil {
            var latest = FetchDescriptor<FeltStateLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
            latest.fetchLimit = 1
            if let answer = try? container.mainContext.fetch(latest).first {
                ledger.nextPromptAllowedAt = answer.timestamp.addingTimeInterval(CheckInScheduler.minimumSpacing)
            } else if ClientProfileStore(defaults: defaults).load().state.isAnswered {
                // Old profiles have no answer time. Wait once after upgrading;
                // do not fabricate a baseline timestamp or a regular check-in.
                ledger.nextPromptAllowedAt = clock().addingTimeInterval(CheckInScheduler.minimumSpacing)
            }
        }
        self.ledger = CheckInScheduler.postponingPendingMoment(ledger, calendar: calendar)
        self.ledger.save(to: defaults)
        if ledger.momentFireAt != nil { notifier.cancelPending() }
    }

    // MARK: Inputs

    /// Called every few seconds by the strap-watching loop in `AppEnvironment`.
    /// `wornSince` is when the current wear began, nil when the strap is off.
    func strapPolled(connected: Bool, wornSince: Date?, now: Date, isForeground: Bool) {
        // Network recovery must not depend on wearing the strap or answering
        // another prompt. This loop already runs while the strap is off.
        if isForeground,
           lastSyncAttemptAt.map({ now < $0 || now.timeIntervalSince($0) >= syncRetryInterval }) ?? true {
            requestSync(now: now)
        }
        self.wornSince = connected ? wornSince : nil
        guard connected, let wornSince else {
            // Off before the ask fired: the day has not been asked after all.
            if CheckInScheduler.shouldCancelOnStrapOff(now: now, ledger: ledger) {
                invalidateNotification()
                ledger = CheckInScheduler.cancelled(ledger)
            }
            if isForeground { evaluate(now: now) }
            return
        }
        guard canPresent else { return }
        if let fireAt = CheckInScheduler.momentFireTime(wornSince: wornSince, now: now, ledger: ledger,
                                                        calendar: calendar) {
            ledger.momentAskedDayKey = CheckInDayKey.string(for: now, calendar: calendar)
            ledger.momentFireAt = fireAt
            schedulePendingNotification(now: now)
        }
        if isForeground { evaluate(now: now) }
    }

    /// Called on launch and on every return to the foreground — including the
    /// one a notification tap causes.
    func appDidBecomeActive(now: Date? = nil) {
        let now = now ?? clock()
        requestSync(now: now)
        evaluate(now: now)
    }

    /// All lifecycle triggers share one uploader, including its in-flight
    /// coalescing and cloud-sync preference checks.
    func requestSync(now: Date? = nil) {
        lastSyncAttemptAt = now ?? clock()
        Task { await flushPendingAnswers() }
    }

    func flushPendingAnswers() async {
        await uploader.flushPending(context: container.mainContext)
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
        do {
            try saveContext(context)
        } catch {
            // Discard only this unsuccessful insertion, without rolling back
            // unrelated metric samples in the shared main context.
            context.delete(log)
            saveError = "Couldn't save your answers. Please try again."
            return
        }
        saveError = nil
        presented = nil
        recordInteraction(now: now)
        requestSync(now: now)
        evaluate(now: now)
    }

    /// Skip, or a swipe-down. The day stays marked as shown.
    func skipPresented() {
        guard presented != nil else { return }
        saveError = nil
        presented = nil
        let now = clock()
        recordInteraction(now: now)
        evaluate(now: now)
    }

    /// The baseline remains in ClientProfile (0–10); only its timing participates
    /// in the common survey spacing rule.
    func recordOnboardingAnswer(now: Date? = nil) {
        recordInteraction(now: now ?? clock())
    }

    private func recordInteraction(now: Date) {
        let hadPendingMoment = ledger.momentFireAt != nil &&
            ledger.momentPresentedDayKey != ledger.momentAskedDayKey
        ledger.nextPromptAllowedAt = max(ledger.nextPromptAllowedAt ?? .distantPast,
                                        now.addingTimeInterval(CheckInScheduler.minimumSpacing))
        ledger = CheckInScheduler.postponingPendingMoment(ledger, calendar: calendar)
        invalidateNotification()
        if hadPendingMoment { notifier.clearDelivered() }
        schedulePendingNotification(now: now)
    }

    private func invalidateNotification() {
        notificationRevision += 1
        notifier.cancelPending()
    }

    private func schedulePendingNotification(now: Date) {
        guard canPresent, presented == nil, let fireAt = ledger.momentFireAt,
              ledger.momentAskedDayKey == CheckInDayKey.string(for: now, calendar: calendar),
              ledger.momentPresentedDayKey != ledger.momentAskedDayKey else { return }
        let revision = notificationRevision
        let previous = notificationTask
        // Serialize OS adds. An older add may finish after cancelPending; it
        // must be removed before the replacement is added, not after it.
        notificationTask = Task { [weak self] in
            await previous?.value
            guard let self, revision == self.notificationRevision else { return }
            guard await self.notifier.authorizationStatus() == .authorized,
                  revision == self.notificationRevision else { return }
            let scheduledAt = max(now, self.clock())
            guard scheduledAt.timeIntervalSince(fireAt) <= CheckInScheduler.staleAfter else { return }
            await self.notifier.schedule(fireAt: fireAt, now: scheduledAt)
            if revision != self.notificationRevision { self.notifier.cancelPending() }
        }
    }

    func allowNotifications() {
        Task {
            _ = await notifier.requestAuthorization()
            needsNotificationOptIn = false
        }
    }

    // MARK: Decision

    private func evaluate(now: Date) {
        guard canPresent, presented == nil, CheckInScheduler.canAsk(now: now, ledger: ledger) else { return }
        let todayKey = CheckInDayKey.string(for: now, calendar: calendar)

        // If the moment's banner already fired, open that same survey. Showing
        // the review first would ask two different questions within minutes.
        switch CheckInScheduler.momentDue(now: now, ledger: ledger, calendar: calendar) {
        case .notYet:
            break
        case .stale:
            invalidateNotification()
            ledger.momentPresentedDayKey = todayKey
            notifier.clearDelivered()
        case .present:
            ledger.momentPresentedDayKey = todayKey
            notifier.clearDelivered()
            let worn = wornSince.map { now.timeIntervalSince($0) / 60 }
            present(.moment(fireAt: ledger.momentFireAt ?? now, wornMinutes: worn), now: now)
            return
        }

        if ledger.previousDayShownDayKey != todayKey,
           let yesterdayKey = CheckInScheduler.previousDayDue(
                now: now, ledger: ledger,
                hadStrapDataYesterday: hadStrapData(yesterdayOf: now), calendar: calendar) {
            ledger.previousDayShownDayKey = todayKey
            present(.previousDay(dayKey: yesterdayKey), now: now)
        }
    }

    private func present(_ prompt: CheckInPrompt, now: Date) {
        saveError = nil
        presented = prompt
        recordInteraction(now: now)
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
