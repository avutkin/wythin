import SwiftUI

/// W · M · 6M toggle plus the `‹ range ›` navigator. Changing the period
/// resets paging to the current page — carrying an offset across periods
/// would silently jump the user months away.
struct TrackPeriodBar: View {
    @Binding var period: TrackPeriod
    @Binding var offset: Int
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Spacer()
                ForEach(TrackPeriod.allCases) { p in
                    Button(p.rawValue) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            period = p
                            offset = 0
                        }
                    }
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(p == period ? Color.black : Theme.dim)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(p == period ? Theme.accent : Color.clear)
                    .clipShape(Capsule())
                }
            }

            HStack {
                arrow("chevron.left", enabled: true) { offset += 1 }
                Spacer()
                Text(label)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.text)
                Spacer()
                arrow("chevron.right", enabled: offset > 0) { offset -= 1 }
            }
        }
        .padding(.horizontal)
    }

    private func arrow(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Theme.text : Theme.dim.opacity(0.3))
                .frame(width: 32, height: 28)
        }
        .disabled(!enabled)
    }
}
