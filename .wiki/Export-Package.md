# Export Package

`sources.zip`, assembled entirely in the engine (`pipeline::build_zip`). The panel collects
`{path, content}` / `{path, base64}` pairs and one call turns them into bytes.

```
sources.zip
├── _recon/                 what the page was doing
├── _runtime/               raw runtime payloads + manifest
├── _analysis/              the derived investigation material
├── _unpack/<asset>/        each page script, decompressed
├── _unpack-runtime/        each runtime payload, decompressed
└── _unpack/index.json      per-asset report
```

## `_recon/` — capture facts

| File | Contents |
| --- | --- |
| `page.json` | the page snapshot the capture collected (url, title, origin, and whatever the page world published) |
| `localStorage.json`, `sessionStorage.json` | storage dumps, redacted |
| `cookies.json` | parsed cookies, redacted |
| `stack-profile.json` | detected technologies, traits, confidence |
| `capture-strategy.json` | the timings the capture used |
| `capture-status.json` | readiness reason and activity counters |
| `framework-signals.json` | the raw evidence behind the profile |
| `timings.json` | resource timing entries |
| `waterfall.html` | the network waterfall report |
| `xhr.json`, `fetch.json`, `websockets.json`, `sse.json` | captured traffic |
| `mutations.json` | DOM mutation log |
| `graphql-operations.json` | GraphQL operations seen |
| `dom-snapshot.html` | the rendered DOM |

## `_runtime/` — raw payloads

One folder per kind, numbered per entry:

```
_runtime/eval/0001.js
_runtime/function/0001.js
_runtime/blob/0001.js
_runtime/workers/0001.js
_runtime/shared-workers/0001.js
_runtime/service-workers/0001.js
_runtime/script-injections/0001.js
_runtime/wasm/0001.wasm
_runtime/runtime-manifest.json
```

The extension is chosen from the payload's MIME type — `js`, `json`, `html`, `css`, `svg`,
`xml`, `txt` — with `wasm` recognized by kind; anything unrecognized lands in `misc/`.

## `_unpack/<asset>/` — one folder per page script

| Path | Content |
| --- | --- |
| `00-original.js` | the asset exactly as captured — only when a layer was peeled |
| `layers/0<depth>-<tool>.js` | the output of that peel stage — `01-eval-unwrap.js`, `02-base64.js`, … The tools are `eval-unwrap`, `base64`, `hex-escape`, `unescape`, `charcode`, `reverse`, `rot13`, `packer`, `jsfuck`, `string-array` |
| `modules/` | modules split out of the bundle, named from `//# sourceURL` |
| `10-beautified.js` | beautified output, when the recovered source is still minified |
| `10-source.js` | the recovered source as-is, when it is already readable |
| `source-map.json` | the source map, inline or fetched from its URL |
| `sources/` | `sourcesContent` entries — i.e. the original files |

## Binary assets get their own files

A cached-bytecode asset has no source to peel, so it writes structure instead:

| Path | Content |
| --- | --- |
| `wasm-info.json` | version, sections, imports, exports, function and type names, data strings |
| `cache-header.json` | the cache header: magic, runtime, format, version/source/flag hashes, payload length |
| `functions.json` | the JSC function tree with shared-table name resolution |
| `strings.json` | every recovered string |

## `_unpack-runtime/` — the same treatment for runtime payloads

`eval()`/`Function()`/injected/worker JavaScript goes through the identical peel loop, so a
payload that only exists at runtime gets the same decompression as a network script.

## `_unpack/index.json` — the report

Per asset: url, zip path, kind, byte count, SHA-256 digest, the stage list (tool, depth,
input/output bytes, digest, `//# sourceURL`), module count, recovered source count, whether
it was beautified, the source-map summary, notes, and any refusals. Pretty-printed.

## `_analysis/` — the investigation material

| File | Contents |
| --- | --- |
| `index.html` | the Investigation Console: workspace and journey navigation |
| `chunk-map.json` | every script chunk with its classification and score |
| `module-graph.json` | nodes and edges |
| `startup-chain.json` | what bootstraps what, in order |
| `runtime-origins.json` | where each runtime payload came from |
| `boundary-labels.json` | which boundaries each asset touches |
| `cross-boundary-flows.json` | flows between boundaries |
| `framework-runtime.json` | router, stores, query cache, hydration |
| `interesting-entrypoints.json` | ranked starting points, with a `why` |
| `readable/NNNN-<label>.js` | the recovered source with a `Semantic reconstruction` header: label, URL, file, boundaries, why, score, beautified yes/no |
| `workspaces/<id>.json` | one file per boundary workspace |
| `journeys/<id>.json` | `initial-load`, `auth-handshake`, `route-change`, `runtime-materialization` |

## Ordering

The archive is written in four blocks, and `tests/` asserts the order:

```
_recon/*  →  _runtime/*  →  _analysis/*  →  _unpack/*  and  _unpack-runtime/*
```

Context first, payloads last: a consumer reading the archive top-down meets what the page
was doing before it meets the megabytes of deobfuscated source. Each unpack pass writes its
files first and its `index.json` report last.
