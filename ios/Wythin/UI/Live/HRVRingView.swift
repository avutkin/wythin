import SwiftUI

/// Animated arc ring showing a single metric as a fraction of its reference range.
struct HRVRingView: View {
    let label:    String
    let value:    String   // formatted display string
    let unit:     String
    let fraction: Double   // 0–1 fill level
    let color:    Color
    var size:     CGFloat = Theme.ringSize

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                // Track
                Circle()
                    .stroke(color.opacity(0.12), lineWidth: 5)

                // Fill arc
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(duration: 0.6), value: fraction)

                VStack(spacing: 0) {
                    Text(value)
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                    Text(unit)
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.dim)
                }
            }
            .frame(width: size, height: size)

            Text(label)
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.dim)
        }
    }
}
