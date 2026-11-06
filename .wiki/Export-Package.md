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

## Write order

The archive is written in four blocks, and `tests/` asserts the order:

```
_recon/*  →  _runtime/*  →  _analysis/*  →  _unpack/*  and  _unpack-runtime/*
```

Context first, payloads last: a consumer reading the archive top-down meets what the page was
doing before it meets the megabytes of deobfuscated source. Each unpack pass writes its files
first and its `index.json` report last.

## `_recon/` — capture facts

| File | Contents |
| --- | --- |
| `page.json` | the page snapshot the capture collected (url, title, origin, and whatever the page world published) |
| `localStorage.json` | the `ls` map — **only if non-empty** |
| `sessionStorage.json` | the `ss` map — only if non-empty |
| `cookies.json` | parsed cookies — only if the cookie string is non-empty |
| `stack-profile.json` | technologies, traits, confidence, strategy |
| `capture-strategy.json` | the timings the capture used |
| `capture-status.json` | readiness reason and activity counters |
| `framework-signals.json` | the raw evidence behind the profile |
| `timings.json` | resource timing entries |
| `waterfall.html` | the network waterfall report |
| `xhr.json`, `fetch.json`, `websockets.json`, `sse.json` | captured traffic (written only when non-empty) |
| `mutations.json` | the DOM mutation log |
| `graphql-operations.json` | GraphQL operations seen |
| `dom-snapshot.html` | the rendered DOM |

Empty maps are **skipped, not written empty** — an archive full of `{}` files is noise.

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

The folder comes from the payload's **kind**; the extension from its **MIME type**:

| Pattern | Extension |
| --- | --- |
| `javascript\|ecmascript\|typescript` | `js` |
| `json` | `json` |
| `html` | `html` |
| `css` | `css` |
| `svg` | `svg` |
| `xml` | `xml` |
| `text` | `txt` |

`wasm` is recognised by kind or MIME first. A payload with no matching MIME falls back to
`bin` when it arrived as base64, `txt` otherwise. `eval`/`function`/worker/script-injection
kinds default to `js`.

`runtime-manifest.json` is the entries **minus** the payload bodies (`text`, `base64`,
`hasText`, `hasBase64`, `index` are stripped) **plus** the `file` path each payload was
written to. So the manifest is the index, and the payloads are the content.

## `_unpack/<asset>/` — one folder per page script

The folder name is `asset_slug(url, index)`: `0001-example.com__static__app.js`.

| Path | Content |
| --- | --- |
| `layers/0<depth>-<tool>.js` | the output of that peel stage — `01-eval-unwrap.js`, `02-base64.js`, … |
| `00-original.js` | the asset exactly as captured — **only** when a layer was peeled |
| `modules/<name>.js` | modules split out of a webpack bundle, named from `//# sourceURL` |
| `10-beautified.js` | beautified output, when the recovered source is still minified |
| `10-source.js` | the recovered source as-is, when it is already readable |
| `source-map.json` | the source map, inline or fetched from its URL |
| `sources/<path>` | `sourcesContent` entries — the original files |

The layer tools are `eval-unwrap`, `base64`, `hex-escape`, `unescape`, `charcode`, `reverse`,
`rot13`, `packer`, `jsfuck`, `string-array`.

Note that `10-beautified.js` and `10-source.js` are **alternatives**, not both: the pass writes
whichever applies.

## Binary assets get their own files

A cached-bytecode asset has no source to peel, so it writes structure instead:

| Path | Content |
| --- | --- |
| `wasm-info.json` | version, sections, imports, exports, function and type names, data strings, notes |
| `cache-header.json` | the cache header: magic, runtime, format, version/source/flag hashes, payload length |
| `functions.json` | the JSC function tree with shared-table name resolution |
| `strings.json` | every recovered string |

## `_unpack-runtime/` — the same treatment for runtime payloads

`eval()`/`Function()`/injected/worker JavaScript goes through the identical peel loop, so a
payload that only exists at runtime gets the same decompression as a network script. Only
payloads whose extension resolved to `js` are unpacked — a wasm blob is not text.

## `_unpack/index.json` — the report

```json
{
  "generatedBy": "unpack.js",
  "assets": [ … ],
  "totals": { "assets": N, "unpacked": N, "modules": N, "sources": N, "beautified": N },
  "root": "_unpack",
  "unpackedAt": "2026-01-01T00:00:00.000Z"
}
```

Each asset entry:

| Field | Meaning |
| --- | --- |
| `url`, `zipPath` | where it came from, where it landed |
| `kind` | `text` or `binary` |
| `bytes` | UTF-16 length of the content |
| `digest` | SHA-256, absent when the content is empty |
| `stages` | the peel/binary stages: tool, depth, input/output bytes, digest, `sourceUrl` |
| `modules` | webpack modules split out |
| `sources` | `sourcesContent` entries recovered |
| `beautified` | whether the output was reformatted |
| `sourceMap` | `{kind: inline\|external, ref}` |
| `notes` | human-readable remarks — budget refusals, fetch failures, "nothing found" |
| `refusals` | tools that could not be statically decoded, with detail |
| `functions` | JSC function count, when a bytecode module bound |

`unpacked` counts an asset as unpacked when it produced **any** stage, source or module.
Pretty-printed, so it diffs cleanly.

## `_analysis/` — the investigation material

| File | Contents |
| --- | --- |
| `index.html` | the **Investigation Console**: workspace and journey navigation, summary cards |
| `chunk-map.json` | `{generatedAt, summary, items}` — every script chunk with classification and score |
| `module-graph.json` | `{nodes, edges}` |
| `startup-chain.json` | what bootstraps what, in order, plus the capture profile |
| `runtime-origins.json` | `{generatedAt, summary, items}` — where each runtime payload came from |
| `boundary-labels.json` | which boundaries each asset touches, with scores and reasons |
| `cross-boundary-flows.json` | `{events, transitions, topTransitions, chains}` |
| `framework-runtime.json` | router, stores, query caches, hydration, auth, plus available workspaces/journeys |
| `interesting-entrypoints.json` | ranked starting points, each with a `why` |
| `readable/NNNN-<label>.js` | the recovered source behind a `Semantic reconstruction` header |
| `workspaces/<id>.json` | one file per boundary workspace |
| `journeys/<id>.json` | `initial-load`, `auth-handshake`, `route-change`, `runtime-materialization` |

A readable artifact's header carries: label, `URL:`, `File:`, `Boundaries:`, `Why:`,
`Score:`, `Beautified: yes|no` — so a file lifted out of the archive still explains itself.

## What a good archive tells you without opening a script

1. `_recon/stack-profile.json` — what the site is built with, and how sure the detector is.
2. `_recon/capture-strategy.json` — why the capture waited as long as it did.
3. `_analysis/index.html` — the guided tour: which boundary to look at first, and why.
4. `_analysis/interesting-entrypoints.json` — the ranked shortlist with reasons.
5. `_unpack/index.json` — which assets actually yielded something, and which refused.
