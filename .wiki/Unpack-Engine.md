# Unpack Engine

The `devtools-unpack` crate. Everything here is pure: text or bytes in, files and a report
out. No DOM, no network except through an injected fetch closure, no clock except through
an injected `now_ms`.

## The peel loop

`transforms::peel_text` is the heart of the text path:

```
seen = {sha256(text)}
for depth in 0..max_depth:
    findings = detect_layers(current)          # scored, strongest first
    for finding in findings:
        candidate = apply_transform(finding.tool, current)
        if candidate != current and sha256(candidate) not in seen:
            record stage; seen += digest; current = candidate; break
    else: break                                # nothing applied → stable
```

Three properties matter:

- **Cycle-proof.** A digest set stops `rot13(rot13(x))` from looping forever.
- **Budgeted.** `LIMITS.max_depth = 8`; each stage records input/output byte counts.
- **Refusal-aware.** Tools that cannot be reversed produce a `Refusal { tool, detail }`
  that lands in the report instead of being silently skipped. The refusal set is aaencode,
  jjencode, jsfiretruck, and obfuscator.io when the static string-array pass did not match
  (i.e. the payload is a runtime shell). A refusal names what was found, so the report says
  *why* a payload is still obfuscated.

## Detectors — what gets routed

`detectors::detect_layers` returns scored `Finding`s:

| Tool | Trigger | Score |
| --- | --- | --- |
| `jsfuck` | the `[]()!+` alphabet dominates the text | 0.95 |
| `packer` | Dean Edwards' packer signature | 0.90 |
| `string-array` | obfuscator.io string array + rotator | 0.80 |
| `eval-unwrap` | `eval(...)` / `Function(...)` payloads found | 0.70 + payloads/20, capped at 0.30 |
| `charcode` | a `String.fromCharCode` list | 0.65 |
| `hex-escape` | >8 `\xNN` escapes and >15% of the text | 0.60 |
| `unescape` | >8 `%uXXXX` sequences | 0.60 |
| `base64` | longest base64 literal | 0.50 + len/4000, capped at 0.30 |
| `reverse` | reversing the text gains >2 readable points | 0.45 |
| `rot13` | ROT13-ing the text gains >2 readable points | 0.42 |

The strongest applicable finding wins each pass, so a payload that is base64 *inside* an
`eval` gets unwrapped first and decoded second. `reverse` and `rot13` are decided by a
readability **gain** — they only fire when the transform measurably improves the text, which
is what stops them from mangling ordinary minified source.

## Text transforms

`src/transforms.rs` (432 lines) applies one tool by name. The eval collector is the
subtle part: `collect_eval_payloads` finds `eval`/`Function` heads, uses the scanner to
find the balanced argument region, and decodes string literals — so it never trips on a
brace inside a string, a template, a comment, or a regex. `decode_uri_component` and the
`unescape`/`charcode`/`hex` unwrappers follow the same discipline.

## The scanner

`src/scanner.rs` (213 lines) is the shared lexical layer every other module stands on:
`skip_quoted`, `skip_template`, `skip_line_comment`, `skip_block_comment`,
`is_regex_start`, `skip_regex`, `find_balanced`, `collect_string_literals`. Getting
`is_regex_start` right (a `/` after an identifier is division, after an operator it starts
a regex) is what keeps `find_balanced` honest on real minified code.

## Packers and obfuscators

`src/packers.rs` (1056 lines):

- **Dean Edwards' packer** — `detect_packer` / `unpack_packer`, with the original
  `MAX_PACKER_LAYERS` stop conditions preserved so nested packers peel correctly.
- **aaencode / jjencode / jsfiretruck** — detected and **refused**, with a reason. Each is a
  *shell*: decoding it means executing a kaomoji/`$=~[]` expression tree, not applying a
  string transform. The detector requires both a banner hit and real alphabet density, so a
  stray kaomoji in a comment cannot trigger a refusal. Pretending to decode one would
  produce garbage, so the report says what it saw instead.
- **obfuscator.io** — a marker census (banner, string-array shape, rotator, dead-code
  injection, control-flow flattening) that ends in a `Refusal` naming what was found.
- **string-array rebuild** — `detect_string_array` / `transform_string_array` rebuild the
  array, apply the rotator, and inline the references back into the source.

## JSFuck

`src/jsfuck.rs` (917 lines) is a real interpreter over the six-character alphabet
(`[]()!+`): it evaluates the expression tree to a string, then the caller re-parses the
result. `detect_jsfuck` requires **95% purity** over at least 12 alphabet characters, so a
file that merely contains some `[]()!+` is not mistaken for one. `decode_jsfuck` returns the
recovered value and whether it was *captured* (the payload called the capture hook) rather
than returned. The encoder side lives in `tests/jsfuck_encoder/` and generates round-trip
fixtures.

## Binary formats

`pipeline::unpack_binary_asset` is an ordered ladder — first match routes, an unrecognized
blob is a *reported* refusal, never a silent skip:

| Rung | Module | What it writes |
| --- | --- | --- |
| wasm module | `wasm.rs` | `wasm-info.json`: version, sections, imports, exports, function and type names, data strings |
| V8 code cache | `v8codecache.rs` | `cache-header.json` (magic, runtime, format, version/source/flag hashes, payload length) plus the recovered strings |
| brotli-sealed V8 | `v8codecache.rs` | inflate, then re-parse as a code cache |
| JSC bytecode | `jscbytecode.rs` | `cache-header.json` (version, declared length) plus the recovered strings |

A wasm module and a V8 code cache can both match the same blob, so those two rungs are
independent `if`s; the JSC rung only runs when nothing else matched. JSC is the deepest:
it parses Apple's JavaScriptCore bytecode format, reads the shared string table
(`read_jsc_shared_table`, `find_jsc_shared_table`), and walks function blocks to recover
strings and opcode statistics. `wtf_string_hash` reproduces WTF's hash — including its
misleadingly named `read32Big`, which builds little-endian words (the Rust twin comments
this, and the JS quirk is preserved on purpose).

## Bundles, beautification, source maps

- `bundler::extract_bundle_modules` splits **webpack** bundles — both the named
  `__webpack_modules__` map and the push-array form — into modules, naming each from its
  `//# sourceURL` (with `webpack://` / `webpack-internal://` prefixes stripped). A module
  whose body is a lone arrow expression is skipped — a preserved JS quirk. Vite/Rollup output
  is already ESM and is not re-split; those bundles are handled by beautification and source
  maps instead.
- `beautify::looks_minified` decides from line length and code signals;
  `beautify::beautify_js` is a scanner-aware formatter (brace blocks get one statement per
  line, two-space indent, parentheses stay inline). It is deliberately *not* js-beautify:
  it implements the contract the suite asserts and nothing more.
- `sourcemaps::find_source_map_ref` locates inline data URIs and external URLs;
  `parse_source_map` reads `sources`/`sourcesContent`; external maps are fetched through the
  injected `fetch_text` closure. **Only maps the page itself publishes cause network access.**

## Supporting modules

| Module | Role |
| --- | --- |
| `decoders.rs` | escape decoding, base64, gzip/brotli/deflate inflate, printable ratio |
| `jsnumber.rs` | `Number.prototype.toString(radix)`, `String→Number`, `escape()` — exact JS semantics |
| `digest.rs` | SHA-256 hex, text and bytes |
| `util.rs` | UTF-16 length/prefix/suffix (JS slice semantics), ISO-8601, civil dates |
| `zip.rs` | the archive writer: deflate-or-store, UTF-8 names, no zip64 |

`zip.rs` refuses limits rather than truncating, because a silently truncated archive is
worse than a failed one. It returns `Err` on every failure path — a panic would trap the
wasm module.

## Budgets

`lib.rs::LIMITS` is the single source of truth:

| Limit | Value |
| --- | --- |
| `max_depth` | 8 |
| `max_asset_bytes` | 8 MiB |
| `max_beautify_bytes` | 2 MiB |
| `max_modules` / `max_sources` | 400 |
| `max_map_bytes` | 32 MiB |
| `min_payload_length` | 24 |

Falsy-zero semantics are preserved from the JavaScript: `max_depth: 0` means "use the
default", not "no peeling".
