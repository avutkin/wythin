import Charts
import SwiftUI

/// Heart-rate demand and vagal withdrawal across a session, on one normalised
/// axis — and the gap between them is the reading.
///
/// Both curves rise during work, so they are directly comparable. Where the
/// vagal curve sits *above* the heart-rate curve, more vagal tone was spent
/// than that heart rate accounts for. The filled area between them is the
/// session's autonomic cost: the same quantity the Suppression card reports as
/// a slope, shown here as a time series.
///
/// Deliberately a single 0–100 axis. Two y-scales would let the two curves be
/// slid past each other arbitrarily, which would make the gap — the whole
/// point of the chart — meaningless.
struct SessionTimelineChart: View {
    let points:    [MetricsHistoryPoint]
    let startedAt: Date
    let endedAt:   Date
    let restingHR: Float
    let ceiling:   Float
    /// Pre-session DC, the reference for "how much vagal tone is withdrawn".
    let dcPre:     Float?

    private struct Sample: Identifiable {
        let id:    Int
        let date:  Date
        let hrr:   Double     // % of HR reserve in use
        let withdrawn: Double?  // % of pre-session vagal tone withdrawn
    }

    /// Buckets to ~120 points regardless of session length, matching
    /// ActivityWindowChart so the two read at the same density.
    private var bucketed: [Sample] {
        let span = endedAt.timeIntervalSince(startedAt)
        guard span > 0 else { return [] }
        let bucket = max(span / 120, 1)

        var hrSum: [Int: Double] = [:], hrN: [Int: Int] = [:]
        var dcSum: [Int: Double] = [:], dcN: [Int: Int] = [:]

        for pt in points where pt.timestamp >= startedAt && pt.timestamp < endedAt {
            let key = Int(pt.timestamp.timeIntervalSince(startedAt) / bucket)
            if let hr = pt.meanBPM {
                hrSum[key, default: 0] += ExerciseIntensity.hrReserve(
                    hr: hr, restingHR: restingHR, ceiling: ceiling) * 100
                hrN[key, default: 0] += 1
            }
            if let dc = pt.dc { dcSum[key, default: 0] += Double(dc); dcN[key, default: 0] += 1 }
        }

        return hrSum.keys.sorted().map { key in
            let date = startedAt.addingTimeInterval(Double(key) * bucket + bucket / 2)
            var withdrawn: Double?
            if let pre = dcPre, pre > 0, let sum = dcSum[key], let n = dcN[key], n > 0 {
                withdrawn = min(max((1 - (sum / Double(n)) / Double(pre)) * 100, 0), 100)
            }
            return Sample(id: key, date: date,
                          hrr: hrSum[key]! / Double(hrN[key]!),
                          withdrawn: withdrawn)
        }
    }

    private var hasVagalTrace: Bool { bucketed.contains { $0.withdrawn != nil } }

    var body: some View {
        let samples = bucketed
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                // The cost band, drawn first so the lines sit on top of it.
                if hasVagalTrace {
                    ForEach(samples) { s in
                        if let w = s.withdrawn {
                            AreaMark(x: .value("Time", s.date),
                                     yStart: .value("HR", s.hrr),
                                     yEnd: .value("Vagal", w))
                                .foregroundStyle(Theme.hrv.opacity(0.16))
                        }
                    }
                }

                ForEach(samples) { s in
                    LineMark(x: .value("Time", s.date),
                             y: .value("% used", s.hrr),
                             series: .value("Series", "HR reserve"))
                        .foregroundStyle(Theme.rsa)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                }

                ForEach(samples) { s in
                    if let w = s.withdrawn {
                        LineMark(x: .value("Time", s.date),
                                 y: .value("% used", w),
                                 series: .value("Series", "Vagal withdrawn"))
                            .foregroundStyle(Theme.hrv)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                    }
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine().foregroundStyle(Theme.border)
                    AxisValueLabel {
                        if let v = value.as(Int.self) {
                            Text("\(v)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Theme.border.opacity(0.5))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(height: 150)

            // Two series, so a legend is not optional.
            HStack(spacing: 14) {
                legendItem(Theme.rsa, "% HR reserve")
                if hasVagalTrace {
                    legendItem(Theme.hrv, "% vagal withdrawn")
                    legendItem(Theme.hrv.opacity(0.3), "autonomic cost")
                }
            }
        }
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 9, height: 3)
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
        }
    }
}
