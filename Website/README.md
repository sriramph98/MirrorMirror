# Mira website

A responsive static marketing website, kept alongside the apps and independently deployable. It uses the app's bundled typefaces and translated visual tokens. No framework, external font service, tracking, or package installation is required.

## Preview

Run `npm run dev` from this folder, then open http://127.0.0.1:4173. Set `PORT` to choose another local port.

## Build

Run `npm run build`. The generated `dist/` folder can be served by a static host. Publishing is a separate action.

## Beta invitation

Set `betaUrl` in `site-config.js` to the public HTTPS TestFlight join URL when it is available. A valid invitation updates the header, hero, closing button, status, and beta FAQ together. Until then, primary buttons lead to the product explanation; the page states that the invitation is coming soon.

## Visual assets

The living-room scene is an original generated image, created using built-in ImageGen. Prompt: “A premium editorial photograph of a quiet modern living room at dusk, with a caramel leather sofa, a golden retriever resting on a cream rug, dark green walls, plants, a warm lamp, natural amber light, cinematic shadows, and realistic domestic detail. No devices, people, text, logos, or UI.” The optimized JPEG is used on the page; the PNG is the retained source.

Product UI uses genuine app captures from the running iPhone, iPad, Mac, Watch, TV and Vision builds. Captures are preserved without replacement scenes or redrawn controls. Official device PNG artwork is composited with unchanged captures in HTML/CSS, preserving their aspect ratios. The Vision section uses an official photograph of a person wearing the headset and a separate genuine visionOS capture. Current companion captures show development/setup or disconnected states, not finished scenario recordings. Replace them with a reviewed live capture session before launch. Device hardware imagery must use photographs or official renders; product screens must always be actual captures.

The hero pairs a primary iPhone with a supporting iPad on a shared visual baseline. The device stories cover a nearby nursery check from Watch through the paired iPhone, desk viewing and reverse Mac-camera pairing, a scenic camera window in Vision Pro, kitchen viewing on iPad, and multiple cameras on Apple TV. No app screenshots are rebuilt in the website. The generated nursery and mountain-lake images are editorial scenario illustrations kept separate from the app captures; they do not represent recorded footage. Their original PNGs are retained, while JPEGs are served. The nursery prompt requested a quiet room at dusk with a sleeping baby in an empty crib and no devices. The landscape prompt requested morning light over a mountain lake with no devices.
The SVG mark is a website exploration, not a replacement for the app icon. Fonts and their OFL notices are copied from the local UI package.

Before public launch, confirm which companions are included, add the beta invitation, and prepare the support page and a domain-specific sharing image. This implementation does not collect visitor information.

Official artwork: iPhone 17 Pro in Deep Blue and 11-inch iPad Pro (M5) in Space Black, downloaded from Apple Design Resources. The owner authorized acceptance of the supplied license on 7 October 2026. The license is retained beside the PNG artwork.

## Angled device renders

`Production/render-ipad.py` renders the retained official USDZ model into two transparent PNG views. Run it with Blender in background mode using `--factory-startup -b -P Website/Production/render-ipad.py` from the repository root. Hardware geometry is preserved; only the display texture is replaced with the actual app capture. The production model and script are excluded from the static build.

## Privacy policy

The standalone `privacy/` page covers local capture and recordings, encrypted CloudKit payloads, same-account pairing sync, network services, Watch fallback snapshots, retention limits, exports, permissions, support and TestFlight diagnostics. The footer and homepage privacy section link to it. Recheck the policy against release behavior and the selected host before publishing.
