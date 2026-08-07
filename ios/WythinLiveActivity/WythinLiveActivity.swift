#if canImport(ActivityKit)
import ActivityKit
import SwiftUI
import WidgetKit

/// Lock screen and Dynamic Island presentation of a running session.
///
/// Belongs to the widget extension target, not the app. `LiveSessionAttributes`
/// is shared by both — the app pushes state into it, this renders it.
@available(iOS 16.1, *)
struct WythinLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveSessionAttributes.self) { context in
            lockScreen(context)
                .activityBackgroundTint(Color(red: 0.047, green: 0.047, blue: 0.047))
                .activitySystemActionForegroundColor(Color(red: 0, green: 0.898, blue: 0.627))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.activityName,
                          systemImage: context.attributes.iconSystemName)
                        .font(.system(size: 13, design: .monospaced))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.attributes.startedAt, style: .timer)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .frame(maxWidth: 64, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    metrics(context.state)
                }
            } compactLeading: {
                Image(systemName: context.attributes.iconSystemName)
            } compactTrailing: {
                Text(bpmText(context.state))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: context.attributes.iconSystemName)
            }
        }
    }

    private func bpmText(_ s: LiveSessionAttributes.ContentState) -> String {
        s.heartRate.map { "\($0)" } ?? "—"
    }

    @ViewBuilder
    private func lockScreen(_ context: ActivityViewContext<LiveSessionAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: context.attributes.iconSystemName)
                Text(context.attributes.activityName.uppercased())
                    .font(.system(size: 12, design: .monospaced))
                Spacer()
                Text(context.attributes.startedAt, style: .timer)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .frame(maxWidth: 72, alignment: .trailing)
            }
            metrics(context.state)

            // A strap that has dropped out must say so. A heart rate frozen at
            // its last value looks exactly like a live one.
            if context.state.strapLost {
                Text("strap disconnected — values are the last recorded")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func metrics(_ s: LiveSessionAttributes.ContentState) -> some View {
        HStack(spacing: 0) {
            metric("HR", s.heartRate.map { "\($0)" }, "bpm")
            metric("%HRR", s.hrReserve.map { "\($0)" }, "%")
            metric("ZONE", s.zone.map { "Z\($0)" }, "")
        }
        .opacity(s.strapLost ? 0.5 : 1)
    }

    private func metric(_ label: String, _ value: String?, _ unit: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "—")
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                if !unit.isEmpty, value != nil {
                    Text(unit)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

@available(iOS 16.1, *)
@main
struct WythinLiveActivityBundle: WidgetBundle {
    var body: some Widget { WythinLiveActivity() }
}
#endif
