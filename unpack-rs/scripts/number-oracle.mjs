// number-oracle.mjs — emit the JavaScript answers for a fixed value set.
//
// The Rust port has no oracle for Number::toString or toFixed; only the panel's
// own cases cover them. So this file generates one from the live engine, for the
// values most likely to break a hand-written implementation: exponent
// thresholds, denormals, ties, and the 2^53 boundary. Its output is
// tests/fixtures/number-oracle.json, read by the Lisp gate.
//
// Values are emitted as EXACT IEEE-754 BIT PATTERNS, not decimal literals.
// Decimal would round-trip through two float parsers (this one and the reader's)
// and a mismatch there would look like a formatting bug. Bits cannot round
// wrong. It also carries -0 and NaN/Infinity unambiguously, which JSON numbers
// cannot express.
//
// Deterministic on purpose: same values, same order, no clock, no randomness.

import { writeFileSync } from 'node:fs';

const values = [
    0, 1, 2, 3, 10, 100, 1000, 12345, 123.45, 0.1, 0.5, 1.5, 2.5, 1.25, 1.005,
    999.95, 1e-7, 1e-6, 1e-5, 1.5e-7, 1e20, 1e21, 1e22, 1e-320, 5e-324,
    1.7976931348623157e308, 9007199254740991, 9007199254740992, 2 ** 53,
    -0, -1, -1.5, -123.45, -1e-7, -1e21, 0.000001, 0.0000001, 123456789012345680000,
    1 / 3, 2 / 3, 1e-4, 1.1, 2.2, 3.3, 0.30000000000000004, 33.33, 1e-6 * 3,
    Infinity, -Infinity, NaN,
];

const fixedCases = [];
for (const v of [0, 1, 1.25, 1.005, 1.5, 2.5, 3.14159, 999.95, 0.05, 0.15,
                 1234.5678, -1.25, -0.05, 1e-7, 1e21, 0.0005, 2.0005, 1.45]) {
    for (const d of [0, 1, 2, 3, 6]) fixedCases.push({ v, d, expected: v.toFixed(d) });
}

// 64-bit IEEE-754 to 16 hex digits, via a BigUint64 view so no precision is lost.
const bits = (x) => {
    const buf = new ArrayBuffer(8);
    new DataView(buf).setFloat64(0, x);
    return '0x' + new DataView(buf).getBigUint64(0).toString(16).padStart(16, '0');
};

const out = {
    toString: values.map(v => ({ bits: bits(v), expected: String(v) })),
    toFixed: fixedCases.map(({ v, d, expected }) => ({ bits: bits(v), d, expected })),
};

writeFileSync(new URL('../tests/fixtures/number-oracle.json', import.meta.url),
              JSON.stringify(out, null, 1) + '\n');
console.log(`wrote ${out.toString.length} toString cases, ${out.toFixed.length} toFixed cases`);
