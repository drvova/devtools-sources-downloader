# PORTING.md - devtools-unpack (JS -> Rust)

Behavior-faithful port of the DevTools sources-downloader unpack engine
(`../hhfkbeloejjheeiihhjndfcogjhejoek/src/js/{unpack,packers,jsfuck,v8codecache,jscbytecode,wasm}.js`)
to the `devtools-unpack` crate. Same observable behavior, same test surface:
every one of the 67 node baseline cases in
`../hhfkbeloejjheeiihhjndfcogjhejoek/test/unpack.test.mjs` has a 1:1 Rust
twin in `tests/unpack_test.rs` with the same test name (camelCase -> snake_case).

Verification: `cargo build` 0 errors / 0 warnings, `cargo test` 77/77
(67 integration + 10 lib unit), `cargo clippy --all-targets -- -D warnings`
clean. Fixtures are referenced in place
(`env!("CARGO_MANIFEST_DIR")/../hhfkbeloejjheeiihhjndfcogjhejoek/test/fixtures`),
never copied.

## Module map

| JS source | Rust module | Notes |
|---|---|---|
| unpack.js (limits, digests, scanner, decodeEscapes, base64, printableRatio, looksBinaryScript, assetSlug) | `util.rs`, `digest.rs`, `scanner.rs`, `decoders.rs` | LIMITS is `lib::LIMITS` (7 fields) |
| unpack.js detectLayers / collectEvalPayloads / looksMinified | `detectors.rs` | |
| unpack.js beautifyJs | `beautify.rs` | simplified formatter, see Differences |
| unpack.js extractBundleModules | `bundler.rs` | |
| unpack.js findSourceMapRef / parseSourceMap / decodeInlineSourceMap / resolveMapUrl | `sourcemaps.rs` | |
| unpack.js peelText / applyTransform / decodeURIComponent | `transforms.rs` | `Stage` is shared with pipeline |
| unpack.js unpackAsset / unpackAssets / unpackAssetsInto / report shape | `pipeline.rs` | zip writer is a closure seam |
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
