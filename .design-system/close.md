# Close: main at 6f5e40a

| Count | Unit | Before | After | Source |
| --- | --- | --- | --- | --- |
| token source files | files | 0 | 1 | `triage/signals.tsv`, `triage/after/signals.tsv` |
| hex values in the banner source | occurrences | 11 | 0 | `git show HEAD~1:assets/banner/banner.ts`, `assets/banner/banner.ts` |
| renderer warnings on the settled frame | warnings | 2 | 0 | `assets/banner/review/review.json` (before: font bytes unresolved), `clayzo render-frame` after |
| review errors | errors | 0 | 0 | the same |
| review warnings | warnings | 0 | 0 | the same |
| banner bytes | bytes | 43142 | 42923 | `git show HEAD~1:assets/banner.png`, `assets/banner.png` |
| poster test at 360 px | verdict | passes | passes | `assets/banner/poster360.png` |
| surfaces changed | surfaces | | 1 of 1 (the banner) | `assets/banner.png` |
| gates applied | gates | | 0 (2 open, defaults applied) | `state.md#gates` |

## Still raw
- `assets/banner/banner.ts` holds no colour values at all; every colour, face,
  tracking and duration is read from `assets/tokens.json`. The remaining raw
  numbers are geometry (canvas size, ring diameters, text positions), which the
  design language does not tokenise and which belong to the composition.
- `docs/design/dither-ui.md`'s palette (obsidian, bone, ember) is NOT in
  `tokens.json`: that language is the secondary reference and the banner follows
  SIF. Adding a second palette nobody renders would be a token with no consumer.

## Montage warnings
none (no montage on this route; one surface, captured as `assets/banner.png`)
