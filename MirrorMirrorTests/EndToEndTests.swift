import AVFoundation
import Foundation
import Testing
@testable import MirrorMirror

/// Runs a real camera (simulator test pattern) and a real viewer in one process. They find each
/// other over Bonjour, connect with WebRTC, and every remote feature is exercised over the wire.
@MainActor
@Suite("End to end", .serialized)
struct EndToEndTests {
    private func wait(_ what: String, timeout: TimeInterval = 20, _ condition: () async -> Bool) async -> Bool {
        let ok = await waitUntil(timeout: timeout, condition)
        if !ok { Issue.record("Timed out waiting for: \(what)") }
        return ok
    }

    @Test(.timeLimit(.minutes(5)))
    func cameraAndViewerOverTheNetwork() async throws {
        UserDefaults.standard.set(3.0, forKey: "MMSegmentSeconds")
        RecordingStore.shared.deleteAll()

        let host = CameraHost()
        host.settings.recordingMode = .continuous
        host.settings.nightMode = .off
        host.settings.quality = .high
        host.settings.motionSensitivity = 0.6
        await host.start()
        defer { host.stop() }
        #expect(await wait("synthetic camera running") { host.engineState.isSynthetic && host.engineState.isRunning })
        // This simulator may have been a camera for other simulators (TV, Vision Pro) that are still
        // running and paired. A fresh code keeps them out, so the test's viewer is the only one.
        host.resetPairing()

        let hub = ViewerHub.shared
        hub.activate()
        for camera in hub.cameras { hub.remove(camera) }
        let camera = hub.add(host.invite)
        let viewer = hub.connection(for: camera)

        // 1. Connect: local network, live video decoding.
        viewer.connect()
        try #require(await wait("connected", timeout: 30) { viewer.phase == .connected })
        #expect(await wait("video frames decoded") { (viewer.stats.framesDecoded ?? 0) > 15 && viewer.hasVideo })
        #expect(viewer.stats.path == .local)
        #expect(viewer.sink.latestFrame != nil)

        // 2. Handshake bookkeeping on both ends.
        #expect(await wait("status received") { viewer.status != nil })
        #expect(host.viewers.count == 1)
        #expect(host.knownViewers.contains { $0.id == DeviceIdentity.id })

        // 3. Camera audio reaches the viewer.
        #expect(await wait("camera audio arriving") { (viewer.stats.audioBytesReceived ?? 0) > 500 })

        // 4. Remote camera control.
        viewer.send(.setNightMode(.on))
        #expect(await wait("night mode on") { host.settings.nightMode == .on && viewer.status?.nightActive == true })
        viewer.send(.setNightMode(.off))
        #expect(await wait("night mode off") { viewer.status?.nightActive == false })

        viewer.send(.setQuality(.standard))
        #expect(await wait("quality applied") { host.effectiveQuality == .standard && viewer.status?.quality == .standard })
        #expect(await wait("stream resized to 720p") { (viewer.stats.height ?? 9999) <= 720 && (viewer.stats.width ?? 9999) <= 1280 })

        var renamed = host.settings
        renamed.name = "Test Nursery"
        renamed.soundKinds = [.crying]
        viewer.send(.updateSettings(renamed))
        #expect(await wait("settings pushed") { host.settings.name == "Test Nursery" && host.settings.soundKinds == [.crying] })
        #expect(await wait("status reflects settings") { viewer.status?.name == "Test Nursery" })

        viewer.send(.flipCamera)          // no-ops on the test pattern, must not break anything
        viewer.send(.setTorch(true))
        viewer.send(.setLens(1))

        // 5. Recording on/off from the viewer.
        viewer.send(.setRecording(false))
        #expect(await wait("recording stopped") { !host.isRecording && host.settings.recordingMode == .manual })
        viewer.send(.setRecording(true))
        #expect(await wait("recording started") { host.isRecording && viewer.status?.isRecording == true })

        // 6. Timeline of recorded footage (back-to-back segments arrive merged into spans).
        #expect(await wait("segments recorded", timeout: 25) {
            viewer.refreshTimeline()
            try? await Task.sleep(for: .milliseconds(400))
            return viewer.segments.reduce(0) { $0 + $1.duration } >= 5
        })

        // 7. Motion event pushed live, with a thumbnail fetched on demand.
        #expect(await wait("motion event", timeout: 40) { !viewer.events.isEmpty })
        if let event = viewer.events.last {
            #expect([.motion, .person, .animal].contains(event.kind))
            _ = viewer.thumbnail(for: event)
            #expect(await wait("thumbnail") { viewer.thumbnails[event.id] != nil })
        }

        // 8. Playback of recordings, pause, speed, back to live.
        if let first = viewer.segments.first {
            let framesBefore = viewer.stats.framesDecoded ?? 0
            viewer.play(from: first.start)
            #expect(await wait("camera serving playback") { host.viewers.first?.isLive == false })
            #expect(await wait("playback frames flowing") { (viewer.stats.framesDecoded ?? 0) > framesBefore + 30 })
            viewer.togglePause()
            #expect(!viewer.playback.isPlaying)
            viewer.togglePause()
            viewer.setRate(4)
            viewer.goLive()
            #expect(await wait("back to live") { host.viewers.first?.isLive == true && viewer.playback.isLive })

            // Playing the last few seconds at 8× runs into the present and flips back to live by itself.
            viewer.play(from: Date().addingTimeInterval(-6))
            viewer.setRate(8)
            #expect(await wait("auto return to live", timeout: 20) { host.viewers.first?.isLive == true })
        }

        // 9. Clip export: camera cuts the clip, sends it over the data channel.
        if let first = viewer.segments.first {
            let id = viewer.exportClip(from: first.start, to: first.start.addingTimeInterval(2), quality: .sd540)
            #expect(await wait("clip received", timeout: 40) {
                if case .done = viewer.exports[id]?.state { return true }
                if case let .failed(message) = viewer.exports[id]?.state { Issue.record("Export failed: \(message)"); return true }
                return false
            })
            if case let .done(url) = viewer.exports[id]?.state {
                let duration = try await AVURLAsset(url: url).load(.duration).seconds
                #expect(abs(duration - 2) < 0.5)
                viewer.dismissExport(id)
                #expect(!FileManager.default.fileExists(atPath: url.path))
            }
        }

        // 10. Talk-back: the viewer sends no audio at all until Talk is pressed, then its mic reaches the camera.
        let silentBefore = await host.viewerStats().first?.audioBytesReceived ?? 0
        #expect(silentBefore < 500, "viewer must not stream audio before talking")
        await viewer.setTalking(true)
        #expect(viewer.isTalking)
        #expect(await wait("camera sees talker") { host.talkingViewer != nil })
        #expect(await wait("viewer audio arriving at camera") {
            (await host.viewerStats().first?.audioBytesReceived ?? 0) > 500
        })
        await viewer.setTalking(false)
        #expect(!viewer.isTalking)
        #expect(await wait("talk ended") { host.talkingViewer == nil })
        try await Task.sleep(for: .seconds(1))
        let afterTalk = await host.viewerStats().first?.audioBytesReceived ?? 0
        try await Task.sleep(for: .seconds(3))
        let later = await host.viewerStats().first?.audioBytesReceived ?? 0
        #expect(later - afterTalk < 300, "viewer audio must stop when talking ends")
        // Talking again after stopping works (second renegotiation).
        await viewer.setTalking(true)
        #expect(await wait("talking again") { host.talkingViewer != nil })
        await viewer.setTalking(false)

        // 11. Snapshot request: full-resolution still from the camera into Photos.
        viewer.takeSnapshot()
        #expect(await wait("snapshot saved", timeout: 15) { viewer.toast == "Snapshot saved to Photos" })

        // 12. Blocking a viewer cuts it off and refuses reconnects.
        let me = try #require(host.knownViewers.first { $0.id == DeviceIdentity.id })
        host.setBlocked(me, blocked: true)
        #expect(await wait("dropped after block") { host.viewers.isEmpty })
        viewer.connect()
        #expect(await wait("rejected while blocked", timeout: 30) {
            if case .rejected = viewer.phase { return true } else { return false }
        })
        host.setBlocked(me, blocked: false)
        viewer.connect()
        #expect(await wait("reconnects after unblock", timeout: 30) { viewer.phase == .connected })

        // 13. Resetting the pairing code locks out the old code; re-pairing restores access.
        host.resetPairing()
        #expect(await wait("dropped after reset") { host.viewers.isEmpty })
        viewer.disconnect()
        viewer.connect()
        #expect(await wait("old code refused", timeout: 30) {
            if case .failed = viewer.phase { return true } else { return false }
        })
        viewer.disconnect()
        hub.add(host.invite)
        viewer.connect()
        #expect(await wait("re-paired and connected", timeout: 30) { viewer.phase == .connected })

        // 14. Disconnect cleans up on the camera.
        viewer.disconnect()
        #expect(await wait("camera released viewer") { host.viewers.isEmpty })

        // 15. Removing the camera on the viewer makes the camera forget this device.
        let fresh = hub.connection(for: try #require(hub.camera(id: camera.id)))
        fresh.connect()
        #expect(await wait("connected before removing", timeout: 30) { fresh.phase == .connected })
        #expect(host.knownViewers.contains { $0.id == DeviceIdentity.id })
        hub.remove(try #require(hub.camera(id: camera.id)))
        #expect(await wait("camera forgot the viewer") {
            host.viewers.isEmpty && !host.knownViewers.contains { $0.id == DeviceIdentity.id }
        })
    }

    /// A viewer on the same network finds the camera, the camera shows a code, and only the
    /// right code gets the invite.
    @Test(.timeLimit(.minutes(3)))
    func nearbyPairingWithACode() async throws {
        let host = CameraHost()
        await host.start()
        defer { host.stop() }
        let browser = NearbyCameraBrowser()
        browser.start()
        defer { browser.stop() }

        #expect(await wait("camera listed nearby") { browser.cameras.contains { $0.id == host.key.cameraID } })
        let nearby = try #require(browser.cameras.first { $0.id == host.key.cameraID })
        #expect(nearby.name == host.settings.name)

        // A wrong code is refused, ends the attempt, and the camera pauses briefly.
        let first = try await NearbyPairingSession.begin(with: nearby)
        #expect(await wait("code shown on the camera") { host.nearby.request != nil })
        let shown = try #require(host.nearby.request?.code)
        await #expect(throws: NearbyPairingError.wrongCode) {
            _ = try await first.complete(code: shown == "000000" ? "111111" : "000000")
        }
        #expect(await wait("attempt ended") { host.nearby.request == nil })
        await #expect(throws: NearbyPairingError.busy) { _ = try await NearbyPairingSession.begin(with: nearby) }

        // After the pause, the right code delivers the camera's invite.
        try await Task.sleep(for: .seconds(6))
        let second = try await NearbyPairingSession.begin(with: nearby)
        #expect(await wait("new code shown") { host.nearby.request != nil })
        let code = try #require(host.nearby.request?.code)
        let invite = try await second.complete(code: NearbyPairing.formatted(code))
        #expect(invite.key == host.key)
        #expect(invite.name == host.settings.name)
        #expect(await wait("camera reported the pairing") { host.nearby.request == nil })
    }
}
