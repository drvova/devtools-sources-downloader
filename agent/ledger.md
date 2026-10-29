# Self-Improvement Ledger

Append-only. Newest first. One entry per execution-time failure or workflow
defect fixed during a turn: date, seam, root cause, canonical fix, validation.

- 2026-10-29 (webpack -> rstack CLI migration on the MV3 extension): four
  seams, all caught by the artifact-baseline discipline. (1) Rsbuild's
  `output.copy` runs copied .js/.css through the rspack minimizer BY DESIGN
  (rust builtin CopyRspackPlugin; the binding's own doc names the escape):
  a "copy" of bulma.min.css shrank 4.7 kB with autoprefix reordering. The
  documented fix is `info: { minimized: true }` on the pattern; module-rule
  filtering does NOT help because the transform lives in the copy plugin.
  (2) rslint's jsonline columns are 1-based pointing at the ESCAPED char, so
  the removable backslash is at column-1 (0-based) - a naive index produced
  guard-fails; and rslint's `no-useless-escape` MISFIRES on JS-in-JS payload
  strings: in single-quoted literals wrapping double-quoted payload code,
  removing an "unnecessary" `\"` ADDS a quote char to the runtime value
  (empirically `"\"":"&quot;"` -> `""":"&quot;"`, silently corrupting an
  HTML-escape map). Rule scoped off with the evidence in the config comment;
  guard scripts must verify string VALUES, not just byte positions. (3) The
  formatter's ignore list must cover copy-contract INPUTS (src/html,
  src/css, manifest.json), not just output mirrors - reformatting them
  propagates into dist through the byte-copies and breaks the contract one
  step after the check passed. (4) The extension artifact contract survives
  rsbuild only with: unhashed `[name].js` filenames, `splitChunks: false`,
  html plugin deletion via the rspack config object (tools.rspack receives
  the config object, not a chain; html emission defaults to dist/html/ and
  would COLLIDE with the copied src/html files). Validation: dist tree
  14/14 files, all copies byte-identical to the webpack baseline sha256s,
  67/67 Rstest, e2e in real Chrome byte-identical observable outputs
  (63 zip entries, same unpack counts), `rs check` green after a measured
  printWidth 100 / tabWidth 4 / singleQuote formatter pass (churn curve
  plateaued past 100; tab-width mismatch alone was +2.3k diff lines).

- 2026-10-28 (devtools-unpack JS->Rust port, 67-case parity debugging): five
  seams in one round, each a different port-hazard class. (1) JS verbatim
  transcription requires ENDIAN ARBITRATION: `wtfStringHash`'s helper is
  named `read32Big` but its loop builds LITTLE-endian words; porting by name
  (from_be_bytes) made every hash wrong (moduleLoader 0xba832a vs truth
  0x27d79d) and silently zeroed recoverJscStrings (the prove-by-hash step
  never matched). Canonical rule: transcribe JS readers by their LOOP, never
  by their name. (2) `unpack_packer` used `?` on the SECOND iteration's
  detect miss, propagating None as the function result where JS `break`s and
  still returns the peeled text; the loop-control operator is behavior, not
  sugar. (3) `find_source_map_ref` stored the STRIPPED data: payload in
  Inline.value while the decoder regex re-matches `^data:...` — producer and
  consumer must agree on whether the token survives the parse; keep the full
  string exactly like the JS object literal. (4) The JSFuck interpreter
  modeled `target[key]` as a method-name dispatch only: digit keys on strings
  and arrays fell through to Undefined ("NaN"[0] -> 'N' is the whole point
  of the recipes); a numeric member read needs canonical-index handling
  ("0" yes, "00" no), and unwrapToPrimitive must send functions/regexes to
  their SOURCE STRING (`true + [].at` spells the fn text — the 'o' recipe).
  The encoder side had its own transcription bug: four MAPPING rows
  (b, j, [, ]) dropped the `()` call on `[]["entries"]()` — 2 chars each,
  caught by byte-diffing against node-run fixture output rather than by
  reasoning. (5) Test-side bug class: a helper that maps Binary stages to
  `detail` and Text stages to `tool` silently breaks tool-name assertions on
  binary stages (split stage_tools/stage_details), and base64-of-binary built
  through `String::from_utf8_lossy` corrupts the payload (lossy replacement
  chars) — encode raw bytes. Validation: 67/67 integration + 10 lib green,
  `cargo clippy --all-targets -- -D warnings` clean, encoder outputs
  byte-identical to node oracle in all three wrap modes.
