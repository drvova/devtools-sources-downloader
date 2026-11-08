// pipeline-oracle-extra.mjs — the pipeline oracle's three missing tiers.
//
// `pipeline-oracle.mjs` captures `unpackAsset` over TEXT-only assets, which
// leaves the whole binary ladder (wasm / V8 code cache / JSC bytecode / sealed
// brotli), the batch entry points (`unpackAssets`, `unpackAssetsForZip`) and
// `looksBinaryScript` unpinned. All four are reachable from the shipped engine
// and the crate's own binary fixtures are on disk, so leaving them structural
// would be a choice, not a constraint.
//
// Three fixtures, because they answer different questions:
//
//   pipeline-binary-oracle.json  one asset, real fixture bytes -> the bytes path
//   pipeline-batch-oracle.json   many assets -> shared JSC table discovery,
//                                totals, the zip seam's report
//   pipeline-probe-oracle.json   the small predicates (`looksBinaryScript`,
//                                `assetSlug` on regex-edge URLs) and the
//                                UTF-16-vs-bytes unit probe
//
// DETERMINISM. `unpackAsset`/`unpackAssets` are clock-free. The zip seam is not:
// `unpackAssetsInto` stamps `unpackedAt` from the host clock, so its two
// timestamp fields are replaced with the literal `<unpackedAt>` and the gate
// substitutes a fixed stamp back in. Nothing else in these fixtures varies.
//
// Regenerate with:
//   cd unpack-rs && node scripts/pipeline-oracle-extra.mjs

import { writeFileSync, readFileSync } from 'node:fs';

const bridge = await import('../src/js/unpack-bridge.js');

const readBytes = (name) => new Uint8Array(readFileSync(new URL(`../test/fixtures/${name}`, import.meta.url)));
const b64 = (bytes) => Buffer.from(bytes).toString('base64');
const write = (name, value) =>
    writeFileSync(new URL(`../tests/fixtures/${name}`, import.meta.url), JSON.stringify(value, null, 1) + '\n');

const CLOCK_SENTINEL = '<unpackedAt>';

// ---------------------------------------------------------------- text inputs
const plain = `var a = 1;
// a comment
var s = "hello world, a string here";
console.log(a, s);`;

const evalWrapped = 'eval(function(p,a,c,k,e,d){return p}("payload here",62,1,0,0,0));';

const bundle = `var __webpack_modules__ = {
  42: function (module, exports, __webpack_require__) {
    module.exports = 42;
  },
};
//# sourceURL=webpack://app/./src/add.js`;

const mapJson = JSON.stringify({
    version: 3,
    sources: ['app.ts'],
    sourcesContent: ['const a: number = 1;'],
    mappings: 'AAAA',
});
const withMap = `var a = 1;
//# sourceMappingURL=data:application/json;base64,${Buffer.from(mapJson).toString('base64')}`;

// ------------------------------------------------------------- binary oracle
const BINARY_CASES = [
    { name: 'jscChunk', url: 'https://demo.test/app.jsc', file: 'jsc-chunk.jsc', options: {} },
    { name: 'jscChunkIndexed', url: 'https://demo.test/app.jsc', file: 'jsc-chunk.jsc',
      options: { index: 5, pathPrefix: 'raw' } },
    { name: 'jscCjsProgram', url: 'https://demo.test/cjs.bin', file: 'jsc-cjs-chunk.bin', options: {} },
    { name: 'v8CodeCache', url: 'https://demo.test/cache.bin', file: 'v8-codecache.jsc', options: {} },
    { name: 'v8CodeCacheSealed', url: 'https://demo.test/sealed.bin', file: 'v8-codecache-sealed.jsc', options: {} },
    { name: 'wasmNamed', url: 'https://demo.test/mod.wasm', file: 'wasm-named.wasm', options: {} },
    { name: 'wasmData', url: 'https://demo.test/data.wasm', file: 'wasm-data.wasm', options: {} },
    // 64 bytes of non-magic noise: the ladder must refuse it with a note, not
    // silently produce an empty result that looks like a clean parse.
    { name: 'unrecognised', url: 'https://demo.test/blob.bin', bytes: null, options: {} },
];

const binary = {
    note: 'Captured from the shipped wasm engine (.cache/engine.wasm) via src/js/unpack-bridge.js unpackAsset, binary tier.',
    capturedAt: 'fixed input set; regenerate with node scripts/pipeline-oracle-extra.mjs',
    cases: {},
};
for (const c of BINARY_CASES) {
    const bytes = c.file ? readBytes(c.file) : new Uint8Array(64).map((_, i) => (i * 37 + 11) & 0xff);
    binary.cases[c.name] = {
        url: c.url,
        ...(c.file ? { fixture: c.file } : { bytesB64: b64(bytes) }),
        options: c.options,
        result: await bridge.unpackAsset({ url: c.url, bytes }, c.options),
    };
}
write('pipeline-binary-oracle.json', binary);

// -------------------------------------------------------------- batch oracle
const batchAssets = [
    { url: 'https://demo.test/app.js', content: plain },
    // zipPath on an ASSET reaches the report entry only through the batch path:
    // `unpackAssets` builds a per-asset UnpackOptions carrying it, while
    // `unpackAsset` reads `opts.zip_path`, which the bridge never sends. Both
    // halves of that asymmetry are pinned here.
    { url: 'https://demo.test/e.js', content: evalWrapped, zipPath: 'site/e.js' },
    { url: 'https://demo.test/m.js', content: withMap },
    { url: 'https://demo.test/b.js', content: bundle },
    { url: 'https://demo.test/empty.js', content: '' },
];
const batchOptions = { pathPrefix: 'raw' };

// A loose chunk plus the container-wide string table, in that order: nothing
// references the table, so `unpackAssets` has to find it by structure and share
// it, which is what turns `<ordinal N>` slots into real names.
const binaryAssets = [
    { url: 'https://demo.test/cjs.bin', bytes: readBytes('jsc-cjs-chunk.bin') },
    { url: 'https://demo.test/sec.bin', bytes: readBytes('jsc-cjs-sec.bin') },
];

const zipBatch = await bridge.unpackAssetsForZip(batchAssets, batchOptions);
const zipStripped = JSON.parse(JSON.stringify(zipBatch));
zipStripped.report.unpackedAt = CLOCK_SENTINEL;
const indexAt = zipStripped.files.findIndex((f) => f.path === 'raw/index.json');
// The report is pretty-printed JSON with the stamp inside it; substituting the
// sentinel into the TEXT keeps the whole serialisation byte-comparable, which a
// structural comparison of the parsed object would not.
zipStripped.files[indexAt].content =
    zipStripped.files[indexAt].content.replace(/"unpackedAt": "[^"]*"/, `"unpackedAt": "${CLOCK_SENTINEL}"`);

write('pipeline-batch-oracle.json', {
    note: 'Captured from the shipped wasm engine via src/js/unpack-bridge.js. unpackAssets is clock-free; the two unpackAssetsForZip stamps are replaced with <unpackedAt> for the gate to substitute a fixed clock.',
    capturedAt: 'fixed input set; regenerate with node scripts/pipeline-oracle-extra.mjs',
    clockSentinel: CLOCK_SENTINEL,
    textAssets: batchAssets,
    options: batchOptions,
    unpackAssets: await bridge.unpackAssets(batchAssets, batchOptions),
    binaryFixtures: ['jsc-cjs-chunk.bin', 'jsc-cjs-sec.bin'],
    unpackAssetsBinary: await bridge.unpackAssets(
        binaryAssets.map((a) => ({ url: a.url })),
        {},
    ).catch(() => null),
    unpackAssetsForZip: zipStripped,
});

// `unpackAssets` over bytes needs the base64 wire form the bridge builds, so
// capture it through the same serialiser the engine sees.
const binBatch = await bridge.unpackAssets(
    binaryAssets.map((a) => ({ url: a.url, bytes: a.bytes })),
    {},
);
const batch2 = JSON.parse(readFileSync(new URL('../tests/fixtures/pipeline-batch-oracle.json', import.meta.url)));
batch2.unpackAssetsBinary = binBatch;
write('pipeline-batch-oracle.json', batch2);

// -------------------------------------------------------------- probe oracle
const probe = {
    note: 'Small-predicate and unit probes captured from the shipped wasm engine. The `$`-anchored regexes are the reason this exists: Rust `$` is end-of-haystack ONLY, so a trailing newline defeats them, and a port using PCRE semantics silently strips.',
    capturedAt: 'fixed input set; regenerate with node scripts/pipeline-oracle-extra.mjs',
    assetSlug: {},
    looksBinaryScript: {},
    unit: {},
};

// `$` semantics: with text after the newline the query strip cannot match at
// all (Rust `.` excludes \n), so nothing is stripped and `?` becomes `_`.
for (const url of [
    'https://h/a.js?v=1#x', 'https://h/a.js#x', 'a?b', 'a#b', 'HTTP://h/a.js',
    'https://h/a.js\n', 'https://h/a.js\nX', 'https://h/a.b.c', 'https://h/./x',
    'https://h/a b.js', 'https://h/a:b.js', '', '?x', '/',
    'a?b\nc', 'a\n?b', 'a?b\nc\n',
]) {
    probe.assetSlug[`${url} #0`] = bridge.assetSlug(url, 0);
}
probe.assetSlug['https://h/a/b.js #1234'] = bridge.assetSlug('https://h/a/b.js', 1234);

for (const url of [
    'https://demo.test/app.js', 'https://demo.test/app.jsc', 'https://demo.test/x.bc',
    'https://demo.test/m.wasm', 'https://demo.test/m.wasm?v=2', 'https://demo.test/a.JSC',
    'https://demo.test/a.js?x=.jsc', 'https://demo.test/a.json', 'https://demo.test/a',
    'jsc', 'x.bc.wasm', 'https://demo.test/a.wasmx',
    'a.jsc\n', 'a.wasm?', 'a.bc#x', 'A.Wasm?z=1',
]) {
    probe.looksBinaryScript[`${url}||none`] = bridge.looksBinaryScript(url, null);
}
for (const [tag, file] of [
    ['wasm-named.wasm', 'wasm-named.wasm'],
    ['jsc-chunk.jsc', 'jsc-chunk.jsc'],
    ['v8-codecache.jsc', 'v8-codecache.jsc'],
]) {
    probe.looksBinaryScript[`https://demo.test/blob.bin||${file}`] =
        bridge.looksBinaryScript('https://demo.test/blob.bin', readBytes(tag));
}
probe.looksBinaryScript['https://demo.test/blob.bin||garbage'] =
    bridge.looksBinaryScript('https://demo.test/blob.bin', new Uint8Array(64));
probe.looksBinaryScript['https://demo.test/blob.bin||short'] =
    bridge.looksBinaryScript('https://demo.test/blob.bin', new Uint8Array(4));

// UTF-16 units, not bytes: an astral character is 2, `é` is 1 even though it is
// two UTF-8 bytes. `entry.bytes` is `utf16_len`, so a port using the octet count
// answers 2 for `é` and 4 for the emoji.
for (const [name, content] of [['latin1', 'é'], ['astral', '\u{1F600}']]) {
    probe.unit[name] = {
        url: 'https://demo.test/u.js',
        content,
        result: await bridge.unpackAsset({ url: 'https://demo.test/u.js', content }, {}),
    };
}
write('pipeline-probe-oracle.json', probe);

// -------------------------------------------------------------- budget tier
// The over-budget refusal runs BEFORE any peeler, so its answer has ZERO files
// and the fixture stays tiny. The INPUT is described as a recipe rather than
// stored: 9 MiB of `A` in a JSON fixture would dominate every gate run for one
// branch, and `bytes`/`digest` in the captured entry still pin the whole path
// because the digest is of the reconstructed text.
const BUDGET_BYTES = 8 << 20;
const budgetCases = [
    { name: 'textOverBudget', url: 'https://demo.test/huge.js', kind: 'text',
      prefix: 'var x = "', filler: 'A', count: BUDGET_BYTES + 1, suffix: '";' },
    { name: 'bytesOverBudget', url: 'https://demo.test/huge.bin', kind: 'bytes',
      count: BUDGET_BYTES + 1 },
    // EXACTLY at the limit must NOT refuse: the guard is `>`, not `>=`, and a
    // port that used `>=` would still pass the over-budget cases.
    { name: 'textAtBudget', url: 'https://demo.test/at.js', kind: 'text',
      filler: 'A', count: BUDGET_BYTES },
];
const budget = {
    note: 'Budget-branch shapes captured from the shipped wasm engine. Inputs are RECIPES (filler + count), not payloads, so the fixture stays small.',
    capturedAt: 'fixed input set; regenerate with node scripts/pipeline-oracle-extra.mjs',
    budgetBytes: BUDGET_BYTES,
    cases: {},
};
for (const c of budgetCases) {
    let asset;
    if (c.kind === 'text') {
        asset = { url: c.url, content: (c.prefix ?? '') + c.filler.repeat(c.count) + (c.suffix ?? '') };
    } else {
        asset = { url: c.url, bytes: new Uint8Array(c.count).fill(65) };
    }
    budget.cases[c.name] = {
        url: c.url, kind: c.kind,
        recipe: { prefix: c.prefix ?? '', filler: c.filler ?? null, count: c.count, suffix: c.suffix ?? '', fillByte: c.kind === 'bytes' ? 65 : null },
        result: await bridge.unpackAsset(asset, {}),
    };
}
// `atBudget` produces one real file (a 8 MiB `10-source.js`) which would be a
// useless 8 MiB artifact in the fixture; keep only its ENTRY, and let the gate
// assert `files.length === 1` structurally.
for (const [name, c] of Object.entries(budget.cases)) {
    if (name === 'textAtBudget') {
        c.result = { entry: c.result.entry, fileCount: c.result.files.length, files: [] };
        c.filesOmitted = 'one 8 MiB 10-source.js; only the count is asserted';
    }
}
write('pipeline-budget-oracle.json', budget);

console.log('binary cases:', Object.keys(binary.cases).length);
console.log('batch totals:', JSON.stringify(batch2.unpackAssets.report.totals),
    '| binary totals:', JSON.stringify(batch2.unpackAssetsBinary.report.totals));
console.log('probe slug keys:', Object.keys(probe.assetSlug).length,
    '| looksBinaryScript keys:', Object.keys(probe.looksBinaryScript).length);
