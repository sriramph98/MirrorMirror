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
- Targets: `MirrorMirror` (iPhone + iPad, split view on iPad), `MirrorMirrorNotifications` (decrypts event pushes), `MirrorMirrorWatch` (viewer only: live picture and voice relayed by the paired iPhone over WatchConnectivity, sealed iCloud snapshots as fallback). Code shared by all targets lives in `Shared/`.
