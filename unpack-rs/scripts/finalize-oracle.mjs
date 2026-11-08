// finalize-oracle.mjs - capture the shipped wasm engine's whole EXPORT answer,
// so the Lisp port's finalize-zip-with-recon can be compared on CONTENT.
//
// Regenerate with: node unpack-rs/scripts/finalize-oracle.mjs

import { writeFileSync } from 'node:fs';
import path from 'node:path';

const bridge = await import('../src/js/unpack-bridge.js');

const jsAssets = [
    { url: 'https://demo.test/app/main.js', content: 'import a from "react";__webpack_require__(1);' },
    { url: 'https://demo.test/vendor.js', content: 'plain vendor' },
    { url: 'https://demo.test/app/router.js', content: 'history.pushState({},"","/x");createBrowserRouter([])' },
    { url: 'https://demo.test/app/auth.js', content: 'const t = localStorage.getItem("jwt");signin()' },
];

const reconData = {
    ls: { token: 'a' },
    ss: { step: '1' },
    cookies: 'a=1; b=2',
    page: { title: 'Demo', url: 'https://demo.test/' },
    stackProfile: {
        framework: 'react',
        evidence: ['data-reactroot'],
        strategy: { profile: 'balanced', captureGraphQLOps: true },
    },
    captureStatus: { ready: true },
    frameworkState: { summary: { roots: 1 }, router: { path: '/' } },
    timings: [{ name: 'https://demo.test/a.js', startTime: 0, duration: 5 }],
    recon: {
        xhr: [{ url: 'https://demo.test/api' }],
        fetch: [{ url: 'https://demo.test/api2' }],
        websockets: [{ url: 'wss://demo.test/ws' }],
        sse: [{ url: 'https://demo.test/sse' }],
        mutations: [{ type: 'childList' }],
        runtime: [{ id: 'r1', kind: 'eval', text: 'var a = 1' }],
    },
};

const pageSnapshot = null;

const runtimePayloads = [
    { index: 0, id: 'r1', kind: 'eval', url: 'https://demo.test/a.js', text: 'var a = 1', hasText: true, hasBase64: false, size: 9 },
];

const options = { pathPrefix: '_gate-script' };

const result = bridge.panelFinalizeZipWithRecon(
    jsAssets,
    reconData,
    pageSnapshot,
    runtimePayloads,
    options,
);

if (!result || typeof result !== 'object') throw new Error('engine returned no result');
if (!Array.isArray(result.files)) throw new Error('engine returned no file list');

const files = result.files
    .map((f) => (f.base64 !== undefined ? { path: f.path, base64: f.base64 } : { path: f.path, content: f.content }))
    .sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));

const out = {
    note: 'Captured from the shipped wasm engine via src/js/unpack-bridge.js panelFinalizeZipWithRecon. generatedAt is a clock and the Lisp comparison strips it from both sides.',
    inputs: { jsAssets, reconData, pageSnapshot, runtimePayloads, options },
    expected: {
        files,
        fileCount: files.length,
        summary: result.summary,
        reportTotals: result.report && result.report.totals ? result.report.totals : null,
    },
};

const target = path.resolve(import.meta.dirname, '../tests/fixtures/panel/finalize-oracle.json');
writeFileSync(target, JSON.stringify(out, null, 2) + '\n');
console.log('captured ' + files.length + ' files -> ' + target);
console.log('summary: ' + result.summary);
