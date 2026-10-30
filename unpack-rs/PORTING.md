# PORTING.md - devtools-unpack (JS -> Rust)

Behavior-faithful port of the DevTools sources-downloader unpack engine
(`unpack.js` and its pure-transform modules, since replaced by
`src/js/unpack-bridge.js` + the compiled `engine.wasm`)
to the `devtools-unpack` crate. Same observable behavior, same test surface:
every one of the 67 node baseline cases in
`test/unpack.test.mjs` has a 1:1 Rust
twin in `tests/unpack_test.rs` with the same test name (camelCase -> snake_case).

Verification: `cargo build` 0 errors / 0 warnings, `cargo test` 121/121
(67 integration + 54 lib unit: 44 panel, 10 engine), `cargo clippy
--all-targets -- -D warnings` clean. Fixtures are referenced in place
(`env!("CARGO_MANIFEST_DIR")/test/fixtures`),
never copied.

## Browser integration (wasm bridge)

The extension no longer ships the JavaScript engine. `scripts/build-engine.cjs`
compiles this crate for `wasm32-unknown-unknown` (release), stages
`.cache/engine.wasm`, and the rsbuild copy pattern ships it as
`js/engine.wasm` next to the bundles; `src/js/unpack-bridge.js` replaces the
old six-file engine and keeps its export surface (`unpackAssetsIntoZip` became
`unpackAssetsForZip` + `buildZip` when the archive moved into the engine). The
67-case node suite runs against the bridge (wasm compiled synchronously at
import time via `WebAssembly.Module`/`Instance`), so the tests exercise the
shipped artifact, not a parallel implementation. The panel has no runtime
JavaScript dependencies at all: `jszip` and `file-saver` are gone, which took
the panel bundle from 112 kB to 14 kB.

Bridge seams (deliberate, documented):

- **Sync engine, sync bootstrap.** The wasm bytes load synchronously at
  module import (local XHR on the extension origin, `fs` in node via
  `process.getBuiltinModule`, hidden from the bundler). A static `node:`
  import would fail the browser build; a `new URL(<literal>,
  import.meta.url)` would make the bundler emit a second copy of the wasm
  as an asset chunk - both are worked around in the bridge.
- **`fetchText` closures cannot cross the wasm boundary.** The JS engine
  accepted an async `fetchText(url)` option; the wasm seam is synchronous.
  Callers either let the bridge's built-in credentialed sync XHR run
  (`withCredentials = true`, replacing the old extension-fetch + in-page
  fallback pair) or pass a static `fetchMap: { url: text }` dictionary,
  which `wasm_fetch_text` consults before falling back to the host import.
  The injected-fetcher test now spells its fetcher as a `fetchMap`.
- **`parseSealedV8` inflator sentinel.** A JS inflator function maps to the
  engine's brotli default; the `{ inflate: 'throw' }` string sentinel injects
  a failing inflator engine-side to exercise the refusal path (the throwing
  closure is no longer expressible across the boundary).
- **`onProgress` fires once per batch.** The engine runs a batch atomically,
  so the bridge emulates the callback with a single final `(total, total)`
  tick after the run.
- **Shared-table holes.** The engine serializes unshared string slots as
  JSON `null`; the JS contract spells holes `undefined`. The bridge repairs
  the spelling in `readJscSharedTable`/`findJscSharedTable` results.
- **wasm32 span-math hardening.** `read_jsc_shared_table`,
  `find_jsc_shared_table`, and the wasm section walkers compute string-span
  bounds in u64: on 32-bit targets a garbage u32 length wraps and can pass
  the bounds check before slicing past the buffer (a wasm trap; a silent
  reject on 64-bit). The x86_64 behavior is unchanged.


## Module map

| JS source | Rust module | Notes |
|---|---|---|
| unpack.js (limits, digests, scanner, decodeEscapes, base64, printableRatio, looksBinaryScript, assetSlug) | `util.rs`, `digest.rs`, `scanner.rs`, `decoders.rs` | LIMITS is `lib::LIMITS` (7 fields) |
| unpack.js detectLayers / collectEvalPayloads / looksMinified | `detectors.rs` | |
| unpack.js beautifyJs | `beautify.rs` | simplified formatter, see Differences |
| unpack.js extractBundleModules | `bundler.rs` | |
| unpack.js findSourceMapRef / parseSourceMap / decodeInlineSourceMap / resolveMapUrl | `sourcemaps.rs` | |
| unpack.js peelText / applyTransform / decodeURIComponent | `transforms.rs` | `Stage` is shared with pipeline |
| unpack.js unpackAsset / unpackAssets / unpackAssetsInto / report shape | `pipeline.rs` | `unpack_assets_into` is a writer-closure seam; `build_zip` writes the archive |
| packers.js (packer, aaencode, jjencode, jsfiretruck, obfuscator.io, string-array) | `packers.rs` | `Refusal` mirrors the JS refusal record |
| jsfuck.js (detect / decode / interpret) | `jsfuck.rs` | JValue model of the value domain |
| test/fixtures/jsfuck-encoder.js (JSFuck 0.5.0 encoder, oracle only) | `tests/jsfuck_encoder/mod.rs` | byte-identical output verified against node for encode("Number", ...) in all three modes |
| v8codecache.js | `v8codecache.rs` | brotli inflate injectable |
| jscbytecode.js (wtfStringHash, header, recoverJscStrings, opcode table, shared table, module walk) | `jscbytecode.rs` + `src/jsc_opcodes.txt` | |
| wasm.js | `wasm.rs` | |

## API map (JS -> Rust)

- `sha256Hex(text)` / `sha256HexBytes(bytes)` -> `digest::sha256_hex(&str)` / `digest::sha256_hex_bytes(&[u8])`
- `looksBinaryScript(text, bytes)` -> `pipeline::looks_binary_script(&str, Option<&[u8]>)`
- `collectStringLiterals` / `findBalanced` -> `scanner::collect_string_literals` / `scanner::find_balanced`
- `decodeBase64ToBytes` / `bytesToText` / `printableRatio` -> `decoders::{decode_base64_to_bytes, bytes_to_text, printable_ratio}`
- `detectLayers(text)` -> `detectors::detect_layers(&str) -> Vec<LayerFound>` (score-sorted, same order)
- `beautifyJs(source)` -> `beautify::beautify_js(&str) -> Option<String>` (see Differences)
- `extractBundleModules(source)` -> `bundler::extract_bundle_modules(&str) -> Vec<BundleModule>`
- `findSourceMapRef` / `parseSourceMap` / `decodeInlineSourceMap` / `resolveMapUrl` -> `sourcemaps::{find_source_map_ref, parse_source_map, decode_inline_source_map, resolve_map_url}`
- `assetSlug(url, index)` -> `pipeline::asset_slug(&str, usize) -> String`
- `peelText(text, maxDepth)` -> `transforms::peel_text(&str, Option<usize>) -> PeelResult { stages, outputs, final_text, refusals }`
- `applyTransform(tool, text)` -> `transforms::apply_transform(&str, &str) -> Option<String>`
- `detectPacker` / `unpackPacker` -> `packers::{detect_packer, unpack_packer}`
- `detectAaencode` / `detectJjencode` / `detectJsfiretruck` / `detectObfuscatorIo` -> same names in `packers.rs` (snake_case)
- `detectStringArray` / `transformStringArray` -> `packers::{detect_string_array, transform_string_array}`
- `detectJsfuck` / `decodeJsfuck` / `interpretJsfuck` -> `jsfuck::{detect_jsfuck, decode_jsfuck, interpret_jsfuck}`
- `wtfStringHash` / `parseJscHeader` / `detectJscBytecode` / `recoverJscStrings` -> `jscbytecode::{wtf_string_hash, parse_jsc_header, detect_jsc_bytecode, recover_jsc_strings}`
- `jscOpcodeTable` -> built-in table parsed from `src/jsc_opcodes.txt` at first use
- `readJscSharedTable` / `findJscSharedTable` / `analyzeJscModule` -> `jscbytecode::{read_jsc_shared_table, find_jsc_shared_table, analyze_jsc_module}`
- `detectV8CodeCache` / `parseV8CodeCache` / `extractV8Strings` -> `v8codecache::{detect_v8_code_cache, parse_v8_code_cache, extract_v8_strings}`
- `detectWasmModule` / `parseWasmModule` -> `wasm::{detect_wasm_module, parse_wasm_module}`
- `unpackAsset` / `unpackAssets` / `unpackAssetsInto` -> `pipeline::{unpack_asset, unpack_assets, unpack_assets_into}`; the zip writer is `FnMut(&str, &str)` instead of a zip library (no zip crate), so the caller owns storage; `fetchText` (external source maps) is an injected `FetchText` closure; the brotli inflator is an injected `InflateImpl` closure with a `brotli`-backed default.

## Test map

All 67 cases from `unpack.test.mjs` are ported 1:1 (same name, snake_cased),
plus 10 lib unit tests that pin JS semantics the integration suite exercises
indirectly (number-to-string exponent form, radix strings, escape() including
per-surrogate astral output, utf16 slicing, ISO-8601 epochs). The JSFuck
encoder oracle (`test/fixtures/jsfuck-encoder.js`) is a test-side module
(`tests/jsfuck_encoder/mod.rs`) exactly as it is a fixture on the JS side;
its output is byte-identical to node for the three encode modes the suite
asserts (verified against captured node output during the port).

## Deliberate differences (behavior visible to callers)

1. **Sync everywhere.** The JS engine is async (crypto.subtle, fetch);
   the Rust port is fully synchronous - SHA-256 via the `sha2` crate, external
   maps via the injected `FetchText` closure. No FNV fallback (the JS has a
   non-crypto fallback path when crypto.subtle is absent; the crate always
   has real SHA-256).
2. **`sealed.tool` field absent.** `parseSealedV8` in JS attaches the tool
   name; `v8codecache::parse_sealed_v8` returns `SealedV8 { inflated_bytes,
   cache }` and the pipeline carries the tool in the stage record instead.
   The test suite omits the JS assertion accordingly.
3. **Beautifier is a simplified scanner-aware formatter.** js-beautify is a
   whole product; `beautify::beautify_js` implements the contract the suite
   asserts (minified input produces stable multiline output) and nothing more.
4. **`Date()` output is pinned to one locale.** The JS model delegates to the
   host clock; the port's `js_date_string` pins the V8 UTC format from the
   local machine's TZ. Same for `generated_at`/`unpacked_at` (ISO-8601 UTC).
5. **String indexing is char-based, not UTF-16-unit-based.** Rust `&str` cannot
   split astral chars, so `utf16_prefix`/`utf16_suffix` (JS slice semantics)
   never split a surrogate pair; they cut before the whole char. JS slicing
   mid-pair produces a lone surrogate - unrepresentable here.
6. **Lone surrogates decode to U+FFFD.** `bytes_to_text` mirrors
   TextDecoder(fatal: false) which also substitutes; but any JS string that
   contained a lone surrogate (only possible via mid-pair slicing) cannot
   round-trip.
7. **Malformed `\u{...` terminates the escape decode.** JS keeps scanning to
   the end of input on a malformed hex body; the port stops at the first
   malformed sequence and returns what it had (the scanner only feeds it
   well-formed literals in practice).
8. **Percent-decoding is strict about the `%` alphabet** but non-fatal
   overall: `%zz` survives verbatim like JS; `%e0%A4%A` (truncated tail)
   survives verbatim where JS's loop can consume the trailing `%` into a
   failed parse and still append the remainder - the port keeps the remainder
   attached instead.
9. **onProgress dropped.** The JS pipeline takes an onProgress callback; the
   report already carries per-asset stage records, so the Rust port omits the
   callback.
10. **Wasm export order.** JS compares `WebAssembly.Module.exports` order;
    the port compares name-sorted exports against the captured node oracle
    (wasm-data / wasm-named fixtures).
11. **`escape()` uses the crate model.** The JSFuck interpreter uses the host
    `escape`; the port implements it in `jsnumber::js_escape` (verified
    against node: `escape('function at() { [native code] }')` and astral
    output `%uD83D%uDE00`).

## Preserved JS quirks (ported on purpose)

- Falsy-limit fallback: `opts.maxDepth || LIMITS.maxDepth` semantics (0 is
  ignored) in `peel_text`/`unpack_*` option handling.
- `parseIntLiteral`'s hex handling: `0x`-prefixed literals keep JS
  parseInt(…, 16) behavior including `toString` radix edges.
- Arrow-expression module skip: a module whose body is a lone expression is
  not a bundle module.
- Layer names embed the depth the way JS builds them (`('0'+depth)`).
- `assetSlug` truncates rather than errors on long slugs.
- The JSFuck encoder's unmapped-character-class regex keeps the bare `-`
  in `,-.` (the range forms identically in both engines).
- `unpack_packer` loops with the same MAX_PACKER_LAYERS stop conditions
  (detect miss breaks, no-change breaks), preserving nested packer peeling.
- `wtfStringHash` keeps the JS's misleadingly named `read32Big`, which
  builds LITTLE-endian words (the Rust twin comments this).

---

# Panel port (`page.js` -> `src/panel/*`)

The DevTools panel (the former `page.js`, 3676 lines) is the extension's
UI layer: it collects scripts and recon data from the inspected page, builds
the semantic analysis, and assembles the exported archive. Its DOM and
`chrome.devtools` half cannot exist in a crate, so the port splits it at the
seam: **everything that decides or produces content is ported; everything that
reads the page or writes to the screen stays in the extension.**

Verification of this half: every ported function has a node oracle captured by
running the real `page.js` in a harness that loads all 3676 lines with stubbed
DOM/chrome globals. The harness was local scratch and is gone with the port;
what it produced is committed under `tests/fixtures/panel/*.json`, which is
what the tests read. The Rust tests
compare against that captured output, including three whole HTML documents
byte for byte. Where an oracle was impossible, the test says so and names the
substitute (see "Census instead of oracle" below).

## Module map (panel)

| JS source | Rust module | Notes |
|---|---|---|
| `page.js` script/recon collection, scoring, summaries, boundaries | `panel/assets.rs`, `panel/boundary.rs`, `panel/model.rs` | `ScriptInput` -> `ScriptAsset` is `prepare_script_assets` |
| `page.js` module graph, startup chain, GraphQL operations | `panel/graph.rs` | |
| `page.js` workspaces, journeys, investigation model | `panel/workspace.rs` | |
| `page.js` `buildSemanticAnalysis` assembly | `panel/analysis.rs` | the whole analysis object is oracle-compared |
| `page.js` text helpers (formatSize, formatMs, slugify, escape) | `panel/text.rs`, `panel/view.rs` | |
| `page.js` runtime paths, report merging, cookies, inline JSON, recon stats, readable artifacts | `panel/artifacts.rs` | |
| `page.js` console page, waterfall, table, capture reason, export wrappers | `panel/report.rs` | |
| `page.js` `writeReconArtifacts` + `finalizeZipWithRecon` | `panel/export.rs` | |
| `stack-profile.js` page profile: technologies, traits, capture strategy | `panel/stackprofile.rs` | the analysis only - the snapshot is still collected in the page world |
| the page world's capture rules: redaction pattern, text-MIME pattern, GraphQL URL marker, seven budgets | `panel/policy.rs` | the rules only - the page world still applies them |

## API map (panel)

- `escapeXml` / `escapeAttr` / `escapeHtml` -> `panel::view::escape_html` (one
  implementation; `escape_attr`/`escape_xml` coerce through `assets::value_text`)
- `formatSize` / `formatMs` / `sanitizePathPart` / `sanitizePageTitle` /
  `sanitizeFilename` / `safeDecodeURIComponent` -> `panel::text` (snake_case)
- `prepareScriptAssets` -> `panel::assets::prepare_script_assets`
- `buildChunkSummary` / `buildRuntimeOrigins` / `buildRuntimeSummary` /
  `scoreScriptAsset` / `scoreRuntimeEntry` / `stripChunkAsset` /
  `stripRuntimeEntry` / `determineRuntimeOriginType` -> `panel::assets`
- `buildBoundaryLabels` / `buildCrossBoundaryFlows` / the boundary predicates
  and `Any` variants -> `panel::boundary`
- `buildModuleGraph` / `buildStartupChain` / `parseGraphQLOperation` /
  `normalizeGraphQLPayload` / `looksLikeGraphQLBody` /
  `collectGraphQLOperations` -> `panel::graph`
- `buildInvestigationWorkspace` / the boundary workspaces / the framework-state
  workspace / `pushFrameworkCollectionEvents` / the four journey views ->
  `panel::workspace`
- `buildSemanticAnalysis` -> `panel::analysis::build_semantic_analysis`
- `runtimeFolderName` / `runtimeExtension` / `buildRuntimePath` /
  `buildRuntimeUnpackAssets` / `mergeUnpackReports` / `parseCookies` /
  `serializeInlineJson` / `computeReconStats` / `generateDOMSnapshotHTML` /
  `buildReadableArtifact` / `exportReadableArtifacts` -> `panel::artifacts`
- `generateInvestigationIndexHTML` / `generateWaterfallHTML` / `generateTable` /
  `describeCaptureReason` / `exportFrameworkArtifacts` /
  `exportRuntimeArtifacts` / `exportSemanticAnalysis` -> `panel::report`
- `collectRuntimePayloads` / `writeReconArtifacts` (the head of
  `finalizeZipWithRecon`) / `finalizeZipWithRecon` -> `panel::export`
- `analyze` / `buildStrategy` / `createDefaultStrategy` / `VERSION` ->
  `panel::stackprofile` (`analyze` is the entry point; the two builders are
  private because only `analyze` calls them)
- `Object.keys(x).length` guards -> `panel::assets::keys_len`

## Test map (panel)

| JS behaviour | Rust test |
|---|---|
| whole analysis object (assets, chunkMap, moduleGraph, startupChain, runtimeOrigins, boundaryLabels, crossBoundaryFlows, frameworkState, frameworkRuntime, interestingEntrypoints, investigation with its workspaces and journeys) | `panel::analysis` whole-pipeline oracle compare |
| boundary labels, flows, predicates, workspaces, journeys | `panel::boundary`, `panel::workspace` oracle compares |
| script/runtime scoring, summaries, origins | `panel::assets` |
| text helpers, number formatting, slugify | `panel::text`, `panel::view` |
| runtime paths, unpack assets, report merge, cookies, inline JSON, recon stats, readable artifacts | `panel::artifacts` |
| the three console documents (byte for byte), waterfall, table, capture reason, framework/runtime/analysis exports | `panel::report` |
| recon artifact set and order, section guards, DOM snapshot fallback, the full export run and merged totals, runtime payload collection | `panel::export` |
| binary routing of a cached-bytecode resource (V8 code cache -> `cache-header.json`, `strings.json`) | `panel::assets` byte-content tests |
| the whole export through the real extension: reload, poll, click Download All, and the 45-entry zip asserted from the download directory | `test/browser-e2e.mjs` (Chromium over CDP) |
| the injected capture policy: present in the page with the engine's limits and redaction rule, and a runtime capture that only happens under an injected budget | `test/browser-e2e.mjs` (the injected script, evaluated in the page) |
| the capture policy: both predicate patterns over their captured corpora, the seven limits, the injected object's shape, and a guard that neither page-world module carries a local copy again | `tests/capture_policy_test.rs` |
| the page profile for 28 snapshots - values and serialized key order - plus a guard that the oracle still spans every detector, trait and strategy | `tests/stack_profile_test.rs` |

## Panel surface on the wasm bridge

The wasm API carries the panel as well as the engine: five `xu_call` arms -
`panelTrackerView`, `panelDescribeCaptureReason`,
`panelFinalizeZipWithRecon`, `panelStackProfileAnalyze` and
`panelCapturePolicy` - matching the bridge's exports. The document
generators and exporters are not arms: the export run composes them
internally, so exposing each one individually left ten arms nothing could
reach, and `looksBinaryScript`/`decodeBase64ToBytes` duplicated the dedicated
`xu_looks_binary_script`/`xu_b64decode` exports that the hot paths actually
call. Two seams are worth naming:

- **The clock is a host import.** `wasm32-unknown-unknown` has no clock and
  `SystemTime::now()` panics there, which took out every arm that stamps a
  report until `util::iso8601_now` read the time through `xu_host_now_ms`
  (the bridge answers `Date.now()`).
- **Binary payloads cross as base64.** `decoders::encode_base64` is the
  inverse of the decoder, so runtime payloads can be carried as base64 without
  a lossy UTF-8 round trip. The finished archive is the exception: it crosses
  through `xu_call_bytes` as raw bytes, which keeps a multi-megabyte archive
  from inflating by a third on the way to the panel.
- **Byte content has one field, two shapes.** A script input's `content` is a
  string for text and byte values for a binary asset. `JSON.stringify` turns
  the panel's `Uint8Array` into an index-keyed object while a plain array
  stays an array, so `panel::assets::byte_values` accepts both and the caller
  never has to remember which one it holds.

## The page profile (`stack-profile.js` -> `panel::stackprofile`)

`stack-profile.js` was the one page-world module whose work never needed the
page world. It reads a *snapshot* - resource and script URLs, global flags, DOM
markers, network and runtime counters - and returns a profile: the detected
technologies with their confidences and evidence, the traits, and the capture
strategy derived from them. Nothing in it touches a live object; the two
`window.` hits a grep finds are string literals inside signal labels. It lived
in the page world because it was written as a global, not because it needed the
VM.

The analysis therefore runs in the engine and the page world only collects:

- `injected.js` builds the snapshot - the one part that must read the page's
  globals and DOM - publishes it as `window.__STACK_SNAPSHOT__`, and keeps
  reading `window.__STACK_PROFILE__` exactly as before.
- `page.js` polls that snapshot, calls `panelStackProfileAnalyze`, and writes
  the profile back into the page, so the page's own readers - the capture
  strategy, `framework-introspect.js`, the recon export - see the same object
  they used to compute locally.

The module is deleted, and neither the page-world bundle list nor the exported
self-source list mentions it any more.

### Deliberate differences

1. **The analysis lands one round trip later than it did.** The profile now
   arrives from the panel instead of being computed inline. Every capture gate
   is at least a second wide (`bootDelayMs` 1200-1600, `networkQuietMs`
   1000-1600) while the panel polls every 500 ms, so the analysed timings are
   always in place before a gate can fire; until then the page world runs the
   default strategy it already carried as a fallback.
2. **The boot placeholder reports `version: 'fallback'`.** `injected.js` seeds
   an empty profile before the panel answers, and that placeholder no longer
   has a `VERSION` to read. The engine stamps `1.0.0` on the first analysis, so
   the placeholder is visible only for the first poll.
3. **The default strategy is mirrored, not shared.** The page world needs
   timings before the engine can answer, so `defaultStrategy()` in
   `injected.js` keeps its own copy of the engine's defaults. Those values
   drive the capture gates, so the pair is guarded rather than trusted:
   `the_page_world_default_strategy_matches_the_engine` reads the JavaScript
   literal out of `injected.js` and holds it to the engine's default field for
   field (drifting `bootDelayMs` by 100 ms fails it by name).
4. **`generatedAt` comes from the host clock.** The same seam as
   `util::iso8601_now`: `xu_host_now_ms` on wasm, `SystemTime` elsewhere. The
   parity test normalizes the field on both sides, since it is the profile's
   only clock-dependent value.

### Preserved JS quirks

- **`localeCompare` is byte order for this vocabulary.** The tiebreak only runs
  on equal confidences, and node's `localeCompare` orders all nineteen names
  exactly as a code-unit comparison does - checked for every tie group that can
  occur (0.95, 0.9 and 0.88) and pinned by the oracle.
- **The strategy rules run in order and overwrite each other.** `profile` is
  whichever rule fired last, and the two conditional rules (`graphql-app`,
  `static-site`) only take effect while it is still `generic-app`. That is why
  a Nuxt + GraphQL page is `spa-hydration` rather than `graphql-app`, and why
  Nuxt + Shopify also stays `spa-hydration`.
- **`reasons` is replaced only when a rule fires.** With no rule the default
  single reason survives; with rules, the accumulated list replaces it.
- **Whole numbers serialize without a decimal point.** `js_number` emits `1600`
  where `serde_json` would write `1600.0`, matching `JSON.stringify` - without
  it the profile compares unequal on representation alone.

## The capture policy (`framework-introspect.js` + `injected.js` -> `panel::policy`)

Both page-world modules carried their own copy of the rules that decide what a
capture keeps and what it hides: the key-name pattern that redacts a value, the
MIME pattern that decides text from bytes, the URL marker that makes a request
GraphQL, and seven budgets. The redaction rule is the load-bearing one - it is
what keeps a captured token out of the exported archive - and neither test
suite read it: a grep for `shouldRedactKey` and `MAX_ITEMS` across `test/`
returned nothing. That is the shape of a rule that drifts quietly.

The rules are data, so they cross as data. `panel::policy` holds them, the
panel injects the object as `window.__CAPTURE_POLICY__` ahead of the page
world's first line, and both modules read it:

- `page.js` prepends `window.__CAPTURE_POLICY__ = <json>;` to the injected
  script, so it is in scope before any page-world code runs and there is no
  window where a reader finds nothing.
- `framework-introspect.js` builds `REDACT_RE` from `redactKey` and reads
  `limits.items` / `limits.keys` / `limits.string` through one `limit(name)`
  accessor.
- `injected.js` builds `TEXT_MIME_RE` from `textMime`, reads the four runtime
  budgets the same way, and takes the GraphQL URL marker from `graphqlUrl`.
  The body half of that predicate is structural and stays put; it already
  mirrors `panel::graph::looks_like_graphql_body` exactly.

### Deliberate differences

1. **A missing policy fails closed.** There is no local copy to fall back to,
   so `limit(name)` answers `0` and the redaction pattern is `.*`: every key
   redacted, every budget collapsed. A capture that loses its policy is empty
   and loud rather than quietly unredacted. `limit` also answers `0` for an
   unknown name, so a renamed key cannot turn into an unbounded slice.
2. **The patterns are strings, not regex literals.** The engine carries them
   in the JavaScript form the page compiles (`new RegExp(source, 'i')`), since
   the page world is the only place they execute. The engine's own view of that
   vocabulary lives in `panel::graph`, which is why the GraphQL URL marker
   crosses while the body predicate does not.
3. **The oracle is the page world's own code.** `tests/fixtures/panel/
   capture-policy.json` was captured by extracting `shouldRedactKey` and
   `isTextMime` from the shipped modules, running them over a 64-case corpus,
   and reading the seven limits out of their declarations - so the vocabulary
   and its verdicts both come from the code being replaced. The corpus carries
   the cases a hand-port gets wrong: `tokens` / `jwtoken` / `sessionless`
   (substring hits), `authorisation` (a near miss that must not redact), empty
   keys, and MIME parameters (`application/json; charset=utf-8`).

## Deliberate differences (panel)

0. **The archive is written by the engine, without directory entries.** The
   panel collects `[{path, content}]` / `[{path, base64}]` and one call
   (`buildZip` -> `zip.rs`) returns the finished bytes, replacing JSZip. The
   writer emits only real files: JSZip also stored an entry for every parent
   folder, and those carry no information (each file name holds its full
   path), so an archive of the same files now has fewer entries - the file
   count drops, the contents do not. `zip::tests::writes_no_directory_entries`
   pins that, and the browser e2e reads the archive back through its own
   central-directory walker, so the format is checked by something other than
   the code that wrote it.

1. **JSON key order is preserved, not sorted.** The crate enables
   `serde_json`'s `preserve_order` feature so object keys keep insertion order,
   matching `JSON.stringify`. Without it every serialized report differs from
   the JavaScript byte-wise (same data, reordered keys) and the console page's
   embedded data blob cannot match.
2. **The DOM and `chrome.devtools` layers stay in the extension.** They read
   or write the inspected page and the panel UI, which a crate cannot do:
   `setActivity`, `clearActivity`, `doDownload`, `injectAndReload`,
   `startPolling`, `stopPolling`, `resetTrackerView`, `renderResults`,
   `renderPageOrigin`, `renderStackProfile`, `renderTrackerView`,
   `fetchTextAsset`, `fetchSourceMapText`, `fetchSourceMapTextInPage` and
   `collectReconAndFinalize`. Their logic-free parts are seams: payload
   fetching is `export::collect_runtime_payloads`'s `fetch` closure (the
   extension keeps its own copy because it reads the page per entry),
   source-map fetching is `pipeline::UnpackOptions::fetch_text`, and the
   finished archive is the writer closure.

   `page.js` was rewired onto the wasm panel surface: the entry points
   (`buildSemanticAnalysis`, the console/waterfall/table/DOM-snapshot
   generators, `describeCaptureReason`, the four exporters and
   `finalizeZipWithRecon`) call the bridge, file-producing calls return
   `[{path, content}]` (binary payloads as `{path, base64}`) and the file goes
   straight into the zip, and the 99 local copies of ported logic were deleted
   (3676 lines to 606, then to 501 once the text helpers went too). What is
   left in `page.js` is only the platform layer: the DOM, `chrome.devtools`
   and the zip writer.

   The text helpers (`hashString` and the `sanitizeFilename` chain) are gone
   from the panel as well: they name the archive's raw writes and the page
   snapshot, so they now run in Rust behind the bridge
   (`sanitizeFilename`/`sanitizePageTitle`). They are called a handful of
   times per export, so the boundary costs nothing, and the names the archive
   gets can no longer drift from the names the ported reports use.
   `tests/text_helpers.rs` pins both against an oracle captured from the
   shipped `page.js` (`tests/fixtures/text-helpers.json`, 59 cases), which is
   how a real divergence surfaced: the Rust twin added a suffix for a URL
   ending in a bare `#` or `?`, because the `url` crate reports an empty
   query/fragment as `Some("")` while `new URL(...).search`/`.hash` are `''`
   and therefore falsy in the original's `if (parsed.search || parsed.hash)`.
3. **The beautifier is an injectable seam.** `buildReadableArtifact` calls the
   engine's `looksMinified`/`beautifyJs`; the port defaults to
   `beautify::{looks_minified, beautify_js}` and takes both as parameters in
   `*_with` variants. The harness stubs that seam deterministically, so the
   oracle tests pin the assembly (header, facts, branch, body selection) while
   the engine functions carry their own tests.
4. **Census instead of oracle, for one function.** `finalizeZipWithRecon`'s
   JavaScript half cannot run in the harness (its analysis step calls the wasm
   engine, which is not available there). Its `zip.file` paths are therefore
   censused from the source text in source order and the test asserts the Rust
   writes exactly that set, in that order, for a maximal input; the guards and
   the assembly are covered behaviourally. The fixture labels this
   `sourceCensus` and the test comment repeats it.
5. **The runtime unpack prefix is a constant.** The JavaScript hardcodes
   `pathPrefix: '_unpack-runtime'` at the runtime call site; the port sets it
   the same way rather than deriving it from the caller's options.
6. **`parseCookies` returns an insertion-ordered map.** `_recon/cookies.json`
   serializes in the JavaScript's key order; a sorted map would reorder it.
7. **Numbers in embedded JSON are JS-formatted.** Values interpolated into
   documents go through `jsnumber::js_number_to_string`, and tests that build
   JSON fixtures use `panel::text::js_number_value` so `0.0` serializes as `0`.
8. **The parity gate compares text, not parsed JSON.** Two divergences that
   value equality cannot see were found only by comparing serialized output
   byte for byte: the asset record's boundary fields were in the wrong order
   (`applyBoundaryLabels` assigns `boundaryDetails` first) and the analysis
   counters were `BTreeMap`s, so every counts object serialized
   alphabetically instead of in first-seen order. `panel::model::Counts` is
   the insertion-ordered counter, and
   `tests/fixtures/panel/parity-oracle.json` (captured from the pre-port
   `page.js`) gates the analysis, the three documents, the capture reason and
   the recon/framework/runtime file sets as text.

## Preserved JS quirks (panel)

- Guards use `Object.keys(x).length`, so an empty object, array or string is
  falsy-but-present and writes nothing (`keys_len`).
- `reconData.ls && ...` style checks keep JavaScript truthiness: `0`, `''`,
  `[]` and `{}` never pass a presence guard (`js_truthy`).
- `e.field || fallback` keeps the JavaScript fallback for `0` and `NaN`
  (`export::number_or` in the waterfall, `field_number` elsewhere).
- The waterfall's `Math.max(1, ...)` minimum bar width and its
  `Math.min(10, Math.ceil(total/100))` tick count are kept exactly.
- The recon-artifact file order is the source order, including
  `_framework/*` being written from inside the framework export between
  `_recon/capture-status.json` and `_recon/timings.json`.
- The readable-artifact export keeps its ten-entry cap and its skip rules
  (empty chunk content, non-string runtime text, missing record).
- `buildRuntimeUnpackAssets` only takes runtime entries whose extension is
  `js`, and looks its raw file up by id in the manifest.
