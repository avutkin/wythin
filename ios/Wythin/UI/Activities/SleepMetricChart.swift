import Charts
import SwiftUI

/// One metric, drawn across the night.
///
/// A night average is one number standing in for eight hours, and it hides the
/// only thing worth looking at. "Vagal Tone 14.5 ms" is the same figure whether
/// vagal tone climbed steadily until five and then collapsed, or sat flat all
/// night — and those are completely different nights. The average is kept, as
/// the header, but the line is what carries the information.
///
/// The wake bands are the reason this is not just a generic time-series: every
/// metric here is read *against the architecture of the night*. A dip that sits
/// inside a wake bout is a person lying awake; the same dip in the middle of
/// consolidated sleep is something else entirely, and without the shading the
/// two look identical.
///
/// Deliberately not `ActivityWindowChart`. That view is built around
/// before/during/after phases, and a night's "before" is the five minutes you
/// were still awake — which makes every metric look like a triumph and is
/// exactly the framing the sleep views exist to avoid.
struct SleepMetricChart: View {

    let def: ActivityMetricDef
    let samples: [PreparedNight.Sample]
    let wakeBands: [PreparedNight.Band]
    let average: Double?
    let startedAt: Date
    let endedAt: Date

    private var colour: Color {
        switch def.techLabel {
        case "HR":            return Theme.warn
        case "RSA":           return Theme.rsa
        case "DC":            return Theme.coh
        case "DFA α1":        return Theme.ulf
        case "SNS %":         return Theme.domainHeavy
        case "PIP":           return Theme.breathe
        default:              return Theme.hrv
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            chart
        }
        .padding(.vertical, 4)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(def.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            Text(def.techFull.isEmpty ? def.techLabel : def.techFull)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(average.map { def.format($0) } ?? "—")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
            if !def.unit.isEmpty {
                Text(def.unit)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if samples.isEmpty {
            HStack {
                Spacer()
                Text("Not measured")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                Spacer()
            }
            .frame(height: 74)
        } else {
            Chart {
                // Awake, behind everything. Recessive on purpose — it is
                // context for the line, not a mark competing with it.
                ForEach(Array(wakeBands.enumerated()), id: \.offset) { _, band in
                    RectangleMark(xStart: .value("wake from", band.start),
                                  xEnd: .value("wake to", band.end))
                        .foregroundStyle(Color(white: 0.62).opacity(0.16))
                }

                if let average {
                    RuleMark(y: .value("night average", average))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(Theme.dim.opacity(0.55))
                }

                ForEach(samples, id: \.date) { s in
                    LineMark(x: .value("time", s.date),
                             y: .value(def.label, s.value))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                        .foregroundStyle(colour)
                }
            }
            .chartXScale(domain: startedAt...endedAt)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.dim.opacity(0.14))
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(def.format(v))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(Theme.dim)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 2)) { value in
                    AxisGridLine().foregroundStyle(Theme.dim.opacity(0.12))
                    AxisValueLabel(format: .dateTime.hour().minute())
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(height: 74)
        }
    }
}
