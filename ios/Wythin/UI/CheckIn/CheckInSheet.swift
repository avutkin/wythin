import SwiftUI

/// The check-in as a sheet: a title, one line under it, the scale rows,
/// Done and Skip. Done stays off until something has been dragged, so a
/// blank row can never be saved by reflex. Swiping the sheet away is a skip.
struct CheckInSheet: View {
    let prompt: CheckInPrompt
    let needsNotificationOptIn: Bool
    let onDone: (FeltStateDraft) -> Void
    let onSkip: () -> Void
    let onAllowNotifications: () -> Void

    @State private var draft = FeltStateDraft.empty

    private var kind: CheckInKind { prompt.kind }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.text)
                    Text(kind.helper)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.dim)
                }
                .padding(.top, 8)

                ForEach(kind.scales, id: \.self) { key in
                    FeltStateScaleRow(key: key, value: binding(for: key))
                }

                VStack(spacing: 10) {
                    Button { onDone(draft) } label: {
                        Text("Done")
                            .font(Theme.monoBody)
                            .foregroundStyle(draft.hasAnyAnswer ? Theme.bg : Theme.dim.opacity(0.6))
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(draft.hasAnyAnswer ? Theme.accent : Theme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!draft.hasAnyAnswer)
                    Button(action: onSkip) {
                        Text("Skip")
                            .font(Theme.monoBody).foregroundStyle(Theme.dim)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if needsNotificationOptIn {
                        Button(action: onAllowNotifications) {
                            Text("Remind me when the app is closed")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Theme.card)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.card)
    }

    private func binding(for key: FeltStateScaleKey) -> Binding<Double?> {
        Binding(get: { draft[key] }, set: { draft[key] = $0 })
    }
}
