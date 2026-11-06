# Panel

`src/panel/*` is the DevTools panel's own logic, ported out of the former `page.js`. It is
Rust because it is *decisions over data*: filtering, scoring, analysis, report shaping. The
JavaScript that remains is the platform layer — `chrome.devtools` callbacks and the DOM.

## The resource model (`model.rs`)

Normalizes raw `chrome.devtools` resource objects into the panel's shape, then applies
filters and sort orders. A `{}`-style counter keeps first-seen key order, because these maps
serialize straight into the exported analysis and JavaScript objects preserve insertion
order.

## Capture policy (`policy.rs`)

The rules the page world applies, as data:

| Constant | Value |
| --- | --- |
| `REDACT_KEY_PATTERN` | `token\|secret\|password\|passwd\|cookie\|authorization\|bearer\|jwt\|session` |
| `TEXT_MIME_PATTERN` | `(?:javascript\|ecmascript\|typescript\|json\|text\|xml\|svg\|html\|css)` |
| `GRAPHQL_URL_MARKER` | `graphql` |
A key matching the redaction pattern is replaced with `[redacted]` before it can reach the
archive. This rule had **zero test coverage** while it lived inside a page-world bundle;
moving it here is what made it testable (`tests/capture_policy_test.rs`).

Eighteen budgets bound what a capture keeps:

| Limit | Value | Limit | Value |
| --- | --- | --- | --- |
| `items` | 12 | `runtimeItems` | 200 |
| `keys` | 24 | `runtimeText` | 256 KiB |
| `string` | 240 | `runtimeBinary` | 1 MiB |
| `mutations` | 500 | `responseText` | 10 000 |
| `resourceUrls` | 160 | `socketMessage` | 2 000 |
| `scriptUrls` | 80 | `mutationText` | 200 |
| `endpoints` | 20 | `elementText` | 80 |
| `classNames` | 8 | `elementLabel` | 40 |
| `queryItems` | 6 | `technologies` | 12 |

The page world reads these by name through a `limit(name)` accessor that answers 0 for an
unknown name — so a renamed key can never become an unbounded slice, and a test asserts that
every name the page world reads is answered and every key in the object is read.

## Stack profile (`stackprofile.rs`)

Detects 19 technologies from a captured page snapshot — Next.js, Nuxt, Remix, Astro,
SvelteKit, React, Vue, Angular, Webpack, Vite, Parcel, WordPress, Shopify, GraphQL, Apollo,
Relay, WebAssembly, Service Worker, Generic Web App — and 9 traits: `spa-hydration`,
`dynamic-dom`, `graphql-heavy`, `socket-heavy`, `worker-heavy`, `wasm-heavy`, `api-heavy`,
`runtime-generated-code`, `static-ish`.

Then it derives a **capture strategy**. The rules are ordered and cumulative, so later ones
refine or override earlier ones:

| Profile | Trigger | Effect |
| --- | --- | --- |
| `spa-hydration` | Next.js / Nuxt / Remix / Astro / SvelteKit | boot 1600 ms, network quiet 1500 ms, mutation quiet 1800 ms; prefer hydrated DOM, capture framework state, prioritize source maps |
| `graphql-app` | `graphql-heavy`, Apollo, Relay or GraphQL — **only if still `generic-app`** | capture GraphQL ops; network quiet raised to ≥1600 ms |
| `socket-streaming` | `socket-heavy` | socket quiet 3600 ms, max capture ≥22 s |
| `worker-runtime-heavy` | `worker-heavy` or `wasm-heavy` | worker grace 2200 ms, runtime quiet 1800 ms, max capture ≥24 s |
| `static-site` | WordPress / Shopify — **only if still `generic-app`** | network quiet ≤1100 ms, mutation quiet ≤1000 ms |
| `generic-app` | default | boot 1200 ms, network quiet 1000 ms |

A bundler marker (Webpack / Vite / Parcel) adds `prioritizeSourceMaps` without changing the
profile.

The strategy carries the timings the page world's readiness gates read: `bootDelayMs`,
`networkQuietMs`, `mutationQuietMs`, `runtimeQuietMs`, `socketQuietMs`, `workerGraceMs`,
`maxCaptureMs`. The page world keeps its own defaults because it needs usable timings
*before* the panel's analysis arrives — and `tests/stack_profile_test.rs` pins the mirror so
the two cannot drift.

## Asset analysis (`assets.rs`)

For each script asset: bundler detection, framework detection, startup signals, route and
import extraction, classification, and a score.

**Startup signals** — `hydration`, `service-worker-register`, `worker-bootstrap`,
`wasm-bootstrap`, `graphql-client`, `dynamic-import`, `inline-source-map`, `chunk-loader`,
plus the bundler markers `webpack`, `vite`, `parcel`.

**Classification** — `runtime`, `vendor`, `framework`, `app`, plus the more specific
`webpack`, `vite`, `parcel`, `blob-derived`, `bundle-linked`, `data-url`, `object-url`,
`inline-script`, `wasm-module`, `worker-bootstrap`. The order is decisive: a runtime-shaped
name wins over a vendor match, which wins over a framework hint.

**Score** — starts from the classification (`app` 48, `runtime` 34, `framework` 24, other 18),
then adds 7 per startup signal, 4 per route hint, up to 12 for module signals (dynamic
imports ×2 + import count), 6 for an embedded source map, and up to 12 from transfer size.
The score is what ranks `interestingEntrypoints`.

## Boundaries and flows (`boundary.rs`)

Labels each asset and runtime record with the boundaries it touches — `bootstrap`, `router`,
`state`, `data`, `auth`, `analytics`, `editor`, `vendor` — each label carrying a score and
the reason it was applied.

Then it derives cross-boundary flows. The relation is decided by the endpoint kinds:

| From → to | Relation |
| --- | --- |
| chunk → chunk | `imports-boundary` |
| chunk → runtime | `materializes-runtime` |
| runtime → runtime | `spawns-runtime` |

A flow is only kept when it actually crosses a boundary (or is one of the two runtime
relations, which are interesting regardless). `collect_interesting_entrypoints` ranks the
chunks and runtime origins worth looking at first, with a human-readable `why` assembled from
the asset's boundary, classification, bundler and startup signals.

## Module graph and startup chain (`graph.rs`)

A node/edge graph (deduplicated by `id` and `from->to:reason`) plus the startup chain: which
chunk bootstraps what, in what order. Also collects network and GraphQL operations.

## Analysis assembly (`analysis.rs`)

`build_semantic_analysis` is the integration seam. It runs every stage in the JavaScript
order and returns one object:

```
assets, runtimeRecords,
chunkMap, moduleGraph, startupChain, runtimeOrigins,
boundaryLabels, crossBoundaryFlows,
frameworkState, frameworkRuntime,
interestingEntrypoints,
investigation { workspaces, journeys, summary }
```

`serde_json`'s `preserve_order` feature is enabled precisely so a serialized analysis has
the same key order as the JavaScript original.

## Workspaces and journeys (`workspace.rs`)

Eight boundary workspaces (bootstrap, router, state, data, auth, analytics, editor, vendor)
plus a framework-state workspace, each with a description, focus questions, and slices of
the entrypoints, chunks, runtime records, events, transitions and chains. Four journeys
stitch them into narratives:

| Journey | Question it answers |
| --- | --- |
| `initial-load` | How do bootstrap, runtime materialization, routing and data startup fit together on first load? |
| `auth-handshake` | Where does the session/auth path go downstream? |
| `route-change` | What happens on navigation? |
| `runtime-materialization` | Which chunks create runtime artifacts, and what do those artifacts do? |

## Reports (`report.rs`)

Generates the HTML the archive carries: the **Investigation Console** (`_analysis/index.html`,
with workspace and journey navigation), the **network waterfall**, the timings table, and the
DOM snapshot. The long style/script blocks are transcribed verbatim from the JavaScript, and
the oracle test compares the rendered document byte for byte.

## Export orchestration (`export.rs`)

`write_recon_artifacts` writes `_recon/*` synchronously; `finalize_zip_with_recon` runs the
whole export. The platform halves stay on the caller's side — payload fetching is the
caller's, and the finished archive is a writer seam — so everything here is synchronous and
observable.

## View layer (`view.rs`)

View models plus the HTML strings the shim applies to the DOM. The pre-port renderers built
elements with `createElement`/`textContent`; the markup produced here has the same structure,
classes, labels and inline styles, so the CSS and the e2e selectors keep working.

## Text helpers (`text.rs`)

Pure string/path/number helpers with exact JavaScript semantics — filename sanitizing, slug
building, number rendering. Every function was verified against node oracles captured from
the pre-port `page.js`.

## The bridge (`src/js/unpack-bridge.js`)

51 exports, each keeping the exact signature the former JavaScript engine had, so `page.js`
and the test suite consume the same API with only the import path changed.

The engine loads **synchronously at import time** — a sync XHR on the extension origin in the
browser, `fs` in node — so `WebAssembly.Module` + `Instance` are ready the moment the module
finishes evaluating. No init dance, no async gap for consumers to trip over.

Marshalling is allocate → call → free, with the engine's own trap escaping untouched so the
failure reader can read `lastFailure` without recursing into the explanation layer.
