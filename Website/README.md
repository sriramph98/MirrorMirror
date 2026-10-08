# MirrorMirror website

A responsive static marketing website, kept alongside the apps and independently deployable. It uses the app's bundled typefaces and translated visual tokens. No framework, external font service, tracking, or package installation is required.

## Preview

Run `npm run dev` from this folder, then open http://127.0.0.1:4173. Set `PORT` to choose another local port.

## Build

Run `npm run build`. The generated `dist/` folder can be served by a static host. Publishing is a separate action.

## Beta invitation

Set `betaUrl` in `site-config.js` to the public HTTPS TestFlight join URL when it is available. A valid invitation updates the header, hero, closing button, status, and beta FAQ together. Until then, primary buttons lead to the product explanation; the page states that the invitation is coming soon.

## Visual assets

The living-room scene is an original generated image, created using built-in ImageGen. Prompt: “A premium editorial photograph of a quiet modern living room at dusk, with a caramel leather sofa, a golden retriever resting on a cream rug, dark green walls, plants, a warm lamp, natural amber light, cinematic shadows, and realistic domestic detail. No devices, people, text, logos, or UI.” The optimized JPEG is used on the page; the PNG is the retained source.

Product UI uses genuine app captures from the running iPhone and iPad builds. The captures are preserved without replacement scenes, redrawn controls, or simulated hardware frames. They are development captures and should be replaced with a reviewed launch capture session when available. Other platform descriptions are text-only until authentic imagery is supplied. Device hardware imagery must use photographs or official renders; product screens must always be actual captures.

The SVG mark is a website exploration, not a replacement for the app icon. Fonts and their OFL notices are copied from the local UI package.

Before public launch, confirm which companions are included, add the beta invitation, and prepare final privacy/support pages and a domain-specific sharing image. This implementation does not collect visitor information.
