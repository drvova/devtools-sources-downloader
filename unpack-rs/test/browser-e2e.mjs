// End-to-end check of the export pipeline in a real browser.
//
// Loads the built extension page (the same bundle that ships), stubs the devtools
// API with one obfuscated script resource and one eval() runtime payload, clicks
// Download All, then reads the produced sources.zip and asserts the unpack
// artifacts are actually inside it.
//
// Run with: npm run test:e2e   (needs a Chromium browser on this machine)

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';

const ROOT = path.resolve(import.meta.dirname, '..');
const DIST = path.join(ROOT, 'dist');
const BROWSER_CANDIDATES = [
    'C:/Program Files/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
    'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
    'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
];

// dist/ is generated and git-ignored: fail with the fix named, not a 404
for (const rel of ['js/engine.wasm', 'js/page.js']) {
    if (!fs.existsSync(path.join(DIST, rel))) {
        throw new Error(`dist/${rel} is missing - run \`npm run build\` first`);
    }
}

const SCRIPT_PAYLOAD = 'function packed(){return document.title;}\nconst marker = "packed-once";';
const RUNTIME_PAYLOAD =
    'function fromEval(){return "runtime";}\nconst runtimeMarker = "runtime-once";';
const MAP = JSON.stringify({
    version: 3,
    sources: ['webpack://src/original.ts'],
    sourcesContent: ['export const original = true;'],
});
const JSC_BYTES = fs.readFileSync(path.join(ROOT, 'test/fixtures/v8-codecache.jsc'));
const JSC_B64 = JSC_BYTES.toString('base64');
const b64 = (text) => Buffer.from(text, 'utf8').toString('base64');

const CONTENT_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.js': 'text/javascript; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.json': 'application/json',
    '.png': 'image/png',
    '.txt': 'text/plain; charset=utf-8',
};

function startServer() {
    const server = http.createServer((req, res) => {
        const rel = decodeURIComponent(req.url.split('?')[0]).replace(/^\/+/, '');
        const file = path.join(DIST, rel || 'html/page.html');
        if (!file.startsWith(DIST) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
            res.writeHead(404).end('not found');
            return;
        }
        res.writeHead(200, {
            'content-type': CONTENT_TYPES[path.extname(file)] || 'application/octet-stream',
        });
        res.end(fs.readFileSync(file));
    });
    return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

function waitForPortFile(userDataDir, timeoutMs) {
    const file = path.join(userDataDir, 'DevToolsActivePort');
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
        const tick = () => {
            if (fs.existsSync(file)) {
                const port = Number(fs.readFileSync(file, 'utf8').split('\n')[0]);
                if (port) return resolve(port);
            }
            if (Date.now() > deadline)
                return reject(new Error('browser never reported a debug port'));
            setTimeout(tick, 100);
        };
        tick();
    });
}

async function fetchJson(url) {
    const res = await fetch(url);
    return res.json();
}

function connect(wsUrl) {
    return new Promise((resolve, reject) => {
        const ws = new WebSocket(wsUrl);
        const pending = new Map();
        let nextId = 1;
        const events = new Map();
        ws.addEventListener('open', () => resolve({ ws, send, on }));
        ws.addEventListener('error', (err) =>
            reject(new Error('websocket error: ' + (err && err.message))),
        );
        ws.addEventListener('message', (event) => {
            const msg = JSON.parse(event.data);
            if (msg.id && pending.has(msg.id)) {
                const { resolve: done, reject: fail } = pending.get(msg.id);
                pending.delete(msg.id);
                if (msg.error) fail(new Error(msg.method + ': ' + JSON.stringify(msg.error)));
                else done(msg.result);
                return;
            }
            if (msg.method && events.has(msg.method)) {
                events.get(msg.method).forEach((fn) => fn(msg.params));
                events.delete(msg.method);
            }
        });

        function send(method, params) {
            const id = nextId++;
            ws.send(JSON.stringify({ id, method, params: params || {} }));
            return new Promise((done, fail) => pending.set(id, { resolve: done, reject: fail }));
        }

        function on(method, fn) {
            if (!events.has(method)) events.set(method, []);
            events.get(method).push(fn);
        }
    });
}

// Minimal zip reader: central directory -> local headers -> inflateRaw.
function readZip(buffer) {
    let eocd = -1;
    for (let i = buffer.length - 22; i >= 0 && i > buffer.length - 66000; i--) {
        if (buffer.readUInt32LE(i) === 0x06054b50) {
            eocd = i;
            break;
        }
    }
    if (eocd < 0) throw new Error('zip end-of-central-directory not found');
    const count = buffer.readUInt16LE(eocd + 10);
    let offset = buffer.readUInt32LE(eocd + 16);
    const files = {};
    for (let i = 0; i < count; i++) {
        if (buffer.readUInt32LE(offset) !== 0x02014b50)
            throw new Error('bad central directory entry at ' + offset);
        const method = buffer.readUInt16LE(offset + 10);
        const compressedSize = buffer.readUInt32LE(offset + 20);
        const nameLen = buffer.readUInt16LE(offset + 28);
        const extraLen = buffer.readUInt16LE(offset + 30);
        const commentLen = buffer.readUInt16LE(offset + 32);
        const localOffset = buffer.readUInt32LE(offset + 42);
        const name = buffer.toString('utf8', offset + 46, offset + 46 + nameLen);
        const localNameLen = buffer.readUInt16LE(localOffset + 26);
        const localExtraLen = buffer.readUInt16LE(localOffset + 28);
        const dataStart = localOffset + 30 + localNameLen + localExtraLen;
        const raw = buffer.subarray(dataStart, dataStart + compressedSize);
        files[name] = method === 8 ? zlib.inflateRawSync(raw) : Buffer.from(raw);
        offset += 46 + nameLen + extraLen + commentLen;
    }
    return files;
}

const stub = (port) => `
(function(){
  var SCRIPT_URL = 'https://demo.test/app/bundle.js';
  var JSC_URL = 'https://demo.test/app/chunk.jsc';
  var SCRIPT_BODY = 'eval(atob("${b64(SCRIPT_PAYLOAD)}"))\\n//# sourceMappingURL=data:application/json;base64,${b64(MAP)}';
  var RUNTIME_TEXT = 'eval(atob("${b64(RUNTIME_PAYLOAD)}"))';
  window.__TEST_SCRIPT_BODY__ = SCRIPT_BODY;
  window.__TEST_RUNTIME_TEXT__ = RUNTIME_TEXT;
  window.chrome = {
    runtime: { getURL: function (p) { return 'http://127.0.0.1:${port}/' + String(p).replace(/^\\//, ''); } },
    devtools: {
      inspectedWindow: {
        reload: function (options) {
          // Keep the injected script so the harness can run it for real: it is
          // the only thing in the suite that executes the page-world scripts.
          window.__TEST_INJECTED_SCRIPT__ = (options && options.injectedScript) || '';
        },
        getResources: function (cb) {
          cb([
            { url: SCRIPT_URL, type: 'script', getContent: function (done) { done(SCRIPT_BODY, 'text'); } },
            { url: JSC_URL, type: 'script', getContent: function (done) { done('${JSC_B64}', 'base64'); } }
          ]);
        },
        eval: function (expr, cb) {
          if (typeof expr !== 'string') { cb(null, null); return; }
          if (expr.indexOf('__RECON__.runtime') >= 0) {
            var i = Number((expr.match(/runtime\\[(\\d+)\\]/) || [0, '-1'])[1]);
            cb(JSON.stringify({ text: i === 0 ? RUNTIME_TEXT : null, base64: null }), null);
            return;
          }
          if (expr.indexOf('document.documentElement.outerHTML') >= 0) {
            cb(JSON.stringify({ html: '<html><body>demo page</body></html>', title: 'demo' }), null);
            return;
          }
          if (expr.indexOf('__RESOURCE_TRACKER_READY__') >= 0) {
            cb(JSON.stringify({
              ready: true,
              data: { loaded: [], unloaded: [], visible: [], counts: { loaded: 0, unloaded: 0, visible: 0, total: 0 } },
              site: { title: 'demo', url: 'http://127.0.0.1:${port}/html/page.html', origin: 'http://127.0.0.1:${port}' },
              stackProfile: null,
              captureStatus: null
            }), null);
            return;
          }
          if (expr.indexOf('__RECON__') >= 0) {
            cb(JSON.stringify({
              ls: {}, ss: {}, cookies: '', timings: [],
              recon: { xhr: [], fetch: [], websockets: [], sse: [], mutations: [], runtime: [
                { index: 0, id: 'runtime-0', kind: 'eval', mimeType: 'application/javascript', source: 'eval', url: 'eval-0',
                  text: RUNTIME_TEXT, size: RUNTIME_TEXT.length, hasText: true, hasBase64: false }
              ] },
              page: { title: 'demo', url: 'http://127.0.0.1:${port}/html/page.html', origin: 'http://127.0.0.1:${port}', protocol: 'http:', referrer: '', userAgent: 'test' },
              stackProfile: null, captureStatus: null, frameworkState: null
            }), null);
            return;
          }
          cb(null, null);
        }
      }
    }
  };
})();`;

async function main() {
    const browser = BROWSER_CANDIDATES.find((p) => fs.existsSync(p));
    if (!browser)
        throw new Error(
            'no Chromium browser found (looked in: ' + BROWSER_CANDIDATES.join(', ') + ')',
        );

    const server = await startServer();
    const port = server.address().port;
    const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'devtools-sources-e2e-'));
    const downloadDir = path.join(userDataDir, 'downloads');
    fs.mkdirSync(downloadDir, { recursive: true });

    const child = spawn(
        browser,
        [
            '--headless=new',
            '--remote-debugging-port=0',
            '--user-data-dir=' + userDataDir,
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-gpu',
            '--disable-sync',
            '--disable-features=msEdgeSidebarV2,msEdgeCollections',
            'about:blank',
        ],
        { stdio: 'ignore' },
    );

    let ws;
    try {
        const debugPort = await waitForPortFile(userDataDir, 20000);
        let target = null;
        for (let i = 0; i < 60 && !target; i++) {
            const list = await fetchJson('http://127.0.0.1:' + debugPort + '/json/list');
            target = list.find((t) => t.type === 'page' && t.webSocketDebuggerUrl) || null;
            if (!target) await new Promise((r) => setTimeout(r, 200));
        }
        if (!target) throw new Error('no page target exposed');

        const cdp = await connect(target.webSocketDebuggerUrl);
        ws = cdp.ws;
        const consoleErrors = [];
        cdp.on('Runtime.exceptionThrown', (p) =>
            consoleErrors.push(
                p.exceptionDetails.text +
                    ' ' +
                    ((p.exceptionDetails.exception && p.exceptionDetails.exception.description) ||
                        ''),
            ),
        );
        cdp.on('Runtime.consoleAPICalled', (p) => {
            if (p.type === 'error')
                consoleErrors.push((p.args || []).map((a) => a.value || a.description).join(' '));
        });

        await cdp.send('Page.enable');
        await cdp.send('Runtime.enable');
        // Module-load failures surface in the Log domain, not as exceptions.
        cdp.on('Log.entryAdded', (p) => {
            if (!p.entry || p.entry.level !== 'error') return;
            // The static test server has no favicon; that is not a page error.
            if ((p.entry.url || '').endsWith('/favicon.ico')) return;
            consoleErrors.push(p.entry.text + (p.entry.url ? ' <' + p.entry.url + '>' : ''));
        });
        await cdp.send('Log.enable');
        await cdp.send('Browser.setDownloadBehavior', {
            behavior: 'allow',
            downloadPath: downloadDir,
            eventsEnabled: true,
        });
        await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: stub(port) });
        const loaded = new Promise((resolve) => cdp.on('Page.loadEventFired', resolve));
        await cdp.send('Page.navigate', { url: 'http://127.0.0.1:' + port + '/html/page.html' });
        await loaded;

        const stubCheck = await cdp.send('Runtime.evaluate', {
            expression: 'typeof chrome + "/" + typeof chrome.devtools.inspectedWindow.getResources',
            returnByValue: true,
        });
        console.log('page booted, devtools stub: ' + stubCheck.result.value);

        await cdp.send('Runtime.evaluate', {
            expression: "document.getElementById('downloadBtn').click()",
            returnByValue: true,
        });

        let status = '';
        const deadline = Date.now() + 60000;
        while (Date.now() < deadline) {
            const res = await cdp.send('Runtime.evaluate', {
                expression:
                    "document.getElementById('activityText')?document.getElementById('activityText').textContent:''",
                returnByValue: true,
            });
            status = res.result.value || '';
            if (/Export ready\.|failed/i.test(status)) break;
            await new Promise((r) => setTimeout(r, 250));
        }
        console.log('export status: ' + status);

        // Report what the page said before the status check, so a stalled
        // export names its own cause instead of timing out silently.
        if (!/Export ready\./.test(status)) {
            const probe = await cdp.send('Runtime.evaluate', {
                expression:
                    "JSON.stringify({button: !!document.getElementById('downloadBtn'), handler: typeof (document.getElementById('downloadBtn')||{}).onclick, banner: (document.getElementById('activityBanner')||{}).style && document.getElementById('activityBanner').style.display, scripts: Array.from(document.querySelectorAll('script')).map(function(s){return s.src||'(inline)'})})",
                returnByValue: true,
            });
            console.log('page probe: ' + probe.result.value);
        }
        const errors = consoleErrors.length ? ' | console: ' + consoleErrors.join(' | ') : '';
        if (/failed/i.test(status)) throw new Error('export reported failure: ' + status + errors);
        if (!/Export ready\./.test(status))
            throw new Error('export did not complete within 60s; last status: ' + status + errors);

        let zipPath = null;
        for (let i = 0; i < 40 && !zipPath; i++) {
            const found = fs
                .readdirSync(downloadDir)
                .filter((f) => /\.zip$/i.test(f))
                .map((f) => path.join(downloadDir, f));
            zipPath = found[0] || null;
            if (!zipPath) await new Promise((r) => setTimeout(r, 250));
        }
        if (!zipPath) throw new Error('no zip landed in the download directory');
        const zip = readZip(fs.readFileSync(zipPath));
        const names = Object.keys(zip).sort();
        if (process.env.DEBUG_ZIP) console.log('entries:\n  ' + names.join('\n  '));
        const assert = (cond, message) => {
            if (!cond) {
                console.log('zip entries:\n  ' + names.join('\n  '));
                throw new Error('assertion failed: ' + message);
            }
        };

        // The page-world scripts (stack-profile.js + framework-introspect.js +
        // injected.js, concatenated by the panel) are otherwise never executed
        // by any test. Run them in this real page and assert what they publish:
        // a shadowed or broken helper shows up here as a missing global.
        const injected = await cdp.send('Runtime.evaluate', {
            expression: 'window.__TEST_INJECTED_SCRIPT__ || ""',
            returnByValue: true,
        });
        const script = injected.result.value || '';
        assert(script.length > 0, 'the panel must inject the page-world scripts');
        const world = await cdp.send('Runtime.evaluate', {
            expression:
                '(function(){try{(0,eval)(' +
                JSON.stringify(script) +
                ');}catch(e){return JSON.stringify({error:String((e&&e.message)||e)});}' +
                'return JSON.stringify({status:typeof window.__CAPTURE_STATUS__,' +
                'stack:typeof window.__STACK_PROFILE__,' +
                'framework:typeof window.__FRAMEWORK_STATE__,' +
                'tracker:typeof window.__RESOURCE_TRACKER__,' +
                'policy:typeof window.__CAPTURE_POLICY__,' +
                'policyLimits:Object.keys((window.__CAPTURE_POLICY__||{}).limits||{})' +
                '.sort().join(","),' +
                'policyRedact:String((window.__CAPTURE_POLICY__||{}).redactKey||"")});})()',
            returnByValue: true,
        });
        const worldState = JSON.parse(world.result.value || '{}');
        console.log('page world: ' + JSON.stringify(worldState));
        assert(!worldState.error, 'page-world scripts threw: ' + worldState.error);
        assert(worldState.status === 'object', 'capture status must be published');
        assert(worldState.stack === 'object', 'stack profile must be published');
        assert(
            worldState.framework === 'object',
            'framework state must be published (a shadowed refresh leaves it unset)',
        );
        // The capture policy is engine-owned and rides in the injected script;
        // the page world reads it and fails closed without it, so its presence
        // is what keeps redaction and the budgets live.
        assert(
            worldState.policy === 'object',
            'the injected script must carry the engine capture policy',
        );
        assert(
            worldState.policyLimits ===
                'items,keys,mutations,runtimeBinary,runtimeItems,runtimeText,string',
            'the injected policy must carry the engine limits, got ' +
                worldState.policyLimits,
        );
        assert(
            worldState.policyRedact.indexOf('token') >= 0 &&
                worldState.policyRedact.indexOf('secret') >= 0,
            'the injected policy must carry the redaction rule, got ' +
                JSON.stringify(worldState.policyRedact),
        );

        // Re-load the page the way the panel does - the script installed
        // BEFORE the document loads - and then drive the capture path by
        // mutating the DOM. That runs recordMutation -> scheduleProfileRefresh
        // -> the stack and framework refreshes, which is where a helper that
        // is missing from its own scope throws (the exception is swallowed by
        // the observer, so consoleErrors below is the other half of this).
        await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: script });
        const reloaded = new Promise((resolve) => cdp.on('Page.loadEventFired', resolve));
        await cdp.send('Page.navigate', {
            url: 'http://127.0.0.1:' + port + '/html/page.html',
        });
        await reloaded;
        const before = await cdp.send('Runtime.evaluate', {
            expression: 'String((((window.__RECON__||{}).mutations)||[]).length)',
            returnByValue: true,
        });
        await cdp.send('Runtime.evaluate', {
            expression:
                "(function(){var s=document.createElement('script');" +
                "s.src='https://demo.test/app/late.js';document.head.appendChild(s);" +
                "return 'appended';})()",
            returnByValue: true,
        });
        await new Promise((r) => setTimeout(r, 500));
        const recon = await cdp.send('Runtime.evaluate', {
            expression:
                'JSON.stringify({mutations:(((window.__RECON__||{}).mutations)||[]).length,' +
                'runtime:(((window.__RECON__||{}).runtime)||[]).length,' +
                'framework:typeof window.__FRAMEWORK_STATE__})',
            returnByValue: true,
        });
        const captureState = JSON.parse(recon.result.value || '{}');
        captureState.before = Number(before.result.value);
        console.log('capture path: ' + JSON.stringify(captureState));
        assert(
            captureState.mutations > captureState.before,
            'appending a script must ADD a recorded mutation (before=' +
                captureState.before +
                ' after=' +
                captureState.mutations +
                ')',
        );
        assert(
            captureState.framework === 'object',
            'the mutation path must refresh the framework state',
        );
        // Runtime capture is gated by the injected runtimeItems budget: if the
        // policy ever stops crossing, this empties before the zip does.
        assert(
            captureState.runtime > 0,
            'runtime capture must record under the injected budget (runtime=' +
                captureState.runtime +
                ')',
        );

        const unpackRoot = names
            .filter((n) => n.startsWith('_unpack/'))
            .filter((n) => !n.startsWith('_unpack-runtime/'));
        const scriptRoot = '_unpack/0000-demo.test__app__bundle.js/';
        const runtimeRoot = '_unpack-runtime/0000-eval-0.js/';
        const hasAsset = (prefix, suffix) =>
            names.some((n) => n.startsWith(prefix) && n.endsWith(suffix));
        const has = (suffix) => names.some((n) => n.endsWith(suffix));
        const readAsset = (prefix, suffix) => {
            const key = names.find((n) => n.startsWith(prefix) && n.endsWith(suffix));
            return key ? Buffer.from(zip[key]).toString('utf8') : null;
        };

        assert(
            hasAsset(scriptRoot, 'layers/01-eval-unwrap.js'),
            'script layer 01-eval-unwrap.js missing',
        );
        assert(hasAsset(scriptRoot, 'layers/02-base64.js'), 'script layer 02-base64.js missing');
        assert(hasAsset(scriptRoot, '00-original.js'), '00-original.js missing');
        assert(hasAsset(scriptRoot, 'source-map.json'), 'source-map.json missing');
        assert(
            hasAsset(scriptRoot, 'sources/src/original.ts'),
            'recovered original source missing',
        );
        assert(hasAsset(runtimeRoot, 'layers/01-eval-unwrap.js'), 'runtime eval layer missing');
        assert(hasAsset(runtimeRoot, 'layers/02-base64.js'), 'runtime base64 layer missing');
        const binaryRoot = '_unpack/0001-demo.test__app__chunk.jsc.js/';
        assert(hasAsset(binaryRoot, 'cache-header.json'), 'binary cache-header.json missing');
        assert(hasAsset(binaryRoot, 'strings.json'), 'binary strings.json missing');
        assert(
            readAsset(binaryRoot, 'strings.json').includes('hi from cache'),
            'binary strings not recovered from the V8 cache',
        );
        // The raw resource writes and the page snapshot are named by the text
        // helpers (sanitizeFilename / sanitizePageTitle), which now run in Rust
        // behind the bridge - pin the names they produce.
        assert(has('demo.test/app/bundle.js'), 'raw script path must keep its sanitized name');
        assert(has('demo.test/app/chunk.jsc'), 'raw binary path must keep its sanitized name');
        assert(has('demo.html'), 'page snapshot must keep its sanitized title');
        assert(has('_analysis/chunk-map.json'), 'existing analysis artifacts must survive');
        assert(has('_unpack-runtime/index.json'), 'runtime payload unpack report missing');

        const layer1 = readAsset(scriptRoot, 'layers/01-eval-unwrap.js');
        const layer2 = readAsset(scriptRoot, 'layers/02-base64.js');
        assert(
            layer1 && layer1.startsWith('atob('),
            'eval layer must hold the unwrapped expression, got: ' + String(layer1).slice(0, 40),
        );
        assert(
            layer2 && layer2.includes('function packed()'),
            'base64 layer must hold the recovered payload',
        );
        assert(
            readAsset(scriptRoot, 'sources/src/original.ts').includes(
                'export const original = true',
            ),
            'source map content not recovered',
        );
        assert(
            readAsset(runtimeRoot, 'layers/02-base64.js').includes('function fromEval()'),
            'runtime payload not recovered',
        );

        const report = JSON.parse(Buffer.from(zip['_unpack/index.json']).toString('utf8'));
        assert(
            report.totals.assets === 2,
            'report should cover 2 script assets, got ' + report.totals.assets,
        );
        assert(
            report.totals.unpacked === 2,
            'report should count 2 unpacked assets, got ' + report.totals.unpacked,
        );
        assert(report.assets[0].sources === 1, 'report should count 1 recovered source');
        assert(
            report.assets[1].kind === 'binary',
            'second asset should be routed as binary, got ' + report.assets[1].kind,
        );
        assert(
            report.assets[1].stages.some(function (stage) {
                return stage.tool === 'v8-code-cache';
            }),
            'binary asset should carry the v8-code-cache stage, got ' +
                JSON.stringify(report.assets[1].stages),
        );
        assert(report.assets[1].sources === 0, 'binary assets have no source-map sources');

        const runtimeReport = JSON.parse(
            Buffer.from(zip['_unpack-runtime/index.json']).toString('utf8'),
        );
        assert(runtimeReport.root === '_unpack-runtime', 'runtime report root mismatch');
        assert(runtimeReport.totals.assets === 1, 'runtime report should cover the eval payload');

        if (consoleErrors.length)
            throw new Error('browser console reported errors: ' + consoleErrors.join(' | '));

        console.log('zip entries: ' + names.length + ' (' + unpackRoot.length + ' under _unpack/)');
        console.log('unpacked:', JSON.stringify(report.totals));
        console.log('runtime unpacked:', JSON.stringify(runtimeReport.totals));
        console.log('E2E PASS');
    } finally {
        try {
            if (ws) ws.close();
        } catch (_) {}
        child.kill();
        server.close();
        setTimeout(() => {
            try {
                fs.rmSync(userDataDir, { recursive: true, force: true });
            } catch (_) {}
        }, 500);
    }
}

main()
    .then(() => process.exit(0))
    .catch((err) => {
        console.error('E2E FAIL: ' + (err && err.message ? err.message : err));
        process.exit(1);
    });
