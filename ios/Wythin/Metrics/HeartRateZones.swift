import Foundation

/// The familiar five training zones, cut from %HR-reserve.
///
/// These answer a different question from the DFA α1 domains and neither
/// replaces the other. A zone is **cardiovascular and relative to your own
/// ceiling**: how hard the heart was working. A domain is **internal and
/// relative to a physiological threshold**: which system was actually being
/// taxed. They can disagree — a zone-4 heart rate sitting in the moderate
/// domain means the effort was well tolerated — and that disagreement is worth
/// more than either alone.
enum HeartRateZone: Int, CaseIterable, Comparable {
    case z1 = 1, z2, z3, z4, z5

    /// Lower bound as a fraction of heart-rate reserve.
    var floor: Double {
        switch self {
        case .z1: return 0.00
        case .z2: return 0.60
        case .z3: return 0.70
        case .z4: return 0.80
        case .z5: return 0.90
        }
    }

    var label: String {
        switch self {
        case .z1: return "recovery"
        case .z2: return "aerobic base"
        case .z3: return "tempo"
        case .z4: return "threshold"
        case .z5: return "maximal"
        }
    }

    var shortLabel: String { "Z\(rawValue)" }

    static func < (a: HeartRateZone, b: HeartRateZone) -> Bool { a.rawValue < b.rawValue }
}

enum HeartRateZones {

    /// Which zone a moment sat in, from its fraction of heart-rate reserve.
    static func zone(hrReserve: Double) -> HeartRateZone {
        HeartRateZone.allCases.last { hrReserve >= $0.floor } ?? .z1
    }

    /// Seconds spent in each zone.
    ///
    /// Each sample owns the interval forward to the next; the last carries none,
    /// and gaps beyond the dropout tolerance are dropped — the same rule Load
    /// and the domain split use, so the three always account for the same time.
    static func split(samples: [(date: Date, hrReserve: Double)]) -> [HeartRateZone: TimeInterval] {
        guard samples.count >= 2 else { return [:] }
        let sorted = samples.sorted { $0.date < $1.date }
        var out: [HeartRateZone: TimeInterval] = [:]
        for i in 0..<(sorted.count - 1) {
            let dt = sorted[i + 1].date.timeIntervalSince(sorted[i].date)
            guard dt > 0, dt <= ExerciseIntensity.maxGapSeconds else { continue }
            out[zone(hrReserve: sorted[i].hrReserve), default: 0] += dt
        }
        return out
    }

    /// Share of the session spent easy (Z1–2) versus hard (Z4–5), and the
    /// middle it avoided.
    ///
    /// The useful read across a week rather than within one session: training
    /// that pools in Z3 is the grey zone — too hard to recover from, too easy to
    /// drive adaptation.
    static func polarisation(_ split: [HeartRateZone: TimeInterval])
        -> (easy: Double, middle: Double, hard: Double)? {
        let total = split.values.reduce(0, +)
        guard total > 0 else { return nil }
        let easy   = (split[.z1] ?? 0) + (split[.z2] ?? 0)
        let middle = (split[.z3] ?? 0)
        let hard   = (split[.z4] ?? 0) + (split[.z5] ?? 0)
        return (easy / total, middle / total, hard / total)
    }
}
