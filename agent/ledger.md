# Self-Improvement Ledger

Append-only. Newest first. One entry per execution-time failure or workflow
defect fixed during a turn: date, seam, root cause, canonical fix, validation.

- 2026-10-29 (panel rewire onto the wasm bridge: an orchestrator's contract is the pair of both sides, and a browser gate that cannot name its cause is not a gate): Failure pattern: rewiring `page.js` onto the wasm panel surface left three silent seams that only the real-browser gate exposed, and the gate itself was blind to the first of them. (1) The finalize arm returned `{files, report}` while the panel reads `result.summary` for its status line - so the export COMPLETED correctly and the UI reported nothing; the e2e timed out with an empty status and no console output, which reads exactly like a hang. (2) The asset contract was split across the two sides: the JS pushed `{url, zipPath, bytes: Uint8Array}` while the arm's `ScriptInput` reads `content` (string = text, byte values = binary), and `JSON.stringify` of a `Uint8Array` is an index-keyed OBJECT, not an array - so a V8-code-cache resource arrived as an empty TEXT asset, the report counted it as text with zero stages, and `cache-header.json`/`strings.json` were never written (the browser zip showed the raw `chunk.jsc` from the JS raw-write and no `_unpack/0001-*` root at all). (3) The rewire dropped the original's `.catch`, so a throwing export became silent instead of reporting "Unpacking failed: ...". (4) The gate's own blindness: module-load failures surface in the CDP **Log** domain, not as `Runtime.exceptionThrown`, and the collected console errors were only printed on the SUCCESS path - so every failure printed "export did not complete within 60s; last status: " with no cause, and the actual 404 was the test server's own favicon. Better behavior: when replacing a JS orchestrator with a cross-language one, treat the payload contract as a PAIR and pin it - grep the arm for the field names it deserializes and the JS for the keys it sends, and prefer ONE field whose type carries the meaning (here `content`: string or bytes) over parallel `content`/`bytes` fields that can disagree; normalize the encoding on the receiving side (accept both the array and the numeric-keyed object a typed array serializes to) so the caller cannot hold the wrong shape; keep the error path the ported function had (a silent failure is a regression, not a simplification); and make the harness name its cause before failing - watch the Log domain alongside Runtime exceptions, print the collected errors in the FAILURE branch, and dump the produced artifact's entry list on an assertion failure. Corollary: an assertion written against an older fixture URL (`chunk.jsc.js` vs `chunk.jsc`) hides the real defect behind a wrong expectation; when an artifact assertion fails, dump the actual entries first and read the path from the product, not from the test's memory. Validation: probe the bridge in node with the real `v8-codecache.jsc` fixture (binary kind, 1 stage, `_unpack/0001-demo.test__app__chunk.jsc.js/{cache-header,strings}.json`), pin the contract with `panel::assets` unit tests for both byte shapes plus string-stays-text, then `browser-e2e.mjs` PASS on real Chromium over CDP: status "Export ready. Unpacked 3 of 3 scripts", 63 zip entries (15 under `_unpack/`), binary cache-header/strings asserted, plus cargo build/test/clippy (58 + 67), rs lint/test (67), commit 0f7f888.

- 2026-10-29 (panel export port: verify an orchestrator by census when the oracle cannot run, and read the guard's polarity from the source): Failure pattern: `finalizeZipWithRecon` could not be oracle-driven (its analysis step calls the wasm engine, which the JS harness does not load), and the temptation was to either skip verification or hand-assert a path list from memory. Two further traps sat in the same function: the runtime unpack prefix is hardcoded at the JS call site (`'_unpack-runtime'`) so reusing the caller's options prefix silently put both passes under `_unpack` (the test caught it as "runtime unpack pass wrote nothing" only because it asserted on the prefix), and `collectRuntimePayloads` skips entries that report NO payload - the entries it fetches are the ones that DO report one, which is the opposite of what "only fetch what is missing" intuition suggests. Better behavior: when a whole-function oracle is impossible, replace it with a labelled source census (extract the literal output paths from the source in source order into the fixture under a `sourceCensus` key, and have the test assert the port writes exactly that set in that order for a maximal input), plus behavioural tests for the guards, the fallbacks and the assembly - and say in the fixture and the test that this one is a census, not a runtime oracle. Derive each guard's polarity by reading the JS condition verbatim rather than from what the name suggests, and assert the discriminating observable (a path prefix, an order) instead of a count that the engine owns. Proof: the census test covers all 17 censused paths in order (including the GraphQL and DOM-snapshot ones, which needed a GraphQL-shaped fetch entry and a page snapshot to fire), the guard test covers empty/missing sections, the DOM snapshot test covers the recon-page vs snapshot-title fallback, and the full-run test asserts each stage's files, their order and the merged totals (assets summed to 2 across both passes); 54 lib + 67 integration tests green, clippy -D warnings clean.
- 2026-10-29 (panel report port: byte-exact HTML needs insertion-order JSON, JS-unescaped literals, and oracle-shaped fixtures): Failure pattern: three separate fidelity traps surfaced only because the oracle compares whole documents byte for byte. (1) The console embeds the analysis as an inline JSON blob, so `serde_json`'s default alphabetically-sorted map produced a document whose keys were reordered - same data, different bytes; fixed at the root by enabling `serde_json`'s `preserve_order` feature (insertion order everywhere, matching `JSON.stringify`), which also makes every report/artifact JSON file byte-identical. (2) Transcribing JS string literals into Rust raw strings silently kept the JS escape backslashes (`\'` inside a single-quoted JS string is the VALUE `'`, not backslash-quote), so the generated client script was one character off per occurrence; the extractor must UNESCAPE JS string escapes (`\'` `\"` `\\` `\n` `\t` `\r`) after capture, and the oracle diff is what reveals it. (3) A test fixture that omits fields the oracle's own helper fills with defaults diverges in the embedded JSON, and a fixture that builds numbers with `json!(0.0)` prints `0.0` where JS prints `0`; fixtures must mirror the oracle's construction (every field present) and route numbers through the crate's `js_number_value`. Corollary for editing long generated files: splicing a new array into an existing file by searching for the first `];` cuts inside a string literal that contains `];` (e.g. `data.journeys||[];`) - regenerate the whole file from the extractor instead of splicing, or anchor on a structural marker. Proof: after all three fixes the investigation console matches the JavaScript byte for byte at 12078/11764/11741 characters, the waterfall page at 13044 (timestamps normalized) and the request table at 1670; 46 lib + 67 integration tests green, clippy -D warnings clean.
- 2026-10-29 (panel port: a range splice defined by ONE grep hit deleted the
  wrong span): replacing a contiguous block of `src/panel/assets.rs` by an index
  range derived from a single `grep -n` hit for the block's doc comment left the
  old functions in place - the file's declaration order was not the order
  assumed, so `determine_runtime_origin_type`/`score_runtime_entry` (which sit
  ABOVE the struct they take) survived and the build failed with "defined
  multiple times" plus `no field ... on type &Value`. A grep hit locates a LINE,
  never a block boundary. Canonical fix: assert BOTH ends of a range splice
  against their expected content and print the boundary lines before writing
  (the second assert is what reported the real line), compile immediately after
  the splice, and remove a surviving remnant by re-locating it from its own
  unique doc comment instead of re-deriving indices. Validation: build clean,
  `cargo test --lib panel` 20/20, `cargo clippy --lib -- -D warnings` clean.
- 2026-10-29 (serde_json `json!` rejects method chains in value position): the
  macro's value grammar is restricted, so `.iter().find_map(...)` inside
  `json!({...})` is a macro syntax error ("no rules expected `.`"), not a type
  error. Canonical fix: bind each multi-step value to a local before the
  `json!` call (or parenthesize the whole expression); locals read better
  anyway. Validation: build clean, `cargo test --lib panel::graph` 2/2 against
  the node oracle.
- 2026-10-29 (JSON fidelity: `JSON.stringify` never prints `8.0`): comparing a
  ported pipeline against node oracles failed on `Number(8.0)` vs `Number(8)` -
  serde's f64 serialization keeps the fraction while JavaScript drops it, and
  serde_json's `Number` equality is representation-based, so the mismatch is
  real output divergence, not a test artifact. Canonical fix: one JS-number
  serializer/valuer pair (`serialize_js_number` / `js_number_value`: whole
  values print as integers, non-finite values as `null`) applied to every f64
  that reaches a report, plus the same treatment in hand-built `json!` rows.
  Validation: `cargo test --lib panel` 20/20.

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
