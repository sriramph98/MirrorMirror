//
//  MirrorMirrorTests.swift
//  MirrorMirrorTests
//
//  Created by Sriram P H on 1/11/25.
//

import CryptoKit
import Foundation
import Testing
@testable import MirrorMirror

@Suite("Pairing and crypto")
struct PairingTests {
    @Test func sealedMessagesRoundTrip() throws {
        let key = PairingKey.generate(cameraID: "cam-1")
        let message = SignalMessage(kind: .offer, session: UUID(), from: "viewer", fromName: "Phone", sdp: "v=0")
        let opened = try key.open(SignalMessage.self, from: try key.seal(message))
        #expect(opened.session == message.session)
        #expect(opened.sdp == "v=0")
    }

    @Test func wrongKeyCannotOpen() throws {
        let key = PairingKey.generate(cameraID: "cam-1")
        let other = PairingKey.generate(cameraID: "cam-1")
        let sealed = try key.seal(PresenceInfo(name: "Nursery", isCharging: true, isRecording: true, viewerCount: 1, updated: Date()))
        #expect(throws: (any Error).self) { try other.open(PresenceInfo.self, from: sealed) }
    }

    @Test func tamperedPayloadIsRejected() throws {
        let key = PairingKey.generate(cameraID: "cam-1")
        var sealed = try key.seal(["hello": "world"])
        sealed[sealed.count / 2] ^= 0xFF
        #expect(throws: (any Error).self) { try key.open([String: String].self, from: sealed) }
    }

    @Test func mailboxesAreStableOpaqueAndDistinct() {
        let key = PairingKey.generate(cameraID: "cam-1")
        let copy = PairingKey(cameraID: key.cameraID, secret: key.secret)
        let other = PairingKey.generate(cameraID: "cam-1")
        #expect(key.mailbox == copy.mailbox)
        #expect(key.mailbox != other.mailbox)
        #expect(key.mailbox.count == 32)
        #expect(!key.mailbox.contains("cam"))
        let names = [key.mailbox, key.eventMailbox, key.presenceRecordName, key.replyMailbox(session: UUID()), key.replyMailbox(session: UUID())]
        #expect(Set(names).count == names.count)
    }

    @Test func inviteLinkRoundTrips() throws {
        let key = PairingKey.generate(cameraID: "ABC-123")
        let invite = PairingInvite(key: key, name: "Living Room & Kitchen")
        let parsed = try #require(PairingInvite(string: invite.url.absoluteString))
        #expect(parsed.key == key)
        #expect(parsed.name == "Living Room & Kitchen")
        // Pasted with stray whitespace still works.
        #expect(PairingInvite(string: "  \(invite.url.absoluteString)\n") != nil)
    }

    @Test(arguments: [
        "https://example.com/pair?id=1&k=abc",
        "mirrormirror://pair?id=1",
        "mirrormirror://pair?id=1&k=dG9vLXNob3J0",
        "mirrormirror://other?id=1&k=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        "not a link",
    ])
    func invalidInvitesAreRejected(_ string: String) {
        #expect(PairingInvite(string: string) == nil)
    }

    @Test func notificationKeysAndPushFieldRoundTrip() throws {
        let key = PairingKey.generate(cameraID: "cam-push")
        NotificationKeyStore.save(["ev-cam-push": .init(key: key, cameraName: "Nursery")])
        let entry = try #require(NotificationKeyStore.load()["ev-cam-push"])
        #expect(entry.key == key && entry.cameraName == "Nursery")
        #expect(NotificationKeyStore.accessGroup?.hasSuffix("com.sriramph.mirrormirror.shared") == true)

        // What the camera puts in the push, and what the extension does with it.
        let info = CloudEventInfo(event: CameraEvent(date: Date(), kind: .crying, label: "Baby crying", confidence: 0.9), cameraName: "Nursery")
        let field = try key.seal(info).base64EncodedString()
        #expect(field.utf8.count < 1500, "must fit comfortably in a 4 KB push")
        let opened = try entry.key.open(CloudEventInfo.self, from: try #require(Data(base64Encoded: field)))
        #expect(opened.event.label == "Baby crying" && opened.event.kind.isUrgent)
        #expect(!EventKind.motion.isUrgent)
    }

    @Test func devicePairingCodes() throws {
        let code = DevicePairing.makeCode()
        #expect(code.count == DevicePairing.codeLength)
        #expect(DevicePairing.isValid(code))
        #expect(!code.contains(where: { "01IO".contains($0) }), "codes avoid look-alike symbols")
        #expect(DevicePairing.formatted("ABCD2345") == "ABCD-2345")
        // Typing is forgiving: case, separators and look-alikes are normalised.
        #expect(DevicePairing.normalize("abcd-2345") == "ABCD2345")
        #expect(DevicePairing.normalize("abc0 1234") == "ABCOL234")
        #expect(!DevicePairing.isValid("ABC"))
        // Two devices typing the same code derive the same sealed mailbox.
        let payload = DevicePairing.Payload(cameras: [], fromDevice: "Phone")
        let sent = try DevicePairing.sealForTesting(payload, code: "abcd-2345")
        let opened = try DevicePairing.openForTesting(sent, code: "ABCD2345")
        #expect(opened.fromDevice == "Phone")
        #expect(throws: (any Error).self) { try DevicePairing.openForTesting(sent, code: "ABCD2346") }
    }

    @Test func macHostNamesReadLikeComputerNames() {
        #expect(DeviceIdentity.friendlyHostName("srirams-macbook-pro.local") == "Srirams MacBook Pro")
        #expect(DeviceIdentity.friendlyHostName("Office-iMac") == "Office iMac")
        #expect(DeviceIdentity.friendlyHostName("mac-mini.lan") == "Mac Mini")
        #expect(DeviceIdentity.friendlyHostName("").isEmpty)
    }

    @Test func base64URLRoundTrips() {
        for length in 0..<40 {
            let data = Data((0..<length).map { UInt8(($0 * 37 + 250) % 256) })
            #expect(Data(base64URLEncoded: data.base64URLEncoded) == data)
            #expect(!data.base64URLEncoded.contains("+") && !data.base64URLEncoded.contains("/") && !data.base64URLEncoded.contains("="))
        }
    }
}

@Suite("Control protocol")
struct ProtocolTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    @Test func everyViewerCommandEncodes() throws {
        let commands: [ViewerCommand] = [
            .hello(viewerID: "v", name: "Phone"), .setLens(0.5), .setZoom(2.5), .flipCamera, .setTorch(true),
            .setNightMode(.on), .setQuality(.max2K), .setRecording(false), .updateSettings(CameraSettings()),
            .talk(true), .requestTimeline, .playback(from: Date()), .playbackPause, .playbackResume, .playbackRate(4),
            .goLive, .exportClip(requestID: UUID(), from: Date(), to: Date(), quality: .sd540), .goodbye,
            .requestThumbnail(eventID: UUID()), .requestSnapshot(requestID: UUID()), .ping(Date()),
        ]
        for command in commands {
            let decoded = try roundTrip(command)
            if case let .updateSettings(original) = command, case let .updateSettings(copy) = decoded {
                #expect(copy == original)   // contains a Set, so compare values, not descriptions
            } else {
                #expect(String(describing: decoded) == String(describing: command))
            }
        }
    }

    @Test func cameraMessagesEncode() throws {
        let event = CameraEvent(date: Date(), kind: .crying, label: "Baby crying", confidence: 0.9, thumbnailFile: "t.jpg")
        let segment = RecordingSegment(start: Date(), duration: 60, fileName: "a.mp4", byteSize: 10, width: 1920, height: 1080)
        let messages: [CameraMessage] = [
            .welcome(cameraName: "Nursery"), .rejected(reason: "no"), .event(event),
            .timeline(segments: [segment], events: [event]),
            .playbackState(date: nil, isPlaying: true, isLive: true, rate: 1),
            .exportProgress(requestID: UUID(), progress: 0.5), .exportFailed(requestID: UUID(), message: "x"),
            .talkState(viewerName: nil), .pong(Date()),
        ]
        for message in messages {
            #expect(String(describing: try roundTrip(message)) == String(describing: message))
        }
    }

    @Test func settingsSurviveOldPayloads() throws {
        var settings = CameraSettings()
        settings.soundKinds = [.barking]
        settings.recordingMode = .events
        let decoded = try roundTrip(settings)
        #expect(decoded == settings)
    }
}

@Suite("Models")
struct ModelTests {
    @Test func heatStepsQualityDown() {
        #expect(QualityPreset.max2K.lower == .high)
        #expect(QualityPreset.smooth.lower == .high)
        #expect(QualityPreset.high.lower == .standard)
        #expect(QualityPreset.standard.lower == .saver)
        #expect(QualityPreset.saver.lower == .saver)
    }

    @Test func presetsFitTheirBitrates() {
        for preset in QualityPreset.allCases {
            #expect(preset.dimensions.long > preset.dimensions.short)
            #expect(preset.maxBitrate >= 500_000)
        }
        #expect(QualityPreset.smooth.fps == 60)
    }

    @Test func mainsFrequency() {
        #expect(MainsFrequency.hz50.resolvedHz == 50)
        #expect(MainsFrequency.hz60.resolvedHz == 60)
        #expect([50, 60].contains(MainsFrequency.auto.resolvedHz))
    }

    @Test func segmentContainment() {
        let start = Date()
        let segment = RecordingSegment(start: start, duration: 10, fileName: "a", byteSize: 1, width: 1, height: 1)
        #expect(segment.contains(start))
        #expect(segment.contains(start.addingTimeInterval(9.9)))
        #expect(!segment.contains(start.addingTimeInterval(10)))
        #expect(!segment.contains(start.addingTimeInterval(-0.1)))
    }

    @Test func privateAddressClassification() {
        for local in ["192.168.1.20", "10.0.0.5", "172.20.1.1", "169.254.3.4", "fe80::1", "fd12:3456::1", "abc.local"] {
            #expect(PeerLink.isPrivate(local), "\(local) should be private")
        }
        for remote in ["2600:380:1234::1", "8.8.8.8", "100.72.1.1", "172.32.0.1", "2a01:4f8::1"] {
            #expect(!PeerLink.isPrivate(remote), "\(remote) should be public")
        }
    }

    @Test func sameNetworkClassification() {
        #expect(PeerLink.isSameNetwork("192.168.1.2", "192.168.1.9"))
        #expect(PeerLink.isSameNetwork("2600:4040:aa:bb:1::1", "2600:4040:aa:bb:9::2"))     // same home /64
        #expect(!PeerLink.isSameNetwork("2600:4040:aa:bb::1", "2600:1015:b13e:d112::5"))    // phone on cellular
        #expect(!PeerLink.isSameNetwork("192.168.1.2", "8.8.8.8"))
    }

    @Test func lensLabels() {
        #expect(LensOption(factor: 0.5).label == "0.5×")
        #expect(LensOption(factor: 1).label == "1×")
        #expect(LensOption(factor: 5).label == "5×")
    }
}

@Suite("Timeline copy")
struct FootageSummaryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func segment(minutesAgo: Double, length: TimeInterval = 60) -> RecordingSegment {
        RecordingSegment(start: now.addingTimeInterval(-minutesAgo * 60), duration: length, fileName: "s.mp4",
                         byteSize: 1, width: 1, height: 1)
    }

    @Test func countsFootageInsideTheWindow() {
        let summary = FootageSummary.describe(segments: [segment(minutesAgo: 10), segment(minutesAgo: 5)],
                                              window: 3600, isRecording: true, now: now)
        #expect(summary.title == "2 M recorded")
        #expect(summary.caption == "Drag the strip to rewind")
    }

    @Test func olderFootageDoesNotInviteDraggingAnEmptyStrip() {
        let summary = FootageSummary.describe(segments: [segment(minutesAgo: 300)], window: 3600, isRecording: false, now: now)
        #expect(summary.title == "No footage")
        #expect(summary.caption.contains("longer window") && !summary.caption.contains("Drag"))
    }

    @Test func recordingWithNothingClosedYet() {
        let summary = FootageSummary.describe(segments: [], window: 3600, isRecording: true, now: now)
        #expect(summary.title == "Recording")
        #expect(FootageSummary.describe(segments: [], window: 3600, isRecording: false, now: now).caption == "Nothing recorded yet")
        #expect(FootageSummary.windowLabel(7 * 24 * 3600) == "7D" && FootageSummary.windowLabel(6 * 3600) == "6H")
    }
}

@Suite("Live Activities")
struct LiveActivityTests {
    @Test func linksRoundTrip() throws {
        let talk = LiveActivityLinks.live(cameraID: "CAM-1", talk: true)
        #expect(LiveActivityLinks.route(for: talk) == .live(cameraID: "CAM-1", talk: true))
        #expect(LiveActivityLinks.route(for: LiveActivityLinks.live(cameraID: "CAM-1")) == .live(cameraID: "CAM-1", talk: false))
        #expect(LiveActivityLinks.route(for: LiveActivityLinks.camera) == .camera)
        // Pairing links and other schemes are left to their own handlers.
        let invite = PairingInvite(key: .generate(cameraID: "x"), name: "Nursery").url
        #expect(LiveActivityLinks.route(for: invite) == nil)
        #expect(LiveActivityLinks.route(for: try #require(URL(string: "https://example.com/live?camera=1"))) == nil)
        #expect(LiveActivityLinks.route(for: try #require(URL(string: "mirrormirror://live"))) == nil)
    }

    @Test func meterFollowsLoudnessNotRawAmplitude() {
        #expect(LiveActivityFormat.meterLevel(nil) == 0)
        #expect(LiveActivityFormat.meterLevel(0) == 0)
        #expect(LiveActivityFormat.meterLevel(0.003) == 0)      // room tone stays dark
        #expect(LiveActivityFormat.meterLevel(0.1) == 0.6)      // speech lights most of it
        #expect(LiveActivityFormat.meterLevel(1) == 1)
        #expect(LiveActivityFormat.meterLevel(0.05) == 0.5, "rounded to tenths so small changes don't cost an update")
    }

    @Test func viewerAndBatteryText() {
        #expect(LiveActivityFormat.viewers(0, names: []) == "No one watching")
        #expect(LiveActivityFormat.viewers(1, names: ["Sam's iPhone"]) == "Sam's iPhone watching")
        #expect(LiveActivityFormat.viewers(3, names: ["A", "B"]) == "3 viewers")
        #expect(LiveActivityFormat.battery(0.874) == "87%")
        #expect(LiveActivityFormat.battery(nil) == nil)
    }

    @Test func activityStateStaysSmallAndRoundTrips() throws {
        let state = MonitorActivityAttributes.ContentState(
            link: .live, isMuted: false, soundLevel: 0.6, path: "LOCAL", cameraRecording: true, cameraBattery: 0.5,
            otherTalker: nil, isTalking: false,
            lastEvent: ActivityEvent(kind: .crying, label: "Baby crying", date: Date()))
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 1024, "ActivityKit caps the state at 4 KB; stay far below")
        #expect(try JSONDecoder().decode(MonitorActivityAttributes.ContentState.self, from: data) == state)

        let camera = CameraActivityAttributes.ContentState(
            isPaused: true, isRecording: true, recordingMode: .events, viewerCount: 2, viewerNames: ["A", "B"],
            talker: "A", battery: 0.2, isCharging: true, isHot: false, lastEvent: nil)
        #expect(try JSONDecoder().decode(CameraActivityAttributes.ContentState.self, from: JSONEncoder().encode(camera)) == camera)
    }
}

@Suite("Code pairing")
struct CodePairingTests {
    /// Both halves of the nearby handshake, without the network.
    private func handshake(viewerCode: String, cameraCode: String) throws -> (viewerKey: SymmetricKey, cameraKey: SymmetricKey) {
        let nonceV = NearbyPairing.makeNonce(), nonceC = NearbyPairing.makeNonce()
        let viewer = Curve25519.KeyAgreement.PrivateKey(), camera = Curve25519.KeyAgreement.PrivateKey()
        let viewerMasked = NearbyPairing.mask(viewer.publicKey.rawRepresentation,
                                              pad: NearbyPairing.pad(code: viewerCode, role: .viewer, viewerNonce: nonceV, cameraNonce: nonceC))
        let cameraMasked = NearbyPairing.mask(camera.publicKey.rawRepresentation,
                                              pad: NearbyPairing.pad(code: cameraCode, role: .camera, viewerNonce: nonceV, cameraNonce: nonceC))
        let seenByCamera = NearbyPairing.unmask(viewerMasked, pad: NearbyPairing.pad(code: cameraCode, role: .viewer, viewerNonce: nonceV, cameraNonce: nonceC))
        let seenByViewer = NearbyPairing.unmask(cameraMasked, pad: NearbyPairing.pad(code: viewerCode, role: .camera, viewerNonce: nonceV, cameraNonce: nonceC))
        let cameraKey = NearbyPairing.sessionKey(try camera.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: seenByCamera)),
                                                 viewerNonce: nonceV, cameraNonce: nonceC, viewerMasked: viewerMasked, cameraMasked: cameraMasked)
        let viewerKey = NearbyPairing.sessionKey(try viewer.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: seenByViewer)),
                                                 viewerNonce: nonceV, cameraNonce: nonceC, viewerMasked: viewerMasked, cameraMasked: cameraMasked)
        return (viewerKey, cameraKey)
    }

    @Test func matchingCodesAgreeOnAKey() throws {
        let keys = try handshake(viewerCode: "482 913", cameraCode: "482913")
        #expect(NearbyPairing.isValidProof(NearbyPairing.viewerProof(keys.viewerKey), key: keys.cameraKey))
    }

    @Test func aWrongCodeFailsTheProof() throws {
        let keys = try handshake(viewerCode: "482914", cameraCode: "482913")
        #expect(!NearbyPairing.isValidProof(NearbyPairing.viewerProof(keys.viewerKey), key: keys.cameraKey))
    }

    @Test func maskedKeysLookRandomAndUnmask() {
        let key = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let pad = NearbyPairing.pad(code: "123456", role: .viewer, viewerNonce: Data(count: 16), cameraNonce: Data(count: 16))
        #expect(NearbyPairing.unmask(NearbyPairing.mask(key, pad: pad), pad: pad) == key)
        // The public key's always-clear top bit is randomised before masking.
        let topBits = Set((0..<64).map { _ in NearbyPairing.mask(key, pad: Data(count: 32))[31] >> 7 })
        #expect(topBits == [0, 1])
        // Pads differ per role and per attempt.
        #expect(pad != NearbyPairing.pad(code: "123456", role: .camera, viewerNonce: Data(count: 16), cameraNonce: Data(count: 16)))
        #expect(pad != NearbyPairing.pad(code: "123456", role: .viewer, viewerNonce: NearbyPairing.makeNonce(), cameraNonce: Data(count: 16)))
    }

    @Test func nearbyCodesAreSixDigits() {
        for _ in 0..<50 {
            let code = NearbyPairing.makeCode()
            #expect(code.count == 6 && code.allSatisfy(\.isNumber))
        }
        #expect(NearbyPairing.formatted("482913") == "482 913")
        #expect(NearbyPairing.normalize(" 482-913 ") == "482913")
    }

    @Test func cameraCodesSealTheInvite() throws {
        let invite = PairingInvite(key: .generate(cameraID: "cam"), name: "Nursery")
        let sealed = try CameraCode.sealForTesting(invite, code: "abcd-2345")
        #expect(try CameraCode.openForTesting(sealed, code: "ABCD2345")?.key == invite.key)
        #expect(throws: (any Error).self) { _ = try CameraCode.openForTesting(sealed, code: "ABCD2346") }
        #expect(CameraCode.isValid("ABCD-2345") && !CameraCode.isValid("ABC"))
    }
}

@Suite("Timeline spans")
struct TimelineSpanTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func segment(_ start: TimeInterval, _ duration: TimeInterval) -> RecordingSegment {
        RecordingSegment(start: t0.addingTimeInterval(start), duration: duration, fileName: "s.mp4", byteSize: 10, width: 1, height: 1)
    }

    @Test func backToBackSegmentsMerge() {
        // A week of continuous one-minute segments is one span.
        let week = (0..<10_080).map { segment(Double($0) * 60, 60) }
        let spans = RecordingSegment.spans(week)
        #expect(spans.count == 1)
        #expect(spans[0].duration == 10_080 * 60)
        #expect(spans[0].byteSize == 10 * 10_080)
    }

    @Test func gapsSplitSpansAndOrderDoesNotMatter() {
        let spans = RecordingSegment.spans([segment(200, 60), segment(0, 60), segment(61, 60), segment(500, 10)])
        #expect(spans.map(\.start) == [t0, t0.addingTimeInterval(200), t0.addingTimeInterval(500)])
        #expect(spans[0].duration == 121)
        #expect(spans.allSatisfy { $0.fileName.isEmpty }, "spans aren't files")
    }

    @Test func timelineMessageFitsADataChannel() throws {
        // Worst case: thousands of separate clips and events still encode under the cap.
        let clips = (0..<5_000).map { segment(Double($0) * 10, 3) }
        let spans = Array(RecordingSegment.spans(clips).suffix(800))
        let events = (0..<400).map { CameraEvent(date: t0.addingTimeInterval(Double($0)), kind: .motion, label: "Motion detected", confidence: 1) }
        let size = try JSONEncoder().encode(CameraMessage.timeline(segments: spans, events: events)).count
        #expect(size < CameraHost.maxControlMessageBytes)
    }
}
