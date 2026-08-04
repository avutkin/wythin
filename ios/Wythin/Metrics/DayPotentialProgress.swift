import Foundation

// MARK: - Score floor

/// The number shown beside the band word — floored so a genuinely low
/// reading never reads as a broken one.
///
/// A computed score of 0 is real data: PotentialScore, the stored
/// `PotentialResult`, and the server all keep seeing exactly that. But a
/// bare "0" next to "DEPLETED" looks like the app failed rather than like a
/// hard morning, so only the digit on screen is floored — never the model.
enum DayPotentialDisplay {
    static let scoreFloor = 1

    static func score(for result: PotentialResult?) -> Int? {
        guard let result else { return nil }
        return max(result.score, scoreFloor)
    }
}
