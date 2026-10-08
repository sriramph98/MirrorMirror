import ActivityKit
import SwiftUI
import WidgetKit
import MirrorUI

/// This iPhone is the camera: recording, who's watching, battery and heat, and a clear warning
/// when the camera is paused because the app left the screen.
struct CameraLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CameraActivityAttributes.self) { context in
            CameraBanner(context: context)
                .activityBackgroundTint(Palette.canvas)
                .activitySystemActionForegroundColor(Palette.accent)
                .widgetURL(LiveActivityLinks.camera)
        } dynamicIsland: { context in
            let status = CameraBannerStatus(context)
            return DynamicIsland {
                // Corners beside the sensor are narrow: status there, the name centred below it.
                DynamicIslandExpandedRegion(.leading) {
                    LED(status.color, label: status.label)
                        .padding(.leading, Space.xs)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: Space.xs) {
                        ViewerCount(count: context.state.viewerCount)
                        Text(status.readout).type(.readout).lineLimit(1)
                    }
                    .padding(.trailing, Space.xs)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.cameraName).type(.headline).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    CameraDetail(context: context)
                        .padding(.top, Space.xs)
                }
            } compactLeading: {
                LED(status.color, label: status.shortLabel)
                    .accessibilityLabel("Camera, \(status.label)")
            } compactTrailing: {
                ViewerCount(count: context.state.viewerCount)
            } minimal: {
                LED(status.color)
                    .accessibilityLabel("Camera, \(status.label)")
            }
            .widgetURL(LiveActivityLinks.camera)
            .keylineTint(status.color)
        }
        .supplementalActivityFamilies([.small])
    }
}

private struct CameraBannerStatus {
    static let pausedText = "Paused while Mira is closed. Tap to resume."
    static let staleText = "Not updating. Open Mira to check the camera."

    let color: Color
    let label: String
    let shortLabel: String
    let readout: String

    init(_ context: ActivityViewContext<CameraActivityAttributes>) {
        let state = context.state
        if context.isStale {
            (color, label, shortLabel) = (Palette.warn, "Not updating", "OFF")
        } else if state.isPaused {
            (color, label, shortLabel) = (Palette.warn, "Paused", "PAUSED")
        } else if state.isRecording {
            (color, label, shortLabel) = (Palette.live, "Recording", "REC")
        } else {
            (color, label, shortLabel) = (Palette.ok, "Camera on", "ON")
        }
        readout = [LiveActivityFormat.battery(state.battery).map { "BATT \($0)" + (state.isCharging ? "+" : "") },
                   state.isHot ? "HOT" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

private struct ViewerCount: View {
    let count: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "eye.fill").font(.caption2.weight(.semibold))
            Text("\(count)").type(.readoutLarge, color: count > 0 ? Palette.textPrimary : Palette.textTertiary)
        }
        .foregroundStyle(count > 0 ? Palette.accent : Palette.textTertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 viewer" : "\(count) viewers")
    }
}

/// Who's watching or talking, then either the paused/stale warning or the latest event.
private struct CameraDetail: View {
    let context: ActivityViewContext<CameraActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Text(LiveActivityFormat.viewers(state.viewerCount, names: state.viewerNames))
                    .type(.headline, color: state.viewerCount > 0 ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Space.s)
                Text(state.recordingMode.title).type(.readout).lineLimit(1)
            }
            if context.isStale {
                ActivityStaleNotice(CameraBannerStatus.staleText)
            } else if state.isPaused {
                ActivityStaleNotice(CameraBannerStatus.pausedText)
            } else if let talker = state.talker {
                ActivityEventLine(symbol: "mic.fill", label: "\(talker) is talking", date: nil)
            } else {
                ActivityEventLine(symbol: state.lastEvent?.kind.symbol, label: state.lastEvent?.label,
                                  date: state.lastEvent?.date)
            }
        }
    }
}

private struct CameraBanner: View {
    let context: ActivityViewContext<CameraActivityAttributes>
    @Environment(\.activityFamily) private var family

    var body: some View {
        let status = CameraBannerStatus(context)
        switch family {
        case .small:
            VStack(alignment: .leading, spacing: Space.xs) {
                LED(status.color, label: status.label)
                Text(context.attributes.cameraName).type(.headline).lineLimit(1)
                Text(LiveActivityFormat.viewers(context.state.viewerCount, names: context.state.viewerNames))
                    .type(.caps)
                    .lineLimit(1)
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
                HStack(spacing: Space.m) {
                    Text(context.attributes.cameraName).type(.title).lineLimit(1)
                    Spacer(minLength: Space.s)
                    ViewerCount(count: context.state.viewerCount)
                }
                CameraDetail(context: context)
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
        }
    }
}
