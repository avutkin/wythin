import SwiftUI

/// A night in the Activities list.
///
/// Its own row rather than a reuse of `ActivityLogRow`, because a night shares
/// almost nothing with a practice. The practice row leads with a during-vs-
/// before benefit score, and for a night the before-window is the five minutes
/// before sleep onset — awake, upright, possibly still moving — so that number
/// pins near the top every night and measures nothing. The nine-metric grid has
/// the same problem: an eight-hour mean flattens the entire architecture of the
/// night, which is the only part worth looking at.
///
/// What leads instead is **time asleep**, with total duration beside it. That
/// pairing is the honest disclosure most sleep UIs quietly avoid: the gap
/// between the two is the part of the night you were awake for.
struct SleepLogRow: View {

    let entry: ActivityLog
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    private var asleep: String {
        guard let m = entry.sleepAsleepMinutes else { return "—" }
        return "\(m / 60)h \(String(format: "%02d", m % 60))m"
    }

    private var inBed: String? {
        guard let end = entry.endedAt else { return nil }
        let m = Int(end.timeIntervalSince(entry.startedAt) / 60)
        return "\(m / 60)h \(String(format: "%02d", m % 60))m in bed"
    }

    private var window: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        guard let end = entry.endedAt else { return f.string(from: entry.startedAt) }
        return "\(f.string(from: entry.startedAt)) → \(f.string(from: end))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── header ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: ActivityType.sleep.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ActivityType.sleep.color)
                Text("SLEEP")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.9)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(window)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }

            // ── the pair that matters ─────────────────────────────────
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asleep)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.text)
                    if let inBed {
                        Text(inBed)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.dim)
                    }
                }
                Spacer()
                if let score = entry.sleepScore {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(score)")
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
                            .foregroundStyle(ActivityType.sleep.color)
                        Text("NIGHT SCORE")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.dim)
                    }
                }
            }

            if let stages = entry.sleepStageSummary {
                Text(stages)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }

            // ── the five sections, absent ones shown as absent ────────
            SessionIndexSlotGrid(slots: entry.indexSlots, doses: [])

            if let arithmetic = entry.sleepScoreArithmetic {
                Text(arithmetic)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}
