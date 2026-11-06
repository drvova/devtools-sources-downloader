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

The WebSocket and HTTP clients are written from scratch, so there is no CDP library in the
dependency set — and the extension's panel can be driven and screenshotted directly.

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

Order matters: the first failing step stops the run. Every symbol in the file is a keyword;
only `t` and `nil` are bare, and a bare symbol is refused by name — because reading a data
file in a package that `:use`s CL silently turns `step` into `CL:STEP`.

## What `panel` checks that nothing else did

`vovas panel` verifies the extension's DevTools panel **actually registers** in a real
DevTools window. Three things make that harder than it sounds:

- A manually-opened frontend (`/json/new?devtools://…`) loads and titles itself "DevTools",
  but it is a *standalone* frontend: the extension's `devtools.html` iframe is never created
  and `UI.panels` holds no extension panel. Only `--auto-open-devtools-for-tabs` plus a page
  opened *after* the extension settles produces a real DevTools window.
- The tab strip cannot answer the question: at laptop width it overflows into a chevron, and
  the DevTools UI lives behind shadow roots.
- The frontend keeps its own registry — `Object.keys(UI.panels)`, keyed by full origin plus
  the panel title with spaces removed.

So the check asks the app for its own model instead of scraping pixels.
