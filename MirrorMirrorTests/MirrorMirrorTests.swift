//
//  MirrorMirrorTests.swift
//  MirrorMirrorTests
//
//  Created by Sriram P H on 1/11/25.
//

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
            .goLive, .exportClip(requestID: UUID(), from: Date(), to: Date(), quality: .sd540),
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
