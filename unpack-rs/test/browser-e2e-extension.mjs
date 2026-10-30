// End-to-end check of the REAL extension context in a real Chromium.
//
// Unlike browser-e2e.mjs (which stubs chrome.devtools to exercise the unpack
// pipeline), this file loads dist/ as an actual unpacked extension via
// --load-extension on Chrome for Testing, opens the panel page through its
// real chrome-extension:// origin, and asserts the extension identity and
// surface behave correctly in that context.
//
// Run with: npm run test:e2e:ext
// The first run downloads Chrome for Testing into .cache/browser (~160 MB).

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
    assertDist,
    connect,
    DIST,
    ensureChromeForTesting,
    unpackedExtensionId,
} from '../scripts/ext-lib.mjs';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
    assertDist();
    const browser = await ensureChromeForTesting();
    const extensionId = unpackedExtensionId(DIST);
    console.log('extension id (from dist path): ' + extensionId);

    const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'devtools-sources-ext-e2e-'));
    const child = spawn(
        browser,
        [
            '--headless=new',
            '--remote-debugging-port=0',
            '--user-data-dir=' + userDataDir,
            '--no-first-run',
            '--no-default-browser-check',
            '--disable-gpu',
            '--load-extension=' + DIST,
            '--disable-extensions-except=' + DIST,
            'about:blank',
        ],
        { stdio: 'ignore' },
    );

    let ws = null;
    try {
        // debug port from DevToolsActivePort
        const portFile = path.join(userDataDir, 'DevToolsActivePort');
        let debugPort = 0;
        const deadline = Date.now() + 20000;
        while (Date.now() < deadline && !debugPort) {
            if (fs.existsSync(portFile))
                debugPort = Number(fs.readFileSync(portFile, 'utf8').split('\n')[0]) || 0;
            if (!debugPort) await sleep(100);
        }
        if (!debugPort) throw new Error('browser never reported a debug port');

        const version = await (
            await fetch('http://127.0.0.1:' + debugPort + '/json/version')
        ).json();
        const conn = await connect(version.webSocketDebuggerUrl);
        ws = conn.ws;
        const send = conn.send;

        const { targetInfos } = await send('Target.getTargets');
        const page = targetInfos.find((t) => t.type === 'page' && t.url === 'about:blank');
        if (!page) throw new Error('no page target');

        const session = await send('Target.attachToTarget', {
            targetId: page.targetId,
            flatten: true,
        });
        const consoleErrors = [];
        conn.on('Runtime.exceptionThrown', (p) =>
            consoleErrors.push(
                p.exceptionDetails.text +
                    ' ' +
                    ((p.exceptionDetails.exception && p.exceptionDetails.exception.description) ||
                        ''),
            ),
        );
        conn.on('Runtime.consoleAPICalled', (p) => {
            if (p.type === 'error')
                consoleErrors.push((p.args || []).map((a) => a.value || a.description).join(' '));
        });
        await send('Runtime.enable', {}, session.sessionId);

        // open the panel page in its REAL extension context
        const panelUrl = 'chrome-extension://' + extensionId + '/html/page.html';
        await send('Page.enable', {}, session.sessionId);
        await send('Page.navigate', { url: panelUrl }, session.sessionId);
        await sleep(1500);

        const boot = await send(
            'Runtime.evaluate',
            {
                expression:
                    'JSON.stringify({' +
                    'href: location.href,' +
                    'runtimeId: chrome.runtime && chrome.runtime.id || null,' +
                    'manifestVersion: chrome.runtime && chrome.runtime.getManifest && chrome.runtime.getManifest().version || null,' +
                    'btn: typeof document.getElementById("downloadBtn"),' +
                    'activity: typeof document.getElementById("activityText")' +
                    '})',
                returnByValue: true,
            },
            session.sessionId,
        );
        const info = JSON.parse(boot.result.value);
        console.log('panel page booted: ' + info.href);
        const assert = (cond, message) => {
            if (!cond) throw new Error('assertion failed: ' + message);
        };
        assert(info.href === panelUrl, 'page should run at the extension origin, got ' + info.href);
        assert(
            info.runtimeId === extensionId,
            'chrome.runtime.id should match the unpacked id, got ' + info.runtimeId,
        );
        assert(
            info.manifestVersion === '0.1.0',
            'manifest version should read 0.1.0, got ' + info.manifestVersion,
        );
        assert(info.btn === 'object', 'download button missing');
        assert(info.activity === 'object', 'activity banner missing');

        // outside a DevTools window the download must fail with a visible,
        // graceful status instead of throwing inside the click handler
        await send(
            'Runtime.evaluate',
            { expression: 'document.getElementById("downloadBtn").click()', returnByValue: true },
            session.sessionId,
        );
        let status = '';
        const statusDeadline = Date.now() + 10000;
        while (Date.now() < statusDeadline) {
            const r = await send(
                'Runtime.evaluate',
                {
                    expression:
                        'document.getElementById("activityText") ? document.getElementById("activityText").textContent : ""',
                    returnByValue: true,
                },
                session.sessionId,
            );
            status = r.result.value || '';
            if (status) break;
            await sleep(250);
        }
        console.log('off-panel download status: ' + status);
        assert(
            /DevTools API unavailable/.test(status),
            'off-panel download should surface the graceful guard message, got: ' + status,
        );

        assert(
            consoleErrors.length === 0,
            'extension page reported console errors: ' + consoleErrors.join(' | '),
        );

        console.log('EXTENSION E2E PASS');
    } finally {
        try {
            if (ws) ws.close();
        } catch (_) {}
        child.kill();
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
        console.error('EXTENSION E2E FAIL: ' + (err && err.message ? err.message : err));
        process.exit(1);
    });
