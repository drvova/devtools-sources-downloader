# devtools-unpack — project wiki

A Chrome DevTools extension that captures everything an inspected page loads and runs,
then exports it as one unpacked, site-aware `sources.zip`. The unpacking engine is Rust
compiled to WebAssembly; the extension is a thin JavaScript platform layer around it.

## What it does

Open DevTools on any page, switch to the **Sources Downloader** panel, press
**Download All**. The extension reloads the page with capture hooks injected, waits for it
to settle, then collects:

- every network resource the page loaded
- runtime payloads (`eval`, `Function`, workers, blobs, wasm, injected scripts)
- network/storage/cookie state, timings, a DOM snapshot, framework state
- for each script, every obfuscation layer peeled off it

…and writes all of it into a single zip with a per-asset report.

## Pages

| Page | What it covers |
| --- | --- |
| [Architecture](Architecture) | The three layers, the boundaries between them, and the end-to-end flow |
| [Unpack Engine](Unpack-Engine) | The Rust crate: detectors, transforms, packers, binary formats |
| [Panel](Panel) | `src/panel/*` — capture model, analysis, reports, and the wasm bridge |
| [Export Package](Export-Package) | The exact layout of `sources.zip` |
| [Build and Test](Build-and-Test) | Commands, the verification gate, and what each suite proves |
| [Toolchain](Toolchain) | `tools/cl/` — the SBCL driver with a live browser REPL |

## Repository shape

The crate and the extension share one flat folder, `unpack-rs/`:

```
unpack-rs/
  src/*.rs              the crate — the unpack engine
  src/panel/*.rs        the crate — the panel's own logic
  src/wasm_api.rs       the crate — wasm exports (wasm32 only)
  src/js/               the extension's platform layer
  src/html/ src/css/    the panel's DOM and styles
  src/manifest.json     MV3 manifest
  test/                 JS suite + browser e2e
  tests/                Rust suite
  scripts/              engine build, dev-extension runner
  dist/                 generated, loadable extension (not committed)
```

`Cargo.toml` declares `src/lib.rs` as the crate's only entry, so the extension files
living beside the Rust sources are simply not Rust sources.

## Numbers

| | |
| --- | --- |
| Rust source | ~17.8k lines: 19 files in `src/` (18 modules + `lib.rs`) and 14 in `src/panel/` |
| JavaScript | ~3.0k lines, all platform layer |
| Engine wasm | ~2.2 MB (release, `opt-level = "z"`, LTO, stripped) |
| Rust tests | 64 unit + 82 integration |
| JS tests | 67 cases against the shipped wasm |
| Browser e2e | 2 suites (stubbed-API page, real unpacked extension) |
