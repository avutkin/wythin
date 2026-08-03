import Foundation
import SwiftData

/// One check-in: what the user says they actually felt, alongside the state
/// key the widget was showing at that exact moment.
///
/// `stateKey` is what turns a row into a labelled example of what a given
/// state felt like for this person, rather than a mood-diary entry with
/// nothing to anchor it to — see the accuracy design's §6. It is optional
/// because a check-in can be saved before the classifier has ever produced a
/// reading (the first few days, while the baseline is still forming); such
/// rows are kept rather than dropped, but cannot be used to calibrate
/// anything until the field is present.
///
/// Each of the four scales is optional, and `nil` means something different
/// from any in-range number: the user never touched that scale. A default
/// (e.g. 50) in its place would fill the training set with confident
/// non-answers, which is worse than the row simply being blank. The check-in
/// UI that used to build these has since been removed; the model and its
/// schema entry stay, since dropping a `@Model` from a live SwiftData schema
/// risks migration problems on installs that already have rows.
///
/// Values are stored 0–100 but are ordinal, not interval: nobody reliably
/// drags to 63 rather than 68 on a thumb-sized control. A later calibration
/// pass must bucket or rank these, not fit them as continuous measurements.
@Model
final class FeltStateLog {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var focus:  Double?
    var energy: Double?
    var stress: Double?
    var mood:   Double?
    /// `LiveStateKey.rawValue` displayed on the card at the moment this row
    /// was saved.
    var stateKey: String?

    init(timestamp: Date = .now, focus: Double?, energy: Double?, stress: Double?,
         mood: Double?, stateKey: String?) {
        self.id        = UUID()
        self.timestamp = timestamp
        self.focus     = focus
        self.energy    = energy
        self.stress    = stress
        self.mood      = mood
        self.stateKey  = stateKey
    }
}
