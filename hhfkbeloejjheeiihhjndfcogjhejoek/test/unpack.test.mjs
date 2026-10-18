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
    unpackAssets,
    unpackAssetsIntoZip,
    sha256Hex
} from '../src/js/unpack.js';
import { decodeJsfuck, detectJsfuck, interpretJsfuck } from '../src/js/jsfuck.js';
import {
    detectPacker, unpackPacker, detectStringArray, transformStringArray,
    detectAaencode, detectJjencode, detectJsfiretruck
} from '../src/js/packers.js';
import {
    looksBinaryScript, sha256HexBytes
} from '../src/js/unpack.js';
import {
    detectV8CodeCache, parseV8CodeCache, parseSealedV8, extractV8Strings
} from '../src/js/v8codecache.js';
import {
    parseJscHeader, detectJscBytecode, recoverJscStrings, wtfStringHash, analyzeJscModule,
    readJscSharedTable, findJscSharedTable
} from '../src/js/jscbytecode.js';
import { detectWasmModule, parseWasmModule } from '../src/js/wasm.js';
import fs from 'node:fs';
import { brotliDecompressSync } from 'node:zlib';

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
// ---------------------------------------------- jsfuck (JSFuck 0.5.0 oracle)

const jsfuckCases = [
    ['jsfuck: bare recipe value matches the vendored oracle', async () => {
        globalThis.window = globalThis;
        (0, eval)(fs.readFileSync(new URL('./fixtures/jsfuck-encoder.js', import.meta.url), 'utf8'));
        const jsfucked = globalThis.JSFuck.encode('Number', false);
        const decoded = decodeJsfuck(jsfucked);
        assert.equal(decoded.value, 'Number');
        assert.equal(decoded.captured, false, 'bare recipe must yield a plain value, not a capture');
    }],
    ['jsfuck: Function wrapper captures the payload body', async () => {
        const jsfucked = globalThis.JSFuck.encode('Number', true);
        const decoded = decodeJsfuck(jsfucked);
        assert.equal(decoded.captured, true);
        assert.equal(decoded.value, 'Number');
    }],
    ['jsfuck: real engine executes what the interpreter captures', async () => {
        const jsfucked = globalThis.JSFuck.encode('Number', true, true);
        // Real eval executes the payload: Function('Number')() returns undefined.
        // The interpreter captures the same payload body without running it.
        const ran = (0, eval)(jsfucked);
        assert.equal(ran, Number);
        const decoded = decodeJsfuck(jsfucked);
        assert.equal(decoded.value, 'Number');
    }],
    ['jsfuck: detector is positive on encoded payloads and negative on source', async () => {
        const pos = detectJsfuck(globalThis.JSFuck.encode('Number', false));
        assert.ok(pos.detected, 'encoded payload must be detected');
        assert.ok(pos.purity > 0.9, 'purity above 0.9, got ' + pos.purity);
        const neg = detectJsfuck("console.log('a' + 'b');");
        assert.equal(neg.detected, false);
    }],
    ['jsfuck: peelText routes and decodes as one layer', async () => {
        const res = await peelText(globalThis.JSFuck.encode('Number', false));
        assert.equal(res.stages.length, 1);
        assert.equal(res.stages[0].tool, 'jsfuck');
        assert.equal(res.final, 'Number');
    }],

// ---------------------------------------------------------- Dean Edwards packer

    ['packer: detector matches a real packer call and rejects prose', async () => {
        const packed = "eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}(\"0.1('2 3 4');\",36,5,\"console|log|unpacked|from|layer\".split('|'),0,{}))";
        const hit = detectPacker(packed);
        assert.ok(hit, 'real packer call must be detected');
        assert.equal(hit.base, 36);
        assert.equal(hit.words.length, 5);
        assert.equal(detectPacker("console.log('split by pipe words here');"), null);
    }],
    ['packer: unpackPacker substitutes base-36 words into the template', async () => {
        const packed = "eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}(\"0.1('2 3 4');\",36,5,\"console|log|unpacked|from|layer\".split('|'),0,{}))";
        assert.equal(unpackPacker(packed), "console.log('unpacked from layer');");
    }],
    ['packer: nested layers peel in order through peelText', async () => {
        // packer template that itself expands to a packer call over a second template
        const inner = "\\'0.1(\\\'2 3 4\\\');\\',36,5,\\\"console|log|unpacked|from|layer\\\".split(\\\'|\\\')";
        // simpler nesting: packer expands to a string-array source
        const packed = "eval(function(p,a,c,k,e,d){e=function(c){return c.toString(36)};if(!''.replace(/^/,String)){while(c--){d[c.toString(a)]=k[c]||c.toString(a)}k=[function(e){return d[e]}];e=function(){return'\\w+'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp('\\b'+e(c)+'\\b','g'),k[c])}}return p}(\"0 1=['2','3'];4.5(1[9]);\",36,6,\"var|_0xabc|hello|world|console|log\".split('|'),0,{}))";
        const res = await peelText(packed);
        assert.equal(res.stages[0].tool, 'packer');
        assert.equal(res.final, "var _0xabc=['hello','world'];console.log(_0xabc[9]);");
    }],

// -------------------------------------------------------------- string arrays

    ['string-array: detector requires rotation, pivot and inline calls', async () => {
        const src = "var _0xabc=['a','1','hello','world'];(function(_0x1,_0x2){while(!![]){try{var _0x4=parseInt(_0x1[0])*1+1;if(_0x4===_0x2)break;else _0x1.push(_0x1.shift())}catch(e){_0x1.push(_0x1.shift())}}}(_0xabc,0x1));var _0xdec=function(i){return _0xabc[i];};console.log(_0xdec(0x2),_0xdec(0x3));";
        const hit = detectStringArray(src);
        assert.ok(hit, 'string array layout must be detected');
        assert.equal(hit.arrayId, '_0xabc');
        assert.equal(hit.literals, 4);
        assert.equal(detectStringArray("var plain=['a','b'];console.log(plain[0]);"), null, 'no rotation/pivot: not the pattern');
    }],
    ['string-array: transform rotates the array and inlines decoder calls', async () => {
        const src = "var _0xabc=['a','1','hello','world'];(function(_0x1,_0x2){while(!![]){try{var _0x4=parseInt(_0x1[0])*1+1;if(_0x4===_0x2)break;else _0x1.push(_0x1.shift())}catch(e){_0x1.push(_0x1.shift())}}}(_0xabc,0x1));var _0xdec=function(i){return _0xabc[i];};console.log(_0xdec(0x2),_0xdec(0x3));";
        assert.equal(transformStringArray(src), "var _0xabc = ['1', 'hello', 'world', 'a'];console.log('world','a');");
    }],
    ['string-array: peelText peels it as one layer', async () => {
        const src = "var _0xabc=['a','1','hello','world'];(function(_0x1,_0x2){while(!![]){try{var _0x4=parseInt(_0x1[0])*1+1;if(_0x4===_0x2)break;else _0x1.push(_0x1.shift())}catch(e){_0x1.push(_0x1.shift())}}}(_0xabc,0x1));var _0xdec=function(i){return _0xabc[i];};console.log(_0xdec(0x2),_0xdec(0x3));";
        const res = await peelText(src);
        assert.equal(res.stages.length, 1);
        assert.equal(res.stages[0].tool, 'string-array');
        assert.equal(res.final, "var _0xabc = ['1', 'hello', 'world', 'a'];console.log('world','a');");
    }],

// -------------------------------------------------------------- shell refusals

    ['refusals: aaencode shell is reported, never transformed', async () => {
        const shell = "ﾟωﾉ= /´ｍ｠)ﾉ ~┻━┻   //*\\´∇`＊/ ['_']; " + "(ﾟΘﾟ)".repeat(20);
        const res = await peelText(shell);
        assert.equal(res.stages.length, 0, 'no static transform may run on a runtime shell');
        assert.equal(res.refusals.length, 1);
        assert.equal(res.refusals[0].tool, 'aaencode');
        assert.ok(res.refusals[0].detail.length > 0);
    }],
    ['refusals: jjencode shell is reported', async () => {
        const shell = '$=~[];$={___:++$,$___:(![]+"")[$],____:++$};$.___=($.__=$[""])[$.___+$.___];console.log($.___);';
        const res = await peelText(shell);
        assert.ok(res.refusals.some(r => r.tool === 'jjencode'), 'jjencode must be refused');
    }],
    ['refusals: plain source carries none', async () => {
        const res = await peelText("console.log('plain');");
        assert.equal(res.refusals.length, 0);
    }],
    ['refusals: unpackAsset surfaces refusal notes on the entry', async () => {
        const shell = "ﾟωﾉ= /´ｍ｠)ﾉ ~┻━┻   //*\\´∇`＊/ ['_']; " + "(ﾟΘﾟ)".repeat(20);
        const res = await unpackAsset({ url: 'https://x/aa.js', content: shell }, { index: 3 });
        assert.equal(res.entry.refusals.length, 1);
        assert.ok(res.entry.notes.some(n => n.indexOf('refused: aaencode') === 0));
    }],
];
for (const [name, fn] of jsfuckCases) cases.push({ name, fn });

// ------------------------------------------------ binary cached-bytecode layers

const loadFixture = (name) => new Uint8Array(fs.readFileSync(new URL('./fixtures/' + name, import.meta.url)));

const binaryCases = [
    ['v8: header and framed strings on a real node24 cache', async () => {
        const bytes = loadFixture('v8-codecache.jsc');
        assert.ok(detectV8CodeCache(bytes));
        const cache = parseV8CodeCache(bytes);
        assert.ok(cache, 'cache must parse');
        assert.equal(cache.format, 'v12');
        assert.equal(cache.payloadLength + 32, bytes.length);
        assert.deepEqual(cache.strings, ['hi from cache', 'evalmachine.<anonymous>']);
    }],
    ['v8: detector rejects JSC bytecode and truncated blobs', async () => {
        assert.equal(detectV8CodeCache(loadFixture('jsc-chunk.jsc')), false);
        assert.equal(detectV8CodeCache(new Uint8Array(20)), false);
        const zeros = new Uint8Array(64);
        assert.equal(detectV8CodeCache(zeros), false, 'zero magic must not match the 0xC0DE family');
    }],
    ['v8: framed strings are bounded and printable', async () => {
        const bytes = loadFixture('v8-codecache.jsc');
        const strings = extractV8Strings(bytes, 32);
        assert.deepEqual(strings, ['hi from cache', 'evalmachine.<anonymous>']);
        // a scan window that ends before the second frame still yields the first
        const partial = extractV8Strings(bytes, 32, 140);
        assert.deepEqual(partial, ['hi from cache']);
    }],
    ['jsc: header accepts the real chunk and rejects noise', async () => {
        const bytes = loadFixture('jsc-chunk.jsc');
        const header = parseJscHeader(bytes);
        assert.ok(header);
        assert.equal(header.format, 1);
        assert.equal(header.declaredLength, bytes.length);
        assert.equal(header.bodyOffset, 32);
        const noise = new Uint8Array(4096).fill(0x41);
        assert.equal(detectJscBytecode(noise), false, 'uniform noise must fail the format-or-length guard');
        assert.equal(detectJscBytecode(new Uint8Array(20)), false);
    }],
    ['jsc: recovered strings match the unbuned ground truth', async () => {
        const bytes = loadFixture('jsc-chunk.jsc');
        const truth = JSON.parse(fs.readFileSync(new URL('./fixtures/jsc-chunk-strings.json', import.meta.url), 'utf8'));
        assert.deepEqual(recoverJscStrings(bytes), truth);
    }],
    ['jsc: wtfStringHash reproduces every ledger ground truth', async () => {
        const enc = new TextEncoder();
        const truths = [['moduleLoader', 0x27d79d], ['homeObject', 0xc376d0], ['starNamespace', 0x72858b], ['iterator', 0x336a9c]];
        for (const [text, hash] of truths) assert.equal(wtfStringHash(enc.encode(text)), hash, text);
    }],
    ['sealed: brotli-sealed V8 cache peels through two stages', async () => {
        const bytes = loadFixture('v8-codecache-sealed.jsc');
        assert.equal(detectV8CodeCache(bytes), false, 'sealed blob must not read as a plain cache');
        const sealed = await parseSealedV8(bytes, { inflate: async (b) => brotliDecompressSync(Buffer.from(b)) });
        assert.ok(sealed, 'sealed route must parse with an injected inflator');
        assert.equal(sealed.tool, 'jsc-sealed-v8');
        assert.deepEqual(sealed.cache.strings, ['hi from cache', 'evalmachine.<anonymous>']);
    }],
    ['sealed: a throwing inflator degrades to a refusal, not a crash', async () => {
        const bytes = loadFixture('v8-codecache-sealed.jsc');
        const sealed = await parseSealedV8(bytes, { inflate: async () => { throw new Error('not brotli'); } });
        assert.equal(sealed, null);
    }],
    ['routing: looksBinaryScript matches caches by magic and extension only', async () => {
        assert.equal(looksBinaryScript('https://x/app.jsc', null), true);
        assert.equal(looksBinaryScript('https://x/chunk.bc?v=2', null), true);
        assert.equal(looksBinaryScript('https://x/blob', loadFixture('v8-codecache.jsc')), true);
        assert.equal(looksBinaryScript('https://x/blob', loadFixture('jsc-chunk.jsc')), true);
        assert.equal(looksBinaryScript('https://x/app.js', new TextEncoder().encode('console.log(1)')), false);
        assert.equal(looksBinaryScript('https://x/b', new Uint8Array(8)), false);
    }],
    ['binary pass: unrecognized blobs report a refusal note', async () => {
        const noise = new Uint8Array(4096).fill(0x41);
        const res = await unpackAsset({ url: 'https://x/unknown.bin', bytes: noise }, { index: 0 });
        assert.equal(res.entry.kind, 'binary');
        assert.equal(res.entry.stages.length, 0);
        assert.ok(res.entry.notes.some(n => n.indexOf('no V8 code-cache, JSC bytecode, wasm module, or brotli-sealed shape') >= 0));
    }],
    ['binary pass: zip artifacts are scoped to their own asset root', async () => {
        class StubZip { constructor() { this.files = {}; } file(p, c) { this.files[p] = c; } }
        const zip = new StubZip();
        const report = await unpackAssetsIntoZip(zip, [
            { url: 'https://x/v8.jsc', bytes: loadFixture('v8-codecache.jsc') },
            { url: 'https://x/jsc.jsc', bytes: loadFixture('jsc-chunk.jsc') }
        ], { inflate: async (b) => brotliDecompressSync(Buffer.from(b)) });
        const roots = {};
        for (const p of Object.keys(zip.files)) {
            if (p.endsWith('/index.json')) continue;
            const root = p.split('/')[1];
            roots[root] = true;
            assert.ok(p.indexOf(root) >= 0, 'artifact must live under its own root');
        }
        const rootNames = Object.keys(roots);
        assert.equal(rootNames.length, 2);
        const v8Root = rootNames.find(r => r.indexOf('v8.jsc') >= 0);
        const jscRoot = rootNames.find(r => r.indexOf('jsc.jsc') >= 0);
        assert.deepEqual(JSON.parse(zip.files['_unpack/' + v8Root + '/strings.json']), ['hi from cache', 'evalmachine.<anonymous>']);
        assert.deepEqual(JSON.parse(zip.files['_unpack/' + jscRoot + '/strings.json']), ['moduleLoader', 'starNamespace']);
        assert.equal(report.totals.unpacked, 2);
    }],
    ['binary digest: sha256HexBytes is stable and input-sensitive', async () => {
        const a = new Uint8Array([1, 2, 3, 255]);
        const b = new Uint8Array([1, 2, 3, 254]);
        assert.ok(await sha256HexBytes(a));
        assert.equal(await sha256HexBytes(a), await sha256HexBytes(new Uint8Array([1, 2, 3, 255])));
        assert.notEqual(await sha256HexBytes(a), await sha256HexBytes(b));
        assert.equal(await sha256HexBytes(new Uint8Array(0)), null);
    }],
];

// ------------------------------------------- cached-function tree + wasm layer

const structureCases = [
    ['jsc: cached-function tree matches the unbuned oracle', async () => {
        const bytes = loadFixture('jsc-chunk.jsc');
        const stats = analyzeJscModule(bytes);
        assert.equal(stats.valid, true);
        assert.equal(stats.nodes, 7);
        assert.equal(stats.blocks, 7);
        assert.equal(stats.ops, 103);
        assert.equal(stats.bindFailed, 0);
        assert.equal(stats.rootName, '<ordinal 204781>');
        assert.equal(stats.rootParseMode, 0);
        assert.equal(stats.functions.length, 7);
        const truth = JSON.parse(fs.readFileSync(new URL('./fixtures/jsc-chunk-functions.json', import.meta.url), 'utf8'));
        assert.deepEqual(stats, truth, 'full tree must stay stable against the oracle-captured ground truth');
    }],
    ['jsc: structural walk fails closed on non-bytecode bytes', async () => {
        const noise = new Uint8Array(4096).fill(0x41);
        const stats = analyzeJscModule(noise);
        assert.equal(stats.blocks, 0);
        assert.equal(stats.valid, false);
        assert.equal(stats.functions.length, 1, 'root record alone, no blocks bound');
    }],
    ['wasm: exports match the platform oracle on the crafted fixture', async () => {
        const bytes = loadFixture('wasm-data.wasm');
        assert.ok(detectWasmModule(bytes));
        assert.ok(WebAssembly.validate(bytes));
        const info = parseWasmModule(bytes);
        const module = new WebAssembly.Module(bytes);
        const oracle = WebAssembly.Module.exports(module).map((e) => ({ name: e.name, kind: e.kind === 'function' ? 'func' : e.kind })).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
        const mine = info.exports.map((e) => ({ name: e.name, kind: e.kind })).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
        assert.deepEqual(mine, oracle);
        assert.equal(info.exports.find((e) => e.name === 'compute').index, 0);
        assert.equal(info.moduleName, 'handcrafted_module');
        assert.deepEqual(Object.values(info.functionNames), ['compute']);
        assert.deepEqual(info.dataStrings, ['hello from wasm data', 'second string here']);
        assert.equal(info.notes.length, 0);
    }],
    ['wasm: name section recovered from the real corpus fixture', async () => {
        const bytes = loadFixture('wasm-named.wasm');
        assert.ok(detectWasmModule(bytes));
        const info = parseWasmModule(bytes);
        const names = Object.keys(info.functionNames).sort((a, b) => a - b).map((k) => info.functionNames[k]);
        assert.deepEqual(names, ['eval0', 'eval1', 'mix', 'hash']);
        const module = new WebAssembly.Module(bytes);
        const oracleCount = WebAssembly.Module.exports(module).length;
        assert.equal(info.exports.length, oracleCount);
        assert.equal(info.notes.length, 0, 'the section walk must consume the module exactly');
    }],
    ['wasm: detector rejects noise and truncated bytes', async () => {
        assert.equal(detectWasmModule(new Uint8Array(4096).fill(0x41)), false);
        assert.equal(detectWasmModule(new Uint8Array(4)), false);
        assert.equal(detectWasmModule(null), false);
    }],
    ['routing: .wasm extension and wasm magic reach the binary pass', async () => {
        assert.equal(looksBinaryScript('https://x/mod.wasm', null), true);
        assert.equal(looksBinaryScript('https://x/blob?v=1', loadFixture('wasm-named.wasm')), true);
        assert.equal(looksBinaryScript('https://x/app.js', new TextEncoder().encode('console.log(1)')), false);
    }],
    ['binary pass: wasm asset lands the wasm-module stage and artifact', async () => {
        const res = await unpackAsset({ url: 'https://x/mod.wasm', bytes: loadFixture('wasm-data.wasm') }, { index: 0 });
        assert.equal(res.entry.kind, 'binary');
        assert.ok(res.entry.stages.some((s) => s.tool === 'wasm-module'));
        const artifact = res.files.find((f) => f.path.endsWith('/wasm-info.json'));
        assert.ok(artifact, 'wasm-info.json missing');
        const info = JSON.parse(artifact.content);
        assert.equal(info.moduleName, 'handcrafted_module');
        assert.deepEqual(info.dataStrings, ['hello from wasm data', 'second string here']);
    }],
    ['binary pass: JSC asset lands functions.json with the oracle tree', async () => {
        const res = await unpackAsset({ url: 'https://x/chunk.jsc', bytes: loadFixture('jsc-chunk.jsc') }, { index: 0 });
        assert.ok(res.entry.stages.some((s) => s.tool === 'jsc-bytecode'));
        assert.ok(res.entry.stages[0].detail.includes('7 functions'), 'stage detail must name the function count, got: ' + res.entry.stages[0].detail);
        assert.equal(res.entry.functions, 7);
        const artifact = res.files.find((f) => f.path.endsWith('/functions.json'));
        assert.ok(artifact, 'functions.json missing');
        const tree = JSON.parse(artifact.content);
        assert.equal(tree.valid, true);
        assert.equal(tree.functions.length, 7);
    }],
];

// Minimal shared EncoderStringTable from real claude.exe records: count,
// offset per ordinal, records laid out in ordinal order (the writer's own
// layout); unneeded ordinals point at a zero-length marker both readers skip.
function buildSharedTable(corruptOrdinal) {
    const recordsJson = JSON.parse(fs.readFileSync(new URL('./fixtures/jsc-shared-records.json', import.meta.url), 'utf8'));
    const count = recordsJson.count;
    const ordinals = Object.keys(recordsJson.records).map(Number).sort((a, b) => a - b);
    const offsetsLen = 4 + count * 4;
    let total = offsetsLen + 8;
    const recBytes = ordinals.map((o) => Buffer.from(recordsJson.records[o].hex, 'hex'));
    for (const b of recBytes) total += Math.ceil(b.length / 4) * 4;
    const out = Buffer.alloc(total);
    out.writeUInt32LE(count, 0);
    let cursor = offsetsLen + 8;
    const pos = {};
    for (let i = 0; i < ordinals.length; i++) {
        const b = recBytes[i];
        if (ordinals[i] === corruptOrdinal) b[b.length - 1] ^= 0xff; // break the stored hash
        b.copy(out, cursor);
        pos[ordinals[i]] = cursor;
        cursor += Math.ceil(b.length / 4) * 4;
    }
    for (let o = 0; o < count; o++) out.writeUInt32LE(pos[o] !== undefined ? pos[o] : offsetsLen, 4 + o * 4);
    return out;
}

const sharedCases = [
    ['jsc: shared reader resolves real records and leaves holes', async () => {
        const table = buildSharedTable();
        const read = readJscSharedTable(table, 0, table.length);
        assert.equal(read.count, 204782);
        assert.equal(read.resolved, 9);
        assert.equal(read.strings[0], 'B:/~BUN/root/chunk-6xptctz4.js');
        assert.equal(read.strings[10609], 'W');
        assert.equal(read.strings[10759], 'o');
        assert.equal(read.strings[22490], 'S_t');
        assert.equal(read.strings[129467], 'njo');
        assert.equal(read.strings[184967], 'SGs');
        assert.equal(read.strings[204781], 'file:///B:/%7EBUN/root/chunk-nqhgex2p.js');
        assert.equal(read.strings[100], undefined, 'gap ordinals stay holes, never shifted names');
        assert.equal(readJscSharedTable(table, 0, 12).resolved, 0, 'a window too small for the offsets array refuses');
    }],
    ['jsc: scanner finds an embedded shared table and rejects noise', async () => {
        const table = buildSharedTable();
        const padded = new Uint8Array(512 + table.length);
        padded.fill(0x41);
        padded.set(table, 512);
        const found = findJscSharedTable(padded);
        assert.ok(found, 'scanner must find the table inside an arbitrary blob');
        assert.equal(found.offset, 512);
        assert.equal(found.resolved, 9);
        assert.equal(found.strings[204781], 'file:///B:/%7EBUN/root/chunk-nqhgex2p.js');
        assert.equal(findJscSharedTable(new Uint8Array(4096).fill(0x41)), null);
        assert.equal(findJscSharedTable(table.subarray(0, 100)), null, 'a truncated head cannot hold the offsets array');
        assert.equal(findJscSharedTable(null), null);
    }],
    ['jsc: ordinal name slots resolve against the shared table (oracle parity)', async () => {
        const chunk = loadFixture('jsc-chunk.jsc');
        const table = buildSharedTable();
        const read = readJscSharedTable(table, 0, table.length);
        const resolved = analyzeJscModule(chunk, read.strings);
        assert.equal(resolved.rootName, 'file:///B:/%7EBUN/root/chunk-nqhgex2p.js');
        assert.equal(resolved.bindFailed, 0);
        const truth = JSON.parse(fs.readFileSync(new URL('./fixtures/jsc-chunk-functions-resolved.json', import.meta.url), 'utf8'));
        assert.deepEqual(resolved, truth, 'resolved tree must stay stable against the oracle-captured names');
        // the unresolved walk stays byte-identical when no table is passed
        const plain = analyzeJscModule(chunk);
        assert.equal(plain.rootName, '<ordinal 204781>');
        for (let i = 0; i < truth.functions.length; i++) {
            const p = plain.functions[i].name, t = truth.functions[i].name;
            if (t === null) assert.equal(p, null);
            else assert.ok(String(p).indexOf('<ordinal ') === 0, 'resolved slots degrade to placeholders, got: ' + p);
        }
    }],
    ['jsc: a corrupt record leaves a hole, never a shifted name', async () => {
        const table = buildSharedTable(129467); // 'njo' record, hash broken
        const read = readJscSharedTable(table, 0, table.length);
        assert.equal(read.resolved, 8);
        assert.equal(read.strings[129467], undefined, 'the broken ordinal is an unresolvable placeholder');
        assert.equal(read.strings[10609], 'W', 'earlier ordinals keep their own strings');
        assert.equal(read.strings[184967], 'SGs', 'later ordinals keep their own strings (no dense-list shift)');
        assert.equal(read.strings[204781], 'file:///B:/%7EBUN/root/chunk-nqhgex2p.js');
        const chunk = loadFixture('jsc-chunk.jsc');
        const resolved = analyzeJscModule(chunk, read.strings);
        assert.equal(resolved.functions.find((f) => f.record === 0x230).name, '<ordinal 129467>');
    }],
    ['binary pass: batch discovers the shared table and resolves functions.json', async () => {
        const chunkBytes = loadFixture('jsc-chunk.jsc');
        const containerBytes = new Uint8Array(buildSharedTable());
        const result = await unpackAssets([
            { url: 'https://x/assets/chunk-nqhgex2p.jsc', bytes: chunkBytes },
            { url: 'https://x/assets/section.bin', bytes: containerBytes }
        ], { pathPrefix: '_unpack' });
        const chunkEntry = result.report.assets[0];
        assert.ok(chunkEntry.stages.some((s) => s.tool === 'jsc-bytecode'));
        assert.ok(chunkEntry.stages.some((s) => s.detail.includes('names via shared table')), 'stage detail must name the shared-table resolution, got: ' + chunkEntry.stages.map((s) => s.detail).join(' | '));
        const artifact = result.files.find((f) => f.path.endsWith('chunk-nqhgex2p.jsc.js/functions.json'));
        assert.ok(artifact, 'functions.json missing: ' + result.files.map((f) => f.path).join(', '));
        const tree = JSON.parse(artifact.content);
        assert.equal(tree.rootName, 'file:///B:/%7EBUN/root/chunk-nqhgex2p.js');
        assert.equal(tree.sharedTable.source, 'https://x/assets/section.bin');
        assert.equal(tree.sharedTable.resolvedNames, 6);
        assert.equal(tree.functions.find((f) => f.name === 'o') !== undefined, true);
        assert.equal(tree.functions.find((f) => f.name === 'SGs') !== undefined, true);
    }],
];

for (const [name, fn] of sharedCases) cases.push({ name, fn });

for (const [name, fn] of structureCases) cases.push({ name, fn });

for (const [name, fn] of binaryCases) cases.push({ name, fn });

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
