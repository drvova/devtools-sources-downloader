# The README banner

`../banner.png` is rendered from `banner.json`, authored in `banner.ts` with
[Clayzo](https://clayzo.dev).

## The design language

**dither-ui** (`docs/design/dither-ui.md`), fused with the Sculptural
Industrial Futurism form language. dither-ui's identity line is the brief:

> *"A printed thing in the dark: one bone ink on obsidian, a fine grain, the
> kit's Bayer dither as the only art, a monospace voice, and an extended
> display face for the few words that lead. Engineered, never decorated."*

So the plate is **printed, not lit**:

- obsidian `#101214` ground, bone `#E4E1D8` ink, muted `#9C998F` second ink;
- the aperture is drawn as flat rings and then run through the kit's ordered
  dither — **the dither IS the art**, so there are no gradients on it;
- one signal, the ember `#FF9632`, as the optical slit;
- **Michroma**, the extended display face, for the wordmark only;
- **IBM Plex Mono** for the spec line, the print's voice;
- the grain covers the page, because the dither samples the drawn surface.

Bans held: no neon, no cyberpunk HUD, no arbitrary pixel grids, no fake CRT
artifacts, no chrome text everywhere, no noisy RGB gradients, no red, no
meaningless technical labels.

## Tokens

Every colour, face, tracking and duration comes from **`../tokens.json`** (DTCG,
codified from both design languages). `banner.ts` imports it and reads each value
through a guard, so a malformed token fails loudly instead of rendering as
`undefined`. No hex is restated in the banner source.

## Re-rendering

```bash
npm install --global clayzo        # once
clayzo init --yes                  # in a scratch project, installs @clayzo/animation
bun banner.ts                      # writes banner.json
clayzo render-frame banner.json ../banner.png --tick 600 --full-resolution
```

`--tick 600` is the settled frame (the plate prints over the first 1.2 s and
holds). `banner.json` is committed so a render needs no authoring step.

## The faces

Both are SIL OFL and self-hosted in `fonts/`:

- **Michroma** — the extended display face, the wordmark.
- **IBM Plex Mono** — the metadata line.

## The decisions, in one place

| Choice | Why |
| --- | --- |
| Obsidian `#101214` ground | dither-ui's page; the print, not a lit screen |
| Flat rings, then one dither | the dither is the only art; a gradient would only band at 3 levels |
| Three concentric rings + recess | two rings read as construction; one oval reads as a pebble |
| Ember slit, ~1% | dither-ui's single signal: "the one thing that is live or hot" |
| Michroma, bone | the extended display face for the few words that lead |
| Plex Mono spec line | the print's voice; real measured figures only |
| Dither amount 0.35, 3 levels | "a tone under and over the ground", not a screen over the page |
| `cubic-bezier(0.2, 0.7, 0.2, 1)` | decisive travel, soft settling |
