# devtools-unpack — project wiki

A Chrome DevTools extension that captures everything an inspected page loads and runs, then
exports it as one unpacked, site-aware `sources.zip`. The unpacking engine is Rust compiled to
WebAssembly; the extension is a thin JavaScript platform layer around it.

## What it does

Open DevTools on any page, switch to the **Sources Downloader** panel, press **Download All**.
The extension reloads the page with capture hooks injected, waits for it to settle, then
collects:

- every network resource the page loaded
- runtime payloads — `eval`, `Function`, workers, shared workers, service workers, blobs,
  wasm, injected scripts
- network/storage/cookie state, timings, a DOM snapshot, framework state
- for each script, every obfuscation layer peeled off it
- for each cached-bytecode blob, the strings and structure inside it

…and writes all of it into a single zip with a per-asset report and a guided investigation
console.

## The short version of how it works

```
page world (JS)  →  window.__CAPTURE__  {policy, tracker, recon, status, profile, frameworkState}
       │
       ▼  polled through chrome.devtools.inspectedWindow.eval
panel (JS shim)  →  collects, filters, calls the engine
       │
       ▼  JSON over a C ABI
engine (Rust→wasm)  →  peels, parses, analyses, writes the archive
```

The dividing rule for what lives where: **are its inputs plain data or live objects?** Live
objects stay in the page; plain data moves to Rust and gets tested.

## Pages

| Page | What it covers |
| --- | --- |
| [Architecture](Architecture) | The three layers, every hook the page world installs, the wasm boundary and its failure contract, the end-to-end flow |
| [Unpack Engine](Unpack-Engine) | The crate in depth: the scanner, the peel loop, all 10 detectors with scores, packers and refusals, the JSFuck interpreter, the V8/JSC/wasm binary parsers, the zip writer |
| [Panel](Panel) | `src/panel/*`: the resource model, capture policy, stack profiling and capture strategy, asset scoring, boundary labels and flows, workspaces and journeys, the reports |
| [Export Package](Export-Package) | Every path in `sources.zip`, what writes it, and the order |
| [Build and Test](Build-and-Test) | Commands, the seven-step gate, what each suite actually proves, the release profile |
| [Toolchain](Toolchain) | `tools/cl/` — the SBCL driver, the sexp gate definition, the live browser REPL |

## Repository shape

The crate and the extension share one flat folder, `unpack-rs/`:

```
unpack-rs/
  Cargo.toml            crate manifest; src/lib.rs is the only entry
  src/*.rs              the engine — 18 modules
  src/panel/*.rs        the panel's logic — 13 modules
  src/wasm_api.rs       wasm exports (wasm32 only)
  src/js/               the extension's platform layer
  src/html/ src/css/    the panel's DOM and styles
  src/manifest.json     MV3 manifest, zero permissions
  test/                 JS suite + browser e2e + fixtures
  tests/                Rust suite + fixtures
  scripts/              engine build, dev-extension runner
  dist/                 generated, loadable extension (not committed)
  PORTING.md            the JS → Rust port notes
```

`Cargo.toml` declares `src/lib.rs` as the crate's only entry, so the extension files living
beside the Rust sources are simply not Rust sources. That is what makes the flat layout safe.

## Numbers

| | |
| --- | --- |
| Rust source | ~18.0k lines: 19 files in `src/`, 15 in `src/panel/` |
| JavaScript | ~3.0k lines, all platform layer |
| Engine wasm | ~2.2 MB (2 201 236 bytes; release, `opt-level = "z"`, LTO, stripped) |
| Bridge exports | 51 |
| wasm dispatch arms | 44 |
| Rust tests | 67 unit + 85 integration |
| JS tests | 68 cases against the shipped wasm |
| Browser e2e | 2 suites, 54 assertions |

## The five ideas that explain the design

1. **The engine is pure.** Text or bytes in, files and a report out. No DOM, no clock, no
   network — those arrive as injected seams. That is why 146 Rust tests can run without a
   browser.
2. **One definition per rule.** The `Tool` enum is the only place a layer name lives; the
   capture policy has one home; the path-hostile character set has one definition. Renaming
   anything is a compile error, not a silent drift.
3. **Refuse loudly, never silently.** An unrecognised binary blob is a reported refusal. A
   payload that cannot be statically decoded is a refusal with a reason. A zip over its limits
   is an error, not a truncated archive. A panic is recorded before it traps so the bridge can
   name the site.
4. **Falsy-zero is preserved.** `max_depth: 0` means "use the default", because the JavaScript
   said `opts.maxDepth || LIMITS.maxDepth`. Every such quirk is commented so nobody "fixes" it
   into a behaviour change.
5. **The page world keeps only what needs the VM.** Anything whose inputs are plain data moved
   to Rust, where it can be typed, tested and reviewed.

## Where to start reading

- **Want to know what the archive contains?** → [Export Package](Export-Package)
- **Want to understand the deobfuscation?** → [Unpack Engine](Unpack-Engine), the peel loop
  and detectors
- **Want to change the panel?** → [Panel](Panel), then `src/js/page.js`
- **Want to run it?** → [Build and Test](Build-and-Test)
- **Want to debug a live browser?** → [Toolchain](Toolchain)
