# devtools-unpack

Rust unpack engine for the DevTools sources-downloader extension.

- `unpack-rs/` - the whole project, flat: the `devtools-unpack` crate and the
  Chrome DevTools extension in one folder, sharing `src/`. The extension ships
  the crate as `dist/js/engine.wasm` through `src/js/unpack-bridge.js`, which
  keeps the exact export surface of the former JavaScript engine. Port notes
  and deliberate divergences: `PORTING.md`; the extension's docs: `README.md`.

Commands:

```
cd unpack-rs && npm run verify      # the whole gate, run this before committing:
                                    # rs check, cargo test + clippy, unit tests,
                                    # build, both browser end-to-end suites
cd unpack-rs && cargo test          # engine: 58 unit + 67 port cases + 3 helper oracle
cd unpack-rs && npm run build       # wasm + extension bundle into dist/ (generated)
cd unpack-rs && npm test            # 67 cases against the wasm bridge
```

`dist/` is generated and not committed - `npm run build` before loading the
extension. The engine's `Cargo.lock` is committed, so the wasm is built from a
pinned dependency set.
