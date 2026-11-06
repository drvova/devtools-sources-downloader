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
| `npm run build` | `build:engine` (wasm) then `rs build` into `dist/` |
| `npm run dev` | development build (unminified, source maps) |
| `npm run watch` | rebuild on save |
| `npm run dev:ext` | watch build + a dedicated Chrome for Testing window, auto-reloading |
| `npm test` | 68 cases against the shipped wasm |
| `npm run test:e2e` | loads the built bundle in a real browser, clicks Download All, reads the zip |
| `npm run test:e2e:ext` | loads `dist/` as a real unpacked extension |
| `npm run verify` | the whole gate — run this before committing |
| `npm run check` | lint + format check (`rs check`) |
| `npm run format` | `rs fmt` |
| `npm run lint` | `rs lint` |
| `cargo test` | the Rust suite |

## The engine build

`scripts/build-engine.cjs` runs:

```
cargo build --release --target wasm32-unknown-unknown
  → target/wasm32-unknown-unknown/release/devtools_unpack.wasm
  → .cache/engine.wasm          (written only when the bytes changed)
```

`rstack.config.ts` then copies `.cache/engine.wasm` into `dist/js/engine.wasm`. The
"unchanged" branch matters: it keeps the build output honest about whether the engine
actually changed.

## The gate

`npm run verify` runs, in order, stopping at the first failure:

1. `rs check` — lint **and** format
2. `cargo test`
3. `cargo clippy --all-targets -- -D warnings`
4. `npm test`
5. `npm run build`
6. `npm run test:e2e`
7. `npm run test:e2e:ext`

`vovas check` runs those same seven steps and then an eighth that npm cannot reach:
`vovas download --fixture`, which drives the real DevTools panel against a local page and
inspects the archive it produces. So the Lisp gate is a superset of `verify`, never a subset.

`tools/cl/vovas.sexp` holds the gate as data, and `gate-selftest` refuses to run if the first
seven steps drift from the `verify` chain. They used to be kept in agreement by a comment --
which is to say, not at all.

## What each suite proves

| Suite | Count | Proves |
| --- | --- | --- |
| `src/**` unit tests | 68 | each module's contract, in place — scanner walkers, escape decoding, base64 round-trips, JS number formatting, the two whitespace sets, zip CRC/offsets, and every panel module's oracle |
| `tests/unpack_test.rs` | 68 | engine behavior against fixtures: scanner, decoders, every peel layer, packers, JSFuck, bundle splitting, source maps, the binary formats, the full asset pipeline, and the published SHA-256 vectors |
| `tests/stack_profile_test.rs` | 6 | 28 captured snapshots match the page-world analyzer by value **and** by serialized text; a coverage guard asserts the fixtures still span every detector, trait and strategy; the confidence-tie case drives `analyze` over a real snapshot and checks the order it produces (reading the expected array straight out of the fixture would pass no matter what `analyze` did); a non-object snapshot falls back to the generic profile |
| `tests/capture_policy_test.rs` | 9 | both patterns over their corpora, the limits, the injected shape, the GraphQL body predicate against the engine constant and its word-boundary edges, the injected strategy against the engine default, that every limit name the page world reads is answered and every key is read, and a guard that neither page-world module carries a local copy again |
| `tests/text_helpers.rs` | 3 | `sanitizeFilename`, `sanitizePageTitle`, and the helper chain against node oracles |
| `test/unpack.test.mjs` | 68 | the same API through the wasm bridge — i.e. the *shipped artifact* |
| `test/browser-e2e.mjs` | 47 assertions | the built bundle in a real browser: injects, captures, clicks Download All, reads the produced zip |
| `test/browser-e2e-extension.mjs` | 7 assertions | `dist/` as a real unpacked extension, in the real extension context |

### Why the JS suite matters

It exercises the **wasm artifact**, not the Rust source. A marshalling bug — a wrong argument
order, a number that serialises as `1600.0` instead of `1600`, a hole that comes back as
`null` instead of `undefined` — passes both Rust suites and fails there.

### Why the e2e matters

`test/browser-e2e.mjs` drives Chromium over the DevTools protocol with a stubbed
`chrome.devtools` API, plants a realistic Next.js-shaped page (`__NEXT_DATA__`, `#__next`),
and asserts what the page world publishes: the capture policy is present with the engine's
limits and redaction rule, the framework snapshot reads `router: "Next.js"`, `route: "/demo"`,
and a token-named key comes back `[redacted]`. Then it clicks Download All and parses the zip.

That redaction assertion was proven **non-vacuous** by making the pattern non-matching and
watching it fail by name with the leaked value.

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

Runtime dependencies: `base64`, `brotli`, `flate2`, `regex`, `serde`, `serde_json`
(`preserve_order`), `sha2`, `url`. Dev dependencies: `@puppeteer/browsers`, `rstack`.

## Release profile

```toml
[profile.release]
opt-level = "z"     # size over speed; decompressors dominate either way
lto = true
codegen-units = 1
panic = "abort"     # a panic is a trap — see Architecture
strip = true
```

`crate-type = ["rlib", "cdylib"]` — the `cdylib` builds the browser engine, the `rlib` keeps
`cargo test` working.

## Manifest

```json
{
  "manifest_version": 3,
  "devtools_page": "html/devtools.html",
  "permissions": [],
  "content_security_policy": {
    "extension_pages": "script-src 'self' 'wasm-unsafe-eval'; object-src 'self'"
  }
}
```

**Zero permissions** is deliberate: everything the extension needs comes through the
`chrome.devtools` API it already has as a DevTools extension. `'wasm-unsafe-eval'` is the one
CSP concession, and it is what allows `WebAssembly.instantiate` at all.
