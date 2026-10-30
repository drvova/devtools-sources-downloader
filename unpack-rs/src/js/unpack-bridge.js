// Browser bridge to the Rust unpack engine (engine.wasm, built from the
// devtools-unpack crate by scripts/build-engine.cjs).
//
// This module replaces the former six-file JavaScript engine (unpack.js and
// its transform modules): every export below keeps the exact signature the
// old module had, so page.js and the test suite consume the same API with
// only the import path changed. The engine's return shapes are the JS shapes
// (files as {path, content}, source-map refs as {kind, value}, camelCase
// reports) - the Rust seam speaks this dialect natively.
//
// Divergences from the JS engine, all deliberate and shared with the Rust
// port (see unpack-rs/PORTING.md):
//   - fully synchronous core: sha256 is the crate's real SHA-256 (no subtle
//     crypto, no FNV fallback); async-looking exports resolve immediately
//   - remote source maps are fetched with a synchronous XHR from the
//     extension origin (the engine's fetch seam is sync); the old engine's
//     async in-page fetch fallback is gone
//   - the beautifier is the crate's simplified scanner-aware formatter
//   - parseSealedV8 accepts {inflate: 'throw'} to exercise the refusal path;
//     a function value maps to the engine's brotli default

let engine = null;
const textEncoder = new TextEncoder();

function fail(message) {
    throw new Error('[unpack-bridge] ' + message);
}

// The wasm bytes load synchronously at import time: a local sync XHR on the
// extension origin, fs in node. WebAssembly.Module + Instance are themselves
// synchronous, so the engine is ready the moment this module finishes
// evaluating - no init dance, no async gap for consumers to trip over.
function loadEngineBytesSync() {
    if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.getURL) {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', chrome.runtime.getURL('js/engine.wasm'), false);
        // x-user-defined: one code unit per byte, binary-safe responseText
        xhr.overrideMimeType('text/plain; charset=x-user-defined');
        xhr.send(null);
        if (xhr.status !== 200 && xhr.status !== 0) {
            fail('engine.wasm fetch failed: HTTP ' + xhr.status);
        }
        const text = xhr.responseText;
        const bytes = new Uint8Array(text.length);
        for (let i = 0; i < text.length; i++) bytes[i] = text.charCodeAt(i) & 0xff;
        return bytes;
    }
    // Node (test suite): the wasm sits in .cache/ at the extension root.
    // The base is a variable so the bundler does not read this node-only read
    // as a static `new URL(literal, import.meta.url)` asset reference and emit
    // the wasm a second time (`import.meta.dirname` instead would be mocked).
    const base = import.meta.url;
    const wasmPath = fileUrlToNativePath(new URL('../../.cache/engine.wasm', base));
    if (!nodeFs().existsSync(wasmPath)) {
        fail('engine.wasm missing at ' + wasmPath + ' - run npm run build:engine');
    }
    return nodeFs().readFileSync(wasmPath);
}

// file:// URL to a native path without importing node:url: percent-decode
// the pathname, then drop the leading slash Windows prepends to drive letters.
function fileUrlToNativePath(url) {
    let p = decodeURIComponent(url.pathname);
    if (/^\/[A-Za-z]:\//.test(p)) p = p.slice(1);
    return p;
}

// Node's fs without a static import (which would fail the browser build):
// process.getBuiltinModule is available from node 22.3 and invisible to the
// bundler. This branch only runs in the node test suite.
function nodeFs() {
    return process.getBuiltinModule('node:fs');
}

engine = new WebAssembly.Instance(new WebAssembly.Module(loadEngineBytesSync()), {
    env: {
        // wasm32-unknown-unknown has no clock; the host supplies the wall
        // time the engine stamps reports with.
        xu_host_now_ms: () => Date.now(),
        // The engine's fetch seam is synchronous; network reads happen via
        // synchronous XHR (extension pages only - node returns null).
        xu_host_fetch: (urlPtr, urlLen, outLenPtr) => {
            const url = new TextDecoder().decode(
                new Uint8Array(engine.memory.buffer, urlPtr, urlLen),
            );
            let text = null;
            try {
                const xhr = new XMLHttpRequest();
                xhr.open('GET', url, false);
                xhr.overrideMimeType('text/plain; charset=utf-8');
                xhr.send(null);
                if (xhr.status >= 200 && xhr.status < 300) text = xhr.responseText;
            } catch (_) {
                text = null;
            }
            if (text === null) return 0;
            const bytes = textEncoder.encode(text);
            const ptr = engine.xu_alloc(bytes.length);
            new Uint8Array(engine.memory.buffer, ptr, bytes.length).set(bytes);
            new DataView(engine.memory.buffer).setUint32(outLenPtr, bytes.length, true);
            return ptr;
        },
    },
}).exports;

function readStr(ptr, len) {
    return new TextDecoder().decode(new Uint8Array(engine.memory.buffer, ptr, len));
}

function allocStr(str) {
    const bytes = textEncoder.encode(str);
    const ptr = engine.xu_alloc(bytes.length);
    new Uint8Array(engine.memory.buffer, ptr, bytes.length).set(bytes);
    return [ptr, bytes.length];
}

function callRaw(name, argsJson) {
    const [namePtr, nameLen] = allocStr(name);
    const [argsPtr, argsLen] = allocStr(argsJson);
    const lenPtr = engine.xu_alloc(4);
    let out = 0;
    let outLen = 0;
    try {
        out = engine.xu_call(namePtr, nameLen, argsPtr, argsLen, lenPtr);
        outLen = new DataView(engine.memory.buffer).getUint32(lenPtr, true);
        return JSON.parse(readStr(out, outLen));
    } finally {
        engine.xu_free(namePtr, nameLen);
        engine.xu_free(argsPtr, argsLen);
        engine.xu_free(lenPtr, 4);
        if (out) engine.xu_free(out, outLen);
    }
}

function call(name, ...args) {
    if (!engine) fail('engine not initialized');
    const value = callRaw(name, JSON.stringify(args));
    if (value && typeof value === 'object' && value.__error) fail(name + ': ' + value.__error);
    return value;
}

// Bytes cross the JSON boundary base64-encoded (page.js holds Uint8Arrays;
// JSON arrays of megabytes would be absurd).
function bytesToBase64(bytes) {
    let binary = '';
    const chunk = 0x8000;
    for (let i = 0; i < bytes.length; i += chunk) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
    }
    return btoa(binary);
}

function serializeAssets(assets) {
    return (assets || []).map((asset) => {
        if (asset.bytes) {
            return {
                url: asset.url,
                zipPath: asset.zipPath || null,
                bytesB64: bytesToBase64(asset.bytes),
            };
        }
        return { url: asset.url, content: asset.content || '', zipPath: asset.zipPath || null };
    });
}

function serializeOptions(options) {
    const opts = options || {};
    return {
        index: opts.index || null,
        pathPrefix: opts.pathPrefix || null,
        maxDepth: opts.maxDepth || null,
        maxModules: opts.maxModules || null,
        maxBeautifyBytes: opts.maxBeautifyBytes || null,
        // A JS fetchText closure cannot cross the wasm boundary. Callers
        // either let the engine's own sync-XHR fetch seam run (extension
        // origin, credentials included) or hand a static { url: text } map.
        // The key is omitted when absent - an explicit null would still
        // parse, but omitting is the cleaner wire shape.
        ...(opts.fetchMap ? { fetchMap: opts.fetchMap } : {}),
    };
}

// ---------------------------------------------------------------------------
// Engine API - the exact surface the old unpack.js exported.

export const LIMITS = new Proxy(
    { __lazy: true },
    {
        get(target, prop) {
            if (target[prop] !== undefined) return target[prop];
            if (!engine) fail('LIMITS read before engine init');
            return call('LIMITS')[prop];
        },
    },
);

export function sha256Hex(text) {
    return Promise.resolve(call('sha256Hex', text));
}

export function sha256HexBytes(bytes) {
    return Promise.resolve(call('sha256HexBytes', Array.from(bytes || [])));
}

// Zip-path naming lives in Rust (panel::text) so the archive the panel writes
// and the paths the ported reports name cannot drift apart.
export function sanitizeFilename(url) {
    return call('sanitizeFilename', String(url || ''));
}

export function sanitizePageTitle(title) {
    return call('sanitizePageTitle', String(title || ''));
}

export function looksBinaryScript(url, bytes) {
    const encoded = textEncoder.encode(url);
    const ptr = engine.xu_alloc(encoded.length);
    new Uint8Array(engine.memory.buffer, ptr, encoded.length).set(encoded);
    let bytesPtr = 0;
    let bytesLen = 0;
    try {
        if (bytes && bytes.length) {
            bytesLen = bytes.length;
            bytesPtr = engine.xu_alloc(bytesLen);
            new Uint8Array(engine.memory.buffer, bytesPtr, bytesLen).set(bytes);
        }
        return engine.xu_looks_binary_script(ptr, encoded.length, bytesPtr, bytesLen) === 1;
    } finally {
        engine.xu_free(ptr, encoded.length);
        if (bytesPtr) engine.xu_free(bytesPtr, bytesLen);
    }
}

export function collectStringLiterals(text, options) {
    return call('collectStringLiterals', text, options || {});
}

export function findBalanced(text, openIndex) {
    return call('findBalanced', text, openIndex);
}

export function decodeEscapes(raw) {
    return call('decodeEscapes', raw);
}

export function decodeBase64ToBytes(base64) {
    const encoded = textEncoder.encode(base64);
    const ptr = engine.xu_alloc(encoded.length);
    new Uint8Array(engine.memory.buffer, ptr, encoded.length).set(encoded);
    const lenPtr = engine.xu_alloc(4);
    try {
        const out = engine.xu_b64decode(ptr, encoded.length, lenPtr);
        if (!out) return null;
        const len = new DataView(engine.memory.buffer).getUint32(lenPtr, true);
        const bytes = new Uint8Array(engine.memory.buffer, out, len);
        const copy = new Uint8Array(bytes);
        engine.xu_free(out, len);
        return copy;
    } finally {
        engine.xu_free(ptr, encoded.length);
        engine.xu_free(lenPtr, 4);
    }
}

export function bytesToText(bytes) {
    return call('bytesToText', Array.from(bytes || []));
}

export function printableRatio(text) {
    return call('printableRatio', text);
}

export function detectLayers(text) {
    return call('detectLayers', text);
}

export function peelText(text, options) {
    return Promise.resolve(call('peelText', text, options || {}));
}

export function looksMinified(text) {
    return call('looksMinified', text);
}

export function beautifyJs(text, maxBytes) {
    return call('beautifyJs', text, maxBytes === undefined ? null : maxBytes);
}

export function extractBundleModules(text, maxModules) {
    return call('extractBundleModules', text, maxModules === undefined ? null : maxModules);
}

export function findSourceMapRef(text) {
    return call('findSourceMapRef', text);
}

export function parseSourceMap(json) {
    return call('parseSourceMap', json);
}

export function decodeInlineSourceMap(dataUri) {
    return call('decodeInlineSourceMap', dataUri);
}

export function resolveMapUrl(scriptUrl, mapRef) {
    return call('resolveMapUrl', scriptUrl, mapRef);
}

export function assetSlug(url, index) {
    return call('assetSlug', url, index);
}

export function unpackAsset(asset, options) {
    return Promise.resolve(
        call('unpackAsset', serializeAssets([asset])[0], serializeOptions(options)),
    );
}

export function unpackAssets(assets, options) {
    const opts = options || {};
    const result = call('unpackAssets', serializeAssets(assets), serializeOptions(opts));
    // The engine runs the batch atomically, so per-asset progress callbacks
    // are emulated post-hoc: one final (total, total) tick preserves the
    // callback contract for single-asset batches and updates multi-asset
    // progress displays at completion.
    if (typeof opts.onProgress === 'function' && Array.isArray(assets)) {
        opts.onProgress(assets.length, assets.length);
    }
    return Promise.resolve(result);
}

// The engine serializes unshared string slots as JSON null; the JS contract
// spells holes as undefined. Repair the spelling before results cross back.
function repairSharedHoles(table) {
    if (table && Array.isArray(table.strings)) {
        table.strings = table.strings.map((s) => (s === null ? undefined : s));
    }
    return table;
}

export async function unpackAssetsIntoZip(zip, assets, options) {
    // Mirrors the old JS wrapper exactly: run the engine, write the produced
    // files into the JSZip, stamp the report, add the report JSON.
    const opts = options || {};
    const prefix = opts.pathPrefix || '_unpack';
    const result = await unpackAssets(assets, opts);
    for (const file of result.files) zip.file(file.path, file.content);
    result.report.generatedBy = 'unpack.js';
    result.report.root = prefix;
    result.report.unpackedAt = new Date().toISOString();
    zip.file(opts.reportPath || prefix + '/index.json', JSON.stringify(result.report, null, 2));
    return result.report;
}

export function decodeJsfuck(source) {
    return call('decodeJsfuck', source);
}

export function detectJsfuck(source) {
    return call('detectJsfuck', source);
}

export function detectPacker(text) {
    return call('detectPacker', text);
}

export function unpackPacker(text) {
    return call('unpackPacker', text);
}

export function transformStringArray(source) {
    return call('transformStringArray', source);
}

export function detectStringArray(source) {
    return call('detectStringArray', source);
}

export function detectV8CodeCache(bytes) {
    return call('detectV8CodeCache', Array.from(bytes || []));
}

export function parseV8CodeCache(bytes) {
    return call('parseV8CodeCache', Array.from(bytes || []));
}

export function extractV8Strings(bytes, from, to) {
    return call(
        'extractV8Strings',
        Array.from(bytes || []),
        from === undefined ? null : from,
        to === undefined ? null : to,
    );
}

export function parseSealedV8(bytes, options) {
    // A function inflater means the standard brotli path; the string
    // 'throw' exercises the refusal path (see the header note).
    const opts = options || {};
    const inflate = typeof opts.inflate === 'function' ? undefined : opts.inflate;
    return Promise.resolve(call('parseSealedV8', Array.from(bytes || []), { inflate }));
}

export function parseJscHeader(bytes) {
    return call('parseJscHeader', Array.from(bytes || []));
}

export function detectJscBytecode(bytes) {
    return call('detectJscBytecode', Array.from(bytes || []));
}

export function recoverJscStrings(bytes) {
    return call('recoverJscStrings', Array.from(bytes || []));
}

export function wtfStringHash(bytes) {
    return call('wtfStringHash', Array.from(bytes || []));
}

export function analyzeJscModule(bytes, shared) {
    return call('analyzeJscModule', Array.from(bytes || []), shared === undefined ? null : shared);
}

export function readJscSharedTable(bytes, offset, length) {
    return repairSharedHoles(call('readJscSharedTable', Array.from(bytes || []), offset, length));
}

export function findJscSharedTable(bytes) {
    return repairSharedHoles(call('findJscSharedTable', Array.from(bytes || [])));
}

// ---------------------------------------------------------------------------
// Panel surface: the extension's own panel logic (capture state, filtering,
// sorting, view markup) computed by the Rust panel module.

export function panelTrackerView(tracker, filters) {
    return call('panelTrackerView', tracker || {}, filters || {});
}

// The panel's computation and artifact assembly. Functions that produce
// files return [{path, content}] (binary payloads as {path, base64}) so the
// caller keeps the zip while the logic stays in Rust.

export function panelBuildSemanticAnalysis(jsAssets, reconData, runtimeEntries, runtimeManifest) {
    return call(
        'panelBuildSemanticAnalysis',
        jsAssets || [],
        reconData === undefined ? null : reconData,
        runtimeEntries || [],
        runtimeManifest || [],
    );
}

export function panelGenerateInvestigationIndexHTML(investigation) {
    return call('panelGenerateInvestigationIndexHTML', investigation || {});
}

export function panelGenerateWaterfallHTML(timings) {
    return call('panelGenerateWaterfallHTML', timings || []);
}

export function panelGenerateTable(timings) {
    return call('panelGenerateTable', timings || []);
}

export function panelGenerateDOMSnapshotHTML(domHtml, pageMeta) {
    return call('panelGenerateDOMSnapshotHTML', domHtml || '', pageMeta || {});
}

export function panelDescribeCaptureReason(status, profile) {
    return call('panelDescribeCaptureReason', status || null, profile || null);
}

export function panelExportFrameworkArtifacts(frameworkState) {
    return call('panelExportFrameworkArtifacts', frameworkState || null);
}

export function panelExportRuntimeArtifacts(runtimeEntries) {
    return call('panelExportRuntimeArtifacts', runtimeEntries || []);
}

export function panelExportReadableArtifacts(analysis) {
    return call('panelExportReadableArtifacts', analysis || {});
}

export function panelExportSemanticAnalysis(jsAssets, reconData, runtimeEntries, runtimeManifest) {
    return call(
        'panelExportSemanticAnalysis',
        jsAssets || [],
        reconData === undefined ? null : reconData,
        runtimeEntries || [],
        runtimeManifest || [],
    );
}

export function panelWriteReconArtifacts(reconData, pageSnapshot) {
    return call(
        'panelWriteReconArtifacts',
        reconData === undefined ? null : reconData,
        pageSnapshot === undefined ? null : pageSnapshot,
    );
}

export function panelFinalizeZipWithRecon(
    jsAssets,
    reconData,
    pageSnapshot,
    runtimePayloads,
    options,
) {
    return call(
        'panelFinalizeZipWithRecon',
        jsAssets || [],
        reconData === undefined ? null : reconData,
        pageSnapshot === undefined ? null : pageSnapshot,
        runtimePayloads || [],
        options || {},
    );
}

export function detectWasmModule(bytes) {
    return call('detectWasmModule', Array.from(bytes || []));
}

export function parseWasmModule(bytes) {
    return call('parseWasmModule', Array.from(bytes || []));
}
