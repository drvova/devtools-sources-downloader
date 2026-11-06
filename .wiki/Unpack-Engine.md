# Unpack Engine

The `devtools-unpack` crate. Everything here is **pure**: text or bytes in, files and a
report out. No DOM, no direct network access (only through an injected `fetch_text`
closure), no clock (only through an injected `now_ms`).

```
src/lib.rs          LIMITS, module list
src/scanner.rs      the lexical layer everything else stands on
src/decoders.rs     escapes, base64, inflate, printable ratio
src/detectors.rs    scores the layers present; the Tool enum
src/transforms.rs   apply one tool; the peel loop
src/packers.rs      Dean Edwards, aaencode/jjencode/jsfiretruck, obfuscator.io, string arrays
src/jsfuck.rs       a JSFuck interpreter with no host engine
src/bundler.rs      webpack module splitting
src/beautify.rs     minification detection + a scanner-aware formatter
src/sourcemaps.rs   sourceMappingURL discovery, map parsing
src/v8codecache.rs  V8 cached-data blobs and brotli-sealed .jsc
src/jscbytecode.rs  JavaScriptCore bytecode: strings, shared table, function tree
src/wasm.rs         wasm module structure
src/pipeline.rs     the asset pipeline, the report, the archive
src/zip.rs          the zip writer
src/util.rs         UTF-16 semantics, ISO-8601, path characters
src/jsnumber.rs     ECMAScript number semantics
src/digest.rs       SHA-256
```

## Budgets — the single source of truth

`lib.rs::LIMITS` is a `const` struct. Every module reads it; nothing restates a number.

| Field | Value | Guards |
| --- | --- | --- |
| `max_depth` | 8 | peel iterations per asset |
| `max_asset_bytes` | 8 MiB | an asset larger than this is reported, not unpacked |
| `max_beautify_bytes` | 2 MiB | above this, `beautify_js` returns its input |
| `max_modules` | 400 | webpack modules split per bundle |
| `max_sources` | 400 | `sourcesContent` entries written per map |
| `max_map_bytes` | 32 MiB | a fetched source map larger than this is refused |
| `min_payload_length` | 24 | shortest eval/Function payload considered real |

**Falsy-zero is preserved from the JavaScript.** `max_depth: 0` means "use the default",
not "do not peel" — because the original wrote `opts.maxDepth || LIMITS.maxDepth` and `0`
is falsy in JS. The same rule applies to `max_modules` and `max_beautify_bytes`. This is
implemented as `match max_depth { Some(0) | None => DEFAULT, Some(n) => n }` and is
commented at each site so nobody "fixes" it.

## The scanner — `scanner.rs`

One string/comment-aware walker feeds three consumers, so they cannot disagree: literal
extraction, balanced-region slicing, and module splitting.

Scanning is **byte-indexed over ASCII delimiters**. Multi-byte UTF-8 sequences never
contain a delimiter byte, so every delimiter-driven position lands on a char boundary.
That is the whole justification for not decoding to `char` first, and it holds for every
realistic payload shape.

| Function | Behaviour |
| --- | --- |
| `skip_quoted(text, i, quote)` | from the opening quote, `\\` skips two bytes, the closing quote returns `j+1`. A raw newline **ends the literal** unless the quote is a backtick. Unterminated → `text.len()`. |
| `skip_template(text, i)` | as above, but `${` recurses through `find_balanced` so a `}` inside an interpolation does not close the template. |
| `skip_line_comment` | to just past the next `\n`, or EOF. |
| `skip_block_comment` | to just past `*/`, or EOF. |
| `is_regex_start(text, i)` | walks back over whitespace (`util::is_ascii_js_space_byte`). Start of text → true. Otherwise the previous char must **not** be alphanumeric, `_`, `$`, `)`, or `]`. That single rule is what distinguishes division from a regex literal. |
| `skip_regex(text, i)` | tracks `[` … `]` character classes so `[/]` does not end the literal; consumes trailing flags. A raw newline aborts and returns `i+1` (not a regex after all). |
| `collect_string_literals(text, min)` | walks the text; on a quote, records `{start, end, quote, raw, value}` where `value = decode_escapes(raw)`, kept only when `utf16_len(value) >= min`. Skips comments and regexes so their quotes never open a literal. |
| `find_balanced(text, open_index)` | `{`/`[`/`(` → the index **just past** the matching close, or `None`. Skips strings, templates, comments and regexes while counting. |

`find_balanced` is the load-bearing primitive: the eval collector, the packer reader, the
webpack splitter and the beautifier all call it, which is why a brace inside a string
cannot desynchronise any of them.

## Decoders — `decoders.rs`

### `decode_escapes(raw)`

A character-level JS string-escape decoder, with three documented divergences:

| Input | JS | Here |
| --- | --- | --- |
| trailing `\` | appends `"undefined"` (string-concatenates an undefined read) | **same** — quirk preserved |
| `\u{` with no `}` | rewinds the cursor to −1 and loops forever re-emitting NUL | emits once and stops |
| code point > `0x10FFFF` | `fromCodePoint` throws | degrades to U+FFFD |

Handled: `\n \r \t \b \f \v \0`, `\xNN`, `\uNNNN`, `\u{...}`, line continuation (`\` +
newline → nothing), and octal `\1`–`\7` up to three digits. `\xNN` and `\uNNNN` go through
`code_unit_to_char`, which masks to 16 bits — so a lone surrogate becomes U+FFFD, because a
Rust `String` cannot hold one.

### base64

`decode_base64_to_bytes` normalises before decoding: whitespace (` \t \n \v \r \f`) is
stripped, `-`→`+` and `_`→`/` (URL-safe alphabet folded), then `=` padding is appended to a
multiple of four. Failure is `None`, never a panic.

`encode_base64` is hand-written over the standard alphabet and round-trips every tail
length (0, 1, 2 bytes) — the test asserts that explicitly, because a padding bug is
invisible on aligned input.

### inflate

`inflate_bytes(bytes, Gzip | Deflate)` → `flate2`'s `GzDecoder` / `ZlibDecoder`.
`gzip_format(bytes)` sniffs the header: `1F 8B` is gzip; `78 01`, `78 9C`, `78 DA` are
zlib-wrapped deflate. `None` means "not a format we recognise", which is a routing answer,
not an error.

### `printable_ratio`

Counts characters that are tab, LF, CR, or `>= 0x20` and not `0x7F`, over the total
character count. The base64 unwrapper refuses a decode below **0.85** — that threshold is
what stops a random binary blob from being written out as mojibake source.

## Detectors — `detectors.rs`

`detect_layers(text)` returns `Vec<Finding>`, each `{tool, score, detail}`. The scores are
what make the peel loop deterministic and ordered.

| Tool | Trigger | Score |
| --- | --- | --- |
| `jsfuck` | `detect_jsfuck` — ≥95% of 6-char alphabet, ≥12 hits, chain ≤4096 | **0.95** |
| `packer` | `function(p,a,c,k,e,` signature present | **0.90** |
| `string-array` | an obfuscator.io array declaration parses | **0.80** |
| `eval-unwrap` | eval/Function heads yield payloads | `0.70 + payloads/20`, capped at +0.30 |
| `charcode` | `String.fromCharCode(` with ≥7 numeric args | **0.65** |
| `hex-escape` | >8 `\xNN` **and** escapes×4 > 15% of the text | **0.60** |
| `unescape` | >8 `%uXXXX` sequences | **0.60** |
| `base64` | longest `[A-Za-z0-9+/=_-]{40,}` literal | `0.50 + len/4000`, capped at +0.30 |
| `reverse` | reversing the text gains >2 keyword hits | **0.45** |
| `rot13` | ROT13-ing the text gains >2 keyword hits | **0.42** |

The `gain()` measure is a keyword census — `function|return|var |let |const |window\.|document\.|prototype|undefined|null|true|false`. `reverse` and `rot13` only fire when the
transform **measurably improves readability**, which is what stops them from mangling
ordinary minified source. That is the difference between a detector and a guess.

### The `Tool` enum is the single definition of a layer name

```rust
pub enum Tool { EvalUnwrap, Base64, HexEscape, Unescape, CharCode,
                Reverse, Rot13, Packer, JsFuck, StringArray }
```

`detect_layers` produces it, `apply_transform` matches on it exhaustively, and `as_str()`
is the only place the wire spelling lives. Renaming a layer is therefore a **compile
error at every use**, not a detector whose transform silently stops firing through a
`_ => None` tail.

## Transforms — `transforms.rs`

### Collecting eval payloads

`collect_eval_payloads(text)` is the subtle part of the engine:

1. For each `eval` head, find the next `(`, then `find_balanced` to its close.
2. Take the argument text between them.
3. Collect its string literals. If the argument is **literal-only** — after removing
   literals, whitespace and `+(),` nothing remains — the payload is the literals joined.
   Otherwise the payload is the argument expression itself, so the next pass can peel
   `atob(...)`, `decodeURIComponent(...)` or a function call.
4. Keep it only if `utf16_len(payload) >= LIMITS.min_payload_length` (24).
5. For `Function(...)`, the payload is the **last** string argument — that is the body.

Payloads are deduplicated by exact text and sorted by head position, so the output order
is source order.

`unwrap_eval` joins every payload with `"\n;\n"` — a separator that keeps the pieces
parseable as separate statements.

### The unwrappers

| Tool | What it does | Refuses when |
| --- | --- | --- |
| `base64` | normalise → decode → if the bytes sniff as gzip/zlib, inflate → text | decode fails, or `printable_ratio < 0.85` |
| `hex-escape` | `\xNN` → char, then `\uNNNN` → char (requires `\x` present) | no `\x` escape at all |
| `unescape` | `%uXXXX` → `%XX%XX` (the `encodeURIComponent` form), then strict `decodeURIComponent` | any invalid `%` sequence |
| `charcode` | `String.fromCharCode(...)` with ≥7 codes → a JSON-quoted string | fewer than 7 codes |
| `reverse` | `chars().rev()` | never — the detector already gated it |
| `rot13` | ASCII letters shifted 13 | never — same |
| `packer` | `unpack_packer` | signature or args do not parse |
| `string-array` | array rebuild + rotator + decoder inlining | any step does not match |
| `jsfuck` | `decode_jsfuck` | the interpreter errors or yields a non-string |

`decode_uri_component` is **strict**: `%` must be followed by two hex digits, invalid input
returns `None`, and `+` is *not* a space (that is `decodeURIComponent`, not form decoding).
`to_uint16` implements JS `ToUint16` — truncate, wrap mod 65536, NaN/Infinity → 0 — because
`fromCharCode` does exactly that and a naive `as u16` would panic or wrap differently.

### The peel loop

```rust
pub fn peel_text(text: &str, max_depth: Option<usize>) -> PeelResult {
    let max_depth = match max_depth { Some(0) | None => 8, Some(n) => n };
    let refusals = collect_refusals(text);
    let mut seen: HashSet<String> = HashSet::from([sha256_hex(text)]);
    for depth in 0..max_depth {
        let findings = detect_layers(&current);      // scored
        for finding in &findings {                   // strongest first
            let candidate = apply_transform(finding.tool, &current)?;
            if !candidate.is_empty() && candidate != current
               && !seen.contains(&sha256_hex(&candidate)) {
                record stage; seen.insert(digest); current = candidate; break;
            }
        }
        if nothing applied { break; }
    }
}
```

Three properties, each of which is a bug somebody already had:

- **Cycle-proof.** A digest set stops `rot13(rot13(x))` from looping to `max_depth` and
  burning the budget on a no-op.
- **Progress-only.** A transform that returns the input unchanged is not a stage. The
  report never claims a layer that did nothing.
- **Bounded.** `max_depth` iterations, and each stage records input/output byte counts so
  the report shows where the bytes went.

Each `TextStage` carries `{depth, tool, inputBytes, outputBytes, digest, sourceUrl}`. The
`sourceUrl` is extracted with the shared `SOURCE_URL_COMMENT` pattern
(`//[#@]\s*sourceURL\s*=\s*(\S+)`) from the **output** — so a peeled layer that names itself
is recorded. The bundler compiles the same constant, so the pattern is written once.

### Refusals

`collect_refusals` runs once, on the **original** text, and reports what cannot be
statically decoded:

| Tool | Detection | Why refused |
| --- | --- | --- |
| `aaencode` | ≥1 banner hit **and** ≥5% kaomoji density, ≥80 chars | decoding means executing a kaomoji expression tree |
| `jjencode` | `=~[]` **and** `{___:++` | a `$=~[]` global-object shell |
| `jsfiretruck` | ≥256 chars and the `$=~[]`-family markers | same shape, different alphabet |
| `obfuscator-io` | marker census, **only when the string-array pass did not match** | a runtime shell with no static slice |

A refusal is data, not an error: it lands in `ReportEntry.refusals` and becomes a note, so
the report says *why* a payload is still obfuscated instead of silently shipping it.

## Packers — `packers.rs`

### Dean Edwards' packer

Signature `function(p,a,c,k,e,`. The reader parses the call arguments by hand:

- `read_packer_arg` accepts a string literal (with escapes), a number (`0x` hex or decimal,
  and it must be **delimited** — followed by whitespace, `,`, `)` or `%` — so `12abc` is
  not read as `12`), a balanced `{`/`[`/`( ` region it only needs to skip, or an
  identifier.
- `parse_packer_call` reads up to **8** arguments, and recognises the `.split('|')` suffix
  on the words literal. That suffix is matched by `match_split_suffix` **by hand**, because
  the JS pattern uses a backreference (`(['"]).*?\1`) that the `regex` crate cannot express.

`unpack_packer` loops up to `MAX_PACKER_LAYERS = 32`, stopping when detection misses or the
output stops changing — so a nested packer peels fully.

`base_decode_token` decodes the `k` array with `digit_value` (0-9, a-z, A-Z), and refuses a
token whose digit is ≥ the base.

### obfuscator.io — a 15-marker census

| Marker | Pattern intent |
| --- | --- |
| `banner` | `obfuscator.io` / `javascript-obfuscator` |
| `hex identifiers` | `\b_0x[0-9a-fA-F]{3,}\b` |
| `string array rotation` | `.concat`, `.shift()`, `.push(x[0])` |
| `rotation IIFE` | `(function(...){…parseInt` |
| `base64 decoder` | `atob(` or the base64 alphabet literal |
| `rc4 decoder` | `_0x…(_0x…, _0x…` |
| `switch dispatcher` | `switch(_0x…)` / `switch(x + parseInt` |
| `boolean shorthand` | `!![]` |
| `hex literals` | `= 0xNN` |
| `self defending` | `self defending` (case-insensitive) |
| `debug protection` | `debug protect` (case-insensitive) |
| `console disable` | `console[` / `call(this, console)` |
| `opaque predicate` | `? 'a' : 'b'` |
| `split string concat` | `'x' + concat` |
| `renamed properties` | `._0x…` |

Only the first **256 KiB** is scanned, each pattern is capped at 200 hits, and a refusal
requires either a **strong** marker (`banner`, `string array rotation`, `rc4 decoder`) or at
least **3** markers total. That threshold is what keeps a single `atob(` from being
reported as an obfuscated bundle.

### The string-array rebuild

This is the most involved static transform in the crate, and it runs in four stages:

1. **Find the array.** `^(var|let|const) <id> = [ ... ];` on its own line, where `<id>` is
   `_0x…` or a plain identifier. `parse_array_literals` reads the elements; any element that
   is an expression (not a literal) makes the whole thing refuse — the pass stays static or
   it does nothing.
2. **Find the rotator.** An IIFE of the form `(function(a,b){…})(array, pivot)` whose body
   looks like a rotator: it must contain a `while` loop with `!![]`/`true`, both `push` and
   `shift`, and `parseInt`.
3. **Simulate the rotation instead of executing it.** `simulate_rotation` walks up to
   `MAX_ROTATIONS = 4096` offsets looking for the index whose `parseInt(strings[i])` equals
   the pivot. That is exactly what the runtime loop does, computed rather than run. The array
   is then rebuilt in rotated order and the IIFE deleted — order-independent, because the
   two regions are spliced by whichever comes first in the source.
4. **Inline the decoder.** `find_decoder_decl` locates the decoder function (two shapes: a
   `var f = function(...)` and a `function f(...)`), `analyze_decoder_body` proves its body
   is exactly `return arr[i ± offset];` (one `[`, the parameter, an optional constant
   offset, nothing else), `find_decoder_call_sites` collects every `f(N)` call, and
   `decode_index` replaces each with the literal it would return.

The decoder declaration is removed **only if** every call site resolved and none was
unresolved — otherwise it stays and the calls stay, because a half-inlined file is worse
than an untouched one.

## JSFuck — `jsfuck.rs`

A real interpreter over `[]()!+`, with **no host JavaScript engine**. The original evaluated
the expression tree over real values so `+`, `!`, `String()` and method calls delegated to
V8. Here the value model implements exactly the surface the canonical encoder
(jsfuck.com 0.5.0) can reach:

```rust
enum JValue {
    Undefined, Bool(bool), Num(f64), Str(String), Arr(Vec<JValue>),
    Native(&'static str),        // []["at"]
    Constructor(&'static str),   // Number, String
    ArrayIterator,               // []["entries"]() -> '[object Array Iterator]'
    FunctionModel, EvalModel,    // capture seams, never executed
    FromSource(String),          // Function("...") result
    Global,                      // Function("return this")()
    RegExp { source, flags },
}
```

Builtins modelled: `Array.prototype.{at, entries, concat, join}`, `String.prototype.{at,
fontcolor, italics, split}`, `Number.prototype.toString(radix)`, and `escape()` / `Date()`
for the encoder's `C`/`D`/`%`/`G`/`M`/`T` recipes.

`Function("return X")` bodies are handled as a **capture seam**: `this`, `eval`,
builtin-by-name, a regex literal, a quoted payload, or a raw payload. Nothing is ever
executed.

Limits: `MAX_PARSE_NODES = 2_000_000`, `MAX_PARSE_DEPTH = 10_000`. Detection requires
≥12 characters, **purity ≥ 0.95**, ≥12 alphabet hits, and an operator chain ≤4096 — the
last gate is what rejects a pathological `++++…` blob that would otherwise parse forever.

`decode_jsfuck` returns `{value, captured}`. `captured` is true when the payload called the
capture hook instead of returning its result — a real distinction in JSFuck payloads.

## Binary formats

`pipeline::unpack_binary_asset` is a ladder. An unrecognised blob is a **reported** refusal,
never a silent skip.

### wasm — `wasm.rs`

`detect_wasm_module`: `00 61 73 6D` and ≥8 bytes. The parser walks sections with a LEB128
reader, and every bounds failure is a **note**, not an abort — a truncated module reports
what it could decode.

Sections are named (0 custom … 12 dataCount). The walker recovers:

- **custom "name" section** — subsection 0 is the module name, 1 function names, 2 locals
  (skipped), 4 type names.
- **import section** — `{module, field, kind}` with kind `func`/`table`/`memory`/`global`.
- **export section** — `{name, kind, index}`.
- **data segments** — printable ASCII runs of ≥4 chars, deduplicated.

`wasm_name` refuses any byte outside `\t \n \r` or `0x20..0x7F`, because wasm names are
UTF-8 and garbage there means the offset is wrong.

### V8 code cache — `v8codecache.rs`

Magic is `0xC0DE0000 | ext_refs`, where the low half is the external-reference-table size
of the build that wrote it. Known builds: `0xC0DE0563` node18, `05CC` node20, `0628` node22,
`0688` node24.

The header layout **changed at node22**: V11 keeps `payload_length` at +16 (24-byte header),
V12 inserts a read-only snapshot checksum there (32-byte header). The parser does not guess
from the magic — it tries both and keeps the layout whose `payload_length + header_size`
**exactly equals the blob length**. That is a self-checking rule, not a version table.

String frames inside the serialized payload: tag `0x52`, a map byte in `{0x61, 0x62, 0x63}`,
the StringImpl hash, a length at +6, characters at +10. Only printable ASCII is kept, and
strings are deduplicated.

`parse_sealed_v8` handles JSCeal-sealed `.jsc`: it refuses if the bytes already look like a
code cache, inflates with brotli (bounded at 64 MiB), and re-checks. The inflator is a
**seam** (`InflateImpl`) so a caller can inject one — the browser uses
`DecompressionStream('br')`, Rust uses the `brotli` crate.

### JSC bytecode — `jscbytecode.rs`

The deepest module. A Bun `--bytecode` chunk opens with a 32-byte header: stamp, format word
(must be 1), version, declared length, body offset.

**String recovery** scans for 12-byte records and *proves* each one:

```
prefilter:  (byte[at+3] & 0x07) == 0  &&  byte[at+7] == 0x00
flags    =  u32(at)        // length in bits 0..26, IS_8_BIT in bit 27
stored   =  u32(at+4)      // 24-bit StringImpl hash
length   =  flags & 0x07FF_FFFF      (1..=4096)
width    =  flags & 0x0800_0000 ? 1 : 2
accept   ⇔  wtf_string_hash(chars) == stored
```

`wtf_string_hash` is WTF's `StringImpl::hash()`: RapidHash over the raw bytes with WTF's
constant secret, low 24 bits, with zero replaced by `0x800000`. It reproduces the
`read32Big` helper faithfully — a function whose name says big-endian and whose body builds
**little**-endian words. The Rust twin comments this rather than fixing it, because the hash
must match the producer.

`rapid_mix` keeps the full 128-bit product before folding. Masking before the shift would
fold zero into the high half and mirror every value — a bug that produces a plausible-looking
but wrong hash for every string.

**The shared string table** (container-wide `EncoderStringTable`) is read sparsely: one slot
per ordinal, holes stay `None`. The span arithmetic is done in `u64` on purpose — on wasm32
the `u32` product and offset sum wrap, and a wrapped sum can *pass* a bounds check before
slicing past the buffer.

**The function tree** (`analyze_jsc_module`) binds code blocks whose instruction stream opens
on `enter`, walks exactly the declared length under the opcode table loaded from
`jsc_opcodes.txt` (id, name, operand bytes, padding), and ends on a transfer of control.
Candidates are ranked tight-first then smallest-gap. One bad slot is **counted**, not raised:
a corrupt slot must not discard the rest of the module.

The `enter` id is **read out of the table by name**, not restated as a constant. It used to be
`const JSC_ENTER_OPCODE: u8 = 134`, which duplicated the row `134 enter 0 0` that the parser
already loads — two facts that could disagree the moment the table was regenerated, and the
failure would be silent: the walker would look for the wrong byte and find no op stream. A
missing `enter` row now means no op stream can be walked, so the scan reports nothing rather
than matching the wrong byte.

## Bundles, beautification, source maps

### webpack splitting — `bundler.rs`

Locates the module map: either `__webpack_modules__` or the push-array form
(`[[ids], {…}]`), then `find_balanced` to its close and slices each
`id: function(params){…}` member.

Two regexes exist because JS `lastIndex` resumption cannot be expressed in one: `HEADER_FULL`
may match at position 0 (`^`), `HEADER_CONT` may not. The first match uses one, every later
match the other — that is the faithful port.

A module whose body is a **lone arrow expression** (`(a) => ({…})`) is skipped. That is a
preserved quirk, not an oversight, and it is commented as such.

`module_file_name` names each module from its `//# sourceURL`, stripping `webpack://` /
`webpack-internal://`, a leading `./`, and leading slashes, then sanitising path characters.

### beautification — `beautify.rs`

`looks_minified` requires a code signal (`function|return|var|let|const|class|new|typeof|
window\.|document\.|module.exports|exports\.|prototype|=>`) in the first 200 000 UTF-16
units, then either fewer than 4 lines, or a longest line >500, or a mean line length >220.

`beautify_js` is a **scanner-aware formatter**, deliberately not js-beautify: brace blocks
get one statement per line at two-space indent, content inside `(`/`[` stays inline
(`paren_depth` gates it), and strings, templates, comments and regexes pass through
untouched because it calls the same `skip_*` primitives. Over `max_beautify_bytes` it
returns its input unchanged.

### source maps — `sourcemaps.rs`

`find_source_map_ref` uses `rfind("sourceMappingURL")` — **the last one wins**, which is what
a browser does when a file carries both a stale and a live comment. The ref is either an
inline `data:` URI (kept whole so the decoder can re-match the prefix) or an external path.

`parse_source_map` reads `sources`, `sourcesContent`, `sourceRoot`, `file`; it emits one file
per source that actually has content, capped at `max_sources`, with paths cleaned of
`webpack://`, `webpack//`, `./`, backslashes and leading slashes.

`decode_inline_source_map` matches `^data:([^;,]*)(;base64)?,([\s\S]*)$` and decodes base64
or percent-encoding accordingly. `resolve_map_url` is `new URL(ref, scriptUrl).href` with a
raw-ref fallback when either side is not absolute.

**Only maps the page itself publishes cause network access** — an external ref goes through
the injected `fetch_text` closure, and a missing closure means no fetch at all.

## The asset pipeline — `pipeline.rs`

```rust
enum Asset { Text { url, content, zip_path }, Bytes { url, bytes, zip_path } }
```

`looks_binary_script(url, bytes)` decides the route **before** an asset is fetched: a
`.jsc`/`.bc`/`.wasm` URL, or bytes that sniff as wasm (≥8) or as a V8 cache / JSC chunk
(≥32). Everything else stays text.

`asset_slug(url, index)` builds the folder name: strip the scheme, strip `?`/`#`, replace
path-hostile characters with `_`, collapse `/` runs to `__`, truncate to the last 90 UTF-16
units, fall back to `inline`, append `.js` if absent, and prefix with a zero-padded index —
`format!("{}-{}", utf16_suffix(&format!("000{index}"), 4), cleaned)`.

### The text pass

```
if empty or > max_asset_bytes → note, return
peel_text(content)                       → stages, refusals, final text
write layers/0<depth>-<tool>.js          for each text stage
write 00-original.js                     if any stage ran
extract_bundle_modules(current)          → modules/<name>.js
if looks_minified(current)  → 10-beautified.js
else                        → 10-source.js
find_source_map_ref(content) or (current) → source-map.json + sources/<path>
if nothing found → note "no obfuscation layer, bundle structure, or source map content found"
```

Note the source-map lookup tries the **original** first, then the peeled text — a map comment
can live in either.

### The report

`ReportEntry` is the per-asset record: `url`, `zipPath`, `kind`, `bytes` (UTF-16 length),
`digest` (SHA-256, absent when empty), `stages`, `modules`, `sources`, `beautified`,
`sourceMap {kind, ref}`, `notes`, `refusals`, `functions`.

`Report` adds `generatedBy: "unpack.js"`, `totals {assets, unpacked, modules, sources,
beautified}`, and — filled by `unpack_assets_into` — `root` and `unpackedAt`.

### The shared JSC table

`unpack_assets` does something the per-asset pass cannot: chunks arrive as loose assets with
no module graph, so the container-wide `EncoderStringTable` is **discovered by structure**
(hash-validated) in any binary asset and shared with every chunk, resolving `<ordinal N>`
name slots. A table is accepted only if it resolves at least 8 names.

## The zip writer — `zip.rs`

Deliberately small: entries are deflated (method 8) when that helps and **stored** (method 0)
when it does not, names carry the UTF-8 flag (`0x0800`), and nothing beyond the original
format is emitted — no zip64, no data descriptors, no encryption, no comments.

| Constant | Value |
| --- | --- |
| local / central / EOCD signatures | `0x04034B50` / `0x02014B50` / `0x06054B50` |
| version | 20 (the one that introduced deflate) |
| max entries | `0xFFFF` |
| DOS epoch | 1980 … 2107 |

**Limits are refused, not truncated** — a silently truncated archive is worse than a failed
one. Every failure path returns `Err`, because a panic would trap the wasm module.

`ZipWriter::new()` stamps the DOS epoch, which makes output for identical input
byte-identical; `with_ms(ms)` stamps a real time. The test parses the archive with an
**independent** reader that walks the central directory and then each local header, so a
wrong offset or size cannot pass.

## Supporting modules

| Module | Role |
| --- | --- |
| `util.rs` | `utf16_len/prefix/suffix` (JS slice semantics — never splits a surrogate pair), `civil_from_unix_secs` (Howard Hinnant's algorithm, shared by ISO-8601 and DOS stamps), `now_unix_millis` (the wasm clock seam), `regex_escape`, `BAD_PATH_CHARS`, and the two whitespace sets |
| `jsnumber.rs` | `js_number_to_string` (ECMA-262 7.1.12.1 — the `k`/`n` digit-position algorithm, so `1e-7` prints `1e-7` and `1e20` prints 21 digits), `js_number_to_radix_string`, `js_string_to_number`, `js_escape` |
| `digest.rs` | SHA-256 over text and bytes; `sha256_hex_bytes` answers `None` for empty input |

### Two whitespace sets, deliberately

`is_ascii_js_space` / `is_ascii_js_space_byte` cover space, tab, LF, VT, FF and CR — the
ASCII subset. `is_ecmascript_whitespace` covers the **full** ECMAScript `\s`, adding U+00A0,
U+FEFF, U+1680, U+2000–200A, U+2028, U+2029, U+202F, U+205F and U+3000.

They are separate because they mean different things. Every pattern in the engine scans
minified source, where those extra characters do not appear between tokens — widening the
class would change what every one of them matches. Only `ToNumber` uses the full set, because
`Number(string)` genuinely trims `\s`. Keeping the two distinguishable **by name** is what
stops a well-meant widening from silently changing the scanner.

`BAD_PATH_CHARS` has **one definition on purpose**: widening the set for one producer used
to leave the other four writing names it would reject. There are two forms — one for a path
segment, one that also strips `/` for a whole path.
