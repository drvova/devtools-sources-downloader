# devtools-unpack

Rust unpack engine for the DevTools sources-downloader extension.

- `unpack-rs/` - the whole project, flat: the `devtools-unpack` crate and the
  Chrome DevTools extension in one folder, sharing `src/`. The extension ships
  the crate as `dist/js/engine.wasm` through `src/js/unpack-bridge.js`, which
  keeps the exact export surface of the former JavaScript engine. Port notes
  and deliberate divergences: `PORTING.md`; the extension's docs: `README.md`.

Builds:

```
cd unpack-rs && cargo test          # engine (58 unit + 67 integration)
cd unpack-rs && npm run build       # wasm + extension bundle (dist/)
cd unpack-rs && npm test            # 67 cases against the wasm bridge
```
