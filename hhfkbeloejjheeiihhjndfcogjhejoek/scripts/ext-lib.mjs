// Shared helpers for driving the extension in a real Chrome for Testing.
//
// Branded Chrome/Edge builds ignore --load-extension, so everything that
// loads dist/ unpacked runs on Chrome for Testing, downloaded once into
// .cache/browser.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
export const DIST = path.join(ROOT, 'dist');
const CFT_ROOT = path.join(ROOT, '.cache', 'browser');

// Unpacked extension id: sha256 of the absolute path (UTF-16LE), first 32
// hex nibbles mapped onto [a-p]. Verified against Chrome-observed ids.
export function unpackedExtensionId(absPath) {
    const hex = crypto.createHash('sha256').update(absPath, 'utf16le').digest('hex');
    return [...hex.slice(0, 32)].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
}

export async function ensureChromeForTesting() {
    const existing = fs
        .readdirSync(CFT_ROOT)
        .filter((d) => d.startsWith('chrome-'))
        .sort()
        .pop();
    if (existing) {
        const exe = path.join(CFT_ROOT, existing, 'chrome-win64', 'chrome.exe');
        if (fs.existsSync(exe)) return exe;
    }
    const { install, resolveBuildId, detectBrowserPlatform } = await import('@puppeteer/browsers');
    const platform = detectBrowserPlatform();
    const buildId = await resolveBuildId('chrome', platform, 'stable');
    console.log('downloading Chrome for Testing ' + buildId + ' (first run only)...');
    const r = await install({ browser: 'chrome', buildId, cacheDir: CFT_ROOT });
    return r.executablePath;
}

export function connect(wsUrl) {
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

        function send(method, params, sessionId) {
            const id = nextId++;
            ws.send(JSON.stringify({ id, method, params: params || {}, sessionId }));
            return new Promise((done, fail) => pending.set(id, { resolve: done, reject: fail }));
        }

        function on(method, fn) {
            if (!events.has(method)) events.set(method, []);
            events.get(method).push(fn);
        }
    });
}
