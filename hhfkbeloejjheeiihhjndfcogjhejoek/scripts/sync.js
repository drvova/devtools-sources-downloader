// Mirrors the webpack build into the root loadable layout.
//
// The extension exists in two loadable copies: `dist/` (the build output) and the
// repository root (an unpacked load of the same files). Keeping them in step by hand
// drifted: the root copy was a legacy globals build that still loaded the UMD
// FileSaver/jszip bundles and had no unpack pass at all. This script makes the build
// output the single source of truth and copies it over the root layout.

const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const dist = path.join(root, 'dist');

const DIRECTORIES = ['js', 'html', 'css', 'images'];
const FILES = ['manifest.json'];

function listFiles(dir, base) {
    const out = [];
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const abs = path.join(dir, entry.name);
        const rel = base ? base + '/' + entry.name : entry.name;
        if (entry.isDirectory()) out.push(...listFiles(abs, rel));
        else out.push(rel);
    }
    return out;
}

function copyFile(from, to) {
    fs.mkdirSync(path.dirname(to), { recursive: true });
    fs.copyFileSync(from, to);
}

let copied = 0;
let unchanged = 0;

for (const dir of DIRECTORIES) {
    const src = path.join(dist, dir);
    if (!fs.existsSync(src)) throw new Error('build output missing: dist/' + dir + ' (run webpack first)');
    for (const rel of listFiles(src, '')) {
        const from = path.join(src, rel);
        const to = path.join(root, dir, rel);
        if (fs.existsSync(to) && fs.readFileSync(to).equals(fs.readFileSync(from))) {
            unchanged++;
            continue;
        }
        copyFile(from, to);
        copied++;
        console.log('sync ' + dir + '/' + rel);
    }
}

for (const file of FILES) {
    const from = path.join(dist, file);
    const to = path.join(root, file);
    if (fs.existsSync(to) && fs.readFileSync(to).equals(fs.readFileSync(from))) {
        unchanged++;
        continue;
    }
    copyFile(from, to);
    copied++;
    console.log('sync ' + file);
}

console.log('root layout in sync with dist: ' + copied + ' written, ' + unchanged + ' already current');
