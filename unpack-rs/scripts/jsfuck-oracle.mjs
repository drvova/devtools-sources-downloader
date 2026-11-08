// jsfuck-oracle.mjs — capture the SHIPPED wasm engine's JSFuck answers, for
// cases that actually reach the capture seam.
//
// Why this file exists
// --------------------
// text-tier-oracle.json already carries detectJsfuck/decodeJsfuck over its 17
// shared sources, but every decodeJsfuck answer there is
// {"value":null,"captured":false}. That is not a capture bug: none of those 17
// sources is a JSFuck PROGRAM. A JSFuck EXPRESSION only ever evaluates to a
// value (`[]+[]` -> ""), so decode_jsfuck can never set `captured` on one.
// `captured` is true only when evaluation walks into a Function/eval seam,
// i.e. the source is `[]["at"]["constructor"](<body>)()`.
//
// So a port could return the null constant and pass the old oracle. This
// script removes that hole. It has three case families, all answering the
// same question — "what does the shipped engine say?" — and all captured
// through src/js/unpack-bridge.js, the bridge text-oracle.mjs uses:
//
//   programs  the real JSFuck 0.5.0 ENCODER (test/fixtures/jsfuck-encoder.js,
//             jsfuck.com) fed complete programs and asked for
//             `wrapWithEval` output. That mode emits
//             `[]["at"]["constructor"](body)()` — Function(body)() — which is
//             exactly the seam `captured` reports on. Without this flag the
//             encoder emits a bare expression and the engine answers
//             {"value":"return 1","captured":false}: the payload leaks out as
//             a plain string and the capture path is never exercised.
//
//   expressions  hand-shaped JSFuck built with the encoder's `encode(s,false,
//             false)` helper for literal fragments. These pin the value model
//             branches that the program family never reaches: array/string
//             `at`, `join`, `split`, `fontcolor`, `italics`, `concat`,
//             `toString(radix)`, `entries`, constructor reads, `escape`,
//             `Date`, regexp sources, and the arithmetic of `+`.
//
//   detection  short/purity/chain boundary inputs. detect_jsfuck has branches
//             ("too short", purity < 95%, hits < 12, chain > 4096) that a real
//             JSFuck program only ever exercises one side of, so the edges are
//             spelled out here.
//
// Nothing is hand-written: `detect` and `decode` are whatever the engine
// answers. The script reports how many cases reached captured:true and fails
// loudly at zero.
//
// Encoder loading. The vendor file is a 2012-era IIFE ending in
//   (typeof(exports) === "undefined" ? window : exports)
// and assigns `self.JSFuck`. It has no export syntax, so ESM `import` is not
// an option, and a bare `require` only works because nothing reassigns
// module.exports. Evaluating the source with explicit `window`/`exports`/`self`
// bindings pins the shim regardless of host module system and keeps the shim
// hermetic — no global pollution.
//
// Usage: node unpack-rs/scripts/jsfuck-oracle.mjs

import { readFileSync, writeFileSync } from 'node:fs';

const ROOT = new URL('../', import.meta.url); // unpack-rs/
const ENCODER = new URL('test/fixtures/jsfuck-encoder.js', ROOT);
const OUT = new URL('tests/fixtures/jsfuck-oracle.json', ROOT);

// ---------------------------------------------------------------------------
// Encoder shim
// ---------------------------------------------------------------------------

const encoderSource = readFileSync(ENCODER, 'utf8');
const encoderSelf = {};
const installEncoder = new Function(
    'window',
    'exports',
    'self',
    encoderSource + '\n;return this.JSFuck;',
);
const JSFuck = installEncoder.call(encoderSelf, encoderSelf, encoderSelf, encoderSelf);
if (!JSFuck || typeof JSFuck.encode !== 'function') {
    throw new Error('jsfuck-encoder.js did not install JSFuck.encode');
}

/// A whole PROGRAM, encoded the way jsfuck.com's "eval" checkbox does it:
/// Function(<source>)() with this bound to the global object.
const program = (source) => JSFuck.encode(source, true, false);
/// A literal FRAGMENT, encoded as a bare value expression.
const fragment = (text) => JSFuck.encode(text, false, false);

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

const programs = {
    // --- the seams decode_jsfuck reports `captured` on ---------------------
    //
    // `Function("return 1")()`: the body has no side effect, so call_from_source
    // falls through every recognised shape to the "payload code: capture"
    // arm. This is the minimal captured:true case.
    retOne: 'return 1',
    // Two digits — different digit-assembly path than retOne.
    retFortyTwo: 'return 42',
    // A negative and a fractional number: the `-` and `.` characters are not
    // in the encoder's direct mapping and go through the escape recipe.
    retFloat: 'return 1.5',
    // `alert(1)` — the canonical jsfuck.com demo. Letters come from prototype
    // member names, and the body has no `return`, so it is raw payload.
    alertOne: 'alert(1)',
    // A member call on a global-ish identifier: the dot and the quotes force
    // the escape recipe; the payload is longer than one token.
    logX: 'console.log("x")',
    // Arithmetic in the body. The encoder's `*` handling emits the escape
    // recipe, which historically produced a slash: the engine answers
    // "return 6/527" for "return 6*7". Pinned because it is a genuine
    // encoder/decoder interaction, not a decoder bug.
    mulExpr: 'return 6*7',
    // A bare number STATEMENT — no keyword at all. Shortest raw payload.
    bareOne: '1',
    // A bare quoted string statement: capture, not a `return "..."` value.
    bareQuoted: '"abc"',
    // A single identifier.
    bareIdent: 'a',
    // The same seam with NO argument: eval(undefined) captures the empty
    // string, not null. A port using `unwrap_or_default()` semantics passes;
    // one that treated a missing argument as "no capture" fails.
    evalNoArgs: 'return eval',
    // `return "hi"` — call_from_source RECOGNISES this shape and answers the
    // unescaped VALUE ("hi") instead of capturing. Same Function seam as
    // retOne, opposite branch, so a port that always captured at the seam
    // would answer `return "hi"` here and fail.
    retQuoted: 'return "hi"',
};

// --- expressions -----------------------------------------------------------
//
// Built from encoder fragments so the operators are canonical JSFuck rather
// than something that merely parses. Each entry's comment says which value
// model branch it is there to pin.

const f = {
    at: fragment('at'),
    join: fragment('join'),
    split: fragment('split'),
    concat: fragment('concat'),
    toString: fragment('toString'),
    constructor: fragment('constructor'),
    name: fragment('name'),
    fontcolor: fragment('fontcolor'),
    italics: fragment('italics'),
    entries: fragment('entries'),
    source: fragment('source'),
    zero: fragment('0'),
};

const expressions = {
    // `[] + []` -> "" (two arrays unwrap to empty strings, then concat).
    emptyConcat: '[]+[]',
    // `[] + [][[]]` -> "undefined" (member read of the missing element).
    undefConcat: '[]+[][[]]',
    // `![] + []` -> "false".
    falseConcat: '![]+[]',
    // `!![] + []` -> "true".
    trueConcat: '!![]+[]',
    // `+![] + []` -> "NaN": unary plus on a boolean-derived string.
    nanConcat: '+![]+[]',
    // `(![]+[])[+[]]` -> "f": the array-index arm on a string receiver.
    falseIndexZero: '(![]+[])[+[]]',
    // String `at` with a positive index, reached through the native method.
    strAtZero: '([][[]]+[])[' + f.at + '](+[])',
    // String `at` with index 1 -> "n" of "undefined".
    strAtOne: '([][[]]+[])[' + f.at + '](+!+[])',
    // Array `at`: `[[+[]]]["at"](+[])` -> 0 (a NUMBER, so decode answers null
    // with captured:false — the value-model arm still has to run without
    // erroring, and a port that threw here would answer null for the wrong
    // reason).
    arrAtZero: '[[+[]]][' + f.at + '](+[])',
    // `[][""+[] ? ...]` — array `join` with no separator on numbers -> "0,0".
    // The engine's join arm uses "," when the argument is absent.
    arrJoinDefault: '([+[]]+[+[]])[' + f.join + ']()',
    // `"ab"["concat"]("c")` -> "abc": the string-concat arm, which is
    // distinct from `+`.
    strConcat: '(' + fragment('ab') + ')[' + f.concat + '](' + fragment('c') + ')',
    // `"x"["fontcolor"]("red")`: HTML wrapper arm; the quotes in the output
    // are the engine's own, so this pins the exact shape.
    fontRed: '(' + fragment('x') + ')[' + f.fontcolor + '](' + fragment('red') + ')',
    // `"x"["italics"]()`: the no-argument wrapper arm.
    italicsX: '(' + fragment('x') + ')[' + f.italics + ']()',
    // `[]["entries"]() + ""` -> "[object Array Iterator]": the iterator value
    // type, which only `entries` produces.
    entriesIterator: '[][' + f.entries + ']()+[]',
    // `(10)["toString"](2)`: radix formatting. The decoder's toString arm
    // must reject radix 1 and accept 2..36.
    radixTwo: '(+[+!+[]+[+[]]])[' + f.toString + '](' + fragment('2') + ')',
    // `[]["at"] + ""`: a native function read as a value stringifies to its
    // `function ... { [native code] }` source text. This is the arm that lets
    // the encoder spell "at" out of the Function prototype.
    nativeAtText: '[][' + f.at + ']+[]',
    // `[]["at"]["constructor"] + ""` -> Function's source text, i.e. the
    // FunctionModel value. Pins that Model stringifies as a function.
    fnConstructorText: '[][' + f.at + '][' + f.constructor + ']+[]',
    // `[]["at"]["constructor"]["name"]` -> "Function": the name arm.
    fnName: '[][' + f.at + '][' + f.constructor + '][' + f.name + ']',
    // `Function("return/ab/")()["source"]` -> "ab": regexp source plumbing.
    regexpSource:
        '[][' + f.at + '][' + f.constructor + '](' +
        fragment('return/') + '+' + fragment('ab') + '+' + fragment('/') +
        ')()[' + f.source + ']',
    // `Function("return escape")()("a b")` -> "a%20b": the legacy escape
    // builtin, which only the encoder's percent recipes reach.
    escapeSpace:
        '[][' + f.at + '][' + f.constructor + '](' + fragment('return escape') +
        ')()(' + fragment('a b') + ')',
    // `Function("return eval")()("xyz")` -> eval seam, captured:true with a
    // payload that did NOT come from the encoder's wrapWithEval shape. This
    // proves the seam is reached by two independent spellings, so a port
    // that special-cased the encoder's exact output would fail here.
    evalSeam:
        '[][' + f.at + '][' + f.constructor + '](' + fragment('return eval') +
        ')()(' + fragment('xyz') + ')',
    // `Function("return 7")()` written by hand rather than by the encoder's
    // wrapper: same payload, different surrounding syntax.
    fnDirect:
        '[][' + f.at + '][' + f.constructor + '](' + fragment('return 7') + ')()',
    // --- refusal cases. Each must answer value:null, captured:false, and each
    // --- refuses for a DIFFERENT reason, so a port that returned null
    // --- unconditionally would pass these but fail every case above.
    // Trailing `+` with no right operand: parse error after a complete value.
    refuseTrailingPlus: '[]+[]+',
    // A character outside the JSFuck alphabet: parse_primary's error arm.
    refuseAlienChar: '[]%[]',
    // Member read on UNDEFINED — read_member's explicit Undefined refusal.
    refuseMemberOnUndefined: '[][[]][' + f.at + ']',
    // Index past the end of a string: a VALID program answering undefined,
    // which decode reports as null with captured:false (not an error).
    undefinedIndex: '([][[]]+[])[+!+[]+[+[]]+[+[]]]',
    // `"ab"["join"]()` — join on a non-array receiver is an explicit
    // ERROR arm, and errors and undefined both answer null. Distinct code
    // path from the index miss above, same wire answer: both must be
    // exercised so a port that conflated them still has to get the
    // non-null cases right.
    refuseJoinOnString: '(' + fragment('ab') + ')[' + f.join + ']()',
    // A fractional index: `0.5` is not a canonical array index and the string
    // `at` arm refuses it, answering undefined.
    refuseFractionalIndex: '([][[]]+[])[' + f.at + '](+[+[]]/[+!+[]+[+[]]])',
    // Radix 0 is outside 2..36, so the toString arm answers the plain
    // string form "0" rather than a radix expansion — the arm's FALLBACK,
    // which a port that clamped the radix would answer differently.
    radixOutOfRange: '(+[+[]])[' + f.toString + '](![])',
    // Radix 1 likewise. Distinct from 0 because `to_number(![])` is 0 and
    // `to_number(+![])` is -0, and the range test must reject both.
    radixOne: '(+[+[]])[' + f.toString + '](' + fragment('1') + ')',
    // A double quote inside the fontcolor argument is HTML-escaped to
    // &quot; — the only place the model rewrites its own output.
    fontQuote: '(' + fragment('x') + ')[' + f.fontcolor + '](' + fragment('a"b') + ')',
    // `Function("return foo")()` — an unknown builtin NAME is an explicit
    // error in call_from_source, not an undefined value. A port that fell
    // through to a default would answer null here too, so this is only
    // discriminating together with radixOutOfRange above.
    unknownBuiltinName:
        '[][' + f.at + '][' + f.constructor + '](' + fragment('return foo') + ')()',
    // `Number`/`String`/`Boolean` read through an instance's constructor
    // stringify to their native source text — three keys of the same
    // CONSTRUCTOR-value stringification arm.
    numberCtorText: '(+[])[' + f.constructor + ']+[]',
    stringCtorText: '([]+[])[' + f.constructor + ']+[]',
    booleanCtorText: '(!![])[' + f.constructor + ']+[]',
};

// --- detection boundaries --------------------------------------------------

const detection = {
    // Under 12 characters, so the length test fires before purity.
    emptyInput: '',
    whitespaceOnly: '   \n\t  ',
    // Exactly 11 characters: still "too short".
    elevenChars: 'x'.repeat(11),
    // 14 characters, all charset: the smallest body that can be detected.
    minimalCharset: '[][][][][][][]',
    // Plain source: purity 0%, and the reason names 0 charset bytes.
    plainSource: 'var a = 1; // hi there',
    // Pure-looking but one tab: 18/19 = 94.7%, just under the 95% floor.
    oneTab: '[][\t][][][][][][][]',
    // One non-ASCII character: purity 12/13 = 92.3%.
    oneNonAscii: '[][][][][][]\u00fc',
    // A 4096-long `+` run is allowed; 4097 is refused. Both are pure.
    chainAtLimit: '[]' + '+'.repeat(4096) + '[]',
    chainOverLimit: '[]' + '+'.repeat(4097) + '[]',
    // A real detector negative: parentheses and letters only.
    callSyntax: '[]["at"]["constructor"]("return 1")()',
};

// ---------------------------------------------------------------------------
// Capture
// ---------------------------------------------------------------------------

const bridge = await import('../src/js/unpack-bridge.js');

const oracle = {
    note:
        'Captured from the shipped wasm engine (unpack-rs/.cache/engine.wasm) via ' +
        'src/js/unpack-bridge.js. `programs` sources are produced by the shipped ' +
        'JSFuck 0.5.0 encoder (test/fixtures/jsfuck-encoder.js) with wrapWithEval, ' +
        'which emits Function(body)() — the seam `captured` reports on.',
    capturedAt: 'fixed-input set; regenerate with node unpack-rs/scripts/jsfuck-oracle.mjs',
    families: { programs: {}, expressions: {}, detection: {} },
};

const rows = [];

async function capture(family, name, source, origin) {
    const detect = await bridge.detectJsfuck(source);
    let decode;
    try {
        decode = await bridge.decodeJsfuck(source);
    } catch (err) {
        // A trap is an ANSWER too: the shipped engine refuses some inputs by
        // panicking (Date() reads a clock wasm32 does not have). Recording it
        // as a value would hide that, so the case is reported and skipped.
        rows.push({ family, name, origin, source, detect, decode: null, trap: String(err.message) });
        return;
    }
    oracle.families[family][name] = { source, detect, decode };
    rows.push({ family, name, origin, source, detect, decode });
}

for (const [name, source] of Object.entries(programs)) {
    await capture('programs', name, program(source), 'program ' + JSON.stringify(source));
}
for (const [name, source] of Object.entries(expressions)) {
    await capture('expressions', name, source, 'expression');
}
for (const [name, source] of Object.entries(detection)) {
    await capture('detection', name, source, 'detection');
}

writeFileSync(OUT, JSON.stringify(oracle, null, 1) + '\n');

// ---------------------------------------------------------------------------
// Report — verbose on purpose; this is the evidence the port claim rests on.
// ---------------------------------------------------------------------------

for (const r of rows) {
    const d = r.detect;
    const c = r.decode;
    console.log(
        [
            r.family.padEnd(12),
            r.name.padEnd(26),
            'len=' + String(r.source.length).padEnd(6),
            'detected=' + String(d.detected).padEnd(6),
            'purity=' + String(d.purity).padEnd(20),
            r.trap ? 'TRAP ' + r.trap.slice(0, 40) : 'captured=' + String(c.captured).padEnd(6),
            r.trap ? '' : 'value=' + JSON.stringify(c.value),
        ].join(' '),
    );
}

const counted = rows.filter((r) => !r.trap);
const captured = counted.filter((r) => r.decode.captured === true);
const decoded = counted.filter((r) => r.decode.captured === false && r.decode.value !== null);
const nulls = counted.filter((r) => r.decode.captured === false && r.decode.value === null);
const detected = counted.filter((r) => r.detect.detected === true);

console.log('');
console.log('wrote tests/fixtures/jsfuck-oracle.json');
console.log('cases:                 ' + counted.length);
console.log('  programs:            ' + rows.filter((r) => r.family === 'programs' && !r.trap).length);
console.log('  expressions:         ' + rows.filter((r) => r.family === 'expressions' && !r.trap).length);
console.log('  detection:           ' + rows.filter((r) => r.family === 'detection' && !r.trap).length);
console.log('trapped (excluded):    ' + (rows.length - counted.length));
console.log('detect.detected=true:  ' + detected.length);
console.log('decode captured=true:  ' + captured.length + '   <-- the non-vacuous decode assertions');
console.log('decode string, no cap: ' + decoded.length);
console.log('decode null, no cap:   ' + nulls.length + '   (refusals)');

if (captured.length === 0) {
    console.log('');
    console.log('WARNING: ZERO cases answered captured:true.');
    console.log('The decode capture path is UNPROVEN — the gate would be pinning');
    console.log('nulls again. Do not treat the port as verified.');
    process.exitCode = 1;
}
