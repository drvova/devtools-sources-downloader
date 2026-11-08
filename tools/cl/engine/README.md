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
| **Ported** | **1,013 LOC** (`package` 66, `util` 143, `number` 321, `text` 483) |
| Gate | 330 LOC (`gate.lisp`) + 49 (`run-engine.lisp`) |
| Verdict | 4 gates, **209/209 cases** |

That is ~6% of the Rust by line count, and it covers the layer every other module
depends on: UTF-16 semantics, JS number formatting, and the archive-path writers.
It is the smallest slice that can be proven, not the smallest useful one.

**The line-count result is worth stating plainly**, because the usual objection to
a Lisp port is verbosity: for the identical surface (Rust `util.rs` 242 +
`jsnumber.rs` 228 + `panel/text.rs` 582 = **1,052**) the Lisp is **1,013**,
comments included. It is not a blowup, and it is not a win — it is parity, with
the JS semantics written out instead of delegated to crates. The one place Lisp
cost *more* is the URL parser (~150 lines) that Rust got from the `url` crate.

Ported so far:

| module | source | status |
| --- | --- | --- |
| `util.lisp` | `util.rs` (JS string semantics) | done |
| `number.lisp` | `jsnumber.rs` (Number::toString/toFixed) | done |
| `text.lisp` | `panel/text.rs` (path + title helpers) | done |
| `scanner.rs` | string/comment-aware walker | **next** |
| `detectors.rs`, `decoders.rs`, `beautify.rs` | text tier | queued |
| `packers.rs`, `jsfuck.rs`, `transforms.rs`, `pipeline.rs` | the peel engine | queued |
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
