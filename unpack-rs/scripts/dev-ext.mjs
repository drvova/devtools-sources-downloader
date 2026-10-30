// Extension development loop.
//
// Spawns `rs build --watch --source-map`, opens a dedicated Chrome for
// Testing window with dist/ loaded unpacked, and reloads the extension
// whenever the build output changes. Open DevTools in that window (F12 on
// any page) and the "Sources Downloader" panel reflects every save.
//
// Run with: npm run dev:ext     (Ctrl+C tears everything down)

import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import {
    connect,
    DIST,
    ensureChromeForTesting,
    unpackedExtensionId,
    waitForDist,
} from './ext-lib.mjs';

const ROOT = path.resolve(import.meta.dirname, '..');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function waitForPort(userDataDir) {
    const portFile = path.join(userDataDir, 'DevToolsActivePort');
    const deadline = Date.now() + 20000;
    while (Date.now() < deadline) {
        if (fs.existsSync(portFile)) {
            const port = Number(fs.readFileSync(portFile, 'utf8').split('\n')[0]) || 0;
            if (port) return port;
        }
        await sleep(100);
    }
    throw new Error('browser never reported a debug port');
}

// The reload trigger runs in the extension's own page context: opening the
// panel page as a target and calling chrome.runtime.reload() restarts the
// extension, which re-runs its devtools page and refreshes any open panel.
async function reloadExtension(debugPort, _extensionId) {
    const version = await (await fetch('http://127.0.0.1:' + debugPort + '/json/version')).json();
    const cdp = await connect(version.webSocketDebuggerUrl);
    try {
        const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
        const session = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
        await cdp.send('Runtime.enable', {}, session.sessionId);
        await cdp.send(
            'Runtime.evaluate',
            {
                expression: 'chrome.runtime.reload()',
                returnByValue: true,
            },
            session.sessionId,
        );
        await sleep(300);
        await cdp.send('Target.closeTarget', { targetId });
    } finally {
        cdp.ws.close();
    }
}

async function main() {
    const browserExe = await ensureChromeForTesting();
    const extensionId = unpackedExtensionId(DIST);
    console.log('extension id: ' + extensionId);

    const build = spawn('cmd.exe', ['/c', 'npx rs build --watch --source-map'], {
        cwd: ROOT,
        stdio: 'inherit',
    });

    // Chrome would load an empty extension if it started before the first pass
    await waitForDist();
    console.log('[dev-ext] dist/ ready');

    const userDataDir = path.join(ROOT, '.cache', 'ext-profile');
    fs.mkdirSync(userDataDir, { recursive: true });
    // a port file from a previous run is stale and would read as a dead port
    const portFile = path.join(userDataDir, 'DevToolsActivePort');
    if (fs.existsSync(portFile)) fs.rmSync(portFile);
    const browser = spawn(
        browserExe,
        [
            '--window-size=1400,900',
            '--remote-debugging-port=0',
            '--user-data-dir=' + userDataDir,
            '--no-first-run',
            '--no-default-browser-check',
            '--load-extension=' + DIST,
            '--disable-extensions-except=' + DIST,
            'chrome://newtab',
        ],
        { stdio: 'ignore' },
    );

    const debugPort = await waitForPort(userDataDir);
    console.log('dev browser ready (debug port ' + debugPort + ')');
    console.log('open DevTools (F12) in that window; the panel lives under "Sources Downloader".');

    let reloadTimer = null;
    let reloading = false;
    const watcher = fs.watch(DIST, { recursive: true }, () => {
        clearTimeout(reloadTimer);
        reloadTimer = setTimeout(async () => {
            if (reloading) return;
            reloading = true;
            try {
                await reloadExtension(debugPort, extensionId);
                console.log('[dev-ext] extension reloaded');
            } catch (err) {
                console.error('[dev-ext] reload failed: ' + (err && err.message));
            }
            reloading = false;
        }, 700);
    });

    const shutdown = () => {
        watcher.close();
        build.kill();
        browser.kill();
        process.exit(0);
    };
    process.on('SIGINT', shutdown);
    process.on('SIGTERM', shutdown);
    build.on('exit', (code) => {
        console.error('[dev-ext] build watcher exited with code ' + code + '; shutting down');
        watcher.close();
        browser.kill();
        process.exit(code || 0);
    });
}

main().catch((err) => {
    console.error('dev-ext failed: ' + (err && err.message ? err.message : err));
    process.exit(1);
});
