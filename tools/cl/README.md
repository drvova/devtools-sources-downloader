# tools/cl — the SBCL toolchain

A Common Lisp (SBCL) driver for this repo: the build/check/pack pipeline plus a
Chrome DevTools Protocol client. It replaces nothing — `npm run verify` still
works — but it gives you a **live REPL against a real browser** and per-step
verdicts with timings instead of one long shell `&&` chain.

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

## Use it

```bash
# from the repo root
sbcl --script tools/cl/run.lisp build        # wasm + bundle, then verify dist/
sbcl --script tools/cl/run.lisp check        # the whole gate, per-step verdicts
sbcl --script tools/cl/run.lisp check --fast # lint + cargo test + clippy only
sbcl --script tools/cl/run.lisp pack         # dist/ -> dist-<version>.zip
sbcl --script tools/cl/run.lisp smoke        # end-to-end CDP selftest
sbcl --script tools/cl/run.lisp panel        # the extension's DevTools panel registers
sbcl --script tools/cl/run.lisp version
```

First run pulls `usocket`, `babel`, `com.inuoe.jzon`, `cl-base64`, `ironclad`
through Quicklisp and compiles them (a minute or two); after that it is instant.

Build the standalone binary once and drop the `sbcl` prefix:

```bash
sbcl --noinform --non-interactive --script tools/cl/make-image.lisp
./tools/cl/vovas.exe check
```

`vovas.exe` locates the repo root by walking up from its own path, so it works
from any directory inside the checkout — and from outside it, too.

## The REPL is the point

```bash
sbcl --load tools/cl/run.lisp
```

```lisp
(vcdp:launch :headless t)          ; or (vcdp:attach 9222) to a browser you already run
(vcdp:tabs)                        ; every target as a hash-table
(vcdp:use "example")               ; connect to the target whose id/url/title matches
(vcdp:nav "http://localhost:3000")
(vcdp:eval* "document.title")      ; => value, type
(vcdp:shot :file "shot.png")
(vcdp:call "Network.enable")       ; anything not wrapped yet
(vcdp:kill)
```

This is the reason to have it in Lisp rather than another shell script: an
extension's DevTools panel is a browser surface, and being able to poke at a
live one — evaluate an expression, screenshot, iterate — without writing a
throwaway script each time is the whole value. `(vcdp:smoke-test)` is the same
machinery as `vovas smoke`, so the client is proven on every run.

## `panel` — the check nothing else made

`test/browser-e2e-extension.mjs` loads the built extension and opens
`html/page.html` **directly**, then asserts the off-panel guard
(`DevTools API unavailable`). That is the opposite of the question: it proves the
page degrades gracefully outside DevTools, and says nothing about whether
`chrome.devtools.panels.create` produces a tab in a real DevTools window.

`vovas panel` answers that. It launches Chrome for Testing with
`--load-extension=dist`, waits for the extension to settle, opens a page **after**
that settle (the startup tab's DevTools opens before registration and never gets
the panel), then asks the frontend for its own panel registry:

```js
Object.keys(UI.panels)
// => "elements,chrome-extension://nnlmok…SourcesDownloader"
```

Five checks: the extension's `devtools.html` loaded, a DevTools window opened,
the panel is in `UI.panels`, the registered page boots at the extension origin,
and a screenshot of the DevTools window is captured.

**Why not scrape the tab strip.** Two approaches fail here and both look like
"the panel is missing": the strip overflows into a chevron on any laptop-width
window (the panel becomes a bare `1` badge), and the DevTools UI lives behind
shadow roots, so `querySelectorAll` and even `DOM.performSearch` with
`pierce: true` return nothing. The registry is the frontend's own answer and is
immune to both.

The check is proven non-vacuous: blanking `dist/js/devtools.js` makes it fail by
name — `panel registered in UI.panels: FAIL (elements)` — and exit 1.

It is deliberately **not** part of `vovas check`: it needs a real browser window
(DevTools does not open in headless), so the gate stays headless and this runs on
demand, or in a job that has a display.

## Data files are sexps

Anything this toolchain reads or writes for itself is a Lisp form — symbols,
strings, numbers, nested lists. No JSON, no schema.

```lisp
;; tools/cl/vovas.sexp — the gate, as data
(:gate
 (:step "lint+format (rs check)"
        :npm ("run" "check")
        :fast t)
 (:step "clippy"
        :cargo ("clippy" "--all-targets" "--" "-D" "warnings")
        :fast t))
```

`vovas check` reads that file instead of carrying the steps in code, so adding,
reordering or gating a step is an edit to data. A run records itself the same
way, in `unpack-rs/.cache/gate.sexp`:

```lisp
(:gate-run (:at 4002900941) (:fast t)
 (:steps (:step "lint+format (rs check)" :exit 0)
         (:step "rust tests (cargo test)" :exit 0)
         (:step "clippy" :exit 0)))
```

**The format is closed on purpose.** Reading binds `*READ-EVAL*` to `NIL`, so a
data file can never execute code (`#.(print 1)` is refused), and it reads in the
`vovas.sexp` package, which `:use`s CL so `t` and `nil` are the real booleans —
the same arrangement an `.asd` file has.

Every symbol must be a **keyword**, `t`, or `nil`. A bare symbol is refused:

```
sexp: bare symbol: GATE is a bare symbol; write it as :gate
```

That is not pedantry. Reading `step` in a package that uses CL yields
`CL:STEP` — the stepper macro — so the data would compare unequal to `:step`
with nothing visible in the file to explain it. Keywords cannot collide.

`sexp-selftest` round-trips a form containing every type the format allows,
including both escapes and an embedded newline, and `vovas check` runs it before
reading the gate: a broken reader can never silently misread a data file.

JSON remains only where the wire demands it — the DevTools Protocol and the
extension's `manifest.json`, both of which Chrome defines — and it stops at one
boundary. `json-decode` returns plists and `json-encode` takes them, so call
sites read as data:

```lisp
(call browser "Runtime.evaluate"
      (list :expression "2+2" :return-by-value t :await-promise t))
;; => (:RESULT (:TYPE "number" :VALUE 4) :EXCEPTION-DETAILS NIL)
```

Keys convert at that boundary: a JSON `camelCase` key becomes a `:LISP-CASE`
keyword and back (`returnByValue` ↔ `:RETURN-BY-VALUE`). **Only case boundaries
become hyphens** — `manifest.json`'s `manifest_version` stays `:MANIFEST_VERSION`,
because inventing a hyphen there would make the encode direction ambiguous
(`:MANIFEST-VERSION` would have to guess between `manifestVersion` and
`manifest_version`). `json-selftest` round-trips every key this toolchain reads,
and `vovas check` runs it, so a drifted key fails the gate instead of quietly
reading NIL.

## Design notes

**No dependencies beyond Quicklisp staples.** The WebSocket and HTTP clients are
~350 lines total. They exist because the only thing needed is loopback CDP:
text frames, no TLS, no compression, no extensions. Anything that needs TLS
(Chrome downloads) goes through `powershell`, which owns the system trust store.

**One source of truth per job.** `read-headers`, `read-exactly`,
`read-until-double-crlf` and `crlf-join` live in `util.lisp` and are imported by
`ws.lisp` and `http.lisp`; neither re-implements them.

**`run-program` normalizes two SBCL traps** so no call site has to know about
them:

- `uiop:run-program` returns `(values stdout stderr exit-code)` — the reverse of
  what every caller expects. `run-program` returns `(values exit-code stdout
  stderr)`.
- `uiop:run-program :cwd` is **silently ignored** on SBCL 2.6.9: the child runs
  in the parent's directory and you get a confusing `Missing script: "check"`
  from npm instead of an error. `run-program` calls `sb-ext:run-program` with
  `:directory`, which honours it.

**Strings are not constants.** `defconstant` on a string mints a fresh object per
compile, so reloading the fasl signals `DEFCONSTANT-UNEQL` even for identical
text. String config values are `defparameter`.

**The smoke test flushes every verdict.** A harness that buffers its output
cannot name the step that hung. It also uses an explicit `try` macro returning
`(values value ok-p)` rather than `ignore-errors`, whose second value is the
*body's* second value — which made three correct checks report `FAIL (4)`.

## Adding a command

`main.lisp` dispatches on the first argument; `tasks.lisp` holds the pipeline
steps. A step is one `run-step` call:

```lisp
(vovas.tools.util:run-step "label" argv :cwd (unpack-rs-dir))
```

It prints the command, times it, prints `OK`/`FAIL`, and on failure dumps
stdout and stderr. Non-zero exits never signal, so a failing step is a value you
can branch on.
