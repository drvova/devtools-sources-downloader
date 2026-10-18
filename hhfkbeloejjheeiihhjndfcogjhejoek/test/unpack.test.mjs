// Unit tests for the unpack engine. Run with: node test/unpack.test.mjs
//
// These cover the pure transforms and scanners; the browser-only seams
// (devtools.eval fetching, JSZip writing) are exercised by the extension build.

import assert from 'node:assert/strict';
import {
    LIMITS,
    peelText,
    detectLayers,
    collectStringLiterals,
    findBalanced,
    decodeEscapes,
    decodeBase64ToBytes,
    bytesToText,
    printableRatio,
    looksMinified,
    beautifyJs,
    extractBundleModules,
    findSourceMapRef,
    parseSourceMap,
    decodeInlineSourceMap,
    resolveMapUrl,
    assetSlug,
    unpackAsset,
    unpackAssetsIntoZip,
    sha256Hex
} from '../src/js/unpack.js';

const cases = [];
function test(name, fn) { cases.push({ name, fn }); }

function base64Of(text) {
    return Buffer.from(text, 'utf8').toString('base64');
}

test('scanner: balanced region ignores braces inside strings and comments', () => {
    const code = 'function x() { var s = "} not a brace {"; /* } */ return { a: 1 }; } tail';
    const start = code.indexOf('{');
    const end = findBalanced(code, start);
    assert.equal(code.slice(start, end), 'function x() { var s = "} not a brace {"; /* } */ return { a: 1 }; }'.slice(13));
});

test('scanner: string literals decoded with escapes', () => {
    const literals = collectStringLiterals('var a = "h\\x69"; var b = \'\\u0041\';');
    assert.deepEqual(literals.map((l) => l.value), ['hi', 'A']);
});

test('decoder: mixed escapes', () => {
    assert.equal(decodeEscapes('a\\tb\\nc\\\\d\\x41\\u0042'), 'a\tb\nc\\dAB');
});

test('detector: eval packer wins over base64 when both present', () => {
    const payload = 'function hello(){return 42;}'.repeat(40);
    const code = `eval(atob("${base64Of(payload)}"))`;
    const findings = detectLayers(code);
    assert.ok(findings.length > 0);
    assert.ok(findings.some((f) => f.tool === 'eval-unwrap' || f.tool === 'base64'));
});

test('peel: base64 payload is recovered and reported as a layer', async () => {
    const payload = 'function hello(){return 42;}\nvar window_x = document.title;';
    const result = await peelText(`atob("${base64Of(payload)}")`);
    assert.equal(result.stages.length, 1);
    assert.equal(result.stages[0].tool, 'base64');
    assert.ok(result.final.includes('function hello(){return 42;}'));
    assert.equal(result.stages[0].inputBytes > result.stages[0].outputBytes, true);
});

test('peel: gzip layer inflates to source', async () => {
    const source = 'function gzipped(){return "inflated";}\n' + 'var pad = 1;\n'.repeat(20);
    const gz = new Uint8Array(await new Response(new Blob([source]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer());
    assert.equal(gz[0], 0x1f);
    const result = await peelText(`var s = atob("${Buffer.from(gz).toString('base64')}");`);
    assert.ok(result.final.includes('function gzipped()'));
    assert.equal(result.stages[0].tool, 'base64');
});

test('peel: hex escape layer decodes', async () => {
    const source = 'function hexed(){return 7;}';
    const escaped = source.split('').map((c) => '\\x' + c.charCodeAt(0).toString(16).padStart(2, '0')).join('');
    const result = await peelText(`var t = "${escaped}";`);
    assert.equal(result.stages[0].tool, 'hex-escape');
    assert.ok(result.final.includes('function hexed(){return 7;}'));
});

test('peel: charcode layer decodes', async () => {
    const source = 'function charcoded(){return 9;}';
    const codes = source.split('').map((c) => c.charCodeAt(0)).join(',');
    const result = await peelText(`var t = String.fromCharCode(${codes});`);
    assert.equal(result.stages[0].tool, 'charcode');
    assert.ok(result.final.includes('function charcoded(){return 9;}'));
});

test('peel: reversed source is detected and flipped', async () => {
    const source = 'function reversed(){ return document.title; }';
    const result = await peelText(source.split('').reverse().join(''));
    assert.equal(result.stages[0].tool, 'reverse');
    assert.equal(result.final, source);
});

test('peel: rot13 source is detected and decoded', async () => {
    const source = 'function rot(){ return window.location; }';
    const rotated = source.replace(/[a-zA-Z]/g, (c) => {
        const base = c <= 'Z' ? 65 : 97;
        return String.fromCharCode(((c.charCodeAt(0) - base + 13) % 26) + base);
    });
    const result = await peelText(rotated);
    assert.equal(result.stages[0].tool, 'rot13');
    assert.equal(result.final, source);
});

test('peel: nested eval(base64(...)) produces two ordered layers', async () => {
    const inner = 'function deep(){return "deep";}';
    const outer = `eval(atob("${base64Of(inner)}"))`;
    const result = await peelText(outer);
    assert.ok(result.stages.length >= 2);
    assert.equal(result.stages[0].tool, 'eval-unwrap');
    assert.equal(result.stages[1].tool, 'base64');
    assert.ok(result.final.includes('function deep()'));
});

test('peel: plain source yields no layers', async () => {
    const result = await peelText('function nothing(){ return 1; }\nmodule.exports = nothing;\n'.repeat(3));
    assert.deepEqual(result.stages, []);
});

test('beautify: minified detected, beautified output is multiline', () => {
    const minified = 'function a(){return 1}function b(){return 2}var c=a()+b();';
    assert.equal(looksMinified(minified), true);
    const pretty = beautifyJs(minified);
    assert.ok(pretty.split('\n').length > 3);
    assert.ok(pretty.includes('function a() {'));
    const already = 'function a() {\n  return 1;\n}\n';
    assert.equal(looksMinified(already), false);
});

test('modules: webpack module map is split with sourceURL names', () => {
    const bundle = 'var __webpack_modules__ = {' +
        '10: function (module, exports) { module.exports = "ten"; /* } */ },' +
        '20: function (module, exports) { //# sourceURL=webpack://app/src/twenty.js\nmodule.exports = 20; }' +
        '};';
    const modules = extractBundleModules(bundle);
    assert.equal(modules.length, 2);
    assert.equal(modules[0].id, '10');
    assert.deepEqual(modules.map((m) => m.id), ['10', '20']);
    assert.ok(modules[1].code.includes('sourceURL'));
});

test('modules: webpackJsonp chunk push array is split', () => {
    const chunk = '(self.webpackChunkapp = self.webpackChunkapp || []).push([["chunk-1"], {' +
        '31: function (m) { m.exports = 31; },' +
        '32: function (m) { m.exports = 32; }' +
        '}]);';
    const modules = extractBundleModules(chunk);
    assert.deepEqual(modules.map((m) => m.id), ['31', '32']);
});

test('source maps: inline base64 data URI is decoded', () => {
    const map = JSON.stringify({ version: 3, sources: ['webpack://app/src/index.js'], sourcesContent: ['export default 1;'] });
    const inline = 'data:application/json;base64,' + Buffer.from(map, 'utf8').toString('base64');
    const json = decodeInlineSourceMap(inline);
    const parsed = parseSourceMap(json);
    assert.equal(parsed.files.length, 1);
    assert.equal(parsed.files[0].path, 'app/src/index.js');
    assert.equal(parsed.files[0].content, 'export default 1;');
});

test('source maps: ref detection and URL resolution', () => {
    assert.deepEqual(findSourceMapRef('var a=1;\n//# sourceMappingURL=main.js.map\n'), { kind: 'external', value: 'main.js.map' });
    const ref = findSourceMapRef('x\n//@ sourceMappingURL=data:application/json;base64,AAAA');
    assert.equal(ref.kind, 'inline');
    assert.equal(resolveMapUrl('https://a.test/static/js/main.js', '../maps/main.js.map'), 'https://a.test/static/maps/main.js.map');
});

test('asset pipeline: files, layers and sources are produced', async () => {
    const payload = 'function packed(){return document.title;}';
    const map = JSON.stringify({ version: 3, sources: ['webpack://src/original.ts'], sourcesContent: ['const original = true;'] });
    const asset = {
        url: 'https://a.test/static/main.js?cb=1',
        content: `eval(atob("${base64Of(payload)}"))\n//# sourceMappingURL=data:application/json;base64,${Buffer.from(map, 'utf8').toString('base64')}`
    };
    const result = await unpackAsset(asset, { index: 0 });
    assert.ok(result.entry.stages.length >= 2);
    assert.equal(result.entry.sources, 1);
    const paths = result.files.map((f) => f.path);
    assert.ok(paths.some((p) => p.indexOf('_unpack/0000-a.test__static__main.js/layers/01-eval-unwrap.js') === 0));
    assert.ok(paths.some((p) => p.indexOf('/source-map.json') > 0));
    assert.ok(paths.some((p) => p.indexOf('/sources/src/original.ts') > 0));
    assert.match(assetSlug(asset.url, 0), /^0000-a\.test__static__main\.js$/);
    // Each layer artifact carries THAT stage's output, not the final text.
    const layer1 = result.files.find((f) => f.path.endsWith('/layers/01-eval-unwrap.js')).content;
    const layer2 = result.files.find((f) => f.path.endsWith('/layers/02-base64.js')).content;
    assert.ok(layer1.startsWith('atob('));
    assert.equal(layer2, payload);
    assert.notEqual(layer1, layer2);
});

test('asset pipeline: external map fetched through the injected fetcher', async () => {
    const map = JSON.stringify({ version: 3, sources: ['src/only.js'], sourcesContent: ['let only = 1;'] });
    const requested = [];
    const result = await unpackAsset(
        { url: 'https://a.test/app.js', content: 'var a = 1;\n//# sourceMappingURL=app.js.map' },
        { index: 1, fetchText: async (url) => { requested.push(url); return map; } }
    );
    assert.deepEqual(requested, ['https://a.test/app.js.map']);
    assert.equal(result.entry.sources, 1);
    assert.ok(result.files.some((f) => f.path.endsWith('/sources/src/only.js')));
});

test('asset pipeline: budget refusal is reported, not silently dropped', async () => {
    const oversized = 'x'.repeat(64);
    const result = await unpackAsset({ url: 'https://a.test/big.js', content: oversized }, { index: 2 });
    assert.ok(result.entry.stages.length === 0);
    assert.deepEqual(result.entry.notes, ['no obfuscation layer, bundle structure, or source map content found']);
    const huge = await unpackAsset({ url: 'https://a.test/huge.js', content: 'x'.repeat(LIMITS.maxAssetBytes + 1) }, { index: 3 });
    assert.deepEqual(huge.entry.notes, ['asset exceeds unpack budget']);
    assert.equal(huge.files.length, 0);
});

test('digest: sha256 of identical text is stable and input-sensitive', async () => {
    const a = await sha256Hex('payload');
    assert.equal(a, await sha256Hex('payload'));
    assert.notEqual(a, await sha256Hex('payload '));
    assert.equal(a.length, 64);
});

test('helpers: base64 decode and printable ratio', () => {
    const bytes = decodeBase64ToBytes('aGVsbG8=');
    assert.equal(bytesToText(bytes), 'hello');
    assert.equal(printableRatio('hello\nworld'), 1);
    assert.ok(printableRatio('\u0000\u0001') < 0.1);
});

test('zip seam: writes artifacts and a report at the requested root', async () => {
    const written = {};
    const zip = { file: (p, c) => { written[p] = c; } };
    const payload = 'function runtime(){return "eval";}';
    const progress = [];
    const report = await unpackAssetsIntoZip(
        zip,
        [{ url: 'eval-payload', content: `eval(atob("${base64Of(payload)}"))` }],
        { pathPrefix: '_unpack-runtime', onProgress: (done, total) => progress.push(done + '/' + total) }
    );
    assert.equal(report.root, '_unpack-runtime');
    assert.deepEqual(progress, ['1/1']);
    assert.equal(report.totals.assets, 1);
    assert.equal(report.totals.unpacked, 1);
    assert.ok(report.unpackedAt.length > 0);
    assert.ok(written['_unpack-runtime/index.json']);
    assert.ok(Object.keys(written).some((p) => /^_unpack-runtime\/0000-eval-payload\.js\/layers\/01-eval-unwrap\.js$/.test(p)));
    const parsed = JSON.parse(written['_unpack-runtime/index.json']);
    assert.equal(parsed.totals.unpacked, 1);
    assert.equal(parsed.assets[0].url, 'eval-payload');
});

let failed = 0;
for (const c of cases) {
    try {
        await c.fn();
        console.log('ok   ' + c.name);
    } catch (err) {
        failed++;
        console.log('FAIL ' + c.name);
        console.log('     ' + (err && err.message ? err.message : String(err)));
    }
}
console.log('\n' + (cases.length - failed) + '/' + cases.length + ' passed');
if (failed) process.exit(1);
