# The README banner

`../banner.png` is rendered from `banner.json`, authored in `banner.ts` with
[Clayzo](https://clayzo.dev).

## The design language

**Sculptural Industrial Futurism** — `docs/design/sculptural-industrial-futurism.md`,
the early-2000s industrial design language, not the eyewear. §12 is the brief:
*"a past era's optimistic prediction of future hardware: silver materials,
elliptical geometry, flowing forms, visible mechanisms ... discard arbitrary
pixel grids, fake CRT artifacts, chrome text everywhere, meaningless technical
labels."*

The banner is **the era's aerodynamic ellipse**: a machined aperture built from
three concentric rings and a recessed core, with one optical slit. Object left,
type right, one thin alignment rule between them (§7 "planes", §14 poster).

## Tokens

Every colour, face, tracking and duration comes from **`../tokens.json`** (DTCG
format, codified from the design language). `banner.ts` imports it and reads
each value through a guard, so a malformed token fails loudly instead of
rendering as `undefined`. No hex is restated in the banner source.

## Re-rendering

```bash
npm install --global clayzo        # once
clayzo init --yes                  # in a scratch project, installs @clayzo/animation
bun banner.ts                      # writes banner.json
clayzo render-frame banner.json ../banner.png --tick 600 --full-resolution
```

`--tick 600` is the settled frame (the piece assembles over the first 1.2 s and
holds). `banner.json` is committed so a render needs no authoring step.

## The faces

Both are SIL OFL and self-hosted in `fonts/` beside the document:

- **Space Grotesk** (variable) — the display face, the wordmark.
- **IBM Plex Mono** — the metadata line.

## The decisions, in one place

| Choice | Why |
| --- | --- |
| Carbon `#0B0E11` ground | the studio backdrop; the object is lit, the field is not |
| One elliptical aperture | the era's aerodynamic ellipse; one memorable silhouette |
| Three concentric rings + recess | two rings read as construction; a single oval reads as a pebble |
| Optic-cyan slit, ~3% | one optical accent at the 75/20/5 ratio |
| Object left, type right, one rule | §7 planes; §14 poster: one dramatic scale shift |
| Space Grotesk uppercase +2 tracking | a compact geometric grotesk, technical not decorative |
| Plex Mono spec line | real measured figures only — 26 modules, 49 arms, 48 gates, 2,729 assertions |
| `cubic-bezier(0.2, 0.7, 0.2, 1)` | design.md §8: decisive travel, soft settling |
