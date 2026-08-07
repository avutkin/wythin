import Foundation
#if canImport(ActivityKit)
import ActivityKit

/// The shape of a running session as the lock screen and Dynamic Island see it.
///
/// Must be visible to both the app and the widget extension — the app pushes
/// updates into it, the extension renders them — so it lives in Models and is
/// added to both targets.
///
/// Deliberately small. Every field crosses a process boundary on each update,
/// and updates arrive as often as the strap ticks, so this carries what a
/// glance needs and nothing else.
@available(iOS 16.1, *)
struct LiveSessionAttributes: ActivityAttributes {

    /// Fixed for the life of the session.
    let activityName: String
    let iconSystemName: String
    let startedAt: Date
    /// Target duration in minutes, when one was set. Drives the progress ring.
    let targetMinutes: Int?

    /// Everything that changes while the session runs.
    struct ContentState: Codable, Hashable {
        let heartRate: Int?
        /// % of heart-rate reserve, 0–100.
        let hrReserve: Int?
        /// Zone number 1–5, or nil before there is enough signal.
        let zone: Int?
        /// True while the strap is disconnected, so the lock screen can say the
        /// numbers are stale rather than showing a frozen heart rate as live.
        let strapLost: Bool
    }
}
#endif
