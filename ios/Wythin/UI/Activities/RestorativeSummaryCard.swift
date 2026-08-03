import SwiftUI

/// Summary and reflection for a restorative practice.
///
/// Deliberately not called "success". A practice is not a test to be passed,
/// and the point of the card is to help someone notice what happened and decide
/// what to do next — not to grade them.
///
/// Everything here is derived from what was measured, so it cannot contradict
/// the score above it.
struct RestorativeSummaryCard: View {
    let entry:     ActivityLog
    /// Benefit-signed % change per metric, during vs before, in display order.
    let uplifts:   [Double?]
    let labels:    [String]
    /// Benefit-signed % vs this activity type's 2-month average, per metric.
    let vsAverage: [Double?]

    /// The metric that moved most, and the one that moved least.
    private var extremes: (best: (String, Double)?, weakest: (String, Double)?) {
        let pairs = zip(labels, uplifts).compactMap { l, u in u.map { (l, $0) } }
        return (pairs.max { $0.1 < $1.1 }, pairs.min { $0.1 < $1.1 })
    }

    private var observations: [String] {
        var out: [String] = []
        if let best = extremes.best, best.1 > 0 {
            out.append("\(best.0) moved most — \(signed(best.1)) versus where you started.")
        }
        let beat = zip(labels, vsAverage).compactMap { l, v in v.map { (l, $0) } }
        if !beat.isEmpty {
            let above = beat.filter { $0.1 > 0 }
            out.append("You were above your own 2-month average on \(above.count) of \(beat.count) metrics.")
            if let standout = above.max(by: { $0.1 < $1.1 }), standout.1 > 5 {
                out.append("\(standout.0) was \(signed(standout.1)) against that average — the clearest departure from your usual.")
            }
        }
        if let weakest = extremes.weakest, weakest.1 < 0 {
            out.append("\(weakest.0) went the other way, \(signed(weakest.1)). One metric drifting is normal; a pattern across sessions is the thing to watch.")
        }
        return out
    }

    private var reflection: String {
        let pairs = uplifts.compactMap { $0 }
        guard !pairs.isEmpty else { return "Not enough signal from this session to reflect on." }
        let improved = pairs.filter { $0 > 0 }.count
        switch Double(improved) / Double(pairs.count) {
        case 0.8...:
            return "Almost everything settled together, which is what a practice landing properly looks like. Worth remembering what the conditions were."
        case 0.5..<0.8:
            return "More settled than not. Mixed sessions are the normal case — the useful question is whether the same metrics keep lagging."
        default:
            return "This one did not settle much. That is often about what you arrived carrying rather than the practice itself."
        }
    }

    private var nextStep: String {
        let pairs = uplifts.compactMap { $0 }
        let improved = pairs.isEmpty ? 0 : Double(pairs.filter { $0 > 0 }.count) / Double(pairs.count)
        let minutes = Int(((entry.duration ?? 0) / 60).rounded())
        if improved >= 0.8 {
            return "Repeat this at the same length and time of day. You are looking for whether it holds, not for something new."
        }
        if minutes > 0 && minutes < 12 {
            return "Try the same practice a few minutes longer — short sessions often stop just as the shift begins."
        }
        return "Try it once more before changing anything. Two sessions tell you far more than one."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SUMMARY & REFLECTION")
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)

            Text(reflection)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            if !observations.isEmpty {
                group("WHAT STOOD OUT", observations, Theme.hrv)
            }
            group("NEXT STEP", [nextStep], Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func signed(_ v: Double) -> String {
        String(format: "%+.0f%%", v)
    }

    private func group(_ title: String, _ lines: [String], _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(tint)
                .tracking(1.1)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(tint).frame(width: 4, height: 4).padding(.top, 6)
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.text.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
