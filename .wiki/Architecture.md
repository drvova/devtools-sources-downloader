# Architecture

Three layers, one direction of dependency: the page world cannot see the panel, the panel
cannot see the engine's internals, and the engine never touches the DOM.

```
  inspected page            DevTools panel              wasm engine
  ─────────────────         ──────────────────          ──────────────────────
  injected.js               page.js                     src/*.rs
  framework-introspect.js   devtools.js                 src/panel/*.rs
  (page's own JS context)   (extension page)            (engine.wasm)
        │                        │                            │
        │  window.__CAPTURE__    │  unpack-bridge.js          │
        │    .policy .tracker    │  (JSON over a C ABI)       │
        │    .recon  .status     │                            │
        │    .profile .snapshot  │                            │
        │    .signals            │                            │
        │    .frameworkState     │                            │
        │    .introspector       │                            │
        └────────────────────────┴────────────────────────────┘
              polled via chrome.devtools.inspectedWindow.eval
```

## Repository shape

Flat on purpose: the crate and the extension share `unpack-rs/`.

```
unpack-rs/
  Cargo.toml            crate manifest; src/lib.rs is the only entry
  src/*.rs              the engine (18 modules + lib.rs)
  src/panel/*.rs        the panel's logic (13 modules + mod.rs)
  src/wasm_api.rs       wasm exports — compiles only for wasm32
  src/js/               the extension's platform layer
  src/html/ src/css/    the panel's DOM and styles
  src/images/           icons
  src/manifest.json     MV3 manifest
  test/                 JS suite + browser e2e + fixtures
  tests/                Rust suite + fixtures
  scripts/              engine build, dev-extension runner
  dist/                 generated, loadable extension (not committed)
  PORTING.md            the JS → Rust port notes
```

`Cargo.toml` declares `src/lib.rs` as the crate's only entry, so the extension files living
beside the Rust sources are simply not Rust sources. That is what makes the flat layout safe.

## Layer 1 — the page world (JavaScript, must stay JavaScript)

`src/js/injected.js` (1348 lines) and `src/js/framework-introspect.js` (462 lines) run
**inside the inspected page**, injected by
`chrome.devtools.inspectedWindow.reload({injectedScript})` before the page's own scripts.

They cannot be wasm: to intercept a JavaScript call, the hook has to be JavaScript running in
that same realm.

### What it patches

| Hook | Captures |
| --- | --- |
| `XMLHttpRequest.prototype.{open,send,setRequestHeader}` | xhr requests, bodies, headers |
| `window.fetch` | fetch calls and their responses |
| `window.WebSocket` | socket opens, frames, close codes |
| `window.EventSource` | SSE streams |
| `window.eval` | code evaluated at runtime |
| `window.Worker` / `window.SharedWorker` | worker sources (blob or URL) |
| `navigator.serviceWorker.register` | service worker scripts |
| `WebAssembly.instantiate` / `compileStreaming` | wasm modules, by source or by cloned response |
| `MutationObserver` | the DOM mutation log |

The `MutationObserver` observes **`document`**, not `document.documentElement`. That is a
real fix, not a preference: the script is injected *before* the page loads, so at that moment
`documentElement` is still null, `observe()` throws, and the surrounding `catch` swallowed it
— no mutation was ever recorded.

### What it publishes — one channel

Everything the extension owns lives under **one root**, `window.__CAPTURE__`, so it is
distinguishable at a glance from the page's own globals (`__NEXT_DATA__`, `__NUXT__`,
`__APOLLO_STATE__`, `__INITIAL_STATE__`, `__SWR_DATA__` and a dozen more) — which these files
only ever read.

| `__CAPTURE__.` | Contents |
| --- | --- |
| `policy` | seeded by the panel — the redaction, MIME, GraphQL and strategy rules, plus the eighteen budgets |
| `tracker` | every resource seen: url, type, source, status, loaded/unloaded |
| `trackerReady` | the readiness flag the panel polls |
| `recon` | xhr, fetch, websockets, sse, mutations, runtime payloads |
| `profile` / `snapshot` | technologies, traits, capture strategy |
| `signals` | the live counters the readiness gates read |
| `status` | readiness reason, activity counters, last-event timestamps |
| `introspector` / `frameworkState` | router, stores, query caches, hydration payloads, auth state |

`injected.js` and `framework-introspect.js` each take `CHANNEL` once at the top and write
through it; `page.js` reads sub-properties inside its eval strings. Before this, ten separate
properties were published and `__STACK_PROFILE__` was written by two different files — nothing
marked which globals the extension owned and which it merely observed.

### The capture policy boundary

The policy is **engine data** (`src/panel/policy.rs`), serialized and prepended to the
injected script by `page.js::injectAndReload`:

```js
var policy = 'window.__CAPTURE__ = {policy: ' + JSON.stringify(panelCapturePolicy()) + '};\n';
var code = policy + scripts.join('\n;\n');
chrome.devtools.inspectedWindow.reload({ injectedScript: code, ignoreCache: true });
```

A missing policy **fails closed** — zero budgets, no redaction pattern — so nothing is
decoded and nothing is kept. The page world keeps no copy that could drift, and a test
asserts that.

### Readiness

The page world decides when capture is complete, from six independent signals:

| Signal | Condition |
| --- | --- |
| `domReady` | `document.readyState === 'complete'` or elapsed ≥ `bootDelayMs` |
| `networkQuiet` | no active requests **and** last network ≥ `networkQuietMs` ago |
| `mutationQuiet` | last mutation ≥ `mutationQuietMs` ago |
| `runtimeQuiet` | last runtime capture ≥ `runtimeQuietMs` ago |
| `socketQuiet` | last socket event ≥ `socketQuietMs` ago |
| `workerQuiet` | last worker event ≥ `workerGraceMs` ago |

All six must hold. Otherwise, when `elapsed >= maxCaptureMs`, readiness is **forced** with
reason `max-capture` — so a page with a permanent websocket still produces an export instead
of hanging.

Each `touchSignal(channel)` stamps a timestamp; that is the entire mechanism.

### Runtime capture

`captureRuntime(kind, payload)` appends to `RECON.runtime` with an id of `kind-N`, a
timestamp, and the payload merged over it. It is **budgeted by `runtimeItems`** (200) and
updates the counters the profile reads (`runtimeCount`, `wasmCount`, `workerCount`,
`serviceWorkerCount`) before touching the readiness signal.

Two wrappers do the limiting:

- `captureTextRuntime` truncates to `runtimeText` (256 KiB) and records `textLength` +
  `truncated`.
- `captureBinaryRuntime` base64-encodes up to `runtimeBinary` (1 MiB).

Kinds: `eval`, `function`, `blob`, `worker`, `shared-worker`, `service-worker`,
`script-injection`, `wasm`.

### Framework introspection

`framework-introspect.js` builds `CHANNEL.frameworkState`:

```
{generatedAt, reason, page, profile, strategy,
 technologies, roots, router, stores, queries, hydration, auth,
 summary {rootCount, storeCount, queryCount, hydrationCount, authCount,
          routerFramework, detectedTechnologies}}
```

It refreshes on `boot`, `DOMContentLoaded`, `load`, and on demand from the page world after a
significant capture event. Every value passes through `safeValue`, which redacts by key name,
limits strings, and replaces live objects and elements with a marker — the walker is generic,
but its **input is a live framework instance**, which is exactly why it cannot move to Rust.

## Layer 2 — the panel (JavaScript shim + Rust logic)

`src/js/page.js` (555 lines) is the only file that touches `chrome.devtools` *and* the DOM —
eleven `chrome.*` call sites, all capture plumbing. Everything else the panel does lives in
`src/panel/*.rs` and crosses the wasm boundary as JSON.

`src/js/devtools.js` is seven lines: it registers a **main panel**, not a sidebar pane —
Chrome stopped rendering extension sidebar panes in the Sources panel (the creation callback
fires, the UI never appears). A main panel is the pattern React DevTools uses.

### The panel's own flow

```
click  →  injectAndReload(buttonLabel, onComplete)
          ├─ fetch framework-introspect.js + injected.js as text
          ├─ prepend window.__CAPTURE__ = {policy: <engine policy>}
          ├─ inspectedWindow.reload({injectedScript, ignoreCache: true})
          └─ startPolling()

poll (500 ms, max 180 attempts = 90 s)
          ├─ inspectedWindow.eval(JSON.stringify({ready, data, site,
          │                                       stackProfile, stackSnapshot, captureStatus}))
          ├─ render page origin, stack profile, capture reason, resource rows
          └─ stop when ready or attempts exhausted → onComplete()

onComplete → doDownload()
          ├─ inspectedWindow.getResources(cb)
          ├─ fetch each script's text; looksBinaryScript routes cached bytecode to bytes
          ├─ collect recon (LS/SS/cookies/page/HTML) via inspectedWindow.eval
          └─ collectReconAndFinalize → finalizeZipWithRecon → buildZip → saveBytes
```

`saveBytes` is the one step that cannot leave the DOM: an object URL on an `<a download>`,
revoked on a later tick (revoking in the same tick can cancel the download in some builds).

## Layer 3 — the engine (Rust → wasm)

`src/lib.rs` declares 18 modules plus `wasm_api` (compiled only for `wasm32`). The pipeline
is:

```
Asset (text | bytes)
   │
   ├─ text  → peel_text: detect → score → transform → re-detect, until stable
   │           then bundle-module split, beautify, source-map follow
   └─ bytes → ladder: wasm | V8 code cache | JSC bytecode | brotli-sealed V8
   │
   └→ AssetResult { report entry, files[] }
```

`unpack_assets` runs that over every asset and returns a `BatchResult`; `build_zip` turns the
collected files into archive bytes. The engine owns the file names, the report and the
archive — the panel never assembles a zip.

## The wasm boundary

`src/wasm_api.rs` compiles **only** for `wasm32`, so `cargo test` never sees it.

### Exports

| Export | Purpose |
| --- | --- |
| `xu_alloc(len)` | allocate a block for the host to write into |
| `xu_free(ptr, len)` | release a block |
| `xu_call(name, argsJson)` | the generic dispatcher — 44 arms |
| `xu_call_bytes(name, argsJson)` | binary results (the archive) |
| `xu_b64decode` | hot path for the panel's own decoding |
| `xu_looks_binary_script` | the routing decision, before an asset is fetched |

The dispatch table covers the whole engine surface: `buildZip`, `LIMITS`, `lastFailure`,
`panelCapturePolicy`, `panelStackProfileAnalyze`, `panelTrackerView`,
`panelDescribeCaptureReason`, `panelFinalizeZipWithRecon`, `sanitizeFilename`,
`sanitizePageTitle`, `collectStringLiterals`, `findBalanced`, `decodeEscapes`, `bytesToText`,
`printableRatio`, `detectLayers`, `peelText`, `looksMinified`, `beautifyJs`,
`extractBundleModules`, `findSourceMapRef`, `parseSourceMap`, `decodeInlineSourceMap`,
`resolveMapUrl`, `assetSlug`, `unpackAsset`, `unpackAssets`, `unpackAssetsForZip`,
`decodeJsfuck`, `detectJsfuck`, `detectPacker`, `unpackPacker`, `transformStringArray`,
`detectStringArray`, `parseJscHeader`, `detectJscBytecode`, `recoverJscStrings`,
`wtfStringHash`, `analyzeJscModule`, `readJscSharedTable`, `findJscSharedTable`,
`detectWasmModule`, `parseWasmModule`.

### Imports

| Import | Provided by |
| --- | --- |
| `xu_host_now_ms` | `Date.now()` — wasm32-unknown-unknown has no clock |
| `xu_host_fetch` | synchronous XHR from the extension origin |

### The failure contract

The release profile sets `panic = "abort"`, so a panic is a **trap**, not an unwind —
`catch_unwind` cannot catch it. This was verified, not assumed: the std for
`wasm32-unknown-unknown` ships precompiled with the abort strategy, and `panic = "unwind"`
needs nightly `-Z build-std`.

Rather than ship a boundary that only *looks* like one, the dispatcher installs a panic hook
that records the message. A trap leaves the instance and its memory alive, so
`xu_call("lastFailure")` reads the real panic site back, and the bridge turns an opaque
`RuntimeError: unreachable` into text.

## Why the split falls where it does

The dividing question is not "is this code pure?" but **"are its inputs plain data or live
objects?"**

- `framework-introspect.js::safeValue` enumerates and recurses generically — no
  framework-specific code at all — but its *argument* is a live framework instance, so it must
  run in the page. Its rules (`shouldRedactKey`, `limitString`) come from the injected policy,
  which is why the policy crossed to Rust even though the walker stayed.
- `stack-profile.js::analyze` had an equally generic body, but its input was a plain snapshot
  — which is exactly why it moved to `panel::stackprofile` and now has tests.
- `page.js::checkDone` is five lines with no `chrome` or DOM tokens, but it closes over state
  created inside a `getResources` callback — a closure can look pure while living entirely on
  VM state.

The same rule moved the capture policy: the *rules* are data (five patterns and key lists,
the default strategy, eighteen numbers) and cross; the *predicates* that consume them are
structure (enumerate a live object, recurse, read the page) and stay.

## Numbers

| | |
| --- | --- |
| Rust source | ~18.0k lines: 19 files in `src/`, 15 in `src/panel/` |
| JavaScript | ~3.0k lines, all platform layer |
| Engine wasm | ~2.2 MB (release, `opt-level = "z"`, LTO, stripped) |
| Bridge exports | 51 |
| Dispatch arms | 44 |
| Rust tests | 68 unit + 85 integration |
