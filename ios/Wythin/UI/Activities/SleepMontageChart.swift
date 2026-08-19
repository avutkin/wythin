import SwiftUI

/// The night: a stepped hypnogram, a movement strip, and the stage legend.
///
/// Drawn in Canvas rather than Swift Charts because the shape is specific —
/// each block fills from its own stage level **down to the floor**, so the
/// shallowest stage is the tallest bar and the deepest is a short block along
/// the bottom. That is what produces the skyline: awake reads as a tall thin
/// spike, N3 as a low dark step, and the depth of the night is legible as a
/// silhouette rather than as a colour key.
struct SleepMontageChart: View {

    private let points: [MetricsHistoryPoint]
    private let startedAt: Date
    private let endedAt: Date

    /// Staging arrives already done, from `PreparedNight`.
    ///
    /// It used to be a computed property here, so every access re-ran the whole
    /// pipeline over ~19,000 samples — and `minutes(_:)` is asked nine times
    /// per render (five legend rows, four more inside `asleepMinutes`), with
    /// `runs` on top. That was the hang on opening a night. Classification is a
    /// property of the night, not of the view, so it belongs off the main
    /// thread and upstream of the render.
    private let stages: [SleepStageDetail]
    private let stageMinutes: [SleepStageDetail: Int]
    private let motionThreshold: Float

    init(night: PreparedNight, startedAt: Date, endedAt: Date) {
        self.points = night.points
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.stages = night.stages
        self.stageMinutes = night.stageMinutes
        self.motionThreshold = night.motionThreshold
    }

    /// Deepest at the bottom. The index is the floor-to-ceiling position, so a
    /// bigger number is a taller bar and a shallower stage.
    private func level(_ s: SleepStageDetail) -> Int {
        switch s {
        case .n3:   return 1
        case .n2:   return 2
        case .n1:   return 3
        case .rem:  return 4
        case .wake: return 5
        }
    }

    private func colour(_ s: SleepStageDetail) -> Color {
        switch s {
        // Awake is not a depth, so it sits outside the blue ramp entirely.
        case .wake: return Color(white: 0.94)
        case .rem:  return Color(red: 0.55, green: 0.76, blue: 0.94)
        case .n1:   return Color(red: 0.42, green: 0.66, blue: 0.89)
        case .n2:   return Color(red: 0.30, green: 0.58, blue: 0.85)
        case .n3:   return Color(red: 0.20, green: 0.40, blue: 0.58)
        }
    }

    private var span: Double { max(1, endedAt.timeIntervalSince(startedAt)) }

    private func minutes(_ s: SleepStageDetail) -> Int { stageMinutes[s] ?? 0 }

    private var asleepMinutes: Int {
        SleepStageDetail.allCases.filter(\.isAsleep).reduce(0) { $0 + minutes($1) }
    }

    private func hm(_ m: Int) -> String { "\(m / 60)h \(String(format: "%02d", m % 60))m" }

    private func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            hypnogram
            axis
            movementStrip
            legend
        }
    }

    // MARK: - Hypnogram

    private var hypnogram: some View {
        Canvas { ctx, size in
            guard stages.count == points.count, !points.isEmpty else { return }
            let levels = 5.0
            let unit = size.height / levels

            var start = 0
            for i in 1...stages.count {
                if i == stages.count || stages[i] != stages[start] {
                    let x0 = xPos(points[start].timestamp, size.width)
                    let x1 = i < points.count
                        ? xPos(points[i].timestamp, size.width)
                        : size.width
                    let h = Double(level(stages[start])) * unit
                    let rect = CGRect(x: x0, y: size.height - h,
                                      width: max(1.2, x1 - x0), height: h)
                    ctx.fill(Path(rect), with: .color(colour(stages[start])))
                    start = i
                }
            }
        }
        .frame(height: 132)
        .padding(.horizontal, 2)
        .overlay(alignment: .leading) { edge }
        .overlay(alignment: .trailing) { edge }
    }

    private var edge: some View {
        Rectangle()
            .fill(Theme.dim.opacity(0.45))
            .frame(width: 1)
    }

    private func xPos(_ t: Date, _ width: Double) -> Double {
        width * min(1, max(0, t.timeIntervalSince(startedAt) / span))
    }

    // MARK: - Axis

    private var axis: some View {
        HStack(spacing: 0) {
            Text(clock(startedAt))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
            Spacer()
            ForEach(hourTicks, id: \.self) { t in
                Text(clock(t))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.dim)
                Spacer()
            }
            Text(clock(endedAt))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 5))
        }
        .padding(.top, 8)
    }

    /// Every second hour, and never so close to an end that it collides with
    /// the boxed start or finish time.
    private var hourTicks: [Date] {
        var out: [Date] = []
        let cal = Calendar.current
        var t = cal.date(bySetting: .minute, value: 0, of: startedAt) ?? startedAt
        while t < endedAt {
            let h = cal.component(.hour, from: t)
            if t > startedAt.addingTimeInterval(45 * 60),
               t < endedAt.addingTimeInterval(-45 * 60),
               h % 2 == 0 {
                out.append(t)
            }
            t = t.addingTimeInterval(3600)
        }
        return out
    }

    // MARK: - Movement

    private var movementStrip: some View {
        VStack(spacing: 6) {
            Text("MOVEMENT")
                .font(.system(size: 11, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(Theme.dim)
            Canvas { ctx, size in
                let mid = size.height / 2
                ctx.stroke(Path { p in
                    p.move(to: CGPoint(x: 0, y: mid))
                    p.addLine(to: CGPoint(x: size.width, y: mid))
                }, with: .color(Theme.dim.opacity(0.25)), lineWidth: 1)

                // Only movement that stands out from this night's own stillness
                // is worth a tick; drawing every sample would be a grey wash.
                // The threshold needs a median of the whole night, so it is
                // computed upstream — doing it here ran it on every redraw.
                let threshold = motionThreshold
                guard threshold < .greatestFiniteMagnitude else { return }

                for p in points {
                    guard let m = p.motion, m > threshold else { continue }
                    let x = xPos(p.timestamp, size.width)
                    let scale = min(1, Double(m / (threshold * 4)))
                    let h = 6 + scale * (mid - 4)
                    ctx.fill(Path(CGRect(x: x, y: mid - h / 2, width: 1.6, height: h)),
                             with: .color(Color(white: 0.92).opacity(0.55 + scale * 0.45)))
                }
            }
            .frame(height: 46)
        }
        .padding(.top, 26)
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach([SleepStageDetail.wake, .rem, .n1, .n2, .n3], id: \.self) { s in
                let mins = minutes(s)
                if mins > 0 || s == .wake {
                    HStack(spacing: 12) {
                        Capsule()
                            .fill(colour(s))
                            .frame(width: 92, height: 9)
                        Text(s.label)
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.text)
                        Text(hm(mins))
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.text)
                        if s.isAsleep, asleepMinutes > 0 {
                            Text("\(Int(round(Double(mins) / Double(asleepMinutes) * 100)))%")
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.dim)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(.top, 30)
    }
}
