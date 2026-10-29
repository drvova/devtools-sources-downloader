// JSFuck ([], (), !, +) decoding without eval/Function.
//
// The language the canonical encoder (jsfuck.com) emits is tiny: arrays, groups,
// unary ! and +, binary +, computed member access and calls. Everything else is
// builtins reached through that surface: Array.prototype methods, stringification
// of real functions ("function Boolean() { [native code] }"), String.prototype
// helpers (fontcolor, italics, at) and Function/eval reached via constructor
// lookups.
//
// The interpreter below evaluates that grammar over REAL JavaScript values, so
// +, !, String(), Number() and every method call delegate to the engine and match
// native semantics exactly. Only the two execution seams are modeled instead of
// invoked (CSP forbids them in the panel):
//   - Function(...): a fromSource function object whose body we micro-evaluate
//     when called. Canonical bodies are "return <builtin>", "return/false/",
//     "return\"<payload>\"" or the payload code itself (that call is a capture).
//   - eval(...): records a capture instead of executing.

const CHARSET = '[]()!+';

const MAX_PARSE_NODES = 2_000_000;
const MAX_PARSE_DEPTH = 10_000;

function longestOperatorChain(source) {
    let longest = 0;
    let run = 0;
    for (let i = 0; i < source.length; i++) {
        if (source[i] === '+') {
            run++;
            if (run > longest) longest = run;
        } else {
            run = 0;
        }
    }
    return longest;
}

// Detection ports disrobe's jsfuck heuristic: only the four characters of the
// language (plus whitespace), high purity, and a long-enough body.
function detectJsfuck(source) {
    const trimmed = source.trim();
    if (trimmed.length < 12) return { detected: false, reason: 'too short' };

    let hits = 0;
    let counted = 0;
    for (let i = 0; i < trimmed.length; i++) {
        const c = trimmed[i];
        if (CHARSET.includes(c)) hits++;
        if (c !== ' ') counted++;
    }
    const purity = counted > 0 ? hits / counted : 0;
    if (purity < 0.95 || hits < 12) {
        return {
            detected: false,
            reason: `purity ${(purity * 100).toFixed(1)}% (${hits} charset bytes)`,
        };
    }
    const chain = longestOperatorChain(trimmed);
    if (chain > 4096) {
        return { detected: false, reason: `operator chain too long (${chain})` };
    }
    return { detected: true, purity, chain };
}

class JsFuckError extends Error {
    constructor(message, index) {
        super(`jsfuck decode error at ${index}: ${message}`);
        this.name = 'JsFuckError';
    }
}

function interpretJsfuck(source) {
    let pos = 0;
    let nodes = 0;
    let capture = null;

    const peek = () => source[pos];
    // Whitespace-only: canonical JSFuck has no other bytes, so anything else is
    // a structural error we want to refuse loudly, not silently swallow.
    const skipNoise = () => {
        while (pos < source.length && /\s/.test(source[pos])) pos++;
    };

    function expect(ch) {
        skipNoise();
        if (peek() !== ch) throw new JsFuckError(`expected ${ch}`, pos);
        pos++;
    }

    // Groups and array literals recurse (structural nesting, small). Plus chains
    // and member/call suffixes iterate at the same depth: real payload strings
    // are thousands of atoms long and must not consume one stack frame each.
    function parsePrimary(depth) {
        if (++nodes > MAX_PARSE_NODES) throw new JsFuckError('expression budget exceeded', pos);
        if (depth > MAX_PARSE_DEPTH) throw new JsFuckError('nesting too deep', pos);
        skipNoise();
        const c = peek();
        if (c === undefined) throw new JsFuckError('unexpected end of input', pos);
        if (c === '(') {
            pos++;
            const value = parseExpression(depth + 1);
            expect(')');
            return value;
        }
        if (c === '[') {
            pos++;
            const elements = [];
            skipNoise();
            if (peek() === ']') {
                pos++;
                return [];
            }
            for (;;) {
                elements.push(parseExpression(depth + 1));
                skipNoise();
                if (peek() === ',') {
                    pos++;
                    skipNoise();
                    if (peek() === ']') break; // trailing comma tolerated
                    continue;
                }
                break;
            }
            expect(']');
            return elements;
        }
        if (c === '!') {
            pos++;
            return !parsePrimary(depth + 1);
        }
        if (c === '+') {
            pos++;
            return Number(parsePrimary(depth + 1));
        }
        throw new JsFuckError(`unexpected character ${JSON.stringify(c)}`, pos);
    }

    function parseSuffixes(value, depth) {
        // Real JS binds `this` at CALL time from the member-read receiver:
        // `a[b](c)` runs with this=a; a detached fn call gets this=undefined.
        let receiver;
        for (;;) {
            skipNoise();
            const c = peek();
            if (c === '[') {
                pos++;
                const key = parseExpression(depth + 1);
                expect(']');
                receiver = value;
                value = readMember(value, key);
            } else if (c === '(') {
                pos++;
                const args = [];
                skipNoise();
                if (peek() !== ')') {
                    for (;;) {
                        args.push(parseExpression(depth + 1));
                        skipNoise();
                        if (peek() === ',') {
                            pos++;
                            continue;
                        }
                        break;
                    }
                }
                expect(')');
                value = callValue(value, args, receiver);
                receiver = undefined;
            } else {
                return value;
            }
        }
    }

    function parseExpression(depth) {
        if (++nodes > MAX_PARSE_NODES) throw new JsFuckError('expression budget exceeded', pos);
        let value = parseSuffixes(parsePrimary(depth), depth);
        for (;;) {
            skipNoise();
            if (peek() !== '+') return value;
            pos++;
            const right = parseSuffixes(parsePrimary(depth), depth);
            value = jsPlus(value, right);
        }
    }

    function unwrap(v) {
        return v && typeof v === 'object' && Object.prototype.hasOwnProperty.call(v, '__jsfuckRaw')
            ? v.__jsfuckRaw
            : v;
    }

    function unwrapToPrimitive(v) {
        if (v === null || v === undefined) return v;
        if (typeof v === 'object') {
            if (Array.isArray(v)) return v.join(',');
            if (v === FUNCTION_MODEL) return 'function Function() { [native code] }';
            if (v === EVAL_MODEL) return 'function eval() { [native code] }';
            return String(v);
        }
        return v;
    }

    function jsPlus(left, right) {
        const l = unwrapToPrimitive(unwrap(left));
        const r = unwrapToPrimitive(unwrap(right));
        if (typeof l === 'string' || typeof r === 'string') {
            return String(l) + String(r);
        }
        // Real engine semantics cover number+function ("101function Boolean()
        // { [native code] }"), array+array, number+array, etc.
        return l + r;
    }

    const FUNCTION_MODEL = { __jsfuckFunction: true };
    const EVAL_MODEL = { __jsfuckEval: true };

    function isModeledFn(v) {
        return v === FUNCTION_MODEL || v === EVAL_MODEL;
    }

    function readMember(base, keyExpr) {
        const key = String(unwrapToPrimitive(unwrap(keyExpr)));
        const target = unwrap(base);
        if (target && typeof target === 'object' && target.__jsfuckGlobal) {
            return readGlobalMember(key);
        }
        if (target === null || target === undefined) {
            throw new JsFuckError(`member access on ${target} for key ${JSON.stringify(key)}`, pos);
        }
        if (isModeledFn(target) || typeof target === 'function') {
            if (key === 'constructor') return FUNCTION_MODEL;
            if (key === 'name') return fnName(target);
        }
        const value = target[key];
        return value;
    }

    function fnName(target) {
        if (target === FUNCTION_MODEL) return 'Function';
        if (target === EVAL_MODEL) return 'eval';
        return target.name || '';
    }

    function readGlobalMember(key) {
        if (key === 'eval') return EVAL_MODEL;
        if (key === 'Function') return FUNCTION_MODEL;
        const value = globalThis[key];
        return value;
    }

    function callValue(callee, args, receiver) {
        const target = unwrap(callee);
        const realArgs = args.map((a) => unwrap(a));
        if (target === FUNCTION_MODEL) {
            return makeFromSource(realArgs);
        }
        if (target === EVAL_MODEL) {
            // eval(payload) is the capture point: record, never execute.
            capture = String(unwrapToPrimitive(realArgs[0]));
            return undefined;
        }
        if (target && typeof target === 'object' && target.__jsfuckFn) {
            return callFromSource(target);
        }
        if (typeof target === 'function') {
            const thisArg = receiver === undefined ? undefined : unwrap(receiver);
            if (thisArg === undefined) return target(...realArgs);
            return Reflect.apply(target, thisArg, realArgs);
        }
        throw new JsFuckError(`call target is ${typeof target}, not a function`, pos);
    }

    function makeFromSource(args) {
        const body = args.map((a) => String(unwrapToPrimitive(a))).join(',');
        return { __jsfuckFn: true, body };
    }

    function callFromSource(fnObj) {
        const body = fnObj.body;
        // Canonical bodies produced by the encoder: "return <builtin name>",
        // "return/<pattern>/<flags>", "return\"<payload>\"", "return this",
        // "return eval". Anything else is raw payload code — capturing it is the
        // entire point of the decode.
        let m = /^return\s+([A-Za-z_$][\w$]*)$/.exec(body);
        if (m) {
            const name = m[1];
            if (name === 'this') return { __jsfuckGlobal: true };
            if (name === 'eval') return EVAL_MODEL;
            const builtin = globalThis[name];
            if (typeof builtin === 'function') return builtin;
            if (builtin !== undefined) return builtin;
            throw new JsFuckError(`unknown builtin ${JSON.stringify(name)} in fromSource`, pos);
        }
        m = /^return\s*\/(.*)\/([a-z]*)\s*$/.exec(body);
        if (m) {
            return new RegExp(m[1], m[2]);
        }
        m = /^return\s*"((?:[^"\\]|\\.)*)"\s*$/.exec(body);
        if (m) {
            return unescapeLiteral(m[1]);
        }
        // Payload code: capture instead of executing.
        capture = body;
        return undefined;
    }

    function unescapeLiteral(raw) {
        return raw.replace(
            /\\(?:(u[0-9a-fA-F]{4})|(x[0-9a-fA-F]{2})|([0-7]{1,3})|(\r|\n)|(.))/g,
            (all, u, x, oct, nl, ch) => {
                if (u) return String.fromCharCode(parseInt(u.slice(1), 16));
                if (x) return String.fromCharCode(parseInt(x.slice(1), 16));
                if (oct) return String.fromCharCode(parseInt(oct, 8));
                if (nl) return '';
                if (ch === 'n') return '\n';
                if (ch === 'r') return '\r';
                if (ch === 't') return '\t';
                if (ch === 'b') return '\b';
                if (ch === 'f') return '\f';
                if (ch === 'v') return '\v';
                if (ch === '0') return '\0';
                return ch;
            },
        );
    }

    const value = parseExpression(0);
    skipNoise();
    if (pos < source.length) throw new JsFuckError(`trailing input at ${pos}`, pos);
    return { value, capture };
}

// Decode returns the captured payload (what the script would have executed) when
// the program reaches a Function/eval seam, otherwise the string the expression
// evaluates to.
function decodeJsfuck(source) {
    const { value, capture } = interpretJsfuck(source);
    if (typeof capture === 'string') return { value: capture, captured: true };
    if (typeof value === 'string') return { value, captured: false };
    return { value: null, captured: false };
}

export { detectJsfuck, decodeJsfuck, interpretJsfuck, longestOperatorChain };
