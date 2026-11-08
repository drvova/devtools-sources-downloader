// assets-oracle-paired.mjs — turn the assets oracle into input/output pairs.
//
// The captured oracle (`assets-oracle.json`) holds only the EXPECTED values; the
// inputs live as hardcoded arrays inside `assets.rs`'s own `#[cfg(test)]` block.
// That is fine for Rust, where the two sit in one file, but a port in another
// language has no way to reproduce the pairing without copying ~200 values by
// hand - and a hand-copied table is exactly the kind of thing that drifts.
//
// So this script emits `assets-oracle-paired.json`: one section per function,
// each a list of `{ input, expected }` objects. Inputs are transcribed from the
// Rust test block, which is the authoritative source, and every count is checked
// against the oracle so a mismatch fails loudly here rather than silently
// producing a gate that tests fewer cases than it claims.
//
//   node unpack-rs/scripts/assets-oracle-paired.mjs

import { readFileSync, writeFileSync } from 'node:fs';

const oracle = JSON.parse(
    readFileSync(new URL('../tests/fixtures/panel/assets-oracle.json', import.meta.url), 'utf8'),
);
const exp = oracle.expected;

// ---------------------------------------------------------------------------
// The inputs, transcribed from src/panel/assets.rs's test block in the same
// order the oracle's expected arrays are indexed by.
// ---------------------------------------------------------------------------

const inputs = {
    normalizeUrlKey: ['https://x/y?a=1#f', 'https://x/y#f', '', ''],
    stripUrlVariant: ['https://x/y?a=1#f', 'https://x/y', ''],
    getBareFileName: ['/a/b/c.js', 'https://x/y/z.js?v=1', 'plain.js', '', 'a\\b\\c.js'],
    cleanStackReference: [
        'https://x/a.js:10:5',
        'https://x/a.js:10',
        'https://x/a.js),',
        ' https://x/a.js ',
        '',
    ],
    // the oracle only asserts the first two of these
    extractStackRefs: [
        'at https://x/a.js:1:2\nat blob:https://x/b:3:4\n',
        'no refs',
        Array.from({ length: 12 }, (_, i) => `at https://x/${i}.js:1:1`).join('\n'),
    ],
    detectBundlerName: [
        ['https://x/app.js', 'var x = __webpack_require__(1);'],
        ['https://x/_next/static/chunks/main.js', ''],
        ['https://x/app.js', 'parcelRequire("a")'],
        ['https://x/app.js', 'if (import.meta.hot) {}'],
        ['https://x/@vite/client', ''],
        ['https://x/app.js', 'console.log(1)'],
    ],
    detectFrameworkHints: [
        ['https://x/app.js', 'ReactDOM.hydrate(x)'],
        ['https://x/app.js', '__NEXT_DATA__'],
        ['https://x/app.js', 'createApp({})'],
        ['https://x/app.js', 'ng-version'],
        ['https://x/app.js', 'SvelteKit'],
        ['https://x/app.js', 'plain'],
    ],
    detectStartupSignals: [
        'ReactDOM.hydrate()',
        'navigator.serviceWorker.register("/sw.js")',
        'new Worker("w.js")',
        'WebAssembly.instantiate(b)',
        'apolloClient',
        'import("./x")',
        '//# sourceMappingURL=data:application/json;base64,AA',
        '__webpack_require__.e(1)',
        'history.pushState({}, "", "/a")',
        'nothing here',
    ],
    extractRouteHintsFromUrl: [
        'https://x/static/js/app.js',
        'https://x/account/settings/profile.js',
        'https://x/chunks/abcdef1234.js',
        'https://x/a/b/c.js',
        'https://x/',
        'not a url',
    ],
    extractImportSpecifiers: [
        'import a from "react";import("./dyn.js");const b = require("lodash");',
        'import { x } from "./x.js"; import "./side.css";',
        'require("a");require("a");',
    ],
};

// ---------------------------------------------------------------------------
// Pair each section and verify the counts line up.
// ---------------------------------------------------------------------------

const problems = [];
const paired = {
    note: 'inputs transcribed from src/panel/assets.rs test block; expected values from assets-oracle.json',
    sections: {},
};

for (const [key, list] of Object.entries(inputs)) {
    const want = exp[key];
    if (!Array.isArray(want)) {
        problems.push(`${key}: oracle section missing or not an array`);
        continue;
    }
    // extractStackRefs asserts only the first two, so a longer input list is
    // fine; every OTHER section must match exactly or the gate would silently
    // test a different set than the Rust does.
    const limit = key === 'extractStackRefs' ? 2 : want.length;
    if (key !== 'extractStackRefs' && list.length !== want.length) {
        problems.push(
            `${key}: ${list.length} inputs but ${want.length} expected values`,
        );
        continue;
    }
    paired.sections[key] = list.slice(0, limit).map((input, i) => ({
        input,
        expected: want[i],
    }));
}

// The sections whose inputs are the shared script/recon fixtures, copied
// verbatim rather than reconstructed.
for (const key of ['prepareScriptAssets', 'prepareScriptAssetsNoRecon']) {
    paired.sections[key] = [{ input: 'scriptFixture', expected: exp[key] }];
}
for (const key of [
    'classifyScriptAsset',
    'scoreScriptAsset',
    'findAssetByReference',
    'buildChunkSummary',
    'stripChunkAsset',
    'buildRuntimeOrigins',
    'buildRuntimeSummary',
    'stripRuntimeEntry',
    'determineRuntimeOriginType',
    'scoreRuntimeEntry',
]) {
    if (exp[key] !== undefined) {
        paired.sections[key] = [{ input: 'see assets.rs test block', expected: exp[key] }];
    }
}

if (problems.length) {
    console.error('MISMATCHES - refusing to write a fixture that tests fewer cases than it claims:');
    for (const p of problems) console.error('  ' + p);
    process.exit(1);
}

// The shared fixtures the pipeline sections need, so the Lisp gate has them.
paired.fixtures = {
    scriptFixture: oracle.input.scriptFixture,
    reconFixture: oracle.input.reconFixture,
    runtimeEntries: oracle.input.runtimeEntries,
    runtimeManifest: oracle.input.runtimeManifest,
};

writeFileSync(
    new URL('../tests/fixtures/panel/assets-oracle-paired.json', import.meta.url),
    JSON.stringify(paired, null, 1) + '\n',
);

const counts = Object.entries(paired.sections).map(([k, v]) => `${k}:${v.length}`);
console.log('wrote assets-oracle-paired.json');
console.log('  ' + counts.join(' '));
