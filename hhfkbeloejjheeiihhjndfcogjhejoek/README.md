# DevTools - Sources downloader

Chrome DevTools extension. Captures the inspected page's resources, runtime payloads
and framework state, then exports an unpacked, site-aware package as `sources.zip`.

## Layout

The extension exists in two loadable copies that must stay identical:

- `dist/` - rsbuild (Rstack CLI) build output (`manifest.json` + `js/ html/ css/ images/`).
- repository root - an unpacked load of the same files.

`npm run build` writes `dist/` and then mirrors it over the root with `scripts/sync.cjs`,
so the build output is the single source of truth and the two copies cannot drift.
`src/js/*` is the source; nothing in `js/` or `dist/` should be edited by hand.

## Commands

| Command                | What it does                                                                                        |
| ---------------------- | --------------------------------------------------------------------------------------------------- |
| `npm run build`        | production rsbuild build + mirror into the root layout                                              |
| `npm run dev`          | development build (unminified, source maps) + mirror                                                |
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
  "Load unpacked", select the repository root (or `dist/`). Open DevTools on any
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

`src/js/unpack.js` runs the same loop as offline unpackers (detect -> route -> transform
-> re-detect) but entirely inside the DevTools panel: no Python, no sandbox, no
toolchain. Each pass scores the layers it can see, applies the strongest one, and
repeats until the payload stops changing (bounded by depth and size budgets). Only
source maps the page itself publishes cause network access.

Everything in it is a pure function over text, which is why `npm test` can cover the
whole engine outside a browser.
