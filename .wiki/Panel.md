# Panel

`src/panel/*` is the DevTools panel's own logic, ported out of the former `page.js`. It is
Rust because it is **decisions over data** — filtering, scoring, analysis, report shaping.
The JavaScript that remains is the platform layer: `chrome.devtools` callbacks and the DOM.

```
src/panel/model.rs        resource normalization, filters, sort orders
src/panel/text.rs         JS-semantics string/number/path helpers
src/panel/policy.rs       the capture policy the page world applies
src/panel/stackprofile.rs technology + trait detection, capture strategy
src/panel/assets.rs       script-asset analysis, runtime origins
src/panel/boundary.rs     boundary labels, cross-boundary flows, entrypoints
src/panel/graph.rs        module graph, startup chain, GraphQL/network ops
src/panel/analysis.rs     the whole-pipeline assembly
src/panel/workspace.rs    investigation workspaces and journeys
src/panel/report.rs       the HTML pages the archive carries
src/panel/export.rs       export orchestration
src/panel/view.rs         view models + row markup
src/panel/artifacts.rs    artifact paths, runtime unpack assets
```

## The resource model — `model.rs`

`normalize_resource(raw, status, index)` turns a `chrome.devtools` resource into
`{status, type, source, url, size, time, order}`. Every string field goes through a JS
`String(value)` coercion that answers `"?"` for a falsy value — so a missing URL reads `?`,
not `undefined`. `size` is kept only when non-zero and finite.

`get_resource_time` takes the **first truthy** of `time`, `timestamp`, `seenAt`,
`startTime`, coerces it, and requires it to be finite. That field order is the original's and
it matters: a resource with both `time: 0` and `timestamp: 1234` reads 1234.

`Counts` is a `{}`-style counter backed by a `serde_json::Map`, so it **preserves first-seen
key order**. These maps serialize straight into the exported analysis, and JS objects keep
insertion order — sorting them would change the output bytes.

### Filtering and sorting

`matches_resource_filters`: status and type must match unless empty or `"all"`; the search
is trimmed, lowercased, and matched as a substring against
`status type source url` joined by spaces.

`compare_resources` has four modes:

| Mode | Order |
| --- | --- |
| `largest` | size desc, then time desc |
| `type` | kind via `js_locale_compare`, then url |
| `url` | url via `js_locale_compare` |
| *default* (`newest`) | time desc, then **insertion order asc** |

`js_locale_compare` folds case first, then breaks a tie by a per-character
uppercase/lowercase key — which is how `localeCompare` orders the fixed vocabulary here.

`collect_types` returns distinct types in first-seen order, then sorts by **UTF-16 code
units** — the way `Array.prototype.sort()` sorts strings, not the way Rust's `str` ordering
does.

## Text helpers — `text.rs`

Every function here was verified against node oracles captured from the pre-port `page.js`.

| Function | Semantics worth knowing |
| --- | --- |
| `hash_string` | the Java-style 32-bit rolling hash (`h*31 + unit`), hex-rendered. `Math.abs(i32::MIN)` is `2147483648`, so the value is widened **before** abs or `0x80000000` would come out negative. |
| `js_trim` | trims only JS whitespace, not Rust's Unicode set |
| `sanitize_path_part` | strip path-hostile chars, fall back on empty, truncate to 100 UTF-16 units |
| `sanitize_filename` | full URL → path: `data:` → MIME-based name, `blob:` → the inner URL, loose schemes handled, empty → `unknown/resource` |
| `normalize_url_candidate` | backslash runs → `/`, and the scheme's `://` normalisation (the JS lazy quantifier could only ever match two slashes, so the port does the same) |
| `format_size` | `0 B`, `<1024 → N B`, `<1 MiB → N.N KB`, else `N.NN MB` |
| `js_to_fixed` | expands with **25 guard digits** before rounding half-away-from-zero, so `999.95` (stored just above) rounds up the way JS does |
| `js_truthy` | `null`/`false`/`0`/`NaN`/`""` are falsy; **arrays and objects are always truthy** (JS rule) |
| `serialize_js_number` | a whole finite value serialises as an integer, so `1600.0` becomes `1600` |

That last one is not cosmetic: `serde_json` keeps `Float(1600.0)` and `PosInt(1600)`
distinct, and the profile tests compare the **serialized text**.

## Capture policy — `policy.rs`

The rules the page world applies, as data. They used to be literals inside
`framework-introspect.js` and `injected.js`, where no test could reach them.

| Constant | Value |
| --- | --- |
| `REDACT_KEY_PATTERN` | `token\|secret\|password\|passwd\|cookie\|authorization\|bearer\|jwt\|session` |
| `TEXT_MIME_PATTERN` | `(?:javascript\|ecmascript\|typescript\|json\|text\|xml\|svg\|html\|css)` |
| `GRAPHQL_URL_MARKER` | `graphql` |

A key matching the redaction pattern becomes `[redacted]` before it can reach the archive.
**This rule had zero test coverage while it lived in a page-world bundle** — moving it here
is what made it testable.

Eighteen budgets bound a capture:

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

The page world reads these by name through a `limit(name)` accessor that answers **0** for an
unknown name — so a renamed key can never become an unbounded slice, it becomes an empty one.
A test asserts every name the page world reads is answered and every key in the object is
read.

The object is injected as `window.__CAPTURE_POLICY__` ahead of the page-world scripts. **A
missing policy fails closed**: zero budgets and no redaction pattern, so nothing is decoded
and nothing is kept.

## Stack profile — `stackprofile.rs`

`analyze(snapshot)` reads a plain snapshot — `urls`, `globals`, `dom`, `network`, `runtime`,
`activity`, `globalsDetected` — and returns `{version, generatedAt, technologies, traits,
confidence, evidence, strategy, summary}`.

### The 19 technologies

| Technology | Category | Confidence | Signal |
| --- | --- | --- | --- |
| Next.js | framework | 0.97 | `__NEXT_DATA__`, `#__next`, `/_next/` |
| React | library | 0.86 | `__REACT_DEVTOOLS_GLOBAL_HOOK__`, `/react-dom`, `/react@` |
| Nuxt | framework | 0.95 | `__NUXT__`, `#__nuxt`, `/_nuxt/` |
| Vue | framework | 0.84 | `__VUE__`, devtools hook, Vue mount markers — **only if not Nuxt** |
| Angular | framework | 0.85 | Angular globals, `[ng-version]` |
| SvelteKit | framework | 0.90 | `__SVELTEKIT_APP_VERSION__`, `/_app/immutable/` |
| Astro | framework | 0.90 | `<astro-island>`, `/_astro/` |
| Remix | framework | 0.88 | `__remixContext`, Remix DOM markers |
| Webpack | bundler | 0.88 | `webpackChunk*`, `webpackJsonp`, chunk naming |
| Vite | bundler | 0.95 / 0.72 | `__vite_plugin_react_preamble_installed__` or `/@vite/client`; **else** hashed `/assets/…[a-f0-9]{6,}.js` at 0.72 |
| Parcel | bundler | 0.67 | any `parcel` URL |
| WordPress | platform | 0.94 | generator meta tag, `/wp-content/`, `/wp-includes/` |
| Shopify | platform | 0.95 | `window.Shopify`, `cdn.shopify.com`, `/shopifycloud/` |
| GraphQL | protocol | 0.90 | `graphqlCount > 0` |
| Apollo | data | 0.82 | `__APOLLO_CLIENT__`, `__APOLLO_STATE__`, endpoint match |
| Relay | data | 0.76 | `__RELAY_DEVTOOLS_HOOK__`, endpoint match |
| WebAssembly | runtime | 0.88 | `wasmCount > 0` |
| Service Worker | runtime | — | controller present or `serviceWorkerCount > 0` |
| Generic Web App | profile | 0.45 | fallback when nothing matched |

`tech()` **merges** by name: a second signal raises the confidence to the max and appends to
`evidence`, so a technology detected two ways shows both reasons.

### The 9 traits

`spa-hydration` (hydration markers), `dynamic-dom` (>20 mutations), `graphql-heavy`
(`graphqlCount > 0`), `socket-heavy` (websocket/SSE/open sockets), `worker-heavy`
(`workerCount > 0`), `wasm-heavy` (`wasmCount > 0`), `api-heavy` (fetch+xhr > 10),
`runtime-generated-code` (`runtimeCount > 6`), `static-ish` (≤6 scripts, ≤2 fetches, ≤1 xhr).

### Confidence

```
base      = top technology's confidence × 100   (45 if none)
+ 4 × min(techCount, 4)
+ 3 × min(traitCount, 5)
clamped to [35, 99], rounded
```

### The capture strategy

The rules are ordered and cumulative — later ones refine or override earlier ones.

| Profile | Trigger | Effect |
| --- | --- | --- |
| `spa-hydration` | Next.js / Nuxt / Remix / Astro / SvelteKit | boot 1600 ms, network quiet 1500, mutation quiet 1800, runtime quiet 1400; `preferHydratedDom`, `captureFrameworkState`, `prioritizeSourceMaps` |
| `graphql-app` | `graphql-heavy`, Apollo, Relay or GraphQL — **only if still `generic-app`** | `captureGraphQLOps`; network quiet raised to ≥1600 |
| `socket-streaming` | `socket-heavy` | socket quiet 3600, max capture ≥22 s |
| `worker-runtime-heavy` | `worker-heavy` or `wasm-heavy` | worker grace 2200, runtime quiet 1800, max capture ≥24 s |
| `static-site` | WordPress / Shopify — **only if still `generic-app`** | network quiet ≤1100, mutation quiet ≤1000 |
| `generic-app` | default | boot 1200, network quiet 1000, mutation quiet 1200, runtime quiet 1000, socket quiet 2200, worker grace 1200, max capture 18 000 |

A bundler marker (Webpack / Vite / Parcel) adds `prioritizeSourceMaps` without changing the
profile. Every rule appends a human-readable `reasons` entry.

The strategy carries the timings the page world's readiness gates read: `bootDelayMs`,
`networkQuietMs`, `mutationQuietMs`, `runtimeQuietMs`, `socketQuietMs`, `workerGraceMs`,
`maxCaptureMs`. The page world keeps its own defaults because it needs usable timings
*before* the panel's analysis arrives — and `tests/stack_profile_test.rs` pins the mirror so
the two cannot drift.

Technologies sort by **confidence desc, then name asc**; traits sort by name.

## Asset analysis — `assets.rs`

### Detection

- **Bundler** — `__webpack_require__` / `webpackChunk` / `/_next/static/chunks/` → webpack;
  `parcelRequire` → parcel; `import.meta.hot` / `/@vite/` / `__vite__` → vite.
- **Framework hints** — Next.js, React, Nuxt, Vue, Angular, SvelteKit, Astro, Remix from
  content, **plus** every technology the stack profile detected. Capped at 8.
- **Startup signals** — `hydration`, `service-worker-register`, `worker-bootstrap`,
  `wasm-bootstrap`, `graphql-client`, `dynamic-import`, `inline-source-map`, `chunk-loader`,
  `router`.
- **Route hints** — path segments of the URL, with `static|assets|chunks|build|dist|js|
  runtime|vendor` skipped, hash-like segments (`[0-9a-f_-]{8,}`) skipped, segments shorter
  than 3 skipped, extensions stripped. Capped at 6.
- **Imports** — three patterns (`import … from "x"`, `import("x")`, `require("x")`), capped
  at 40.
- **Module signals** — import count, dynamic imports, requires, exports.

Only the first **200 000 UTF-16 units** are scanned, so a huge bundle cannot stall the panel.

### Classification

`runtime` wins over `vendor`, which wins over `framework`, then `app`:

| Rule | Classification |
| --- | --- |
| name/content matches `runtime\|manifest\|polyfill\|bootstrap`, or `chunk-loader` signal | `runtime` |
| matches `vendor\|node_modules\|chunk-vendors` | `vendor` |
| framework hints match `react\|vue\|angular\|next\|nuxt\|svelte\|astro\|remix` | `framework` |
| otherwise | `app` |

Runtime **origins** get a parallel vocabulary: `blob-derived` (has a blobId),
`inline-script` (script-injection), `worker-bootstrap` (worker kinds), `wasm-module`,
`bundle-linked` (has related chunks), `object-url` (`blob:` URL), `data-url` (`data:` URL),
`runtime-generated` (fallback).

### Scoring

```
classification:  app 48 | runtime 34 | framework 24 | other 18
+ 7 × startupSignals
+ 4 × routeHints
+ min(12, dynamicImports×2 + importCount)
+ 6   if a source map is embedded
+ min(12, round(transferSize / 50_000))
```

Runtime entries score differently: `eval`/`function` 46, `wasm` 42, `script-injection` 38,
other 28; `+8` per related chunk, `+10` for a blobId, `+6` for captured text, `+4` for a
timestamp.

### The asset id

`chunk-<sanitized bare filename>-<first 8 hex of hash_string(url)>` — content-addressed, so
two assets with the same name in different folders stay distinct.

## Boundaries and flows — `boundary.rs`

### The 8 labels

`BoundaryLabel` is an enum with `ALL` spelled out separately — because `as_str`'s match is
exhaustive but `ALL` is not derived from it, so a new variant must be added in both places or
it would be attributed to chunks and never appear in the report's category list.

### Label rules (asset side)

| Label | Score | Trigger |
| --- | --- | --- |
| `bootstrap` | 30 | classification `runtime` (non-runtime entry), or the bootstrap regex, or a `hydration`/`chunk-loader`/`service-worker-register`/`worker-bootstrap`/`wasm-bootstrap` signal, or a worker-kind runtime |
| `router` | 24 | any route hint, or the router regex |
| `state` | 24 | redux/zustand/mobx/recoil/vuex/pinia/createStore/dispatch(/subscribe(/setState( |
| `data` | 24 | graphql/apollo/relay/axios/tanstack/react-query/swr/trpc/fetch(/xhr/`/api/`/urql, or a `graphql-client` signal |
| `auth` | 24 | auth0/next-auth/firebase auth/oauth/bearer/jwt/csrf/signin/session/tokenrefresh/clerk/okta/passport |
| `analytics` | 22 | gtag/google-analytics/segment/mixpanel/amplitude/posthog/hotjar/fullstory/datadogrum/sentry/fbq( |
| `editor` | 24 | monaco/codemirror/tiptap/prosemirror/quill/slate/draftjs/tinymce/ckeditor/editorjs |
| `vendor` | 20 / 16 | classification `vendor`/`framework` or the vendor regex; **16** when a runtime was spawned from a vendor chunk |

The sample a label is matched against is the asset's url, file, kind, source, originType,
classification, framework/route/startup hints, imports, note, mimeType, stack, **and the
first 120 000 UTF-16 units of content**.

Network events get their own, smaller rule set — `auth` 28, `analytics` 26, `data` 24,
`router` 18, `editor` 18, `state` 14 — matched against type, url, method, request body,
request headers, response headers and response preview.

`boundary_outcome` sorts matches by score desc, **keeps the top 4**, and the highest becomes
`primaryBoundary`. The reasons from all kept labels are deduplicated into `boundaryReasons`.

### Flow relations

| From → to | Relation |
| --- | --- |
| chunk → chunk | `imports-boundary` |
| chunk → runtime | `materializes-runtime` |
| runtime → runtime | `spawns-runtime` |
| anything → network | `triggers-request` |
| network → anything | `follows-response` |
| otherwise | `sequence` |

A flow is kept only when it actually crosses a boundary — except `materializes-runtime` and
`spawns-runtime`, which are interesting regardless.

### The timeline

Flow events get a synthetic, comparable time. Assets use their real `startTime` (or `index ×
25` when absent). Runtime and network events are placed **after the asset horizon**
(`max(startTime + duration) + 50`) plus their offset from the earliest absolute timestamp —
so the timeline reads: chunks load, then runtime materializes, then requests fire.

### Entrypoints

`collect_interesting_entrypoints` returns every chunk and runtime origin with a `why` string
assembled from its boundary, classification, bundler and startup signals — ranked by the
score above.

## Module graph and startup chain — `graph.rs`

`build_module_graph` produces nodes and edges, deduplicated by `id` and by
`from->to:reason`.

| Node type | Source |
| --- | --- |
| `page` | the inspected page (one node) |
| `chunk` | each script asset, with classification/bundler/boundary meta |
| `runtime` | `runtime:<id>` per runtime origin |
| `package` | an unresolved bare import — `pkg:<specifier>` |
| `reference` | an unresolved relative import — `ref:<specifier>` |

| Edge reason | Meaning |
| --- | --- |
| `resource` | page → chunk |
| `imports` | chunk → chunk, or chunk → package/reference |
| `materializes` / `spawns` | chunk → runtime, runtime → runtime |

An import specifier is resolved against the asset list by `find_asset_by_reference`, which
tries four keys in order: exact URL, URL without `#`, URL without `#`/`?`, bare filename.
That fallback chain is why a webpack `"./chunk-abc.js"` still binds to the asset whose URL is
`https://host/static/chunk-abc.js`.

`build_startup_chain` sorts scripts by `startTime` and runtime origins by `timestamp`, takes
the first 40 of each, and reports the capture profile alongside.

`looks_like_graphql_body` accepts a string containing `query|mutation|subscription` or
`operationName`, or an object with a truthy `query`/`operationName`/`extensions`.

## Analysis assembly — `analysis.rs`

`build_semantic_analysis` is the integration seam. It runs every stage **in the JavaScript's
order** and returns one object:

```
assets, runtimeRecords,
chunkMap {generatedAt, summary, items},
moduleGraph, startupChain,
runtimeOrigins {generatedAt, summary, items},
boundaryLabels, crossBoundaryFlows,
frameworkState, frameworkRuntime,
interestingEntrypoints,
investigation { workspaces, journeys, summary }
```

`serde_json`'s `preserve_order` feature is enabled **precisely so** a serialized analysis has
the same keys in the same textual order as the JavaScript one — the report pages embed it and
are compared byte for byte.

`frameworkRuntime` is then annotated with `availableWorkspaces` and `availableJourneys`
(id, title, item/event/transition counts), so the console can render navigation without
re-deriving anything.

## Workspaces and journeys — `workspace.rs`

Eight boundary workspaces plus a framework-state workspace. Each carries a title, a
description, **focus questions**, and slices of the entrypoints, chunks, runtime records,
events, transitions, top transitions and chains — capped at 10/10/10/24/24/10/10 so a page
with 400 chunks still produces a readable slice.

| Workspace | Question it is built to answer |
| --- | --- |
| Bootstrap | *Which chunk booted first, and what did it materialize?* |
| Router | *Where does navigation live, and what does it trigger?* |
| State | *Where is state held, and does it drive data or routing?* |
| Data | *Which requests are the primary API layer?* |
| Auth | *Where is the session set up, and what follows it?* |
| Analytics | *Which beacons exist, and what feeds them?* |
| Editor | *Which assets are content-authoring, and what follows?* |
| Vendor | *Which third-party bundles matter, and where do they cross in?* |
| Framework State | *What does the framework itself say about router, stores, queries, hydration?* |

Four journeys stitch them into narratives:

| Journey | Focus | Question |
| --- | --- | --- |
| `initial-load` | bootstrap, router, data, state | How do bootstrap, runtime materialization, routing and data startup fit together on first load? |
| `auth-handshake` | auth, data, router, analytics | Where does the session/auth path go downstream? |
| `route-change` | router, data, state, analytics | What happens on navigation? |
| `runtime-materialization` | bootstrap, vendor, data | Which chunks create runtime artifacts, and what do those artifacts do? |

## Reports — `report.rs`

| Function | Produces |
| --- | --- |
| `generate_investigation_index_html` | the **Investigation Console**: workspace and journey navigation, summary cards, one panel per slice |
| `generate_waterfall_html` | the network waterfall, with per-request bars and DNS/TCP/TTFB breakdowns |
| `generate_table` | the timings table |
| `generate_dom_snapshot_html` | the captured DOM |
| `describe_capture_reason` | the one-line explanation of why capture ended when it did |
| `export_framework_artifacts` | `_analysis/framework-*` slices |
| `export_runtime_artifacts` | `_runtime/*` plus the manifest |
| `export_semantic_analysis` | every `_analysis/*` file |

The long style/script blocks are transcribed **verbatim** from the JavaScript, and the oracle
test compares the rendered document byte for byte.

`export_readable_artifacts` writes `_analysis/readable/NNNN-<label>.js`: the recovered source
behind a `Semantic reconstruction` header carrying label, URL, file, boundaries, why, score
and whether it was beautified.

## Export orchestration — `export.rs`

`write_recon_artifacts` writes `_recon/*` synchronously and returns the runtime entries the
caller should fetch payloads for. `finalize_zip_with_recon` then runs, in the JavaScript's
order:

```
_recon/*  →  _runtime/* + manifest  →  _analysis/*  →  _unpack/*  →  _unpack-runtime/*
```

The runtime pass gets its own `UnpackOptions` with `path_prefix = "_unpack-runtime"` — the
JavaScript hardcodes that prefix at the runtime call site, so the script pass's prefix never
applies to it. The two unpack reports are then **merged**: totals summed, assets concatenated.

The platform halves stay on the caller's side — payload fetching is the caller's, and the
finished archive is a writer seam — so everything here is synchronous and observable.

## View layer — `view.rs`

`tracker_view(tracker, filters)` returns the complete view model: `loaded`, `unloaded`,
`visible`, `total`, `typeSelection`, three visibility flags, `rowsHtml` and `typesHtml`.

The pre-port renderers built elements with `createElement`/`textContent`; the markup produced
here has the same structure, classes, labels and inline styles, so the CSS and the e2e
selectors keep working. `escape_html` escapes `& < > " '` — element **and** attribute
contexts, which is why the URL cell carries both a `title` and a body.

## Artifacts — `artifacts.rs`

`build_runtime_path` names a runtime payload `_runtime/<folder>/NNNN.<ext>`, where the folder
comes from the kind (`eval`, `function`, `blob`, `workers`, `shared-workers`,
`service-workers`, `script-injections`, `wasm`, `misc`) and the extension from the MIME type
(`js`, `json`, `html`, `css`, `svg`, `xml`, `txt`), with `wasm` recognised by kind and
`bin`/`txt` as the fallback.

`build_runtime_unpack_assets` converts the text payloads the engine can read into `Asset`s,
carrying the manifest's recorded path so the unpack output lands beside the raw file.

## The bridge — `src/js/unpack-bridge.js`

51 exports, each keeping the exact signature the former JavaScript engine had, so `page.js`
and the test suite consume the same API with only the import path changed.

**The engine loads synchronously at import time** — a sync XHR on the extension origin in the
browser, `fs` in node — so `WebAssembly.Module` + `Instance` are ready the moment the module
finishes evaluating. No init dance, no async gap for consumers to trip over.

Marshalling is allocate → call → free. Two details matter:

- **Trap explanation.** The engine builds with `panic = "abort"`, so a panic is a trap and
  `catch_unwind` cannot catch it. The dispatcher records the panic message first; a trap
  leaves the instance and its memory alive, so the bridge calls `lastFailure` and turns an
  opaque `RuntimeError: unreachable` into the real panic site and text. A misspelled arm comes
  back as `{"__error": …}` and is surfaced as a failure — **drift must not read as silence**.
- **Holes.** The engine serialises unshared string slots as JSON `null`; the JS contract
  spells holes as `undefined`. `repairSharedHoles` fixes the spelling before results cross
  back.

`buildZip` goes through `callBytes`, so the archive crosses as raw bytes rather than
base64-in-JSON — a third smaller.
