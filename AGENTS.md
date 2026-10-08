# MirrorMirror

This is a **personal project** (GitHub: `sriramph98/MirrorMirror`), not a work repo. Do not use work accounts, branch prefixes, or work changelog conventions here.

## Identity and accounts

- Commit as `Sriram P H <dukeonline98@outlook.com>`, set repo-locally (`git config --local user.name/user.email`). Check before every commit.
- Push and open PRs with the `sriramph98` GitHub account (`gh auth switch --user sriramph98`), never the work account.
- Sign with the personal paid Apple Developer team `3YPL755X3M` ("Sriram Puli Hemanth Kumar"). Bundle ID `com.sriramph.mirrormirror`, iCloud container `iCloud.com.sriramph.mirrormirror`. The free personal team `34587JNE8E` cannot use iCloud or push.

## Branches

- Work on a feature branch; never commit straight to, push to, or merge into `main` without being asked in that turn.
- Branch names don't need the work `skumar/` prefix.

## Testing

- `xcodebuild test -project MirrorMirror.xcodeproj -scheme MirrorMirror -destination 'id=<simulator>' -parallel-testing-enabled NO -only-testing:MirrorMirrorTests` runs unit and end-to-end tests (grant the simulator camera, microphone and photos access first).
- Debug-only launch arguments for driving devices from a Mac: `-MMAutoStartCamera`, `-MMSegmentSeconds N`, `-MMPairURL <invite>`, `-MMAutoWatch`, `-MMDisableLAN`, `-MMTestEventAfter N`, `-MMGallery` (design system gallery), `-MMScreen <home|add|addlink|settings|gallery|recordings|player|wall|sidebar|confirm>` (open a screen directly). Watch app: `-MMWatchTalkTest`. Logs are prefixed `MM `.
- Simulator screenshots: use `xcrun simctl io <udid> screenshot <path>` (the simulator panel's screenshot action can return stale frames). Physical devices: `xcrun devicectl device capture screenshot --device <udid> --destination <path>`.

## Design system

- All UI comes from the local package `Packages/MirrorUI` (tokens, components, `DESIGN.md`). App code never uses raw colours, fonts or magic numbers; add or extend a component in the package instead. Dark only. Fonts are Space Grotesk and JetBrains Mono (OFL), bundled in the package.
- Targets: `MirrorMirror` (iPhone, iPad, and Mac via Mac Catalyst with the Mac idiom; camera + viewer), `MirrorMirrorNotifications` (decrypts event pushes), `MirrorMirrorWidgets` (iPhone Live Activities and Dynamic Island; no Home Screen widgets), `MirrorMirrorWatch` (viewer only: live picture and voice relayed by the paired iPhone over WatchConnectivity, sealed iCloud snapshots as fallback), `MirrorMirrorTV` (tvOS viewer, focus-driven, device-code pairing), `MirrorMirrorVision` (visionOS viewer, one window per camera). Folders: `Shared/` is compiled into every target (no UI, no WebRTC); `Streaming/` is the WebRTC viewer stack shared by iOS/Catalyst, TV and Vision; `LiveActivities/` (activity attributes, Lock Screen button intents, deep links) is shared by the app and `MirrorMirrorWidgets`; each app's UI lives in its own folder.
- Live Activities have no server behind them: the app starts them while in the foreground and updates them while it runs (`MirrorMirror/LiveActivity/`). Updates are coalesced to one a second and carry a 150 s stale date refreshed every minute, so a closed app shows "Not updating" rather than old values. Simulator checks: `xcrun simctl io <udid> screenshot --mask=black` shows the Dynamic Island; long-press the island to expand it.
- WebRTC comes from `livekit/webrtc-xcframework` (module `LiveKitWebRTC`, classes prefixed `LKRTC…`), chosen because it ships tvOS, visionOS, macOS and Catalyst slices. Don't switch back to `stasel/WebRTC`.
- Build the TV and Vision targets with `-sdk appletvsimulator` / `-sdk xrsimulator` and `ARCHS=arm64` (the library has no Intel simulator slices). Catalyst: `-destination 'platform=macOS,variant=Mac Catalyst' -allowProvisioningUpdates`.
- Simulator audio: LiveKit's audio module opens a hardware audio unit on start, and the Simulator's audio server aborts the whole process (`AURemoteIO::Initialize` RPC timeout, SIGABRT about 20 s in). `RTCEnvironment` therefore runs the module in manual-rendering mode and `CameraHost` skips audio-session activation under `#if targetEnvironment(simulator)`. Don't remove those guards; real devices don't need them and aren't affected.
- Scripting `project.pbxproj`: match whole lines. `INFOPLIST_FILE` is a substring of `GENERATE_INFOPLIST_FILE`, so a naive "already present" check silently skips the edit.
- TV and Vision targets use `INFOPLIST_FILE` plists (`MirrorMirrorTV/Info.plist`, `Config/MirrorMirrorVision-Info.plist`) because the `mirrormirror://` URL scheme and `NSBonjourServices` can't be set through `INFOPLIST_KEY_*` settings.

## Working in parallel

- When several agents or background commands run at once, use absolute paths and never `cd`: the shell's working directory is shared and changes under you.
