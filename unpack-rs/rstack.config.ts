// Rstack CLI configuration - https://rstack.rs
//
// One config drives every `rs` command for this repo. The MV3 extension build
// has a strict artifact contract that survived the webpack migration:
//   - dist/js/[name].js  : one UNHASHED bundle per entry (the html files and
//                          devtools panel wiring load these exact names)
//   - dist/manifest.json : byte-for-byte copy
//   - dist/{html,css,images}/ : byte-for-byte copies
//   - dist/ is the loadable extension: point Chrome's Load unpacked at it
import { define } from 'rstack';

define.app({
    source: {
        entry: {
            devtools: './src/js/devtools.js',
            page: './src/js/page.js',
            injected: './src/js/injected.js',
            'framework-introspect': './src/js/framework-introspect.js',
        },
    },
    output: {
        distPath: {
            root: 'dist',
            js: 'js',
        },
        filename: {
            js: '[name].js',
        },
        copy: {
            patterns: [
                { from: 'src/manifest.json', to: 'manifest.json' },
                { from: 'src/html', to: 'html' },
                { from: 'src/css', to: 'css', info: { minimized: true } },
                { from: 'src/images', to: 'images' },
                {
                    // The Rust unpack engine (scripts/build-engine.cjs builds
                    // it from the devtools-unpack crate). info.minimized
                    // marks it pre-minimized so the copy pipeline leaves the
                    // binary alone.
                    from: '.cache/engine.wasm',
                    to: 'js/engine.wasm',
                    info: { minimized: true },
                },
            ],
        },
    },
    // One bundle per entry, nothing shared: each file is loaded by exact name.
    splitChunks: false,
    tools: {
        rspack: (config) => {
            // This is a Chrome extension, not a web page: Rsbuild's default
            // HTML emission targets dist/html/, which would collide with the
            // copied src/html/ files, so every html plugin goes.
            config.plugins = (config.plugins ?? []).filter(
                (p) => !/html/i.test(p?.constructor?.name ?? ''),
            );
        },
    },
});
define.test({
    // The suite imports src/js ESM directly; no Rsbuild inheritance needed,
    // and the adapter would otherwise force a DOM test environment.
    extends: {},
    testEnvironment: 'node',
});
define.lint(({ js, globalIgnores }) => [
    // Build output (dist/) and tracked fixture data are never lint input.
    globalIgnores(['dist/**', 'tests/**', 'test/fixtures/**']),
    js.configs.recommended,
    {
        // House conventions the tree already follows everywhere:
        //   - best-effort probes catch with `catch (_)` (often an empty block),
        //     so underscore bindings are exempt and empty catches are fine -
        //     an UNDERScoreD catch is the signal, an uncaught-looking typo
        //     like `catch (err)` with an unused err still fails the gate
        //   - signature-docs parameters (e.g. WebAssembly wrappers that
        //     forward via `arguments`) start with `_`
        rules: {
            'no-unused-vars': [
                'error',
                { argsIgnorePattern: '^_', caughtErrorsIgnorePattern: '^_' },
            ],
            'no-empty': ['error', { allowEmptyCatch: true }],
            // no-useless-escape misfires on this tree's payload strings: the
            // embedded renderer sources are single-quoted strings containing
            // double-quoted JS, where removing an "unnecessary" `\"` adds a
            // quote character to the runtime value and corrupts the payload
            // (verified empirically: `"\"":"&quot;"` became `""":"&quot;"`,
            // losing the quote-entity mapping).
            'no-useless-escape': 'off',
        },
    },
]);

define.fmt({
    // Measured, not defaulted: the written style sits at p90 83-113 columns
    // (p95 106-157), and the churn curve plateaus past 100 - widening to 120
    // buys ~1.2k lines while drifting past the house style band. Indent and
    // quote style match the tree so only genuine divergence reformats.
    printWidth: 100,
    tabWidth: 4,
    singleQuote: true,
    // Tracked trees that are data or build output, never formatter input:
    //   - test/fixtures/** : byte-sensitive ground truth (the unpack-rs Rust
    //     port verifies byte-identity against these exact files)
    //   - src/{html,css}/** and src/manifest.json : copied byte-for-byte into
    //     the build output, so they are contract data too (src/css is vendored)
    //   - dist/** : build output
    ignorePatterns: [
        'dist/**',
        'src/html/**',
        'src/css/**',
        'src/manifest.json',
        // Fixture data and the port notes are byte-sensitive ground truth:
        // test/fixtures/** is read by the Rust engine tests, tests/fixtures/**
        // holds the panel oracles, and PORTING.md is hand-written prose.
        'test/fixtures/**',
        'tests/fixtures/**',
        'PORTING.md',
    ],
});

define.staged({
    '*.{js,mjs}': ['rs lint --fix', 'rs fmt'],
    '*.{json,md,css,html}': 'rs fmt',
});
