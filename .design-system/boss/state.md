# Design system run: devtools-unpack (README surface)

## Ask
> still looks like shit
Received 2026-11-09.

## Triage
State: **empty** (routes 0, product_component_defs 0 — rule 4; there is no app UI at all)
Intent: **seed** (the ask matches no intent row; the fallback for `empty` is seed)
Foundation: **raw** — no UI library, no `components.json`, no `package.json`, no CSS.
  The brand material is the two design languages in `docs/design/` and the banner.
Host: subagents yes, browser yes (Edge/Playwright), shell yes. Not flat.
Signals: `triage/signals.tsv` (37 rows). Recorded fallback: `rg` is a shell
  builtin in this harness, not a binary, so `scripts/triage.sh` refuses to run;
  the documented grep fallback in `references/triage.md` produced the file.
Question: none. The repo has no app to target and no migration to clear.
Bans: none named. The design languages carry their own bans and they stand:
  no neon, no cyberpunk HUD, no arbitrary pixel grids, no fake CRT artifacts,
  no chrome text everywhere, no meaningless technical labels, no red.
Design source: the two supplied languages — `docs/design/sculptural-industrial-futurism.md`
  (primary) and `docs/design/dither-ui.md`. The look goes **in place**: the
  banner and the README are the only surfaces, so a second folder would be a
  folder nobody renders.
Answer:

## Route
**Seed.** Steps copied from `references/routes.md` (Seed) on 2026-11-09:
1. `build-design-system`, seed mode — receives the brand material, the
   foundation (`raw`) and the budget. Done when the handoff lists every brand
   value as a gate with its default, and the spec check passes on the seed
   components.
2. Check the system, as Build step 4.
Branch: `main` (the person's own branch; the repo has one branch by policy and
  the work is additive). No migration to clear.
Clearance: n/a (no migration on this route).

## Budget
Session 1h from 23:20. Phase caps from `routes.md`:
- triage and Frame 5%, 3m (23:23)
- seed, with the pilot 65%, 39m (00:02) — no migration on this route
- decided defaults 15%, 9m (00:11), reserved
- close 15%, 9m (00:20), never cut
No new writing step after 00:02 (70%).

## Standing orders
1. The person's words win over every default: "more like oakley 2000's but not
   focusing on the glasses, just the actual design language of the year and age"
   and "still looks like shit".
2. The design languages in `docs/design/` are the criteria, ahead of any
   sibling default. `sculptural-industrial-futurism.md` §12 is the brief.
3. No number in a report that no row in `close.md` holds.
4. One writer per file. The boss records; workers write.
5. Never ship a new visual direction nobody chose: the direction is chosen —
   SIF, in place.

## Steps
| # | Step | Skill | Status | Record | Verdict | Evidence |
|---|---|---|---|---|---|---|
| 1 | Seed: tokens + the banner as the seed component | build-design-system (seed mode), boss holds the seat | doing | `.design-system/run.md` | | |
| 2 | Check the system | boss | todo | | | |

## Decisions
| When | Decision | Why | Evidence |
|---|---|---|---|
| 23:20 | Route Seed, not Build | state empty: 0 routes, 0 components, 0 token files | `triage/signals.tsv` |
| 23:20 | Foundation `raw`, not the shadcn default | there is no app to seed shadcn into; the brand material is the two design languages | `triage/signals.tsv`, `docs/design/` |
| 23:20 | The banner is the pilot | it is the only rendered surface in the repo | `README.md`, `assets/banner.png` |
| 23:20 | Boss holds the seed seat | the seed is one component and one token file; a fan-out would be three agents on one file | `references/routes.md` (Small app) |

## Gates
| ID | Question | Default | Status | Commit | From |
|---|---|---|---|---|---|
| G-01 | Keep the current banner composition or replace it with the era's elliptical aperture? | replace | default (unanswered) | | Frame, this run |
| G-02 | Does the token source ship as CSS custom properties, a JSON token file, or both? | both, CSS as the source and JSON generated | default (unanswered) | | Frame, this run |

## Resume
Next action: write `assets/tokens.css` from the design languages and rebuild
`assets/banner/banner.ts` to read it, then render and check.

## Report
