# Toolchain (`tools/cl/`)

A Common Lisp (SBCL) driver for this repo: the build/check/pack pipeline plus a Chrome
DevTools Protocol client. It replaces nothing — `npm run verify` still works — but it gives
per-step verdicts with timings instead of one long shell `&&` chain, and a **live REPL
against a real browser**.

## Layout

```
tools/cl/
  package.lisp     all packages up front, so every file's symbols resolve at read time
  util.lisp        paths, subprocesses, logging, HTTP/1.1 byte helpers, JSON
  sexp.lisp        the toolchain's own data format: read/write/round-trip
  vovas.sexp       the gate definition, as data
  ws.lisp          RFC 6455 WebSocket client (masking, fragmentation, ping/pong, close)
  http.lisp        HTTP/1.1 client for Chrome's /json endpoints
  chrome.lisp      Chrome for Testing: cache discovery, download, DevToolsActivePort
  cdp.lisp         launch/attach, targets, evaluate, navigate, screenshot, smoke test
  panel.lisp       verify the extension's DevTools panel actually registers
  tasks.lisp       build / check / pack, mirroring npm run verify
  main.lisp        CLI dispatch (also the saved-image toplevel)
  run.lisp         dev entry point
  make-image.lisp  build tools/cl/vovas.exe
  vovas-tools.asd  the ASDF system
```

## Commands

```bash
# from the repo root
sbcl --script tools/cl/run.lisp check        # the whole gate, one verdict per step
sbcl --script tools/cl/run.lisp check --fast # lint + cargo test + clippy only
sbcl --script tools/cl/run.lisp build        # wasm + bundle, then verify dist/
sbcl --script tools/cl/run.lisp pack         # dist/ -> dist-<version>.zip
sbcl --script tools/cl/run.lisp smoke        # end-to-end CDP selftest
sbcl --script tools/cl/run.lisp panel        # the extension's panel registers
sbcl --script tools/cl/run.lisp version
```

Build the standalone binary once and drop the `sbcl` prefix:

```bash
sbcl --noinform --non-interactive --script tools/cl/make-image.lisp
./tools/cl/vovas.exe check
```

`vovas.exe` locates the repo root by walking up from its own path, so it works from any
directory inside the checkout — and from outside it too.

First run pulls `usocket`, `babel`, `com.inuoe.jzon`, `cl-base64` and `ironclad` through
Quicklisp and compiles them; after that it is instant.

## The REPL

```bash
sbcl --load tools/cl/run.lisp
```

```lisp
(vcdp:launch :headless t)      ; or (vcdp:attach 9222) to a browser you already run
(vcdp:tabs)                    ; every target as a plist
(vcdp:eval* "location.href")   ; evaluate in the inspected page
(vcdp:navigate "https://…")
(vcdp:screenshot "shot.png")
```

The WebSocket and HTTP clients are written from scratch — RFC 6455 masking, fragmentation,
ping/pong and close handling included — so there is no CDP library in the dependency set, and
the extension's panel can be driven and screenshotted directly.

## The gate is data

`vovas.sexp` is the gate definition. `vovas check` reads it; `--fast` keeps only the steps
marked `(fast t)`. A step names its runner (`:npm` or `:cargo`) and the argv it receives.

```lisp
(:gate
 (:step "lint+format (rs check)" :npm ("run" "check") :fast t)
 (:step "rust tests (cargo test)" :cargo ("test") :fast t)
 (:step "clippy" :cargo ("clippy" "--all-targets" "--" "-D" "warnings") :fast t)
 (:step "js tests (npm test)" :npm ("test"))
 (:step "build (npm run build)" :npm ("run" "build"))
 (:step "e2e (npm run test:e2e)" :npm ("run" "test:e2e"))
 (:step "extension e2e" :npm ("run" "test:e2e:ext")))
```

Order matters: the first failing step stops the run.

### Why every symbol is a keyword

Reading a data file in a package that `:use`s CL silently turns `step` into `CL:STEP` — the
stepper macro — and the form then compares unequal to `:step` with nothing in the file to
explain why. Any bare name colliding with a CL export (`type`, `values`, `list`, `error`,
`file`, `check`) is affected.

So the vocabulary is restricted: **every symbol must be a keyword, `t`, or `nil`**, and a bare
symbol is refused with "write it as :gate". `*READ-EVAL*` is `NIL`, so a data file can never
execute code. A round-trip selftest covers every type the format admits — booleans, negative
numbers, escaped quotes, backslashes, embedded newlines — because a reader that "works" can
silently change a value's type. Reading `t` in the keyword package interns `:T`, which is
truthy and would have silently kept every step in `--fast` mode.

## What `panel` checks that nothing else did

`vovas panel` verifies the extension's DevTools panel **actually registers** in a real
DevTools window. Three things make that harder than it sounds:

- A manually-opened frontend (`/json/new?devtools://…`) loads and titles itself "DevTools",
  but it is a *standalone* frontend: the extension's `devtools.html` iframe is never created
  and `UI.panels` holds no extension panel. Only `--auto-open-devtools-for-tabs` plus a page
  opened *after* the extension settles produces a real DevTools window.
- The tab strip cannot answer the question: at laptop width it overflows into a chevron, and
  the DevTools UI lives behind shadow roots — `querySelectorAll` and
  `DOM.performSearch(…, {pierce:true})` both return nothing useful.
- The frontend keeps its own registry — `Object.keys(UI.panels)` — keyed by full origin plus
  the panel title with spaces removed:
  `chrome-extension://<id>SourcesDownloader`.

So the check asks the app for its own model instead of scraping pixels. A registry is immune
to layout, overflow and shadow DOM; pixels are not.

## What `download` checks that nothing else did

`vovas download` runs the product: it opens a real page, presses **Download All** in the
real panel, and inspects the archive that comes back. Until it existed, every browser check
stopped short — `panel` proved the panel registers, and the extension e2e opened
`html/page.html` as a plain tab to prove it refuses to run without the DevTools API. Nothing
had ever collected from a real inspected page.

Two things had to be solved to drive it:

- **The panel iframe is lazy.** DevTools creates it only when its tab is selected, and on
  Chrome for Testing 157 `UI.InspectorView` is undefined — the frontend exposes `UI.panels`,
  which is a registry, not a selector. There is no API to select a panel. The way in is the
  panel-cycle keybind (**Ctrl+]**), dispatched as `Input.dispatchKeyEvent` to the DevTools
  window; the extension panel came up on the ninth press.
- **The archive has to come back without touching Downloads.** `saveBytes` hands the bytes to
  `URL.createObjectURL`, so the check hooks that in the panel, reads the blob as a data URL,
  and decodes it in Lisp. The anchor click is intercepted so the check does not write into the
  user's Downloads folder on every run — the real download was confirmed by hand, four times,
  before the interception went in.

The DevTools frontend is itself a `page` target, so the inspected tab has to be selected by
excluding `devtools://` and `chrome-extension://` URLs; without that the startup tab is
mistaken for the DevTools window and the navigation lands in the wrong place.

What the run proves, in order: the extension loads, a real page loads, the panel iframe comes
up, the panel hooks the archive, the click lands, the archive is built, it is named
`sources.zip`, it decodes, it is a zip, and it carries `_recon/`, `_unpack/` and `_analysis/`
entries. Against `https://example.com` that is 43 entries.

`--fixture` is the stronger form and the one to run when changing capture code. It serves
`fixtures/download-page` on a free port — an external script, an `eval`, a `Function`
constructor, a worker, an inline source map, and a real WebAssembly module — so the run needs
no network and reaches the paths `example.com` cannot exercise at all. That page produces 65
entries and the run makes 22 assertions: the runtime manifest records `eval`, `function`,
`worker` and `wasm`; the `eval` and `Function` payloads are written to `_runtime/`; the inline
map resolves to `_unpack/<asset>/source-map.json` with the original recovered from
`sourcesContent` into `_unpack/<asset>/sources/app.ts`; the wasm parser writes
`_unpack/<asset>/wasm-info.json` naming the module's `answer` export; the packed script peels
to `_unpack/<asset>/layers/01-packer.js`, whose contents are asserted to be the payload the
packer encodes; and the GraphQL request is recorded in `_recon/graphql-operations.json` with
its `operationName` and `operationType` parsed out.

Four of those matter more than they look, because without them the module had no
product-level coverage at all — only unit tests. `decodeInlineSourceMap` and `resolveMapUrl`
need a map in the fixture; `detect_wasm_module` and `parseWasmModule` need a module;
`detect_packer` and `unpack_packer` need a genuinely packed script; and
`looks_like_graphql_body` with `parseGraphQLOperation` need a request whose body is a GraphQL
document. The wasm module is hand-assembled bytes committed beside the page, so it needs no
toolchain to regenerate.

The packed script has to be the **real minified shape**: `detect_packer` keys on
`function(p,a,c,k,e,` with no spaces, so a readable reformatting of the same algorithm is not
detected at all. That cost one round trip.

One asymmetry worth knowing: a worker entry carries a `url` and a `workerType`, not inline
text, so it has no `_runtime/workers/` file — its script arrives as an unpacked asset under
`_unpack/`. Only `eval` and `Function` produce payload files.

## Why this exists at all

`npm run verify` gives one exit code for seven steps. The Lisp driver gives a verdict and a
timing per step, and — the actual point — a **live browser you can interrogate**. When the
panel registers but renders wrong, `vovas panel` tells you whether the panel is missing or the
probe is looking at the wrong surface, and the REPL lets you check the second hypothesis
without editing anything.

## Hard-won details worth keeping

- `uiop:run-program :cwd` is **silently ignored** on SBCL 2.6.9; `sb-ext:run-program
  :directory` honours it. The wrapper calls `sb-ext` directly.
- `uiop:run-program` returns `(values stdout stderr exit-code)` — the reverse of the natural
  order — so the wrapper normalises once and never at call sites.
- `ignore-errors` does **not** return an error flag; its second value is the body's second
  value. Use an explicit `(values value ok-p)`.
- `defconstant` on a string mints a fresh object per compile, so reloading signals
  `DEFCONSTANT-UNEQL`. String config values are `defparameter`.
- A test harness that does not `force-output` after each verdict cannot name the step that
  hung.
- `jzon` parses JSON arrays as **vectors**, so results need `loop … across`, not `dolist`.
- A shadow-root walker must iterate `childNodes`, not `children` — `children` holds elements
  only, so a text collector silently returns nothing against 53 KB of `innerHTML`.
- A **named** `--user-data-dir` profile restores the previous window size, so `--window-size`
  silently does not apply on later runs. Use a fresh profile when geometry matters.
