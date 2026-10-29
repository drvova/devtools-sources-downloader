# Self-Improvement Ledger

Append-only. Newest first. One entry per execution-time failure or workflow
defect fixed during a turn: date, seam, root cause, canonical fix, validation.

- 2026-10-29 (making the extension real: load-automation archaeology on the
  DevTools surface): (1) Branded Chrome/Edge IGNORE `--load-extension`
  (Chrome 137 removal persists in Edge 156) - the known-working route is
  Chrome for Testing (`@puppeteer/browsers install chrome@stable`, ~4 s,
  keeps the flag by design); the probe-copy trick (a throwaway manifest with
  a dummy `background.service_worker`) makes "did the extension load"
  OBSERVABLE for extensions that otherwise expose no targets. (2) The
  extension id for unpacked loads = sha256 of the UTF-16LE absolute path,
  first 32 hex nibbles mapped onto [a-p] - verified against a live-observed
  id, which turns `chrome-extension://<id>/...` URLs into deterministic
  targets. (3) A devtools:// page opened via Target.createTarget is NOT a
  real DevTools window to the browser (no extension plumbing), and
  --auto-open-devtools-for-tabs yields a REDUCED frontend that hosts the
  devtools_page (proved via chrome.runtime.getContexts from an injected SW
  oracle: the context EXISTS) but renders NO extension UI - sidebar pane,
  main panel, even ExtensionPanel.show() all fire callbacks while the tab
  strip never gains the entry; conversely the full frontend (manual
  inspector.html URL) hosts no extension pages at all. Conclusion: Chrome
  156 cannot render extension DevTools surfaces headlessly/programmatically;
  automate what the platform exposes (real context, real origin, real
  identity) and leave panel visibility to manual verification. (4) DevTools
  frontend DOM is shadow-DOM end to end - document.querySelectorAll sees
  nothing; a recursive shadowRoot walker (deepAll) reaches real tab titles.
  (5) The stale DevToolsActivePort file from a killed browser reads as a
  dead port on the next launch - delete it before spawn. Validation: new
  test/browser-e2e-extension.mjs drives the REAL unpacked extension (runtime
  id match, getManifest version, graceful off-panel guard, zero console
  errors), scripts/dev-ext.mjs gives the watch+auto-reload loop (reload
  proved live: touch -> "[dev-ext] extension reloaded"), full npm run verify
  green (67/67 + both e2e suites), sidebar pane -> main panel migration in
  src/js/devtools.js (panels.create returns a Promise since Chrome 152).

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

- 2026-10-29 (devtools-unpack: wasm engine integration - the wasm32 span-wrap trap class + five bridge seams): Failure pattern: (1) four JS-suite tests died with bare wasm traps ("unreachable") that x86_64 cargo tests never showed - read/find_jsc_shared_table computed string spans in u32 ((text_length*width) as usize, rec+8+byte_length > end): on wasm32 a garbage u32 length wraps and the WRAPPED SUM passes the bounds check, then the slice start>end panics = trap; the same wrap pattern sat in the wasm section walkers (leb size as usize + at+size > len). Fix: u64 span math in jscbytecode.rs (both fns) and wasm.rs (3 sites: u64 compare against (len-at) before any narrowing) - x86_64 behavior unchanged (cargo test stayed 77/77), wasm32 traps gone. (2) The bridge (src/js/unpack-bridge.js) hit four browser/node seams in sequence: static `import 'node:fs'` fails the rspack browser build outright -> process.getBuiltinModule('node:fs') + a hand fileUrlToNativePath (percent-decode + drive-letter slash strip); `new URL(<literal>, import.meta.url)` is rspack's static-asset pattern -> the bundler emitted a SECOND engine.wasm as dist/static/wasm/*.module.wasm -> the specifier must be a runtime VARIABLE (adjacent string literals constant-fold, so 'a'+'b' still gets detected); async bootstrap raced the tests ("engine not initialized") -> WebAssembly.Module/Instance are synchronous: load bytes at import (XHR on the extension origin, fs in node) and compile inline; callRaw freed the result buffer with len 0 (Vec::from_raw_parts on a capacity-N alloc = allocator UB) -> free with the REAL outLen in the finally. (3) JS closures cannot cross the wasm boundary: fetchText -> static `fetchMap: {url: text}` consulted by wasm_fetch_text via a thread_local (HostOptions, null-tolerant deserialize_with - an explicit null fails HashMap deserialization and ERRORS EVERY UNPACK ARM, 12-test regression); parseSealedV8 inflator fn -> {inflate:'throw'} sentinel arm; onProgress -> one final (total,total) tick after the atomic batch. (4) serde camelCase leaks (header.declaredLength/cache.payloadLength/hit.arrayId/info.moduleName came through snake): rename_all="camelCase" on JscHeader/V8CodeCache/StringArrayDetected/Wasm{ModuleInfo,Section,Import,Export} - safe because the rust tests assert struct fields or hand-shaped artifact JSON, never raw serde of these types; sha256HexBytes empty input returns null (the arm's ok_or threw instead). Proof: full gate green in one pass - cargo test 77/77, clippy -D warnings clean, engine.wasm 1709KB release, JS suite 67/67 against the wasm bridge (tests exercise the SHIPPED artifact), rsbuild bundle carries the bridge + js/engine.wasm with 'wasm-unsafe-eval' CSP, no duplicate wasm emission, lint clean.
