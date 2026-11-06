# Handoff

Written 2026-11-06. Everything below was verified against the tree at `a9aeaa9`, not
recalled. Where something is *unverified*, it says so.

## State

| | |
| --- | --- |
| HEAD | `a9aeaa9` — wiki: the digest vectors and the confidence-tie test that can now fail |
| Working tree | clean |
| `cargo test` | green — 68 unit + 86 integration |
| Wiki | `.wiki/`, 1987 lines, seven pages, all internal links resolving |

The tree was green when this was written. The **browser suites were not run** in this
session — `npm run test:e2e` and `npm run test:e2e:ext` need Chrome, and `npm run verify`
(the full seven-step gate) was never executed end to end here. Run it before trusting a
release.

## What this project is

A Chrome DevTools extension that captures everything an inspected page loads and runs, then
exports one unpacked, site-aware `sources.zip`. The unpacking engine is Rust compiled to
WebAssembly; the extension is a thin JavaScript platform layer.

Read `.wiki/Home.md` first. It is current and it is the map.

## What was done in this session

1. **Wrote the wiki** — seven pages, 1987 lines, derived by reading all 31 source modules
   rather than their doc comments. That mattered: five claims from an earlier draft were
   wrong and only reading the implementations caught them.
2. **Kept it current through seven refactors** — "Untangle" passes 10–16 landed while the
   wiki was being written, and each invalidated something:
   - pass 10: the page world's default-strategy copy was deleted; the strategy now rides in
     the injected policy. The wiki had claimed the two copies were held together by a test.
   - pass 11: the GraphQL body predicate became one pattern compiled on both sides.
   - pass 12: the JSC `enter` opcode became a table lookup; the `sourceURL` pattern is
     written once.
   - pass 13: ten page-world globals collapsed into one `window.__CAPTURE__` channel.
   - pass 14: two whitespace sets, named for which one they are.
   - pass 15: `panel/paths.rs` — every archive path spelled once, plus one presence rule.
     This surfaced a whole `_framework/` archive block the wiki had never documented.
   - pass 16: two tests that could not fail now can.
3. **Fixed the todo cell** (`~/.nodecode/cells/nodecode-todo/cell.lisp`) — five bugs, one of
   which explained the others. Details in `agent/ledger.md`, newest entry.

## Where the bodies are buried

These are the things that cost time, so they are worth knowing before they cost it again.

**The tree is edited by another agent.** Throughout this session a second agent was
committing "Untangle" passes into the same working tree. Consequences:

- A single `grep` is a snapshot, not a fact. Twice I reported a break that was really a
  read racing an in-flight edit. **Wait for five consecutive unchanged `git status` samples
  before quoting anything as fact.**
- Committing with `git add <path>` is safe; `git add -A` would have swept their
  in-progress work into my commit. One of their commits did sweep my `.wiki/` files in, so
  `git log -- .wiki` attributes most of the wiki to the wrong message. The content is
  correct.
- Their passes land uncommitted and sit for minutes. Uncommitted ≠ broken; check
  `cargo check` before assuming.

**`panic = "abort"` on wasm.** A panic is a trap, not an unwind — `catch_unwind` cannot
catch it. The dispatcher records the message before trapping and `xu_call("lastFailure")`
reads it back. Do not "fix" this by adding `catch_unwind`.

**Falsy-zero is deliberate.** `max_depth: 0` means "use the default", because the JavaScript
said `opts.maxDepth || LIMITS.maxDepth`. Every such site is commented. Changing one is a
behaviour change, not a cleanup.

**Two whitespace sets.** `is_ascii_js_space` (ASCII subset, used by every scanning pattern)
and `is_ecmascript_whitespace` (full `\s`, used only by `ToNumber`). Widening the ASCII one
would silently change what every scanner pattern matches. Two tests hold them apart.

**One definition per rule.** The `Tool` enum is the only place a layer name lives; the
capture policy has one home; path-hostile characters have one definition; archive paths live
in `panel/paths.rs`. Renaming anything is a compile error at every use — that is the point,
not an accident.

**The todo cell's `setf (getf …)` trap.** `(setf (getf item :key) v)` on a *local binding*
does not update the sheet when the key is absent: `getf` answers a fresh list head, the
variable rebinds, the sheet keeps the old cons. Field writes go through `set-item-field` /
`rem-item-field`, which find the item's tail **in** the sheet. Any new verb must do the same.

## Open work

Nothing is half-finished. The wiki is current, the tree is clean, the cell works.

Worth doing next, in rough order of value:

1. **Run `npm run verify`.** The full gate has not been executed in this session. It is the
   one claim above that rests on the individual suites rather than on the gate itself.
2. **`npm run build` then load `unpack-rs/dist/` in Chrome** and click Download All on a
   real page. Everything is verified by tests; nothing here was verified by hand in a
   browser.
3. **`PORTING.md` is 37 KB and predates the panel port.** It is accurate where it was
   updated (pass 10 rewrote its strategy section) but it is now a second, older description
   of the same system as the wiki. Consider folding anything still unique into `.wiki/` and
   retiring it, rather than maintaining two.

## Conventions this repo actually uses

- Commit before ending a turn; the message states *what was wrong*, not just what changed.
- `agent/ledger.md` is append-only, newest first, one entry per execution-time failure:
  date, seam, root cause, canonical fix, validation. Entries name the probe that proved the
  fix, including probes that failed for the wrong reason.
- Wiki claims are measured, not remembered. Every count in `.wiki/` was re-derived from the
  tree; if you change a count, re-derive it.
- `rs check` runs lint **and** format before every toolchain step, so a hand-written JS edit
  needs `npx rs check --fix` as its own last step.
