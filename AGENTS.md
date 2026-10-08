# MirrorMirror (shipped as "Mira")

The app is called **Mira** everywhere people see it (display names, wordmark, copy). The code, targets, folders and bundle IDs keep the MirrorMirror name: changing bundle IDs, the iCloud container, the keychain service (`sriramph.MirrorMirror`) or the `mirrormirror://` scheme would orphan existing pairings, recordings and alerts. Write new user-facing text with "Mira".

This is a **personal project** (GitHub: `sriramph98/MirrorMirror`), not a work repo. Do not use work accounts, branch prefixes, or work changelog conventions here.

## No references to other companies

Never name other companies, products, apps or designers (competitors or design inspirations) in code, comments, docs, commit messages, branch names, PRs or website copy. Describe the idea instead. Only names the app can't work without stay: Apple platform APIs and services, the WebRTC package dependency, the STUN servers it calls, and the privacy policy's required provider disclosures.

## Identity and accounts

- Commit as `Sriram P H <dukeonline98@outlook.com>`, set repo-locally (`git config --local user.name/user.email`). Check before every commit.
- Push and open PRs with the `sriramph98` GitHub account (`gh auth switch --user sriramph98`), never the work account.
- Sign with the personal paid Apple Developer team `3YPL755X3M` ("Sriram Puli Hemanth Kumar"). Bundle ID `com.sriramph.mirrormirror`, iCloud container `iCloud.com.sriramph.mirrormirror`. The free personal team `34587JNE8E` cannot use iCloud or push.

## Branches

- Work on a feature branch; never commit straight to, push to, or merge into `main` without being asked in that turn.
- Branch names don't need the work `skumar/` prefix.

## Testing

- `xcodebuild test -project MirrorMirror.xcodeproj -scheme MirrorMirror -destination 'id=<simulator>' -parallel-testing-enabled NO -only-testing:MirrorMirrorTests` runs unit and end-to-end tests (grant the simulator camera, microphone and photos access first).
- Debug-only launch arguments for driving devices from a Mac: `-MMAutoStartCamera`, `-MMSegmentSeconds N`, `-MMPairURL <invite>`, `-MMAutoWatch`, `-MMDisableLAN`, `-MMTestEventAfter N`, `-MMGallery` (design system gallery), `-MMScreen <home|add|addlink|addcode|settings|gallery|recordings|player|wall|sidebar|confirm>` (open a screen directly), `-MMCodeSelfTest` (publish a camera code to iCloud and look it up; needs iCloud, so run it on the Mac). Watch app: `-MMWatchTalkTest`. Apple TV: `-MMScreen pair`, and in the simulator write `nearby/<n>`, `type/<code>` or `cameracode` to the debug file the log names. Camera logs print each nearby pairing code (`MM pairing: code …`) in Debug builds so a test can type it. Logs are prefixed `MM `.
- Simulator screenshots: use `xcrun simctl io <udid> screenshot <path>` (the simulator panel's screenshot action can return stale frames). Physical devices: `xcrun devicectl device capture screenshot --device <udid> --destination <path>`.

## Design system

- All UI comes from the local package `Packages/MirrorUI` (tokens, components, `DESIGN.md`). App code never uses raw colours, fonts or magic numbers; add or extend a component in the package instead. Dark only. Fonts are Space Grotesk and JetBrains Mono (OFL), bundled in the package.
- Targets: `MirrorMirror` (iPhone, iPad, and Mac via Mac Catalyst with the Mac idiom; camera + viewer), `MirrorMirrorNotifications` (decrypts event pushes), `MirrorMirrorWidgets` (iPhone Live Activities and Dynamic Island; no Home Screen widgets), `MirrorMirrorWatch` (viewer only: live picture and voice relayed by the paired iPhone over WatchConnectivity, sealed iCloud snapshots as fallback), `MirrorMirrorTV` (tvOS viewer, focus-driven, device-code pairing), `MirrorMirrorVision` (visionOS viewer, one window per camera). Folders: `Shared/` is compiled into every target (no UI, no WebRTC); `Streaming/` is the WebRTC viewer stack shared by iOS/Catalyst, TV and Vision; `LiveActivities/` (activity attributes, Lock Screen button intents, deep links) is shared by the app and `MirrorMirrorWidgets`; each app's UI lives in its own folder.
- Live Activities have no server behind them: the app starts them while in the foreground and updates them while it runs (`MirrorMirror/LiveActivity/`). Updates are coalesced to one a second and carry a 150 s stale date refreshed every minute, so a closed app shows "Not updating" rather than old values. Simulator checks: `xcrun simctl io <udid> screenshot --mask=black` shows the Dynamic Island; long-press the island to expand it.
- WebRTC comes from `livekit/webrtc-xcframework` (module `LiveKitWebRTC`, classes prefixed `LKRTC…`), chosen because it ships tvOS, visionOS, macOS and Catalyst slices. Don't switch to a WebRTC build that lacks them.
- Build the TV and Vision targets with `-sdk appletvsimulator` / `-sdk xrsimulator` and `ARCHS=arm64` (the library has no Intel simulator slices). Catalyst: `-destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates`.
- Simulator audio: LiveKit's audio module opens a hardware audio unit on start, and the Simulator's audio server aborts the whole process (`AURemoteIO::Initialize` RPC timeout, SIGABRT about 20 s in). `RTCEnvironment` therefore runs the module in manual-rendering mode and `CameraHost` skips audio-session activation under `#if targetEnvironment(simulator)`. Don't remove those guards; real devices don't need them and aren't affected.
- Scripting `project.pbxproj`: match whole lines. `INFOPLIST_FILE` is a substring of `GENERATE_INFOPLIST_FILE`, so a naive "already present" check silently skips the edit.
- TV and Vision targets use `INFOPLIST_FILE` plists (`MirrorMirrorTV/Info.plist`, `Config/MirrorMirrorVision-Info.plist`) because the `mirrormirror://` URL scheme and `NSBonjourServices` can't be set through `INFOPLIST_KEY_*` settings.

## Pairing and the camera protocol

- Ways to pair: QR/link (the invite carries the 256-bit key), same Apple Account (iCloud key-value store), device codes for TV/Vision (`DevicePairing`), nearby cameras with a one-time 6-digit code shown on the camera (`NearbyPairing`, Bonjour `_mirror-pair._tcp`, code-masked X25519 exchange; the code never crosses the network), and the 8-symbol code on the camera's Pair screen (`CameraCode`, sealed invite in iCloud while that screen is open). New Bonjour services must be listed in `NSBonjourServices` in the iOS, TV and Vision plists.
- Removing a camera on a viewer sends `goodbye` (open connection, else local network, else iCloud) so the camera forgets that device.
- Control-channel messages must stay well under WebRTC's 256 KB data-channel limit or the channel fails and later commands silently stop arriving. The camera sends the timeline as merged coverage spans (`RecordingSegment.spans`), capped by `CameraHost.maxControlMessageBytes`. Send anything bulky over the files channel.
- The segment recorder drops pieces shorter than a second; a capture that stutters (as in the background) used to leave thousands of them.

## Working in parallel

- When several agents or background commands run at once, use absolute paths and never `cd`: the shell's working directory is shared and changes under you.
