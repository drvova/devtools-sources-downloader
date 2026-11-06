# devtools-unpack

Rust unpack engine for the DevTools sources-downloader extension.

- `unpack-rs/` - the whole project, flat: the `devtools-unpack` crate and the
  Chrome DevTools extension in one folder, sharing `src/`. The extension ships
  the crate as `dist/js/engine.wasm` through `src/js/unpack-bridge.js`, which
  keeps the exact export surface of the former JavaScript engine. Port notes
  and deliberate divergences: `PORTING.md`; the extension's docs: `README.md`.
- `.wiki/` - how the whole thing works: architecture, the unpack engine, the
  panel, the export package, the build gate, and the SBCL toolchain. Start at
  `.wiki/Home.md`.

Commands:

```
cd unpack-rs && npm run verify      # the whole gate, run this before committing:
                                    # rs check, cargo test + clippy, unit tests,
                                    # build, both browser end-to-end suites
cd unpack-rs && cargo test          # engine: 58 unit + 67 port cases + 3 helper oracle
cd unpack-rs && npm run build       # wasm + extension bundle into dist/ (generated)
cd unpack-rs && npm test            # 67 cases against the wasm bridge
```

Or drive the same work from SBCL, with per-step verdicts and a live browser REPL:

```
sbcl --script tools/cl/run.lisp check        # the whole gate, one verdict per step
sbcl --script tools/cl/run.lisp check --fast # lint + cargo test + clippy only
sbcl --script tools/cl/run.lisp build        # wasm + bundle, then verify dist/
sbcl --script tools/cl/run.lisp pack         # dist/ -> dist-<version>.zip
sbcl --script tools/cl/run.lisp smoke        # end-to-end Chrome DevTools Protocol selftest
sbcl --script tools/cl/run.lisp panel        # the extension's DevTools panel registers
sbcl --load   tools/cl/run.lisp              # REPL: (vcdp:launch) (vcdp:tabs) (vcdp:eval* "...")
```

`tools/cl/` also carries a from-scratch WebSocket + HTTP client for the DevTools
Protocol, so the extension's panel can be driven and screenshotted directly.
Details and design notes: `tools/cl/README.md`.

`dist/` is generated and not committed - `npm run build` before loading the
extension. The engine's `Cargo.lock` is committed, so the wasm is built from a
pinned dependency set.
