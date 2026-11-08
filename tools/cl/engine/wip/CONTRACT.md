# Parallel port — worker contract

Each worker owns exactly one module and its gate. Nothing is shared, so nothing
conflicts.

## Fasls: the rule that covers peers, not just yourself

A `.fasl` beside a source loads in preference to it and reports "these symbols
are not accessible", which reads as a source bug. **An untracked fasl whose
timestamp you cannot explain is a false signal, not a build artefact.**

Three clauses, because a peer's mistake can reach your files:

1. **Never let `compile-file` default its output.** Always pass `:output-file` to
   a temp path.
2. **Never compile a DIRECTORY.** Compile exactly the files you own. A blanket
   directory compile writes fasls for *every* source in it, including modules
   another worker is actively editing — that is how a `beautify.fasl` appeared
   beside an agent's sources at the same minute as a peer's `packers.fasl`.
3. **To build someone else's source, use ASDF.** `asdf:load-system` and
   `asdf:compile-system` write to the ASDF cache, which is outside the tree and
   correct. That is the only sanctioned way.

Prove a runner clean by **deleting the artefact and re-running**, not by reading
its source: `rm <file>.fasl` → run → confirm it did not reappear.

`tools/cl/**/*.fasl` and `*.fas` are gitignored, so a stray one cannot be staged —
but gitignored is not harmless, because it still shadows the source at load time.

## The shared ASDF cache: the hazard nobody watches

**Two agents compiling `:vovas-engine` at the same time corrupt each other's
fasls.** This produced three different failures across four runs of unchanged
`zip.lisp` — a 65535-entry archive unreadable, then a corrupted-byte CRC check
failing, then a clean 140/140.

The evidence that settled it:

| test | result |
| --- | --- |
| gate run 4× on the SHARED cache | PASS, PASS, PASS, PASS **after** a purge — but FAIL with shifting assertions before it |
| same gate 3× in ONE image, private fasl dir | PASS, PASS, PASS |
| `deflate-raw` on identical input 5× in one image | byte-identical every time |
| inflate round trip 5× | 5/5 identical |

So `salza2` is deterministic, the port is deterministic, and the variance came
from the cache. **Purging before a verdict is not optional when a live agent may
be building.** The purge that works on this box:

    rm -rf "C:/Users/bigmo/AppData/Local/cache/common-lisp/sbcl-2.6.9-win-x64/C/<repo-path>"

Note the cache root: `AppData/Local/cache/common-lisp`. `~/.cache/common-lisp`
does not exist here, and a stale path in an instruction costs a round.

**Before believing any red verdict:** purge, then re-run. If the failure changes
its name between runs, it was the cache. If it persists identically, it is code.

## What a worker produces

| file | contents |
| --- | --- |
| `tools/cl/engine/<module>.lisp` | the port, in its own `defpackage` |
| `tools/cl/engine/<module>.asd` | an ASDF system `vovas-engine.<module>` depending on `vovas-engine` |
| `tools/cl/engine/gate-<module>.lisp` | `(defun vovas.engine.gate::run-<module>-gate () ...)` returning `T`/`NIL` |
| `tools/cl/engine/wip/run-<module>.lisp` | runnable: loads the system, runs the gate, exits 0/1 |

`gate-<module>.lisp` is loaded by the module's own `.asd` (after the module), so
a worker never edits `package.lisp`, `vovas-engine.asd`, `gate.lisp` or
`run-engine.lisp` — those belong to the integrator, who wires them in at the end.

## Hard rules (each of these cost a real debugging round)

1. **Load order.** LOAD reads one top-level form at a time. Any top-level form
   that mentions `pkg:sym` must come AFTER the form that loads the system, or the
   read fails with "package does not exist". Keep every foreign-package reference
   inside a function body.

2. **No `defconstant` on a string.** It mints a fresh object per compile and
   reloading signals `DEFCONSTANT-UNEQL` even for identical text. Use
   `defparameter`.

3. **Never `(/= nan nan)`.** SBCL *signals* floating-point-invalid-operation.
   Use `sb-ext:float-nan-p`.

4. **UTF-16, not characters.** `(length s)` is wrong wherever the original used
   `.length` or `charCodeAt`. `vovas.engine.util:utf16-length` /
   `utf16-prefix` / `utf16-suffix` / `utf16-substring` exist for this. Index
   arithmetic in a ported scanner is BYTE/CHAR offset in Rust — preserve the
   same unit the Rust used, and say which in a comment.

5. **`~f` is not exact.** It prints the shortest decimal that round-trips, not
   the stored binary value. For anything rounding-sensitive use
   `vovas.engine.number:to-string` / `to-fixed`, or `(rational v)`.

6. **JSON numbers and JZON.** JZON 1.1.4 cannot parse `1.7976931348623157e308`;
   its fallback overflows. Bind `*read-default-float-format*` to
   `double-float` around any parse, and expect the oracle to cross floats as
   bit patterns.

7. **Read a UTF-8 file to EOF**, never `(make-string (file-length s))` +
   `read-sequence`: file-length is BYTES, the stream decodes UTF-8, and any
   non-ASCII fixture leaves trailing NULs that surface as a bogus
   "content after reading element" JSON error.

## The gate must be non-vacuous

A gate that passes proves nothing unless it can fail. For each module:

- assert every case in the oracle, and
- assert at least 3 *plausible wrong implementations* are NOT what the port
  does (this is what caught an off-by-one in `Number::toString` that no oracle
  case reached), and
- assert the case count is > 0, so an empty or mis-read oracle fails loudly.

## The truth source

`unpack-rs/tests/fixtures/text-tier-oracle.json` was captured from
`dist/js/engine.wasm` — the engine that actually ships. It is the specification.
Where the Rust and the oracle disagree, the oracle wins and the disagreement is
worth reporting.

Regenerate (do not edit by hand): `node unpack-rs/scripts/text-oracle.mjs`
