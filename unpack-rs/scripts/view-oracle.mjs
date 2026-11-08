// view-oracle.mjs — capture the shipped engine's `panelTrackerView` answers.
//
// view.rs owns the panel's HTML: the row markup, the type options, and the
// show/hide booleans the platform shim applies to the DOM. Its Rust unit tests
// cover some of this, but this oracle is stronger because the SHIPPED BINARY
// answers - so it also catches a divergence between view.rs and the binary.
//
// Cases are chosen so each boolean can be pinned independently:
//   items present, none filtered   -> showList
//   items present, all filtered out -> showEmpty
//   no items at all                 -> neither, and empty rowsHtml
// and the escaping cases are the ones that matter: a URL with & and a kind of
// <img> must be escaped in BOTH the cell text and the title attribute.
//
//   node unpack-rs/scripts/view-oracle.mjs

import { writeFileSync } from 'node:fs';

const bridge = await import('../src/js/unpack-bridge.js');

const loaded = [
    { type: 'script', source: 'network', url: 'https://x/a.js?a=1&b=2', size: 2048, time: 5 },
    { type: 'image', source: 'memory', url: '<img>.png', size: 0, time: 1 },
    { type: 'script', source: 'network', url: 'https://x/c.js', size: 100, time: 9 },
];
const unloaded = [
    { type: '', source: '', url: '', size: 0, time: 0 },
    { type: 'css', source: 'disk', url: "https://x/d.css?'quote'", size: 512, time: 3 },
];

const cases = [
    { name: 'mixed', tracker: { loaded, unloaded }, filters: {} },
    { name: 'sortedLargest', tracker: { loaded, unloaded }, filters: { sort: 'largest' } },
    { name: 'sortedUrl', tracker: { loaded, unloaded }, filters: { sort: 'url' } },
    { name: 'filteredToNothing', tracker: { loaded, unloaded }, filters: { search: 'zzz-no-such-thing' } },
    { name: 'filteredByKind', tracker: { loaded, unloaded }, filters: { kind: 'script' } },
    { name: 'filteredByStatus', tracker: { loaded, unloaded }, filters: { status: 'unloaded' } },
    { name: 'emptyTracker', tracker: { loaded: [], unloaded: [] }, filters: {} },
    { name: 'onlyLoaded', tracker: { loaded: [loaded[0]] }, filters: {} },
    { name: 'selectionPreserved', tracker: { loaded, unloaded }, filters: { kind: 'script' } },
    { name: 'selectionDropped', tracker: { loaded, unloaded }, filters: { kind: 'gone-kind' } },
];

const out = {
    note: 'Captured from the shipped wasm engine (.cache/engine.wasm) via src/js/unpack-bridge.js panelTrackerView',
    capturedAt: 'fixed input set; regenerate with node unpack-rs/scripts/view-oracle.mjs',
    cases: {},
};

for (const c of cases) {
    // Await: JSON.stringify of an unresolved Promise is "{}", which is how seven
    // functions looked like the engine refusing input earlier in this port.
    out.cases[c.name] = {
        tracker: c.tracker,
        filters: c.filters,
        view: await Promise.resolve(bridge.panelTrackerView(c.tracker, c.filters)),
    };
}

writeFileSync(
    new URL('../tests/fixtures/panel/view-oracle.json', import.meta.url),
    JSON.stringify(out, null, 1) + '\n',
);

const summary = Object.entries(out.cases).map(
    ([k, v]) => `${k}:${v.view.visible}/${v.view.total}`,
);
console.log(`wrote view-oracle.json\n  ${summary.join(' ')}`);
