import Foundation

/// Parsed day-potential reply.
///
/// Unlike `LiveStateInsight` there is no state key — the band, colour and
/// score are computed on-device, so the model has nothing numeric to
/// contradict and supplies language only.
struct DayPotentialInsight {
    let title:          String
    let bullets:        [String]
    let recommendation: String?

    init(raw: String) {
        let lines = raw
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var title = ""
        var bullets: [String] = []
        var recommendation: String?

        for line in lines {
            // "->" is checked before "-" so a hyphen arrow is not eaten as a bullet.
            if line.hasPrefix("→") || line.hasPrefix("->") {
                recommendation = line
                    .replacingOccurrences(of: "->", with: "")
                    .replacingOccurrences(of: "→", with: "")
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("•") || line.hasPrefix("-") || line.hasPrefix("*") {
                bullets.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if title.isEmpty {
                title = line
            }
        }

        self.title = title
        self.bullets = bullets
        self.recommendation = recommendation
    }
}
