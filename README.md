# devtools-unpack

Rust unpack engine for the DevTools sources-downloader extension.

- `unpack-rs/` - the `devtools-unpack` crate: the engine plus its 77 tests
  (`cargo test`). Port notes and deliberate divergences: `PORTING.md`.
- `unpack-rs/extension/` - the Chrome DevTools extension. It ships the engine
  as `js/engine.wasm`, loaded through `src/js/unpack-bridge.js`, which keeps
  the exact export surface of the former JavaScript engine. The 67-case node
  suite runs against the bridge, so the tests exercise the shipped artifact.

Builds:

```
cd unpack-rs && cargo test                     # engine
cd unpack-rs/extension && npm run build        # wasm + bundles + root layout
cd unpack-rs/extension && npm test             # 67 cases against the wasm bridge
```
