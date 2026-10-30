# devtools-unpack

Rust unpack engine for the DevTools sources-downloader extension.

- `unpack-rs/` - the `devtools-unpack` crate: the engine plus its 77 tests
  (`cargo test`). Port notes and deliberate divergences: `PORTING.md`.
- `unpack-rs/extension/` - the Chrome DevTools extension. It ships the engine
  as `js/engine.wasm`, loaded through `src/js/unpack-bridge.js`, which keeps
  the exact export surface of the former JavaScript engine. The 67-case node
  suite runs against the bridge, so the tests exercise the shipped artifact.

Why two folders, both with a `src/`: they are two projects, coupled in both
directions. The crate is a Rust library (`src/lib.rs` -> one `engine.wasm`);
the extension is a JS/Chrome project (its own `package.json`, `rstack.config.ts`
and `dist/`) whose `src/` holds `js/ html/ css/ images/ manifest.json`. The
extension builds the crate to wasm (`extension/scripts/build-engine.cjs`), and
the crate's tests read the extension's fixtures
(`tests/unpack_test.rs` -> `extension/test/fixtures/`), which is why they live
in one folder rather than two - neither can absorb the other, and separating
them breaks the fixture path the Rust gate depends on.

Builds:

```
cd unpack-rs && cargo test                     # engine
cd unpack-rs/extension && npm run build        # wasm + extension bundle (dist/)
cd unpack-rs/extension && npm test             # 67 cases against the wasm bridge
```
