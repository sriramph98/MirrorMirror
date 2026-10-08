# MirrorUI — MirrorMirror design system

MirrorMirror is a camera. The interface should feel like a well-made camera body: black, quiet,
precise, with markings that tell you exactly what the instrument is doing. Two references drive
everything:

- **Halide / Kino** (Lux): structure and behaviour. A black frame around a rounded viewfinder;
  technical readouts in the corners; a deck of round tool buttons; a single accent that means
  *active*; tick-mark dials instead of sliders; grouped dark panels for settings; letterspaced caps.
- **7ahang / yuhang**: character. Instrument dials with a red needle, big confident numerals with
  small units, LED dots next to caps labels, raised widget panels.

The package is the single source of truth. App code imports `MirrorUI` and never uses raw colours,
fonts or magic numbers.

## Principles

1. **The picture is the hero.** Chrome is black and recedes; the viewfinder is the brightest thing on screen.
2. **One accent, one meaning.** `Palette.accent` (pale signal yellow) means *selected / on / active*. Never decoration.
3. **Red is live.** `Palette.live` is for LIVE, REC, needles and destructive actions only.
4. **Say it like an instrument.** State goes in readouts (`1080 · 30 · HEVC`), badges (`AUTO`, `•REC`) and LEDs (`● BATT`), not sentences. Sentences are for explanations.
5. **Dials, not sliders.** Continuous values use `TickRuler`; small option sets use `SegmentPill`.
6. **Everything reachable, everything labelled.** 44 pt targets, Dynamic Type, VoiceOver labels on every icon, colour never the only signal.

## Tokens

| Token | Use |
|---|---|
| `Palette.frame` #000 | Camera screens, viewfinder surround. |
| `Palette.canvas` #0A0A0B | List and sheet backgrounds. |
| `Palette.surface` #161618 | Panels, cards, the deck. |
| `Palette.raised` #232326 | Controls on panels: tool buttons, pills, chips. |
| `Palette.raisedHigh` | Pressed / unselected segment. |
| `Palette.textPrimary / Secondary / Tertiary` | Warm white at 100 / 62 / 38 %. |
| `Palette.accent` #EEED7C + `onAccent` | Active state. |
| `Palette.live` #FF453A | Live, recording, needles, destructive. |
| `Palette.ok / warn / info / night` | LED and gauge tints. |

Spacing is a 4-pt scale (`Space.xs…xxxl`). Radii are continuous: `badge 6`, `chip 10`, `control 14`,
`panel 22`, `viewfinder 26`, `deck 32`. Controls: `tool 44`, `toolLarge 52`, `shutter 76`.
Motion: `Motion.snappy` for controls, `Motion.smooth` for layout, `Motion.pulse` for LEDs; no bounce.

### Type

| Style | Face | Use |
|---|---|---|
| `.numeral` | Space Grotesk Bold 44 | Hero numbers: storage hours, battery, clip length. |
| `.display` / `.title` | Space Grotesk Bold 30 / 22 | Screen heroes, card titles. |
| `.headline` | Space Grotesk Medium 17 | Row titles, event names. |
| `.navTitle` | Space Grotesk Medium 16, tracking 4, caps | Sheet and screen titles (`CAPTURE`). |
| `.caps` | Space Grotesk Bold 11, tracking 1.4, caps | Labels, section headers, LED labels. |
| `.readout` / `.readoutLarge` | JetBrains Mono Medium 11 / 15 | Technical values, times, formats. |
| `.body` / `.callout` / `.footnote` | SF Pro | Sentences and explanations. |

Apply with `.type(.caps)`; it sets font, tracking, case and default colour, and all styles scale
with Dynamic Type.

## Components

| Component | When |
|---|---|
| `.panel()` | Any grouped content. Panels sit on `canvas` or `frame`. |
| `Badge` (`outline`, `filled`, `accent`, `recording`, `live`) | Short state tags: AUTO, 2K, NIGHT, •REC. |
| `LED` | Status with a caps label; `pulsing` only for live/recording. |
| `ReadoutLine`, `Readout`, `Numeral` | Technical values; corner readouts; hero numbers. |
| `StatChip` | Compact metrics: battery, viewers, clip count. |
| `.tool(isOn:)` button style | Round deck buttons. Glyph or ≤4-letter caps label. |
| `.pill(isOn:)` | Secondary inline actions (LIVE, AF, GRID). |
| `.primary / .secondary / .accent / .destructive` | Full-width actions in sheets. One primary per screen. |
| `RecordButton` | Start/stop recording (camera side only). |
| `ShutterButton` | The one primary action on a deck (Talk on the viewer). |
| `SegmentPill` | 2–5 short options (lenses, speeds, night mode, time window). |
| `TickRuler` | Continuous values (zoom, sensitivity, storage cap, time). |
| `InstrumentGauge` | One ranged value worth glancing at (battery, storage, heat). |
| `LevelMeter` | Live levels (microphone, motion, incoming audio). |
| `Viewfinder` | Every live or recorded picture, with four corner readout slots. |
| `.focusBrackets()` | Draw attention: QR target, new event, selected item. |
| `SheetHeader`, `SettingsSection`, `ToggleRow`, `MenuRow`, `RulerRow`, `ValueRow`, `ActionRow` | All settings and sheets. |
| `Toast`, `EmptyState`, `Wordmark` | Feedback, empty/error states, branding. |
| `ActivityControl`, `ActivityEventLine`, `ActivityStaleNotice` | Live Activities only: button faces for `Button(intent:)`/`Link`, the latest-event line, the paused / not-updating warning. |

`DesignSystemGallery` renders all of the above; it is in Settings › Design System and is the package preview.

## Screen blueprints

### Navigation
- **iPhone:** `NavigationStack`. Home shows the wordmark, camera cards and a bottom deck with *Use as Camera* (primary), Recordings and Settings tools.
- **iPad (regular width):** `NavigationSplitView`. Sidebar: wordmark; CAMERAS (LED + name + battery); ALL CAMERAS (wall); THIS DEVICE (Use as Camera, Recordings); Settings. Detail shows the selection in place (live view, wall, recordings, settings). Camera mode is always full-screen.

### Camera card (home, sidebar detail)
A panel with: name (`.title`) and connection LED (`LIVE` red when someone is watching, `ON NETWORK` green, `ONLINE` green, `OFFLINE` tertiary); chips for battery, REC and last seen; a small battery `InstrumentGauge` on the trailing side. Whole card is the tap target.

### Camera mode (Kino)
Black frame. Top strip: mic `LevelMeter` + `MIC`, viewer `LED` (`2 WATCHING` / `WAITING`), storage `Readout` (`142 H` / `LEFT`). Badge row: `•REC`, `NIGHT`, `AUTO`, format `ReadoutLine`. `Viewfinder` with talk indicator and brief `focusBrackets` flash on events. Tool row: pair, flip, torch, night, settings. Deck: lens `SegmentPill`, then latest-event thumbnail · `RecordButton` · dim. Landscape / iPad: viewfinder left, deck becomes a vertical rail on the right. Dimmed state: black, large clock `Numeral`, status LEDs, `TAP TO WAKE`.

### Live view (Halide)
Header: back tool, camera name (`.navTitle`), path readout (`P2P · 8 MS`), battery chip. `Viewfinder` corners: LIVE LED or `PLAYBACK 10:06:56` accent badge (TL); REC/NIGHT badges (TR); `1080 · 30 · 4.1 MBPS` (BL); incoming audio `LevelMeter` (BR). Deck: speaker, snapshot, PiP, controls tools; Talk `ShutterButton` centre; latest event thumbnail left; LIVE / −60 s right. Timeline below: window `SegmentPill`, strip of recorded footage with event ticks, playback row (pause, speed pill, LIVE pill, export), then event rows. iPad: picture and deck on the left, timeline column (≈380 pt) on the right. iPhone landscape: full-bleed picture with overlay deck.

### Sheets and settings (Halide)
`canvas` background, `SheetHeader` with caps title, `SettingsSection` panels, accent toggles, `MenuRow`s and `RulerRow`s, footers in footnote. Constrain to `readableWidth()` on iPad.

### Wall
Adaptive grid of `Viewfinder` tiles: name (TL), LED (TR), latest event badge (BL), audio focus tool (BR). 1 column on compact portrait, 2 on iPhone landscape, 2–3 on iPad.

### Apple Watch (viewer only)
The watch can't run WebRTC, so it watches through the paired iPhone (small JPEG stream + voice) or,
when the iPhone is out of reach, sealed iCloud snapshots. Screens: a carousel list of cameras
(headline name, LED `VIA IPHONE` / `ICLOUD`), and a full-bleed picture per camera paged with the
Digital Crown. Over the picture: camera name `.caps`, pulsing LIVE LED or a `STILL · 4s` badge, REC
badge, battery readout; bottom corners hold a listen tool and a hold-to-talk shutter. Everything on
the picture sits on a top/bottom gradient so it stays legible on any scene.

### Live Activities (iPhone)
Two activities, both on `canvas` with accent system actions. **Viewer** (the camera you hear):
Lock Screen shows LED (`LIVE` red, `RECONNECTING` / `NOT UPDATING` amber) with a `LOCAL · BATT 80% · REC`
readout, the camera name (`.title`) beside a `LevelMeter` (or `MUTED`), the latest event line, and
Mute · Talk · Stop controls (Mute lights accent when muted; Talk lights while talking and then stops it).
Dynamic Island: compact is camera glyph + LED / 5-segment meter (mic when talking, speaker-slash when
muted); expanded puts LED and meter in the corners, the name centred under the sensor, then the event
line and the three controls; minimal is the LED. **Camera** (this phone is the camera): LED `REC` /
`CAMERA ON` / `PAUSED`, name, eye + viewer count, who's watching, recording mode, then the latest event,
who's talking, or the paused warning. Lock Screen activities are capped at 160 pt, so keep to `Space.s`
rhythm and one-line notices. The Apple Watch Smart Stack gets a three-line small layout.

## Accessibility
- Every icon-only button gets an `accessibilityLabel`; state goes in `accessibilityValue`.
- LEDs and badges always carry text; never colour alone.
- Respect Reduce Motion: pulsing LEDs and bracket flashes become static.
- Minimum 44 pt targets; Dynamic Type everywhere (custom fonts use `relativeTo:`).
- Contrast: `textSecondary` on `surface` passes 4.5:1; use `textTertiary` only for non-essential captions.
