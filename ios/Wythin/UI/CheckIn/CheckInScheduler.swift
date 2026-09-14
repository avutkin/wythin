import Foundation

// The timing rules behind the two prompts, pure so every real day can be a
// test. The app's loops only run while the strap keeps the process alive,
// so what these decide is handed to the OS (`CheckInNotification`) to fire
// later; the coordinator re-reads the ledger when the app is next active.

/// What has been asked and shown, persisted so a relaunch — including one
/// from a notification tap — picks up where the process left off.
struct CheckInLedger: Codable, Equatable {
    /// The local day a moment ask was scheduled for. Set at scheduling
    /// time, not at the answer, so an ignored ask still counts as the day's
    /// one ask.
    var momentAskedDayKey: String?
    /// When that ask fires.
    var momentFireAt: Date?
    /// The day a moment sheet was actually shown (or dropped as stale), so
    /// the poll does not present it twice.
    var momentPresentedDayKey: String?
    /// The day the previous-day review was shown, answered or not.
    var previousDayShownDayKey: String?

    static let defaultsKey = "checkIn.ledger"

    static func load(from defaults: UserDefaults = .standard) -> CheckInLedger {
        guard let data = defaults.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(CheckInLedger.self, from: data) else {
            return CheckInLedger()
        }
        return ledger
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

/// Zero-padded local day keys. `NudgeBudget.dayKey` is not padded, and this
/// string goes to the server as `day_key`, so it gets its own formatter.
enum CheckInDayKey {
    static func string(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Yesterday, as a half-open range of instants in the calendar's zone.
    static func yesterdayRange(now: Date, calendar: Calendar = .current) -> Range<Date> {
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today.addingTimeInterval(-86_400)
        return yesterday..<today
    }
}

enum CheckInScheduler {
    /// How long the strap has to have been on before a moment can be asked.
    static let wearLead: TimeInterval = 10 * 60
    /// The random spread after that, so the ask does not always land on the
    /// same post-strap-on minute.
    static let jitter: TimeInterval = 5 * 60
    /// Local hours the moment ask may fire in: from 08:00, before 21:00.
    static let askWindowOpenHour = 8
    static let askWindowCloseHour = 21
    /// An answer this long after the ask is about a different moment.
    static let staleAfter: TimeInterval = 60 * 60

    /// When to ask, given the strap has been on since `wornSince`, or nil if
    /// today has been asked already or the window cannot be met today. A wear
    /// that started before the window (an overnight one) is asked when the
    /// window opens, so evaluate this on every poll, not only on connect.
    static func momentFireTime(wornSince: Date, now: Date, ledger: CheckInLedger,
                               calendar: Calendar = .current,
                               random: (ClosedRange<TimeInterval>) -> TimeInterval = { .random(in: $0) }) -> Date? {
        let todayKey = CheckInDayKey.string(for: now, calendar: calendar)
        guard ledger.momentAskedDayKey != todayKey else { return nil }
        let today = calendar.startOfDay(for: now)
        guard let open = calendar.date(byAdding: .hour, value: askWindowOpenHour, to: today),
              let close = calendar.date(byAdding: .hour, value: askWindowCloseHour, to: today) else { return nil }
        let eligible = max(wornSince.addingTimeInterval(wearLead), open)
        let fire = eligible.addingTimeInterval(random(0...jitter))
        guard fire < close else { return nil }
        return fire
    }

    enum MomentDue: Equatable {
        /// Nothing scheduled, not yet time, or already shown today.
        case notYet
        /// Fire time has passed within the hour: show the sheet.
        case present
        /// Fire time passed more than an hour ago: drop it, the moment is gone.
        case stale
    }

    static func momentDue(now: Date, ledger: CheckInLedger, calendar: Calendar = .current) -> MomentDue {
        let todayKey = CheckInDayKey.string(for: now, calendar: calendar)
        guard ledger.momentAskedDayKey == todayKey, let fireAt = ledger.momentFireAt,
              ledger.momentPresentedDayKey != todayKey else { return .notYet }
        guard now >= fireAt else { return .notYet }
        return now.timeIntervalSince(fireAt) > staleAfter ? .stale : .present
    }

    /// The strap came off before the ask fired: the day has not been asked.
    static func shouldCancelOnStrapOff(now: Date, ledger: CheckInLedger) -> Bool {
        guard let fireAt = ledger.momentFireAt else { return false }
        return now < fireAt
    }

    static func cancelled(_ ledger: CheckInLedger) -> CheckInLedger {
        var next = ledger
        next.momentAskedDayKey = nil
        next.momentFireAt = nil
        return next
    }

    /// Yesterday's key when the review is due now, else nil.
    static func previousDayDue(now: Date, ledger: CheckInLedger, hadStrapDataYesterday: Bool,
                               calendar: Calendar = .current) -> String? {
        guard hadStrapDataYesterday else { return nil }
        let todayKey = CheckInDayKey.string(for: now, calendar: calendar)
        guard ledger.previousDayShownDayKey != todayKey else { return nil }
        let yesterday = CheckInDayKey.yesterdayRange(now: now, calendar: calendar).lowerBound
        return CheckInDayKey.string(for: yesterday, calendar: calendar)
    }
}
