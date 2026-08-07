import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Starts, updates and ends the lock-screen Live Activity for a running session.
///
/// Every entry point is a no-op when Live Activities are unavailable or the
/// user has them switched off, so callers never have to check — the alternative
/// is an availability test at four call sites that will eventually disagree.
@MainActor
final class LiveSessionController {

    static let shared = LiveSessionController()
    private init() {}

    /// How often the lock screen is refreshed.
    ///
    /// The strap ticks every two seconds in the foreground. Pushing every tick
    /// would spend the system's update budget in minutes and get the activity
    /// throttled, so updates are coalesced to something a glance can use.
    static let updateInterval: TimeInterval = 10

    private var lastUpdate: Date = .distantPast

#if canImport(ActivityKit)
    @available(iOS 16.1, *)
    private var current: Activity<LiveSessionAttributes>? {
        Activity<LiveSessionAttributes>.activities.first
    }
#endif

    var isSupported: Bool {
#if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return false }
        return ActivityAuthorizationInfo().areActivitiesEnabled
#else
        return false
#endif
    }

    func start(name: String, icon: String, startedAt: Date, targetMinutes: Int?) {
#if canImport(ActivityKit)
        guard #available(iOS 16.1, *), isSupported, current == nil else { return }
        let attributes = LiveSessionAttributes(activityName: name,
                                               iconSystemName: icon,
                                               startedAt: startedAt,
                                               targetMinutes: targetMinutes)
        let state = LiveSessionAttributes.ContentState(heartRate: nil, hrReserve: nil,
                                                       zone: nil, strapLost: false)
        _ = try? Activity.request(attributes: attributes,
                                  content: .init(state: state, staleDate: nil))
        lastUpdate = .now
#endif
    }

    /// Throttled: callers may fire this on every tick.
    func update(heartRate: Int?, hrReserve: Int?, zone: Int?, strapLost: Bool, now: Date = .now) {
#if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = current else { return }
        guard now.timeIntervalSince(lastUpdate) >= Self.updateInterval || strapLost else { return }
        lastUpdate = now
        let state = LiveSessionAttributes.ContentState(heartRate: heartRate,
                                                       hrReserve: hrReserve,
                                                       zone: zone,
                                                       strapLost: strapLost)
        Task { await activity.update(.init(state: state, staleDate: now.addingTimeInterval(120))) }
#endif
    }

    func end() {
#if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity = current else { return }
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
        lastUpdate = .distantPast
#endif
    }

    /// Clears anything left behind by a crash or a force-quit mid-session.
    func endAnyOrphaned() {
#if canImport(ActivityKit)
        guard #available(iOS 16.1, *) else { return }
        for activity in Activity<LiveSessionAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
#endif
    }
}

/// Update-rate policy, extracted so the throttle can be tested without
/// ActivityKit or a live session.
enum LiveSessionUpdatePolicy {
    static func shouldUpdate(last: Date, now: Date, strapLost: Bool,
                             interval: TimeInterval = LiveSessionController.updateInterval) -> Bool {
        // A lost strap goes through immediately: a frozen heart rate presented
        // as live is worse than a slightly early update.
        strapLost || now.timeIntervalSince(last) >= interval
    }
}
