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

## Verifying a change: the working tree is not the committed tree

A passing suite proves the WORKING TREE and nothing else. Three separate defects
in one session were only visible by extracting `git archive HEAD` and running from
that:

- a module wired into `vovas-engine.asd` but never committed (jsfuck.lisp), so a
  clean clone could not load the system at all
- a fixture committed one generation stale: 56 cases / 11 captured in git versus
  60 / 16 on disk, with the gate's floors raised to the newer numbers, so only the
  working tree could pass
- a FALSE GREEN: the first clone test reported 16 PASS because `cd` into the
  extracted directory had silently failed and the run executed against the
  original checkout

**The `cd` fault is real and must be proven, not assumed.** `cd` into a
subdirectory of this repo fails intermittently in the bash layer — absolute path,
relative path, trailing slash, `pushd` all have been observed to fail while
`stat`/`ls`/PowerShell report the directory fine and `Get-Location` works. When it
fails, the shell stays where it was and the next command runs against the WRONG
tree, silently.

So any test whose meaning depends on the cwd must PROVE the cwd:

    pwd; printf 'files here: %s\n' "$(ls tools/cl/engine/*.lisp | wc -l)"

and if `cd` refuses, use the other layer:

    powershell -NoProfile -Command "Set-Location '<abs>'; ... ; Write-Host \$LASTEXITCODE"

A run that reports success from an unverified cwd is not evidence, and it is the
same shape as the `/dev/null` zero: a failed operation that yields a plausible
result.

## A zero from a probe that can fail to run is not evidence

Four instances this session, all producing a confident wrong answer:

| probe | what it reported | reality |
| --- | --- | --- |
| `cmd 2>/dev/null \| wc -l` | 0 fasls | 12 — `/dev/null` does not exist here |
| `find ... \| wc -l` after a failed purge | clean cache | stale fasls served old code |
| a gate whose only assertion cannot fail | PASS | asserts nothing |
| `rmdir` on a directory that would not delete | silence | residue left behind |

The pattern: a command that fails LOUDLY is fine. A command that fails and
returns a plausible value is indistinguishable from success until something
downstream disagrees. Measure with the error stream attached, and prefer three
independent methods over one.

## Writing prose with backticks: use a file

An inline heredoc lets the SHELL interpret backticks as command substitution. A
commit message containing `packed` had that word silently removed and replaced
with the empty output of a nonexistent command, and the commit succeeded - so the
loss was invisible unless the message was re-read.

    cat > /tmp/msg.txt <<'MSGEOF'
    ... prose with `backticks` ...
    MSGEOF
    git commit -F /tmp/msg.txt

The quoted heredoc delimiter (`<<'MSGEOF'`) is what stops expansion. Verify by
re-reading: `git log -1 --format=%B | grep <a phrase that was backticked>`.
