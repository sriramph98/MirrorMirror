import SwiftUI
import MirrorUI

/// Sends this device's cameras to an Apple TV or Vision Pro showing a pairing code. The code
/// is the only thing typed; the cameras and their keys travel sealed through iCloud.
struct PairDeviceSheet: View {
    @EnvironmentObject private var hub: ViewerHub
    @Environment(\.dismiss) private var dismiss

    enum Phase: Equatable { case entering, sending, sent, failed(String) }

    @State private var code = ""
    @State private var phase: Phase = .entering
    @FocusState private var codeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Pair a device", leadingAction: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    switch phase {
                    case .sent: sent
                    default: form
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.s)
                .padding(.bottom, Space.xxl)
                .readableWidth()
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .canvasBackground()
        .animation(Motion.smooth, value: phase)
        .onAppear { codeFocused = true }
    }

    // MARK: Form

    private var isValid: Bool { DevicePairing.isValid(code) }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack {
                Text("Pairing code").type(.caps)
                Spacer()
                Button {
                    setCode(UIPasteboard.general.string ?? "")
                } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                .buttonStyle(.pill())
            }
            TextField("ABCD-2345", text: Binding(get: { code }, set: setCode))
                .type(.readoutLarge, color: Palette.textPrimary)
                .font(.custom(Fonts.monoMedium, size: 28, relativeTo: .title))
                .textCase(nil)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .textContentType(.oneTimeCode)
                .submitLabel(.send)
                .onSubmit { if isValid { send() } }
                .focused($codeFocused)
                .padding(.vertical, Space.l)
                .frame(maxWidth: .infinity)
                .background(Palette.frame, in: .continuous(Radius.control))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(codeFocused ? Palette.accent : Palette.hairline, lineWidth: 1))
                .accessibilityLabel("Pairing code")
                .accessibilityValue(code.isEmpty ? "Empty" : code)
            HStack(spacing: Space.s) {
                LED(isValid ? Palette.ok : Palette.textTertiary, label: isValid ? "Ready" : "\(DevicePairing.normalize(code).count) of \(DevicePairing.codeLength)")
                Spacer()
                ReadoutLine(["\(hub.cameras.count) \(hub.cameras.count == 1 ? "camera" : "cameras")"], color: Palette.textTertiary)
            }
        }
        .panel()

        Text("Enter the code shown on your Apple TV or Vision Pro. Your cameras and their keys travel sealed through your iCloud.")
            .type(.callout, color: Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Space.xs)

        if case let .failed(message) = phase {
            HStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.live)
                Text(message).type(.footnote, color: Palette.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.xs)
            .transition(.opacity)
        }

        Button {
            send()
        } label: {
            if phase == .sending {
                HStack(spacing: Space.s) {
                    ProgressView().tint(.black)
                    Text("Sending…")
                }
            } else {
                Label("Send Cameras", systemImage: "paperplane.fill")
            }
        }
        .buttonStyle(.primary)
        .disabled(!isValid || phase == .sending || hub.cameras.isEmpty)
        .opacity(!isValid || hub.cameras.isEmpty ? 0.4 : 1)

        if hub.cameras.isEmpty {
            Text("There are no cameras on this device to send yet.")
                .type(.footnote, color: Palette.textTertiary)
                .padding(.horizontal, Space.xs)
        } else if !hub.cloudAvailable {
            Text("Sign in to iCloud on this device to pair another device.")
                .type(.footnote, color: Palette.textTertiary)
                .padding(.horizontal, Space.xs)
        }
    }

    // MARK: Sent

    private var sent: some View {
        VStack {
            Spacer(minLength: Space.xxl)
            EmptyState(symbol: "checkmark.seal.fill", title: "Cameras sent",
                       message: "\(hub.cameras.count) \(hub.cameras.count == 1 ? "camera is" : "cameras are") on the way to the device showing \(DevicePairing.formatted(code)). It picks them up within a few seconds.") {
                VStack(spacing: Space.s) {
                    Button("Done") { dismiss() }
                        .buttonStyle(.primary)
                    Button("Pair another device") {
                        code = ""
                        phase = .entering
                        codeFocused = true
                    }
                    .buttonStyle(.pill())
                }
                .padding(.top, Space.s)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 0)
        }
        .transition(.opacity)
    }

    // MARK: Actions

    /// Keeps the field to the code's alphabet and shows it as ABCD-2345 while typing.
    private func setCode(_ raw: String) {
        let normalized = String(DevicePairing.normalize(raw).prefix(DevicePairing.codeLength))
        code = normalized.count > 4 ? String(normalized.prefix(4)) + "-" + String(normalized.dropFirst(4)) : normalized
        if case .failed = phase { phase = .entering }
    }

    private func send() {
        guard isValid, phase != .sending else { return }
        codeFocused = false
        phase = .sending
        Task {
            do {
                try await DevicePairing.send(hub.cameras, code: code)
                phase = .sent
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
