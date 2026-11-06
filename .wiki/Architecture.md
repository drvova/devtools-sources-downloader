# Architecture

Three layers, each with one job, and a single direction of dependency:
the page world cannot see the panel, the panel cannot see the engine's internals, and the
engine never touches the DOM.

```
  inspected page            DevTools panel              wasm engine
  ─────────────────         ──────────────────          ──────────────────────
  injected.js               page.js                     src/*.rs
  framework-introspect.js   devtools.js                 src/panel/*.rs
  (page's own JS context)   (extension page)            (engine.wasm)
        │                        │                            │
        │  window.__RESOURCE_TRACKER__                        │
        │  window.__RECON__          │                       │
        │  window.__CAPTURE_STATUS__ │  unpack-bridge.js     │
        └────────────────────────────┴───────────────────────┘
              polled via chrome.devtools.inspectedWindow.eval
```

## Layer 1 — the page world (JavaScript, must stay JavaScript)

`src/js/injected.js` (1348 lines) and `src/js/framework-introspect.js` (462 lines) run
**inside the inspected page**, injected by `chrome.devtools.inspectedWindow.reload({injectedScript})`
before the page's own scripts. They cannot be wasm: to intercept a JavaScript call, the hook
has to be JavaScript running in that same realm.

What it patches, and why each one matters:

| Hook | Captures |
| --- | --- |
| `XMLHttpRequest.prototype.open/send/setRequestHeader` | xhr requests, bodies, headers |
| `window.fetch` | fetch calls and their responses |
| `window.WebSocket` | socket opens, frames, close codes |
| `window.EventSource` | SSE streams |
| `window.eval` | code evaluated at runtime |
| `window.Worker` / `window.SharedWorker` | worker sources (blob or URL) |
| `navigator.serviceWorker.register` | service worker scripts |
| `WebAssembly.instantiate` | wasm modules, by source or by response clone |
| `MutationObserver` | the DOM mutation log |

What they publish on `window`:

| Global | Contents |
| --- | --- |
| `__RESOURCE_TRACKER__` | every resource seen: url, type, source, status, loaded/unloaded |
| `__RECON__` | xhr, fetch, websockets, sse, mutations, runtime payloads |
| `__STACK_PROFILE__` / `__STACK_SNAPSHOT__` | detected technologies, traits, capture strategy |
| `__CAPTURE_STATUS__` | readiness reason, activity counters, last-event timestamps |
| `__FRAMEWORK_STATE__` | router, stores, query cache, hydration payload |
| `__CAPTURE_POLICY__` | injected by the panel — the redaction and budget rules |

The last one is the interesting boundary: the capture policy is **engine data**
(`src/panel/policy.rs`), serialized and prepended to the injected script by
`page.js::injectAndReload`. A missing policy fails closed — zero budgets, no redaction
pattern — so nothing is decoded and nothing is kept. The page world keeps no copy that
could drift.

## Layer 2 — the panel (JavaScript shim + Rust logic)

`src/js/page.js` (555 lines) is the only file that touches `chrome.devtools` *and* the DOM —
eleven `chrome.*` call sites, all of them capture plumbing. Everything else the panel does —
filtering, sorting, scoring, analysis, report HTML — lives in `src/panel/*.rs` and crosses
the wasm boundary as JSON.

`src/js/devtools.js` is seven lines: it registers a main panel (not a sidebar pane, which
Chrome stopped rendering in the Sources panel).

## Layer 3 — the engine (Rust → wasm)

`src/lib.rs` declares 19 modules. The pipeline is:

```
Asset (text | bytes)
   │
   ├─ text  → peel_text: detect → score → transform → re-detect, until stable
   │           then bundle-module split, beautify, source-map follow
   └─ bytes → detection ladder: wasm | V8 code cache | JSC bytecode | brotli-sealed V8
   │
   └→ AssetResult { report entry, files[] }
```

`unpack_assets` runs that over every asset and returns a `BatchResult`; `build_zip` turns
the collected files into archive bytes. The engine owns the file names, the report and the
archive — the panel never assembles a zip.

## The wasm boundary

`src/wasm_api.rs` compiles **only** for `wasm32`, so `cargo test` never sees it. It exposes:

| Export | Purpose |
| --- | --- |
| `xu_alloc` / `xu_free` | hand memory across the boundary |
| `xu_call(name, argsJson)` | the generic dispatcher — 44 arms |
| `xu_call_bytes(name, argsJson)` | binary results (the archive, which would otherwise cross base64-inflated) |
| `xu_b64decode` | hot path for the panel's own decoding |
| `xu_looks_binary_script` | routing decision before an asset is fetched |

Imports the engine expects from the host:

| Import | Provided by |
| --- | --- |
| `xu_host_now_ms` | `Date.now()` — wasm has no clock |
| `xu_host_fetch` | synchronous XHR from the extension origin |

**Failure contract.** The release profile sets `panic = "abort"`, so a panic is a trap, not
an unwind — `catch_unwind` cannot catch it (verified, not assumed: the wasm32 std ships
precompiled with the abort strategy). Instead the dispatcher installs a panic hook that
records the message; a trap leaves the instance and its memory alive, so
`xu_call("lastFailure")` reads the real panic site back and the bridge turns an opaque
`unreachable` into text.

## End-to-end flow

1. **Click Download All** → `page.js::injectAndReload`.
2. Fetch `framework-introspect.js` + `injected.js` as text, prepend
   `window.__CAPTURE_POLICY__ = <engine policy>`, reload the page with that as the injected
   script (`ignoreCache: true`).
3. `startPolling` — every 500 ms, `inspectedWindow.eval` a JSON snapshot of the page-world
   globals, up to 180 attempts (90 s). Readiness is decided **in the page world**, from its
   own capture strategy: six independent signals — `domReady`, `networkQuiet`,
   `mutationQuiet`, `runtimeQuiet`, `socketQuiet`, `workerQuiet` — must all hold, or the
   `maxCaptureMs` window expires and readiness is forced with reason `max-capture`. The
   panel only reports the reason text while it waits.
4. **Capture complete** → `doDownload` walks `chrome.devtools.inspectedWindow.getResources`,
   fetching each script's text; `looksBinaryScript` routes cached bytecode down the bytes
   path.
5. `collectReconAndFinalize` → `panelFinalizeZipWithRecon` in the engine: writes `_recon/*`,
   unpacks every asset into `_unpack/*`, collects runtime payloads into `_unpack-runtime/*`,
   builds the semantic analysis into `_analysis/*`, then `buildZip` returns the archive bytes.
6. `saveBytes` — the one step that cannot leave the DOM: an object URL on an `<a download>`.

## Why the split falls where it does

The dividing question is not "is this code pure?" but **"are its inputs plain data or live
objects?"**

- `framework-introspect.js::safeValue` enumerates and recurses generically — it has no
  framework-specific code at all — but its *argument* is a live framework instance, so it
  must run in the page. Its rules (`shouldRedactKey`, `limitString`) come from the injected
  policy, which is why the policy crossed to Rust even though the walker stayed.
- `stack-profile.js::analyze` had an equally generic body, but its input was a plain
  snapshot — which is exactly why it moved to `panel::stackprofile` and now has tests.
- `page.js::checkDone` is five lines with no `chrome` or DOM tokens, but it closes over
  state created inside a `getResources` callback — a closure can look pure while living
  entirely on VM state.

The same rule moved the capture policy: the *rules* are data (three patterns, seven
numbers) and cross; the *predicates* that consume them are structure (enumerate a live
object, recurse, read the page) and stay.
