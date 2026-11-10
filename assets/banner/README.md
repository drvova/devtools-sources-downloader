# The README banner

`../banner.png` is rendered from `banner.json`, authored in `banner.ts` with
[Clayzo](https://clayzo.dev). The design language is **Sculptural Industrial
Futurism** (`docs/design/sculptural-industrial-futurism.md`) — the early-2000s
industrial design language, not the eyewear: a machined member with one raised
bezelled junction and a single optical accent, presented as a precision studio
plate.

## Re-rendering

```bash
npm install --global clayzo        # once
clayzo init --yes                  # in a scratch project, installs @clayzo/animation
bun banner.ts                      # writes banner.json
clayzo render-frame banner.json ../banner.png --tick 600 --full-resolution
```

`--tick 600` is the settled frame (the piece enters over the first 1.4 s and
holds). `banner.json` is committed so a render needs no authoring step.

## The faces

Both are SIL OFL and self-hosted beside the document:

- **Space Grotesk** (variable) — the display face, the wordmark.
- **IBM Plex Mono** — the metadata line.

## The design decisions, in one place

| Choice | Why |
| --- | --- |
| Carbon `#0B0E11` ground | the studio backdrop; the object is lit, the field is not |
| One tapered member | "long, low, directional silhouettes" — the silhouette is the identity |
| Thin tips, swelled junction | tension between the thin architectural span and the sculptural mass |
| Elliptical bezel + recess | the era's aerodynamic ellipse; two concentric rings read as construction |
| Optic-cyan `#62CFDE` inset, ~3% | one optical accent at the 75/20/5 ratio; never a colour field |
| Space Grotesk, uppercase, +2 tracking | a compact geometric grotesk, technical not decorative |
| Plex Mono spec line | real measured figures only — 26 modules, 49 arms, 48 gates, 2,729 assertions |
| `cubic-bezier(0.2, 0.7, 0.2, 1)` | decisive travel, soft settling, no overshoot |
