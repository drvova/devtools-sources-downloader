# DevTools - Sources downloader

Chrome DevTools extension. Captures the inspected page's resources, runtime payloads
and framework state, then exports an unpacked, site-aware package as `sources.zip`.

## Layout

The extension exists in two loadable copies that must stay identical:

- `dist/` - webpack build output (`manifest.json` + `js/ html/ css/ images/`).
- repository root - an unpacked load of the same files.

`npm run build` writes `dist/` and then mirrors it over the root with `scripts/sync.js`,
so the build output is the single source of truth and the two copies cannot drift.
`src/js/*` is the source; nothing in `js/` or `dist/` should be edited by hand.

## Commands

| Command | What it does |
| --- | --- |
| `npm run build` | production webpack build + mirror into the root layout |
| `npm run dev` | development build (unminified, source maps) + mirror |
| `npm test` | unit tests for the unpack engine (`test/unpack.test.mjs`) |
| `npm run test:e2e` | loads the built bundle in a real browser, clicks Download All, reads the produced zip |
| `npm run verify` | unit tests + build + end-to-end (run this before committing) |

`test:e2e` drives a Chromium browser over the DevTools protocol with a stubbed
`chrome.devtools` API; it needs Chrome or Edge installed (`test/browser-e2e.mjs` lists
the paths it looks in), and it uses the *built* artifacts, so build first.

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

| Path | Content |
| --- | --- |
| `00-original.js` | the asset exactly as captured (only when a layer was peeled) |
| `layers/NN-<tool>.js` | the output of layer `NN` (`eval-unwrap`, `base64`, `hex-escape`, `unescape`, `charcode`, `reverse`, `rot13`) |
| `modules/` | modules split out of webpack bundles, named from `//# sourceURL` |
| `10-beautified.js` | beautified output when the recovered source is still minified |
| `10-source.js` | the recovered source as-is when it is already readable |
| `source-map.json` | the source map, inline or fetched from the referenced URL |
| `sources/` | `sourcesContent` entries from the map, i.e. the original files |

## Unpack engine

`src/js/unpack.js` runs the same loop as offline unpackers (detect -> route -> transform
-> re-detect) but entirely inside the DevTools panel: no Python, no sandbox, no
toolchain. Each pass scores the layers it can see, applies the strongest one, and
repeats until the payload stops changing (bounded by depth and size budgets). Only
source maps the page itself publishes cause network access.

Everything in it is a pure function over text, which is why `npm test` can cover the
whole engine outside a browser.
