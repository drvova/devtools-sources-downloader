# The engine port to Common Lisp

A second implementation of the unpack engine in SBCL, held to the same oracles
the Rust port is. It is **not** a replacement: the shipped extension runs the
Rust engine as WebAssembly in Chrome, and SBCL cannot run there. This is the
native path — CLI and REPL — and the reason to have it is that an unpack pass can
be re-run against one fixture and diffed in a sentence instead of
`cargo test` → wasm build → reload the extension.

## Why, if it is not replacing anything

Three properties, and nothing else:

- **The peel chain becomes data.** `pipeline.rs` is a `Stage` enum with a match
  arm per peel. In Lisp the same chain is a list of rules over a form, which is
  what `packers.rs` is imitating by hand.
- **A live loop over the oracle.** `boundary-oracle.json` is 422 KB of expected
  strings. Being able to change one function and re-diff against it in the same
  process is the whole argument.
- **The oracles already exist.** 597 KB of JSON fixtures, 13 binary fixtures and
  a 68-case node baseline are a specification independent of the Rust
  implementation. A port without them would be guesswork.

## State

| | |
| --- | --- |
| Rust engine + panel | 17,959 LOC |
| **Ported** | **15,131 LOC** across 24 files |
| Gate | 15 gates, **1,149 cases**, `sbcl --script tools/cl/run-engine.lisp` → exit 0 |

| gate | cases | oracle |
| --- | --- | --- |
| harness self-test | — | proves the comparison can fail |
| mutation probes | 10 | plausible wrong implementations |
| scanner + decoders | 27 | wasm |
| digest | 6 | wasm + structural |
| bundler | 20 | wasm |
| text helpers | 59 | `text-helpers.json` |
| number semantics | 140 | node, IEEE-754 bit patterns |
| beautify | 187 | wasm goldens + 20 adversarial |
| detectors | 89 | wasm |
| sourcemaps | 24 + 34 | wasm + structural |
| packers | 84 | wasm + 16 probes |
| wasm parser | 107 | binary fixtures |
| jsc bytecode | 108 | binary fixtures + sidecars |
| v8 code cache | 135 | binary fixtures |
| zip writer | 129 | round trip |

**The line-count result** for the first slice, because the usual objection to a
Lisp port is verbosity: for the identical surface (Rust `util.rs` 242 +
`jsnumber.rs` 228 + `panel/text.rs` 582 = **1,052**) the Lisp was **1,013**,
comments included. Parity, not a blowup and not a win. The one place Lisp cost
*more* is the URL parser (~150 lines) that Rust got from the `url` crate.

### Source defects the port found

These are bugs in the Rust/original, not in the port. Each is pinned to the
shipped behaviour and reported rather than silently followed.

- **`JS_W` contradicts its own docstring.** `util.rs:170` says "JS `\w`: ASCII
  word characters only" and defines `A-Za-z0-9_`; `beautify.rs:15` uses the regex
  crate's **Unicode** `\w` instead. Measured in the binary: `prototypeé` → false,
  `évar a` → false, but `exports.é` → **true**. One of the two is unintentional.
- **Comments and strings are treated differently.** The docstring says strings,
  templates, comments and regexes "pass through untouched", which reads as
  uniform. The literal and regex arms set `line_has_code = true`, the two comment
  arms do not. Observable: `a();/*c*/{b();}` keeps `{` on the comment's line,
  while `a();"s"{b();}` emits `"s" {`.
- **Pinned-and-surprising, worth knowing before changing anything:** the beautify
  budget is a *refusal* not a truncation; `paren_depth` is signed, so one
  unmatched `)` drops a whole file into inline mode; `looks_minified` measures
  the longest line in **bytes** and the average in **UTF-16 units**.

Ported so far — every module below has a gate that passes:

| module | source | gate |
| --- | --- | --- |
| `util` | `util.rs` | via the others |
| `number` | `jsnumber.rs` | 140/140 |
| `text` | `panel/text.rs` | 59/59 |
| `transforms` | `transforms.rs` (URI codec) | via scanner/text |
| `decoders` | `decoders.rs` | via scanner/sourcemaps |
| `scanner` | `scanner.rs` | 27/27 |
| `digest` | `digest.rs` | 6/6 |
| `bundler` | `bundler.rs` | 20/20 |
| `beautify` | `beautify.rs` | 187/187 |
| `detectors` | `detectors.rs` | 89/89 |
| `sourcemaps` | `sourcemaps.rs` | 24 + 34 |
| `packers` | `packers.rs` | 84/84 |
| `wasm` | `wasm.rs` | 107/107 |
| `jscbytecode` | `jscbytecode.rs` | 108/108 |
| `v8codecache` | `v8codecache.rs` | 135/135 |
| `zip` | `zip.rs` | 129/129 |

**Still queued:**

- `transforms.rs` — the peel chain (`peel_text`, `apply_transform`,
  `collect_refusals`, the unwrap ladder). Being ported; `decode-uri-component`
  and the sourceURL pattern are already done. This is the real hinge: `pipeline`
  calls `peel_text`, and `peel_text` calls detectors, packers and jsfuck.
- `jsfuck.rs` (920) — being ported, and the reason it took a dedicated pass is
  that its oracle is **vacuous for decode**: all 17 inputs answer
  `{"value":null,"captured":false}`, so a port returning that constant would pass.
  Real JSFuck encodes need to be generated with the shipped encoder first.
- `pipeline.rs` (713) — **in flight**. Pure orchestration over the modules above,
  with a 13-case oracle captured from the shipped engine (`pipeline-oracle.json`:
  13 cases, 30 output files, entry fields plus every file's path and content).
- `wasm_api.rs` (806) — the browser seam (`xu_call`, `xu_alloc`, the JSON
  envelope). No native counterpart to port: an SBCL build calls functions
  directly, so this file *disappears* rather than being translated.

The 10,102-line `panel/*` tree is out of scope: it is the extension's own UI
logic, not the unpack engine.

### A correction worth recording

An earlier version of this file claimed `pipeline` depends on `jsfuck`. It does
not — `pipeline.rs` contains zero jsfuck references. `transforms.rs` is what
imports jsfuck, and `pipeline` imports `transforms`. The dependency direction
matters because it changes which module is the blocker, and I had it backwards
for two turns because I read a summary instead of grepping the source.

### Known gaps, with the fixture that would close each

Stated here rather than buried in a gate comment, because a gap nobody can act on
is indistinguishable from an omission.

**jsc bytecode, terminal-op check.** Every fixture happens to end on a terminal
op, so the check is pinned by construction rather than by a case. The truncation
lengths that DO exercise it were measured against the real stream: 1, 4, 7, 16,
31, 35, 38, 53. The fixture is `jsc-chunk-terminal-truncated.jsc` — jsc-chunk.jsc
with record 368's `0x38`-tail `.instr` count varint patched from 55 to any value in
that set. `bind-jsc-block` must then answer zero candidates, and a port without the
terminal check answers one while every other assertion stays green. **One byte edit
from being an oracle case.**

**jsc bytecode, slot tags.** Three of the four tags are construction-pinned, not
two — tag 2 is the only one the fixtures exercise, because `moduleLoader` and
`starNamespace` are matched by *hash* in `recover-jsc-strings` and never reach
`decode-jsc-slot`. Each needs its own payload, and the assertion each would gain is
written in `gate-jscbytecode.lisp`: tag 0 → the decoded name is the inline string
and a slot-to-slot pointer resolves to depth 3; tag 3 → the name renders
`<slot hex>` instead of collapsing to empty; tag 1 → characters come out
low-byte-first from bit 8, the reverse of what a naive port produces.

**transforms, `collect-refusals`.** Empty for all 17 oracle cases, so it is pinned
structurally against packers' own refusal detection rather than by an oracle.
| `jscbytecode.rs`, `v8codecache.rs`, `wasm.rs`, `zip.rs` | binary tier | queued |
| `panel/*` | the panel | out of scope for now |

## The gate

```bash
sbcl --script tools/cl/run-engine.lisp          # all gates
sbcl --script tools/cl/run-engine.lisp text     # one gate
sbcl --script tools/cl/run-engine.lisp probe    # ad-hoc evidence
```

Exit code 0 means every gate passed. Four gates run:

1. **harness self-test** — proves the comparison can record a failure at all.
2. **mutation probes** — each names a *plausible wrong implementation* and
   asserts the port does not produce it (`CL's ~f would round 1.25 to 1.2`;
   `CL's length would say 1 for an emoji`; `SBCL would print 0.0000001`).
   This is the gate that earns its keep: it found the `1e-7` exponent
   off-by-one that the oracle's own cases never reached.
3. **text helpers** — `tests/fixtures/text-helpers.json`, 59 cases captured from
   the shipped `page.js`.
4. **number semantics** — `tests/fixtures/number-oracle.json`, 140 cases
   generated from live node by `unpack-rs/scripts/number-oracle.mjs`.

## Oracles cross as bit patterns, not decimals

The number oracle emits IEEE-754 bit patterns rather than JSON numbers. Two
float parsers between the oracle and the comparison (node's and JZON's) would let
a *formatting* bug present as a *parsing* bug, and bits cannot round wrong. It
also carries `-0`, `NaN` and `±Infinity`, none of which JSON numbers can express.

Regenerate after adding cases:

```bash
node unpack-rs/scripts/number-oracle.mjs
```

## Host semantics that are not JavaScript's

Everything in `number.lisp` and `util.lisp` exists because the host disagrees.
The four that produce *plausible* wrong answers rather than errors:

| host behaviour | JavaScript | where |
| --- | --- | --- |
| `(format nil "~,2f" 1.005)` → `"1.00"`... from the shortest decimal | `1.005.toFixed(2)` → `"1.00"` but `0.15.toFixed(1)` → `"0.1"` | exact digits must come from `(rational v)` |
| `(/= nan nan)` **signals** on SBCL | `NaN !== NaN` is `true` | `sb-ext:float-nan-p` |
| `string-trim` uses CL whitespace, no U+FEFF | `String.prototype.trim` drops the BOM | `js-trim` |
| `length` counts characters | `.length` counts UTF-16 code units | `utf16-length` |

## Load-order rules that bite

LOOP reads one top-level form at a time. A script that mentions
`vovas.engine.gate:foo` in the same form as the `load-system` call dies at read
time with "package does not exist" — so the dispatch sits in its own form after a
separate `(load-engine)`. The same trap makes
`--eval '(progn (require :asdf) ... asdf:load-asd ...)'` unusable.

Also: `defconstant` on a **string** mints a fresh object per compile and reloading
signals `DEFCONSTANT-UNEQL` even for identical text. Strings are `defparameter`.

## Dependencies

`cl-ppcre` (the Rust has 93 `Regex::new` sites over minified JS; rewrites would
trade a known-correct engine for a known-buggy one) and `com.inuoe.jzon` (the
same JSON library the toolchain uses, so there is one JSON implementation here).

`brotli` has no quicklisp answer and will need CFFI when the binary tier lands.
`flate2` maps to `chipz` (read) and `salza2` (deflate for the zip writer).
