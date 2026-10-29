# Self-Improvement Ledger

Append-only. Newest first. One entry per execution-time failure or workflow
defect fixed during a turn: date, seam, root cause, canonical fix, validation.

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
