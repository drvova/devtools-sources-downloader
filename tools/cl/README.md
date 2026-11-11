# tools/cl — the SBCL toolchain

Two ASDF systems: the engine (`vovas-engine`, documented in
[`engine/README.md`](engine/README.md)) and the thin toolchain over it
(`vovas-tools`): a native CLI and a Chrome DevTools Protocol client.

```
tools/cl/
  vovas-engine.asd  the engine system: every module and every gate, one serial order
  engine/           the engine modules and their gate-*.lisp files
  fixtures/         the frozen oracle fixtures the gates compare against
  run-engine.lisp   load the engine and run the gates (exit 0 when green)

  vovas-tools.asd   the toolchain system
  package.lisp      all toolchain packages up front
  util.lisp         paths, subprocesses, logging, HTTP/1.1 byte helpers, JSON
  ws.lisp           RFC 6455 WebSocket client (masking, fragmentation, ping/pong, close)
  http.lisp         HTTP/1.1 client for Chrome's /json endpoints
  chrome.lisp       Chrome for Testing: cache discovery, download, DevToolsActivePort
  cdp.lisp          launch/attach, targets, evaluate, navigate, screenshot, smoke test
  cli.lisp          `vovas engine` and `vovas unpack`
  main.lisp         CLI dispatch (also the saved-image toplevel)
  run.lisp          dev entry point
  make-image.lisp   build tools/cl/vovas.exe

  compile-check.lisp  force-recompile the engine and print the first error plainly
  check-parens.py     report where a Lisp file's parens stop balancing
```

## Use it

```bash
# from the repo root
sbcl --script tools/cl/run-engine.lisp                 # the whole gate
sbcl --script tools/cl/run.lisp engine                 # list the callable engine functions
sbcl --script tools/cl/run.lisp engine sha256Hex '["abc"]'
sbcl --script tools/cl/run.lisp unpack tools/cl/fixtures/engine/capture.json --out unpacked
sbcl --script tools/cl/run.lisp smoke                  # end-to-end CDP selftest
sbcl --script tools/cl/run.lisp version
```

First run pulls the dependencies through Quicklisp and compiles them; after that
it is instant.

Build the standalone binary once and drop the `sbcl` prefix:

```bash
sbcl --noinform --non-interactive --script tools/cl/make-image.lisp
./tools/cl/vovas.exe engine
```

`vovas.exe` locates the repo root by walking up from its own path until it finds
`tools/cl/run.lisp`, so it works from any directory inside the checkout.

## The CDP client

```bash
sbcl --load tools/cl/run.lisp
```

```lisp
(vcdp:launch :headless t)          ; or (vcdp:attach 9222) to a browser you already run
(vcdp:tabs)                        ; every target as a plist
(vcdp:use "example")               ; connect to the target whose id/url/title matches
(vcdp:nav "http://localhost:3000")
(vcdp:eval* "document.title")      ; => value, type
(vcdp:shot :file "shot.png")
(vcdp:call (vcdp:*browser*) "Network.enable") ; anything not wrapped yet
(vcdp:kill)
```

`(vcdp:smoke-test)` is the same machinery as `vovas smoke`: launch a headless
Chrome for Testing, list tabs, open a page, evaluate JS (including a 1 MB
payload), screenshot. Chrome for Testing, CDP profiles and screenshots live
under `.cache/` at the repo root, which is ignored.

## Two JSON dialects, one seam each

The toolchain and the engine read JSON differently, on purpose:

- **The toolchain** (`vovas.tools.util:json-decode` / `json-encode`) speaks
  plists, for the DevTools Protocol only. A JSON `camelCase` key becomes a
  `:LISP-CASE` keyword and back (`returnByValue` ↔ `:RETURN-BY-VALUE`), and null
  and false both become `NIL`, because every consumer asks "is it there".

  ```lisp
  (call browser "Runtime.evaluate"
        (list :expression "2+2" :return-by-value t :await-promise t))
  ;; => (:RESULT (:TYPE "number" :VALUE 4) :EXCEPTION-DETAILS NIL)
  ```

- **The engine** speaks JZON's own output: `equal` hash tables with the keys the
  JSON had, vectors, and `null` as the symbol `CL:NULL`. It depends on telling
  "absent" from "null", which a plist cannot express.

`cli.lisp` owns the conversion between them, and nothing else crosses it.

## Design notes

**No dependencies beyond Quicklisp staples.** The WebSocket and HTTP clients are
~350 lines total. They exist because the only thing needed is loopback CDP:
text frames, no TLS, no compression, no extensions. Anything that needs TLS
(Chrome downloads) goes through `powershell`, which owns the system trust store.

**One source of truth per job.** `read-headers`, `read-exactly`,
`read-until-eof` and `crlf-join` live in `util.lisp` and are imported by
`ws.lisp` and `http.lisp`; neither re-implements them.

**`run-program` normalizes two SBCL traps** so no call site has to know about
them:

- `uiop:run-program` returns `(values stdout stderr exit-code)` — the reverse of
  what every caller expects. `run-program` returns `(values exit-code stdout
  stderr)`.
- `uiop:run-program :cwd` is **silently ignored** on SBCL 2.6.9. `run-program`
  calls `sb-ext:run-program` with `:directory`, which honours it.

**Strings are not constants.** `defconstant` on a string mints a fresh object per
compile, so reloading the fasl signals `DEFCONSTANT-UNEQL` even for identical
text. String config values are `defparameter`.

**The smoke test flushes every verdict.** A harness that buffers its output
cannot name the step that hung. It also uses an explicit `try` macro returning
`(values value ok-p)` rather than `ignore-errors`, whose second value is the
*body's* second value.

## Adding a command

`main.lisp` dispatches on the first argument and returns a process exit code;
add a `cond` arm there and put the command's body in `cli.lisp`.
