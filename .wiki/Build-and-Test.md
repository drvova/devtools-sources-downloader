# Build and Test

Everything runs from `unpack-rs/`.

## Getting a loadable extension

```bash
cd unpack-rs
npm install
npm run build      # builds engine.wasm, then bundles the extension into dist/
```

Then open `chrome://extensions`, enable Developer mode, **Load unpacked**, and select
`unpack-rs/dist/`. Open DevTools on any page — the downloader is the **Sources Downloader**
tab.

`dist/` is generated and not committed. Every entry point that hands `dist/` to Chrome checks
it exists first and says so, rather than loading an empty extension.

## Commands

| Command | What it does |
| --- | --- |
| `npm run build` | engine.wasm + production bundle into `dist/` |
| `npm run dev` | development build (unminified, source maps) |
| `npm run dev:ext` | watch build + a dedicated Chrome for Testing window, auto-reloading |
| `npm test` | 67 cases against the shipped wasm |
| `npm run test:e2e` | loads the built bundle in a real browser, clicks Download All, reads the zip |
| `npm run test:e2e:ext` | loads `dist/` as a real unpacked extension, asserts the extension context |
| `npm run verify` | the whole gate — run this before committing |
| `npm run check` | lint + format check |
| `cargo test` | the Rust suite |

## The gate

`npm run verify` runs, in order, stopping at the first failure:

1. `rs check` — lint + format
2. `cargo test`
3. `cargo clippy --all-targets -- -D warnings`
4. `npm test`
5. `npm run build`
6. `npm run test:e2e`
7. `npm run test:e2e:ext`

`tools/cl/vovas.sexp` mirrors this chain step for step. Two entry points, one set of steps:
change one and change the other, or the two gates drift apart while both still pass.

## What each suite proves

| Suite | Count | Proves |
| --- | --- | --- |
| `src/**` unit tests | 64 | each module's contract, in place |
| `tests/unpack_test.rs` | 67 | engine behavior against fixtures: scanner, decoders, every peel layer, packers, JSFuck, bundle splitting, source maps, the binary formats, and the full asset pipeline |
| `tests/stack_profile_test.rs` | 6 | 28 captured snapshots match the page-world analyzer by value **and** by serialized text; a coverage guard asserts the fixtures still span every detector, trait and strategy; confidence ties break by name the way `localeCompare` does; a non-object snapshot falls back to the generic profile |
| `tests/capture_policy_test.rs` | 6 | both patterns over their corpora, the limits, the injected shape, that every limit name the page world reads is answered and every key is read, and a guard that neither page-world module carries a local copy again |
| `tests/text_helpers.rs` | 3 | JS string semantics |
| `test/unpack.test.mjs` | 67 | the same API through the wasm bridge — i.e. the *shipped artifact* |
| `test/browser-e2e.mjs` | 47 assertions | the built bundle in a real browser: injects, captures, clicks Download All, reads the produced zip |
| `test/browser-e2e-extension.mjs` | 7 assertions | `dist/` as a real unpacked extension, in the real extension context |

The JS suite matters because it exercises the wasm artifact, not the Rust source: a
marshalling bug that both Rust suites miss shows up there.

## Browser requirements

- `test:e2e` needs Chrome or Edge installed (`test/browser-e2e.mjs` lists the paths it looks
  in) and uses the *built* artifacts — build first.
- `test:e2e:ext` and `dev:ext` need **Chrome for Testing**, because branded Chrome/Edge ignore
  `--load-extension`. It is downloaded once into `.cache/browser/` on first run.

## Formatting discipline

`rs check` runs lint **and** format before every toolchain check. A hand-written JavaScript
edit needs `npx rs check --fix` as its own last step, or the gate's first step will be the
thing that reports the change.

## Dependency pinning

`Cargo.lock` is committed. The engine ships as `dist/js/engine.wasm`, so its dependency set is
pinned rather than resolved fresh on every clone.

## Release profile

```toml
[profile.release]
opt-level = "z"     # size over speed; decompressors dominate either way
lto = true
codegen-units = 1
panic = "abort"     # a panic is a trap — see Architecture
strip = true
```
