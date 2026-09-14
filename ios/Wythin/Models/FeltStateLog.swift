import Foundation
import SwiftData

/// One self check-in: what the person says they actually felt.
///
/// Two kinds share the row — see `CheckInKind`. A `moment` is asked while the
/// strap is on, 10–15 minutes into a wear, about right now. A `previous_day`
/// is asked on the first open of a day, about yesterday as a whole; `dayKey`
/// names that day. `timestamp` is always the instant the answer was saved,
/// never back-dated — the uploader's watermark keys on it.
///
/// Each scale is optional, and `nil` means something different from any
/// in-range number: the user never touched that scale. A default (e.g. 50)
/// in its place would fill the training set with confident non-answers,
/// which is worse than the row simply being blank. Values are stored 0–100
/// but are ordinal, not interval: nobody reliably drags to 63 rather than 68
/// on a thumb-sized control. A later calibration pass must bucket or rank
/// these, not fit them as continuous measurements.
///
/// `stateKey` was meant to be the live state the widget showed at the
/// moment of a check-in, the field that turns a row into a labelled example
/// of what a given state felt like. It stays nil for now: the live state
/// store is owned by the Live view and not reachable from where the sheet
/// is presented. Kept on the row so a later change can fill it.
///
/// The fields after `stateKey` were added on 2026-09-13; older rows have them
/// nil, and a nil `kind` reads as a moment.
@Model
final class FeltStateLog {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var focus:  Double?
    var energy: Double?
    var stress: Double?
    var mood:   Double?
    /// `LiveStateKey.rawValue` displayed on the card at the moment this row
    /// was saved, when known.
    var stateKey: String?
    /// "moment" or "previous_day"; nil on rows from before the field existed.
    var kind: String?
    var anxiety: Double?
    /// Last night's sleep, on the previous-day review only.
    var sleep: Double?
    /// Local `yyyy-MM-dd` the answer is about.
    var dayKey: String?
    /// The phone's IANA zone when the answer was saved.
    var timezone: String?
    /// How long the strap had been on when a moment was asked, in minutes.
    var wornMinutes: Double?

    init(timestamp: Date = .now, kind: String?, focus: Double?, energy: Double?, stress: Double?,
         mood: Double?, anxiety: Double?, sleep: Double?, dayKey: String?, timezone: String?,
         wornMinutes: Double?, stateKey: String?) {
        self.id          = UUID()
        self.timestamp   = timestamp
        self.kind        = kind
        self.focus       = focus
        self.energy      = energy
        self.stress      = stress
        self.mood        = mood
        self.anxiety     = anxiety
        self.sleep       = sleep
        self.dayKey      = dayKey
        self.timezone    = timezone
        self.wornMinutes = wornMinutes
        self.stateKey    = stateKey
    }
}
