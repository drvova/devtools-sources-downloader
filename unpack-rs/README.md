# DevTools - Sources downloader

Chrome DevTools extension. Captures the inspected page's resources, runtime payloads
and framework state, then exports an unpacked, site-aware package as `sources.zip`.

## Layout

Flat project: the Rust crate and this extension share the folder.

- `src/*.rs` (+ `src/panel/`) - the crate: the unpack engine and the panel
  logic, compiled to `engine.wasm`. `Cargo.toml` declares `src/lib.rs` as its
  only entry, so the extension files below it are simply not Rust sources.
- `src/js`, `src/html`, `src/css`, `src/images`, `src/manifest.json` - the
  extension's sources. The build bundles `src/js` and copies the rest.
- `dist/` - the loadable extension: rsbuild output holding `manifest.json` plus
  `js/ html/ css/ images/`. Point Chrome's "Load unpacked" at this folder.
- `test/` - the JS suite (67 cases + the browser e2e); `tests/` - the Rust
  suite (`cargo test`), which reads this folder's fixtures from `test/fixtures/`.
- `scripts/` - `build-engine.cjs` builds the crate to wasm, `dev-ext.mjs` and
  `ext-lib.mjs` drive the Chrome for Testing runs.

Nothing in `dist/` is edited by hand.

## Commands

| Command                | What it does                                                                                        |
| ---------------------- | --------------------------------------------------------------------------------------------------- |
| `npm run build`        | production rsbuild build into `dist/` (the loadable extension)                                      |
| `npm run dev`          | development build (unminified, source maps)                                                         |
| `npm run dev:ext`      | watch build + a dedicated Chrome for Testing window with the extension auto-reloading               |
| `npm test`             | unit tests for the unpack engine (`test/unpack.test.mjs`)                                           |
| `npm run test:e2e`     | loads the built bundle in a real browser, clicks Download All, reads the produced zip               |
| `npm run test:e2e:ext` | loads `dist/` as an unpacked extension in Chrome for Testing and asserts the real extension context |
| `npm run verify`       | unit tests + build + both end-to-end suites (run this before committing)                            |
| `npm run check`        | Rslint + format check over the source tree                                                          |

`test:e2e` drives a Chromium browser over the DevTools protocol with a stubbed
`chrome.devtools` API; it needs Chrome or Edge installed (`test/browser-e2e.mjs` lists
the paths it looks in), and it uses the _built_ artifacts, so build first.

`test:e2e:ext` and `dev:ext` load `dist/` as a real unpacked extension. Branded
Chrome/Edge ignore `--load-extension`, so both use Chrome for Testing, downloaded
once into `.cache/browser/` on first run.

## Loading the extension

- **Manual (any Chrome):** open `chrome://extensions`, enable Developer mode,
  "Load unpacked", select `unpack-rs/dist/`. Open DevTools on any
  page - the downloader is the "Sources Downloader" panel tab.
- **Dev loop:** `npm run dev:ext` starts the watch build plus a dedicated
  Chrome for Testing window with the extension preloaded; every save rebuilds
  and reloads the extension in that window automatically.

## Export package

```
_recon/            network, storage, cookies, timings, DOM snapshot, framework state
_runtime/          raw runtime payloads (eval, Function, workers, wasm...) + manifest
_analysis/         chunk map, module graph, startup chain, boundary labels, readable views
_unpack/<asset>/   page scripts, decompressed
_unpack-runtime/   eval()/Function()/injected/worker JS payloads, decompressed
_unpack*/index.json  per-asset report: layers, module counts, recovered sources, notes
```

Per asset, `_unpack/<slug>/` holds:

| Path                  | Content                                                                                                      |
| --------------------- | ------------------------------------------------------------------------------------------------------------ |
| `00-original.js`      | the asset exactly as captured (only when a layer was peeled)                                                 |
| `layers/NN-<tool>.js` | the output of layer `NN` (`eval-unwrap`, `base64`, `hex-escape`, `unescape`, `charcode`, `reverse`, `rot13`) |
| `modules/`            | modules split out of webpack bundles, named from `//# sourceURL`                                             |
| `10-beautified.js`    | beautified output when the recovered source is still minified                                                |
| `10-source.js`        | the recovered source as-is when it is already readable                                                       |
| `source-map.json`     | the source map, inline or fetched from the referenced URL                                                    |
| `sources/`            | `sourcesContent` entries from the map, i.e. the original files                                               |

## Unpack engine

`src/js/unpack-bridge.js` + the compiled Rust engine (`dist/js/engine.wasm`, built
by `scripts/build-engine.cjs` from the crate at `../`) run the same loop as offline
unpackers (detect -> route -> transform -> re-detect) but entirely inside the
DevTools panel: no Python, no sandbox, no toolchain. Each pass scores the
layers it can see, applies the strongest one, and repeats until the payload
stops changing (bounded by depth and size budgets). Only source maps the page
itself publishes cause network access (synchronous credentialed XHR from the
extension origin, or a caller-supplied `fetchMap`).

The engine is the `devtools-unpack` crate compiled for wasm32; the bridge
keeps the exact API surface the former JavaScript engine exported, which is
why `npm test` covers the shipped artifact outside a browser. Port notes and
deliberate divergences live in `../PORTING.md`.
