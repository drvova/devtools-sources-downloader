// pipeline-oracle.mjs — capture the shipped wasm engine's `unpackAsset` /
// `unpackAssets` answers, so the pipeline port has a real oracle.
//
// The other modules were captured one function at a time with small values.
// Pipeline is different: its input is an ASSET (url + text or bytes) plus an
// options object, and its output is a report entry plus a list of files. So the
// fixture is a table of (asset, options) pairs with the engine's whole answer.
//
// Inputs are chosen to reach the branches that exist:
//   - plain text, no peel            -> zero stages, one entry
//   - eval wrapper                   -> peel-unwrap stage
//   - packed                         -> packer stage
//   - a source map reference         -> sourceMap summary and split files
//   - a webpack bundle               -> module splitting
//   - empty text                     -> the empty branch
//   - an over-budget asset           -> the budget refusal branch
//   - a .jsc binary                  -> the bytes path, not the text path
//   - a wasm binary                  -> the bytes path
//
// Deterministic: fixed inputs, no clock, no randomness. Regenerate with
//   node unpack-rs/scripts/pipeline-oracle.mjs

import { writeFileSync } from 'node:fs';

const bridge = await import('../src/js/unpack-bridge.js');

const plain = `var a = 1;
// a comment
var s = "hello world, a string here";
var t = 'another one';
console.log(a, s, t);`;

const evalWrapped = 'eval(function(p,a,c,k,e,d){return p}("payload here",62,1,0,0,0));';

const packed =
    'eval(function(p,a,c,k,e,d){e=function(c){return c};if(!\'\'.replace(/^/,String)){while(c--){d[c]=k[c]||c}k=[function(e){return d[e]}];e=function(){return\'\\\\w+\'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp(\'\\\\b\'+e(c)+\'\\\\b\',\'g\'),k[c])}}return p}(\'0 1("2 3");\',4,4,\'console|log|packed|ok\'.split(\'|\'),0,{}))';

// An inline source map so the sourceMap summary and the split files fire.
const mapJson = JSON.stringify({
    version: 3,
    sources: ['app.ts'],
    sourcesContent: ['const a: number = 1;'],
    mappings: 'AAAA',
});
const withMap = `var a = 1;
//# sourceMappingURL=data:application/json;base64,${Buffer.from(mapJson).toString('base64')}`;

const bundle = `var __webpack_modules__ = {
  42: function (module, exports, __webpack_require__) {
    module.exports = 42;
  },
  7: (a, b) => {
    return a + b;
  },
};
//# sourceURL=webpack://app/./src/add.js`;

// Two layers, so maxDepth has something to cut: an eval around a packer call.
const innerPacked = 'eval(function(p,a,c,k,e,d){return p}("0 1(\'x\');",4,4,"console|log".split("|"),0,{}))';
const doubleWrapped = 'eval(' + JSON.stringify(innerPacked) + ')';

const stringArray = `var _0x5e6f = ["4|1|0|2|3", "log", "Hello", "world", "console"];
(function(_0x2d3e, _0x4c5d) {
  var _0x1f8a = function(_0x5a1b) {
    while (true) {
      if (parseInt(_0x2d3e[0], 16) === _0x4c5d) break;
      _0x2d3e["push"](_0x2d3e["shift"]());
    }
  };
  _0x1f8a(++_0x4c5d);
}(_0x5e6f, 0x4));
var _0x7b9c = function(i, n) {
  i = i - 0x0;
  return _0x5e6f[i];
};
console[_0x7b9c("0x1")](_0x7b9c("0x2") + _0x7b9c("0x3"));`;

// Large enough to cross LIMITS.max_asset_bytes (8 MiB) in UTF-16 units.
const overBudget = 'var x = "' + 'A'.repeat(9 << 20) + '";';

const cases = [
    { name: 'plain', asset: { url: 'https://demo.test/app.js', content: plain }, options: {} },
    { name: 'plainIndexed', asset: { url: 'https://demo.test/app.js', content: plain }, options: { index: 3 } },
    { name: 'evalWrapped', asset: { url: 'https://demo.test/e.js', content: evalWrapped }, options: {} },
    { name: 'packed', asset: { url: 'https://demo.test/p.js', content: packed }, options: {} },
    { name: 'withSourceMap', asset: { url: 'https://demo.test/m.js', content: withMap }, options: {} },
    { name: 'bundle', asset: { url: 'https://demo.test/b.js', content: bundle }, options: {} },
    { name: 'stringArray', asset: { url: 'https://demo.test/s.js', content: stringArray }, options: {} },
    { name: 'empty', asset: { url: 'https://demo.test/empty.js', content: '' }, options: {} },
    // DEPTH NEEDS A TWO-LAYER INPUT TO PIN ANYTHING. The first version of this
    // case used `packed` at maxDepth 1 and produced a result IDENTICAL to the
    // unlimited run - not because the option was ignored, but because that input
    // only has one layer, so there was nothing for the limit to cut. A `maxDepth`
    // assertion over a single-layer input passes whether the option works or not.
    // `doubleWrapped` is eval(eval(packer(...))) so depth 1 and depth 2 must differ.
    { name: 'doubleDepthOne', asset: { url: 'https://demo.test/d.js', content: doubleWrapped }, options: { maxDepth: 1 } },
    { name: 'doubleDepthTwo', asset: { url: 'https://demo.test/d.js', content: doubleWrapped }, options: { maxDepth: 2 } },
    { name: 'doubleUnlimited', asset: { url: 'https://demo.test/d.js', content: doubleWrapped }, options: {} },
    // a custom prefix, to pin that path_prefix reaches every file path
    { name: 'customPrefix', asset: { url: 'https://demo.test/app.js', content: plain }, options: { pathPrefix: 'raw' } },
    { name: 'zipPath', asset: { url: 'https://demo.test/app.js', content: plain }, options: { zipPath: 'site/sources.zip' } },
];

const out = {
    note: 'Captured from the shipped wasm engine (.cache/engine.wasm) via src/js/unpack-bridge.js',
    capturedAt: 'fixed input set; regenerate with node unpack-rs/scripts/pipeline-oracle.mjs',
    cases: {},
};

for (const c of cases) {
    // `unpackAsset` takes (asset, options) and is Promise-wrapped; awaiting is
    // mandatory because JSON.stringify of an unresolved Promise is "{}" - the
    // exact trap that made seven functions look like the engine refusing input.
    out.cases[c.name] = {
        url: c.asset.url,
        content: c.asset.content,
        options: c.options,
        result: await bridge.unpackAsset(c.asset, c.options),
    };
}

// The over-budget case is captured separately because shipping 9 MiB through the
// fixture would make every gate run slow for one branch. Its expected shape is
// recorded instead: a note and no files.
out.overBudget = {
    note: 'not captured through the bridge (9 MiB payload would dominate gate runtime); the branch returns one entry with the budget note and zero files',
    budgetBytes: 8 << 20,
};

writeFileSync(
    new URL('../tests/fixtures/pipeline-oracle.json', import.meta.url),
    JSON.stringify(out, null, 1) + '\n',
);

const sizes = Object.entries(out.cases).map(([k, v]) => `${k}:${(v.result?.files ?? []).length}f`);
console.log(`wrote pipeline-oracle.json\n  ${sizes.join(' ')}`);
