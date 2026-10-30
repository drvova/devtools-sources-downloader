// Builds the Rust unpack engine for the browser and stages it where the
// rsbuild copy pattern and the tests pick it up.
//
// Output: .cache/engine.wasm, which rstack.config.ts copies into
// dist/js/engine.wasm as part of the build.
//
// Run via: npm run build:engine

const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..');
// Flat layout: the extension project and the crate share this folder, so the
// crate root is the project root.
const CRATE = ROOT;
const OUT = path.join(ROOT, '.cache', 'engine.wasm');

if (!fs.existsSync(path.join(CRATE, 'Cargo.toml'))) {
    console.error('build-engine: crate not found at ' + CRATE);
    process.exit(1);
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
execFileSync('cargo', ['build', '--release', '--target', 'wasm32-unknown-unknown'], {
    cwd: CRATE,
    stdio: 'inherit',
});

const built = path.join(
    CRATE,
    'target',
    'wasm32-unknown-unknown',
    'release',
    'devtools_unpack.wasm',
);
if (!fs.existsSync(built)) {
    console.error('build-engine: cargo did not produce ' + built);
    process.exit(1);
}

const previous = fs.existsSync(OUT) ? fs.readFileSync(OUT) : null;
const current = fs.readFileSync(built);
if (!previous || !previous.equals(current)) {
    fs.writeFileSync(OUT, current);
    console.log('build-engine: engine.wasm updated (' + Math.round(current.length / 1024) + ' KB)');
} else {
    console.log(
        'build-engine: engine.wasm unchanged (' + Math.round(current.length / 1024) + ' KB)',
    );
}
