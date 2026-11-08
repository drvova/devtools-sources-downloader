// text-oracle.mjs — capture the SHIPPED wasm engine's answers for the text tier.
//
// This is the oracle that matters. The Rust unit tests pin behaviour, but they
// are the same codebase as the port's source: a shared misreading of the
// original JavaScript would pass both. The wasm engine in .cache/engine.wasm is
// what actually ships and runs in Chrome, so its answers are the specification.
//
// Two rules that both cost a debugging round when broken:
//
//   1. EVERY bridge call is awaited. Several are Promise-wrapped even though the
//      engine call is synchronous, and JSON.stringify of an unresolved Promise is
//      "{}" - so seven functions came back as identical empty objects and read as
//      "the engine refuses every input" rather than "we captured nothing".
//
//   2. The output is FLAT: { function: { inputKey: value } }. An earlier version
//      nested it one level deeper, which made the count line and the gate's
//      reader disagree about the shape.
//
// Usage: node unpack-rs/scripts/text-oracle.mjs

import { writeFileSync } from 'node:fs';

const bridge = await import('../src/js/unpack-bridge.js');

// ---------------------------------------------------------------------------
// Inputs: chosen to hit branches rather than to look realistic.
// ---------------------------------------------------------------------------

const jsSources = {
    plain: `var a = 1;\n// a comment\nvar s = "hello world, a string here";\n/* block\n comment */\nvar t = 'another one';`,
    template: 'const x = `outer ${inner} tail`;\nconst y = 2;',
    regex: `var re = /ab+c/gi, s = "a/b/c";\nvar d = a / b / c;\nvar q = /=+/;`,
    escapes: 'var s = "a\\"b\\\\c\\nd\\u00e9";',
    minified: 'function a(b){return b+1}var c=a(1);console.log(c);',
    pretty: 'function add(a, b) {\n    return a + b;\n}\n\nmodule.exports = { add };\n',
    evalLayer: 'eval(function(p,a,c,k,e,d){return p}("payload",62,1,0,0,0));',
    functionLayer: 'var f = new Function("a", "return a * 2");',
    packed: 'eval(function(p,a,c,k,e,d){e=function(c){return c};if(!\'\'.replace(/^/,String)){while(c--){d[c]=k[c]||c}k=[function(e){return d[e]}];e=function(){return\'\\\\w+\'};c=1};while(c--){if(k[c]){p=p.replace(new RegExp(\'\\\\b\'+e(c)+\'\\\\b\',\'g\'),k[c])}}return p}(\'0 1("2 3");\',4,4,\'console|log|packed|ok\'.split(\'|\'),0,{}))',
    base64: 'var payload = "aGVsbG8gd29ybGQgdGhpcyBpcyBhIHRlc3Q=";',
    jsfuck: '[][(![]+[])[+[]]+([![]]+[][[]])[+!+[]+[+[]]]+(![]+[])[!+[]+!+[]]+(!![]+[])[+[]]][([][(![]+[])[+[]]+([![]]+[][[]])[+!+[]+[+[]]]+(![]+[])[!+[]+!+[]]+(!![]+[])[+[]]]+[])[!+[]+!+[]+!+[]]+(![]+[])[+!+[]]+(![]+[])[!+[]+!+[]]]()',
    sourceMapRef: 'var a=1;\n//# sourceMappingURL=app.js.map\n',
    inlineMap:
        'var a=1;\n//# sourceMappingURL=data:application/json;base64,eyJ2ZXJzaW9uIjozLCJzb3VyY2VzIjpbImEudHMiXSwic291cmNlc0NvbnRlbnQiOlsiY29uc3QgYTogbnVtYmVyID0gMTsiXX0=',
    bundle:
        '__webpack_require__.d(exports, { add: () => add });\nfunction add() {}\n//# sourceURL=webpack://app/./src/add.js',
    stringArray:
        'var _0x1a2b=["hello","world","foo","bar","baz","qux","quux","corge"];for(var i=0;i<_0x1a2b.length;i++){console.log(_0x1a2b[i]);}',
    empty: '',
    whitespace: '   \n\t  \n',
};

const sourceNames = Object.keys(jsSources);

const filenames = [
    '',
    'https://example.test/a.js',
    'https://EXAMPLE.Test/A/B.JS?v=1#f',
    'https://x:8080/a.js',
    'https://x:/a.js',
    'https://[::1]:8080/a.js',
    'https://user:pass@host.test/p/q.js',
    'https://host.test/',
    'https://host.test',
    'https://host.test/a%20b.js',
    'https://host.test/a%zz.js',
    'https://host.test/ünïcode/ä.js',
    'https://host.test/😀.js',
    'http://x/y',
    'file:///C:/x.js',
    'chrome-extension://abc/js/x.js',
    'blob:https://h/p',
    'blob:blob:https://h/p',
    'data:image/png;base64,AAAA',
    'data:text/plain,hello',
    'data:,',
    'data:;base64,AA',
    'not a url',
    '//protocol-relative.test/x.js',
    '/absolute/path.js',
    'relative/path.js',
    'custom-scheme:/x',
    'a?b#c',
    'https://h/a?',
    'https://h/a#',
    'https://h/?q',
    '\\\\server\\share\\x.js',
    'x'.repeat(150) + '.js',
    'https://h/' + 'y'.repeat(150) + '.js',
];

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

const oracle = {
    note: 'Captured from dist/js/engine.wasm (the shipped wasm engine) via src/js/unpack-bridge.js',
    capturedAt: 'fixed-input set; regenerate with node unpack-rs/scripts/text-oracle.mjs',
};

// One entry per engine function over the shared source set.
const overSources = async (fn, extra) => {
    const out = {};
    for (const name of sourceNames) {
        out[name] = await fn(jsSources[name], extra);
    }
    return out;
};

oracle.collectStringLiterals = await overSources((t) => bridge.collectStringLiterals(t, 4));
oracle.detectLayers = await overSources((t) => bridge.detectLayers(t));
oracle.peelText = await overSources((t) => bridge.peelText(t));
oracle.detectJsfuck = await overSources((t) => bridge.detectJsfuck(t));
oracle.decodeJsfuck = await overSources((t) => bridge.decodeJsfuck(t));
oracle.detectPacker = await overSources((t) => bridge.detectPacker(t));
oracle.unpackPacker = await overSources((t) => bridge.unpackPacker(t));
oracle.detectStringArray = await overSources((t) => bridge.detectStringArray(t));
oracle.transformStringArray = await overSources((t) => bridge.transformStringArray(t));
oracle.extractBundleModules = await overSources((t) => bridge.extractBundleModules(t));
oracle.findSourceMapRef = await overSources((t) => bridge.findSourceMapRef(t));
oracle.looksMinified = await overSources((t) => bridge.looksMinified(t));

// Fixed-input helpers, unrelated to the source set.
const fromPairs = async (pairs) => {
    const out = {};
    for (const [key, thunk] of pairs) out[key] = await thunk();
    return out;
};

oracle.findBalanced = await fromPairs(
    Object.entries({
        nested: 'a(b(c)d)e',
        string: 'a("(")b',
        template: 'a(`)`)b',
        comment: 'a(/*)*/)b',
        regex: 'a(/(/))b',
        unclosed: 'a(b(c)',
        array: '[1,[2,[3]]]',
        brace: '{a:{b:1}}',
        mismatch: 'a[b)c]',
    }).map(([name, text]) => {
        const open = text.search(/[([{]/);
        return [name, () => (open < 0 ? null : bridge.findBalanced(text, open))];
    }),
);

oracle.decodeEscapes = await fromPairs(
    [
        'plain',
        'a\\nb',
        'a\\\\b',
        '\\x41\\x42',
        '\\u0041\\u00e9',
        '\\u{1F600}',
        '\\0',
        '\\"',
        "\\'",
        '\\q',
        'trailing' + String.fromCharCode(92),
    ].map((s) => [s, () => bridge.decodeEscapes(s)]),
);

oracle.printableRatio = await fromPairs(
    ['', 'abc', 'a\u0000b', 'ünïcode', '\u0001\u0002\u0003', 'a b c', '😀'].map((s) => [
        JSON.stringify(s),
        () => bridge.printableRatio(s),
    ]),
);

oracle.resolveMapUrl = await fromPairs(
    [
        ['https://h/a/b.js', 'c.js.map'],
        ['https://h/a/b.js', '/root.map'],
        ['https://h/a/b.js', '//other.test/x.map'],
        ['https://h/a/b.js', 'https://abs.test/y.map'],
        ['https://h/a/b.js', '../up.map'],
        ['https://h/a/', 'd.map'],
        ['not a url', 'x.map'],
    ].map(([a, b]) => [a + ' :: ' + b, () => bridge.resolveMapUrl(a, b)]),
);

oracle.sanitizeFilename = await fromPairs(
    filenames.map((u) => [u, () => bridge.sanitizeFilename(u)]),
);

oracle.sanitizePageTitle = await fromPairs(
    ['', 'page', 'My: Page?', 'a/b\\c', 'x'.repeat(150), 'ok', 'with\ttab'].map((s) => [
        s,
        () => bridge.sanitizePageTitle(s),
    ]),
);

oracle.sha256Hex = await fromPairs(
    ['', 'abc', 'hello world', 'ünïcode'].map((s) => [s, () => bridge.sha256Hex(s)]),
);

oracle.assetSlug = await fromPairs(
    ['https://h/a/b.js', 'https://h/A/B.JS', 'https://h/a%20b.js', 'https://h/', 'https://h', 'a-b_c.d', 'x'.repeat(150)].flatMap(
        (s) => [
            [s + ' #0', () => bridge.assetSlug(s, 0)],
            [s + ' #7', () => bridge.assetSlug(s, 7)],
        ],
    ),
);

writeFileSync(
    new URL('../tests/fixtures/text-tier-oracle.json', import.meta.url),
    JSON.stringify(oracle, null, 1) + '\n',
);

const lines = Object.entries(oracle)
    .filter(([, v]) => v && typeof v === 'object')
    .map(([k, v]) => '  ' + k + ':' + Object.keys(v).length);
console.log('wrote text-tier-oracle.json\n' + lines.join('\n'));
