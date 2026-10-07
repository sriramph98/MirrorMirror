import SwiftUI

/// Every token and component on one scrollable page. Reachable from the app's Settings › Design
/// System, and used as the package's SwiftUI preview.
public struct DesignSystemGallery: View {
    @State private var lens = 1.0
    @State private var zoom = 2.0
    @State private var toggle = true
    @State private var mode = "Auto"
    @State private var recording = false
    @State private var talking = false
    @State private var level = 0.55
    let onClose: (() -> Void)?

    public init(onClose: (() -> Void)? = nil) {
        Fonts.register()
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Design System", leadingAction: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    Wordmark(size: 18)
                    colors
                    typography
                    status
                    controls
                    instruments
                    settings
                    feedback
                }
                .padding(Space.l)
                .readableWidth(820)
            }
        }
        .canvasBackground()
        .preferredColorScheme(.dark)
    }

    private func heading(_ text: String) -> some View {
        Text(text).type(.caps, color: Palette.accent)
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Colour")
            let swatches: [(String, Color)] = [
                ("frame", Palette.frame), ("canvas", Palette.canvas), ("surface", Palette.surface), ("raised", Palette.raised),
                ("raisedHigh", Palette.raisedHigh), ("textPrimary", Palette.textPrimary), ("textSecondary", Palette.textSecondary),
                ("accent", Palette.accent), ("live", Palette.live), ("ok", Palette.ok), ("warn", Palette.warn),
                ("info", Palette.info), ("night", Palette.night),
            ]
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.m)], spacing: Space.m) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(alignment: .leading, spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).fill(color)
                            .frame(height: 52)
                            .overlay(RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
                        Text(name).type(.readout)
                    }
                }
            }
        }
    }

    private var typography: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Type")
            Text("142").type(.numeral)
            Text("Front door").type(.display)
            Text("Recordings").type(.title)
            Text("Motion detected").type(.headline)
            Text("Capture").type(.navTitle)
            Text("Battery").type(.caps)
            Text("1080 · 30 · HEVC · -6.5 EV").type(.readout)
            Text("10:06:56 AM").type(.readoutLarge)
            Text("Video streams directly between your devices, end-to-end encrypted.").type(.body)
            Text("Footnotes explain a setting in one sentence.").type(.footnote)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Status")
            HStack(spacing: Space.m) {
                Badge("Auto")
                Badge("2K", style: .filled)
                Badge("Night", style: .accent)
                Badge("Rec", style: .recording)
                Badge("Live", style: .live)
            }
            HStack(spacing: Space.l) {
                LED(Palette.live, label: "Live", pulsing: true)
                LED(Palette.ok, label: "Batt")
                LED(Palette.warn, label: "Warm")
                LED(Palette.info, label: "P2P")
            }
            HStack(spacing: Space.s) {
                StatChip("72%", tag: "L")
                StatChip("63%", tag: "Case")
                StatChip("80%", symbol: "battery.75percent", tint: Palette.ok)
            }
            HStack(spacing: Space.xl) {
                Readout("7840", caption: "1/15")
                Readout("-6.5", caption: "Meter", color: Palette.live)
                ReadoutLine(["1080", "30", "HEVC"])
            }
            Numeral("142", unit: "h", caption: "Storage left")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Controls")
            HStack(spacing: Space.m) {
                Button {} label: { Text("RAW").type(.readout, color: Palette.textPrimary) }.buttonStyle(.tool())
                Button {} label: { Image(systemName: "camera.rotate") }.buttonStyle(.tool())
                Button { toggle.toggle() } label: { Image(systemName: "flashlight.on.fill") }.buttonStyle(.tool(isOn: toggle))
                Button {} label: { Text("Grid") }.buttonStyle(.pill())
                Button {} label: { Text("AF") }.buttonStyle(.pill(isOn: true))
            }
            HStack(spacing: Space.xl) {
                SegmentPill([0.5, 1.0, 4.0], selection: $lens) { $0 == 0.5 ? ".5" : "\(Int($0))×" }
                SegmentPill(["Auto", "On", "Off"], selection: $mode) { $0 }
            }
            HStack(spacing: Space.xl) {
                RecordButton(isRecording: recording) { recording.toggle() }
                ShutterButton(isActive: talking, action: { talking.toggle() }) { Image(systemName: "mic.fill") }
            }
            Button("Primary action") {}.buttonStyle(.primary)
            Button("Secondary action") {}.buttonStyle(.secondary)
            Button("Accent action") {}.buttonStyle(.accent)
            Button("Destructive action") {}.buttonStyle(.destructive)
        }
    }

    private var instruments: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Instruments")
            HStack(spacing: Space.l) {
                InstrumentGauge(value: 0.72, label: "Batt", valueText: "72%", tint: Palette.ok).frame(width: 110)
                InstrumentGauge(value: 0.35, label: "Storage", valueText: "35%").frame(width: 110)
                VStack(spacing: Space.m) {
                    LevelMeter(level: level)
                    LevelMeter(level: level * 0.8)
                    Slider(value: $level).tint(Palette.accent).frame(width: 120)
                }
            }
            TickRuler(value: $zoom, in: 0.5...10, step: 0.1, labelEvery: 10) { String(format: "%.1f×", $0) }
                .panel(padding: Space.m)
            Viewfinder {
                LinearGradient(colors: [Color(hex: 0x2B3640), Color(hex: 0x101418)], startPoint: .top, endPoint: .bottom)
            } topLeading: {
                LED(Palette.live, label: "Live", pulsing: true)
            } topTrailing: {
                Badge("Auto")
            } bottomLeading: {
                ReadoutLine(["1080", "30", "HEVC"])
            } bottomTrailing: {
                Readout("8 ms", caption: "P2P", alignment: .trailing)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { Color.clear.frame(width: 90, height: 90).focusBrackets() }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Settings")
            SettingsSection("Alerts", symbol: "bell.fill", footer: "Detection runs on the camera. Nothing is uploaded.") {
                ToggleRow("Motion detection", detail: "People, pets and movement", isOn: $toggle)
                MenuRow("Night vision", options: ["Auto", "On", "Off"], selection: $mode) { $0 }
                RulerRow("Zoom", value: $zoom, in: 0.5...10, step: 0.1, labelEvery: 10) { String(format: "%.1f×", $0) }
                ValueRow("Storage used", value: "4.2 GB")
                ActionRow("Devices with access", value: "3") {}
            }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            heading("Feedback")
            Toast("Snapshot saved", symbol: "checkmark.circle.fill")
            EmptyState(symbol: "video.badge.plus", title: "No cameras yet", message: "Open MirrorMirror on a spare iPhone and tap Use as Camera.") {
                Button("Add camera") {}.buttonStyle(.accent).frame(maxWidth: 240)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

#Preview("Design system") {
    DesignSystemGallery()
}
