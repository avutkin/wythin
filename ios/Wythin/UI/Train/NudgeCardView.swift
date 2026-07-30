import SwiftUI

/// The foreground surface for a nudge.
///
/// While the app is open there is no banner — a system banner over the screen
/// already showing that state is noise — so the same nudge arrives as a card
/// with the same menu the notification would have carried.
struct NudgeCardView: View {

    let nudge: InAppNudge
    let onPick: (NudgeInterventionID) -> Void
    let onDismiss: () -> Void

    @State private var showingAlternates = false

    private var primary: NudgeIntervention? { nudge.content.options.first }
    private var alternates: [NudgeIntervention] { Array(nudge.content.options.dropFirst()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Text(nudge.content.title.uppercased())
                .font(Theme.monoLabel)
                .foregroundStyle(Theme.accent)

            Text(nudge.content.body)
                .font(Theme.monoBody)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)

            if let primary {
                Button { onPick(primary.id) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.right.circle")
                        Text(primary.actionLabel)
                        Spacer()
                        Text("\(primary.minutes) min")
                            .foregroundStyle(Theme.dim)
                    }
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.accent)
                }
            }

            if showingAlternates {
                ForEach(alternates, id: \.id) { option in
                    Button { onPick(option.id) } label: {
                        HStack(spacing: 6) {
                            Text(option.title)
                            Spacer()
                            Text("\(option.minutes) min")
                                .foregroundStyle(Theme.dim)
                        }
                        .font(Theme.monoBody)
                        .foregroundStyle(Theme.text)
                    }
                }
            }

            HStack(spacing: 20) {
                if !alternates.isEmpty {
                    Button(showingAlternates ? "Fewer" : "Something else") {
                        withAnimation { showingAlternates.toggle() }
                    }
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
                }
                Spacer()
                Button("Not now", action: onDismiss)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            .padding(.top, 4)
        }
        .padding(16)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }
}
