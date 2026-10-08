import ActivityKit
import SwiftUI
import WidgetKit
import MirrorUI

/// The camera this iPhone is listening to: Lock Screen banner, Dynamic Island and Smart Stack.
struct MonitorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MonitorActivityAttributes.self) { context in
            MonitorBanner(context: context)
                .activityBackgroundTint(Palette.canvas)
                .activitySystemActionForegroundColor(Palette.accent)
                .widgetURL(LiveActivityLinks.live(cameraID: context.attributes.cameraID))
        } dynamicIsland: { context in
            let status = MonitorBannerStatus(context)
            return DynamicIsland {
                // Corners beside the sensor are narrow: status there, the name centred below it.
                DynamicIslandExpandedRegion(.leading) {
                    LED(status.color, label: status.label)
                        .padding(.leading, Space.xs)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: Space.xs) {
                        meter(context.state, isStale: context.isStale).frame(height: Space.m)
                        Text(status.readout).type(.readout).lineLimit(1)
                    }
                    .padding(.trailing, Space.xs)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.cameraName).type(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: Space.s) {
                        if context.isStale {
                            ActivityStaleNotice(MonitorBannerStatus.staleText)
                        } else {
                            MonitorEventLine(state: context.state)
                        }
                        MonitorControls(cameraID: context.attributes.cameraID, state: context.state, isStale: context.isStale)
                    }
                    .padding(.top, Space.xs)
                }
            } compactLeading: {
                HStack(spacing: Space.xs) {
                    Image(systemName: "video.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    LED(status.color)
                }
                .accessibilityLabel("\(context.attributes.cameraName), \(status.label)")
            } compactTrailing: {
                compactTrailing(context.state, isStale: context.isStale)
            } minimal: {
                LED(status.color)
                    .accessibilityLabel("\(context.attributes.cameraName), \(status.label)")
            }
            .widgetURL(LiveActivityLinks.live(cameraID: context.attributes.cameraID))
            .keylineTint(status.color)
        }
        .supplementalActivityFamilies([.small])
    }

    @ViewBuilder
    private func compactTrailing(_ state: MonitorActivityAttributes.ContentState, isStale: Bool) -> some View {
        if isStale {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Palette.warn)
                .accessibilityLabel("Not updating")
        } else if state.isTalking || state.otherTalker != nil {
            Image(systemName: "mic.fill")
                .foregroundStyle(state.isTalking ? Palette.accent : Palette.warn)
                .accessibilityLabel(state.isTalking ? "You're talking" : "\(state.otherTalker ?? "Someone") is talking")
        } else if state.isMuted {
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(Palette.accent)
                .accessibilityLabel("Muted")
        } else {
            LevelMeter(level: state.soundLevel, segments: ControlSize.activityMeterSegments)
        }
    }

    @ViewBuilder
    private func meter(_ state: MonitorActivityAttributes.ContentState, isStale: Bool) -> some View {
        if isStale {
            EmptyView()
        } else if state.isMuted {
            Text("Muted").type(.caps, color: Palette.accent)
        } else {
            LevelMeter(level: state.soundLevel)
        }
    }
}

/// What the LED and readouts say, derived once from the state.
private struct MonitorBannerStatus {
    static let staleText = "Not updating. Open Mira to reconnect."

    let color: Color
    let label: String
    let readout: String

    init(_ context: ActivityViewContext<MonitorActivityAttributes>) {
        let state = context.state
        if context.isStale {
            color = Palette.warn
            label = "Not updating"
        } else if state.link == .reconnecting {
            color = Palette.warn
            label = "Reconnecting"
        } else {
            color = Palette.live
            label = "Live"
        }
        readout = [state.path, LiveActivityFormat.battery(state.cameraBattery).map { "BATT \($0)" },
                   state.cameraRecording ? "REC" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct MonitorEventLine: View {
    let state: MonitorActivityAttributes.ContentState

    var body: some View {
        if let talker = state.otherTalker {
            ActivityEventLine(symbol: "mic.fill", label: "\(talker) is talking", date: nil)
        } else {
            ActivityEventLine(symbol: state.lastEvent?.kind.symbol, label: state.lastEvent?.label,
                              date: state.lastEvent?.date, placeholder: "No events since you started watching")
        }
    }
}

/// Mute runs in the background; Talk has to open the app (iOS won't start the microphone from
/// a Lock Screen button); Stop disconnects and ends the activity. When the app has stopped
/// updating, only Open and Stop make sense.
private struct MonitorControls: View {
    let cameraID: String
    let state: MonitorActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            if isStale {
                Link(destination: LiveActivityLinks.live(cameraID: cameraID)) {
                    ActivityControl("Open", symbol: "arrow.up.forward.app")
                }
                .accessibilityLabel("Open Mira")
            } else {
                liveControls
            }
            Button(intent: StopMonitoringIntent(cameraID: cameraID)) {
                ActivityControl("Stop", symbol: "stop.fill", role: .destructive)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop watching")
        }
    }

    @ViewBuilder
    private var liveControls: some View {
        Button(intent: ToggleMonitorMuteIntent(cameraID: cameraID)) {
            ActivityControl(state.isMuted ? "Unmute" : "Mute",
                            symbol: state.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            isOn: state.isMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isMuted ? "Unmute camera sound" : "Mute camera sound")

        if state.isTalking {
            Button(intent: StopTalkingIntent(cameraID: cameraID)) {
                ActivityControl("Talking", symbol: "mic.fill", isOn: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop talking")
        } else {
            Link(destination: LiveActivityLinks.live(cameraID: cameraID, talk: true)) {
                ActivityControl("Talk", symbol: "mic.fill")
            }
            .accessibilityLabel("Talk through the camera")
            .accessibilityHint("Opens Mira")
        }
    }
}

/// Lock Screen banner (iPhone) and Smart Stack card (Apple Watch).
private struct MonitorBanner: View {
    let context: ActivityViewContext<MonitorActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        let status = MonitorBannerStatus(context)
        switch family {
        case .small:
            VStack(alignment: .leading, spacing: Space.xs) {
                LED(status.color, label: status.label)
                Text(context.attributes.cameraName).type(.headline).lineLimit(1)
                if context.state.isMuted {
                    Text("Muted").type(.caps, color: Palette.accent)
                } else {
                    LevelMeter(level: context.state.soundLevel)
                }
                if let event = context.state.lastEvent {
                    Text(event.label).type(.caps).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s)
        default:
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    LED(status.color, label: status.label)
                    Spacer(minLength: Space.s)
                    Text(status.readout).type(.readout).lineLimit(1)
                }
                HStack(alignment: .center, spacing: Space.m) {
                    Text(context.attributes.cameraName)
                        .type(.title)
                        .lineLimit(1)
                    Spacer(minLength: Space.s)
                    if context.isStale {
                        EmptyView()
                    } else if context.state.isMuted {
                        Text("Muted").type(.caps, color: Palette.accent)
                    } else {
                        LevelMeter(level: context.state.soundLevel)
                    }
                }
                if context.isStale {
                    ActivityStaleNotice(MonitorBannerStatus.staleText)
                } else {
                    MonitorEventLine(state: context.state)
                }
                MonitorControls(cameraID: context.attributes.cameraID, state: context.state, isStale: context.isStale)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }
}
