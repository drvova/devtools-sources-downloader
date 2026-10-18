// Packer and obfuscation layers that decode by pure static rewriting.
//
// Ports, with their origins in the research tree (disrobe / DeScrypt):
//   - Dean Edwards' packer: fully static by construction — the payload, base,
//     count and word list are string/number literals in the trailing call, and
//     unpacking is a lookup substitution over the payload text. (packer.rs)
//   - aaencode / jjencode / jsfiretruck: detection-only here. Their decode in
//     disrobe goes through a sandboxed eval; the DevTools panel forbids
//     execution, so we detect and report a refusal instead. (esoteric/*.rs)
//   - obfuscator.io: marker census for the report. (detection.rs)
//   - String-array + rotator: static rebuild. The array declaration is captured
//     as literals, the push/shift rotation is simulated by finding the pivot
//     the runtime loop stops at, the IIFE is deleted, and the rotated array is
//     re-emitted. A plain index-only decoder gets its calls inlined statically;
//     anything richer (base64/rc4 pipelines) is refused, not executed.
//     (string_array/detect.rs, rotate.rs, inline.rs)

const PACKER_SIGNATURE = 'function(p,a,c,k,e,';
const MAX_PACKER_LAYERS = 32;

// ------------------------------------------------------------ Dean Edwards

function unescapeJsLiteral(raw) {
    var out = '';
    for (var i = 0; i < raw.length; i++) {
        var c = raw[i];
        if (c !== '\\') {
            out += c;
            continue;
        }
        var n = raw[++i];
        if (n === undefined) break;
        if (n === 'n') out += '\n';
        else if (n === 'r') out += '\r';
        else if (n === 't') out += '\t';
        else if (n === 'b') out += '\b';
        else if (n === 'f') out += '\f';
        else if (n === 'v') out += '\v';
        else if (n === '0') out += '\0';
        else if (n === 'x') out += String.fromCharCode(parseInt(raw.substr(i + 1, 2), 16) || 0), i += 2;
        else if (n === 'u') out += String.fromCharCode(parseInt(raw.substr(i + 1, 4), 16) || 0), i += 4;
        else out += n;
    }
    return out;
}

function digitValue(c) {
    if (c >= '0' && c <= '9') return c.charCodeAt(0) - 48;
    if (c >= 'a' && c <= 'z') return c.charCodeAt(0) - 87;
    if (c >= 'A' && c <= 'Z') return c.charCodeAt(0) - 55;
    return -1;
}

function baseDecodeToken(token, base) {
    var value = 0;
    for (var i = 0; i < token.length; i++) {
        var d = digitValue(token[i]);
        if (d < 0 || d >= base) return -1;
        value = value * base + d;
    }
    return value;
}

// Reads one argument after the packer's "}(" — a string literal, a number, or a
// balanced non-literal token we only need to skip.
function readPackerArg(text, index) {
    var i = index;
    while (i < text.length && /\s/.test(text[i])) i++;
    var quote = text[i];
    if (quote === "'" || quote === '"') {
        var j = i + 1;
        var raw = '';
        while (j < text.length && text[j] !== quote) {
            if (text[j] === '\\') {
                raw += text[j] + (text[j + 1] || '');
                j += 2;
            } else {
                raw += text[j];
                j++;
            }
        }
        if (j >= text.length) return null;
        return { type: 'string', value: unescapeJsLiteral(raw), end: j + 1 };
    }
    var numMatch = /^[-+]?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?)/.exec(text.slice(i));
    if (numMatch) {
        var rawNum = numMatch[0];
        // A literal must be followed by a delimiter, not by identifier junk.
        if (!/^[\s,)%]|^$/.test(text.slice(i + rawNum.length))) return null;
        var num = parseIntLiteral(rawNum);
        if (num === null) return null;
        return { type: 'number', value: num, end: i + rawNum.length };
    }
    if (text[i] === '{' || text[i] === '[' || text[i] === '(') {
        var depth = 0;
        var k = i;
        while (k < text.length) {
            if ('([{'.includes(text[k])) depth++;
            else if (')]}'.includes(text[k])) {
                depth--;
                if (depth === 0) return { type: 'other', value: text.slice(i, k + 1), end: k + 1 };
            }
            k++;
        }
        return null;
    }
    if (/[a-z]/.test(text[i] || '')) {
        // Word tokens like `undefined` — skip to the next delimiter.
        var w = i;
        while (w < text.length && /[\w$]/.test(text[w])) w++;
        return { type: 'other', value: text.slice(i, w), end: w };
    }
    return null;
}

function parsePackerCall(text, callStart) {
    // callStart points at the '(' of "}(". Scan the argument list at top level.
    var args = [];
    var i = callStart + 1;
    for (;;) {
        while (i < text.length && /\s|,/.test(text[i])) i++;
        if (text[i] === ')') return { args: args, end: i + 1 };
        var arg = readPackerArg(text, i);
        if (!arg) return null;
        i = arg.end;
        // `.split('|')` suffix on the words literal.
        var rest = /^\s*\.split\s*\(\s*(['"]).*?\1\s*\)/.exec(text.slice(i));
        if (rest && arg.type === 'string') {
            arg.split = unescapeJsLiteral(rest[0].replace(/^\.split\s*\(\s*['"]|['"]\s*\)$/g, ''));
            i += rest[0].length;
        }
        args.push(arg);
        if (args.length > 8) return null;
    }
}

export function detectPacker(text) {
    var sigIdx = text.indexOf(PACKER_SIGNATURE);
    if (sigIdx < 0) return null;
    var callIdx = text.indexOf('}(', sigIdx);
    if (callIdx < 0) return null;
    var parsed = parsePackerCall(text, callIdx + 1);
    if (!parsed || parsed.args.length < 4) return null;
    var payload = parsed.args[0];
    var base = parsed.args[1];
    var count = parsed.args[2];
    var words = parsed.args[3];
    if (payload.type !== 'string' || base.type !== 'number' || count.type !== 'number' || words.type !== 'string') return null;
    if (base.value < 2 || base.value > 62) return null;
    var wordList = words.value.split(words.split || '|');
    return { payload: payload.value, base: base.value, count: count.value, words: wordList };
}

function unpackWith(payload, base, words) {
    return payload.replace(/\w+/g, function (token) {
        var idx = baseDecodeToken(token, base);
        if (idx >= 0 && idx < words.length && words[idx] !== '') return words[idx];
        return token;
    });
}

// Peels every packer layer present (repacked outputs nest), stopping when a pass
// stops changing the text.
export function unpackPacker(text) {
    var current = text;
    for (var layer = 0; layer < MAX_PACKER_LAYERS; layer++) {
        var found = detectPacker(current);
        if (!found) break;
        var next = unpackWith(found.payload, found.base, found.words);
        if (next === current) break;
        current = next;
    }
    return current === text ? null : current;
}

// ------------------------------------------------------- esoteric detectors

const AA_KAOMOJI = ['ﾟ', 'ω', 'ﾉ', 'Θ', 'ｰ', 'Д', 'Σ', 'ε', 'ノ', '∇', '°', '・'];

export function detectAaencode(source) {
    var trimmed = source.trim();
    if (trimmed.length < 80) return null;
    var bannerHits = 0;
    if (trimmed.includes('ﾟωﾟﾉ')) bannerHits++;
    if (trimmed.includes('ﾟДﾟ')) bannerHits++;
    if (trimmed.includes('(ﾟΘﾟ)') || trimmed.includes('(ﾟｰﾟ)')) bannerHits++;
    var kaomoji = 0;
    var total = 0;
    for (var c of trimmed) {
        total++;
        if (AA_KAOMOJI.includes(c)) kaomoji++;
    }
    var density = total ? kaomoji / total : 0;
    if (bannerHits >= 1 && density >= 0.05) {
        return { tool: 'aaencode', detail: 'kaomoji shell (execution required to decode)', bannerHits: bannerHits, density: density };
    }
    return null;
}

export function detectJjencode(source) {
    var trimmed = source.trim();
    if (trimmed.length < 80) return null;
    if (trimmed.includes('=~[]') && (trimmed.includes('{___:++') || trimmed.includes('{ ___:++'))) {
        return { tool: 'jjencode', detail: '$=~[] global-object shell (execution required to decode)' };
    }
    return null;
}

const FIRETRUCK_CHARS = '[]()!+./';

export function detectJsfiretruck(source) {
    var trimmed = source.trim();
    if (trimmed.length < 256) return null;
    var hits = 0;
    var dotSlash = 0;
    var whitespace = 0;
    for (var i = 0; i < trimmed.length; i++) {
        var b = trimmed[i];
        if (FIRETRUCK_CHARS.includes(b)) {
            hits++;
            if (b === '.' || b === '/') dotSlash++;
        } else if (b === ' ' || b === '\n' || b === '\r' || b === '\t') whitespace++;
    }
    var counted = trimmed.length - whitespace;
    if (counted <= 0) return null;
    var purity = hits / counted;
    var dsDensity = dotSlash / counted;
    if (purity >= 0.9 && dsDensity > 0.005 && hits >= 256) {
        return { tool: 'jsfiretruck', detail: '[]()!+./ shell (execution required to decode)', purity: purity };
    }
    return null;
}

// ---------------------------------------------------- obfuscator.io markers

const OBFUSCATOR_MARKERS = [
    { name: 'banner', test: /obfuscator\.io|javascript-obfuscator/ },
    { name: 'hex identifiers', test: /\b_0x[0-9a-fA-F]{3,}\b/ },
    { name: 'string array rotation', test: /\[\s*['"][^'"]+['"]\s*\]\s*\.\s*concat|\.shift\s*\(\s*\)|\.push\s*\(\s*[\w$]+\s*\[\s*0\s*\]/ },
    { name: 'rotation IIFE', test: /\(\s*function\s*\([^)]*\)\s*\{[\s\S]*?parseInt/ },
    { name: 'base64 decoder', test: /atob\s*\(|ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz/ },
    { name: 'rc4 decoder', test: /\b_0x[0-9a-fA-F]+\s*\(\s*_0x[0-9a-fA-F]+\s*,\s*_0x[0-9a-fA-F]+/ },
    { name: 'switch dispatcher', test: /switch\s*\(\s*_?0x[\w$]*\s*\)|switch\s*\(\s*[\w$]+\s*\+\s*parseInt/ },
    { name: 'boolean shorthand', test: /!!\[\]|\[\s*\]/ },
    { name: 'hex literals', test: /=\s*0x[0-9a-fA-F]{2,}\b/ },
    { name: 'self defending', test: /self.?defending/i },
    { name: 'debug protection', test: /debug.?protect/i },
    { name: 'console disable', test: /console\s*\[|call\s*\(\s*this\s*,\s*console\)/ },
    { name: 'opaque predicate', test: /\?\s*['"][^'"]*['"]\s*:\s*['"][^'"]*['"]/ },
    { name: 'split string concat', test: /['"][^'"]{0,3}\['"\s]\s*\+\s*concat/ },
    { name: 'renamed properties', test: /\.\s*_0x[0-9a-fA-F]{3,}\b/ }
];

export function detectObfuscatorIo(text) {
    var window = text.slice(0, 256 * 1024);
    var markers = [];
    for (var i = 0; i < OBFUSCATOR_MARKERS.length; i++) {
        var m = OBFUSCATOR_MARKERS[i];
        var count = 0;
        var re = new RegExp(m.test.source, m.test.flags + (m.test.flags.includes('g') ? '' : 'g'));
        var match;
        while ((match = re.exec(window))) {
            count++;
            if (count >= 200) break;
            if (match.index === re.lastIndex) re.lastIndex++;
        }
        if (count) markers.push({ marker: m.name, count: count });
    }
    if (!markers.length) return null;
    var score = markers.length;
    var hasStrong = markers.some(function (m) { return m.marker === 'banner' || m.marker === 'string array rotation' || m.marker === 'rc4 decoder'; });
    if (!hasStrong && score < 3) return null;
    return { tool: 'obfuscator-io', detail: markers.map(function (m) { return m.marker; }).join(', '), markers: markers };
}

// --------------------------------------------------- string array + rotator

function parseArrayLiterals(body) {
    var out = [];
    var i = 0;
    while (i < body.length) {
        var c = body[i];
        if (c === "'" || c === '"') {
            var quote = c;
            var buf = '';
            i++;
            while (i < body.length && body[i] !== quote) {
                if (body[i] === '\\') {
                    var n = body[++i];
                    if (n === undefined) return null;
                    if (n === 'n') buf += '\n';
                    else if (n === 't') buf += '\t';
                    else if (n === 'r') buf += '\r';
                    else if (n === '\\') buf += '\\';
                    else if (n === "'") buf += "'";
                    else if (n === '"') buf += '"';
                    else if (n === '0') buf += '\0';
                    else if (n === 'x') {
                        var hex = body.substr(i + 1, 2);
                        if (!/^[0-9a-fA-F]{2}$/.test(hex)) return null;
                        buf += String.fromCharCode(parseInt(hex, 16));
                        i += 2;
                    } else buf += n;
                    i++;
                } else {
                    buf += body[i];
                    i++;
                }
            }
            i++; // consume the closing quote
            if (i > body.length) return null; // unterminated literal
            out.push(buf);
        } else if (c === ',' || /\s/.test(c)) {
            i++;
        } else {
            return null; // expressions in the array -> refuse (stay static)
        }
    }
    return out.length ? out : null;
}

export function findStringArray(source) {
    var re = /^(?:var|let|const)\s+(_?0x[0-9a-fA-F]+|[a-zA-Z_]\w*)\s*=\s*\[([^\]]*)\]\s*;/ms;
    var match = re.exec(source);
    if (!match) return null;
    var literals = parseArrayLiterals(match[2]);
    if (!literals) return null;
    return { arrayId: match[1], literals: literals, declRange: [match.index, match.index + match[0].length] };
}

function parseIntLiteral(raw) {
    var t = raw.trim();
    var negative = t.startsWith('-');
    if (negative || t.startsWith('+')) t = t.slice(1);
    if (t.toLowerCase().startsWith('0x')) {
        var v = parseInt(t.slice(2), 16);
        return Number.isFinite(v) ? (negative ? -v : v) : null;
    }
    var d = parseInt(t, 10);
    if (!Number.isFinite(d) || String(d) !== t) return null;
    return negative ? -d : d;
}

export function findRotator(source, arrayId) {
    var needle = arrayId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    var re = new RegExp('\\(\\s*function\\s*\\(([^)]*)\\)\\s*\\{(.+?)\\}\\s*\\(\\s*' + needle + '\\s*,\\s*([-+]?0x[0-9a-fA-F]+|\\d+)\\s*\\)\\s*\\)\\s*;', 'ms');
    var match = re.exec(source);
    if (!match) return null;
    var body = match[2];
    if (!looksLikeRotator(body)) return null;
    var pivotValue = parseIntLiteral(match[3]);
    if (pivotValue === null) return null;
    var pivotIndex = findPivotIndex(body);
    return { pivotIndex: pivotIndex, pivotValue: pivotValue, iifeRange: [match.index, match.index + match[0].length] };
}

function looksLikeRotator(body) {
    var hasLoop = body.includes('while') && (body.includes('!![]') || body.includes('true'));
    var hasPushShift = body.includes('push') && body.includes('shift');
    var hasParseInt = body.includes('parseInt');
    return hasLoop && hasPushShift && hasParseInt;
}

function findPivotIndex(body) {
    var match = /parseInt\([^)]*\(\s*(0x[0-9a-fA-F]+|\d+)\s*\)/.exec(body);
    if (!match) return 0;
    var v = parseIntLiteral(match[1]);
    return v === null || v < 0 ? 0 : v;
}

const MAX_ROTATIONS = 4096;

// The runtime loop push/shifts until parseInt(strings[0]) equals the pivot; find
// the rotation that satisfies it instead of executing anything.
export function simulateRotation(strings, pivotValue) {
    if (!strings.length) return { rotated: strings, rotations: 0 };
    for (var k = 0; k <= MAX_ROTATIONS; k++) {
        var index = k % strings.length;
        var first = strings[index];
        var n = parseIntLiteral(first);
        if (n !== null && n === pivotValue) {
            return { rotated: strings.slice(index).concat(strings.slice(0, index)), rotations: index };
        }
    }
    return { rotated: strings, rotations: 0 };
}

function emitArrayDecl(id, literals) {
    var s = 'var ' + id + ' = [';
    for (var i = 0; i < literals.length; i++) {
        if (i) s += ', ';
        s += "'" + literals[i].replace(/[\\'\n\t\r]/g, function (c) {
            if (c === '\\') return '\\\\';
            if (c === "'") return "\\'";
            if (c === '\n') return '\\n';
            if (c === '\t') return '\\t';
            return '\\r';
        }) + "'";
    }
    return s + '];';
}

function jsQuote(s) {
    return "'" + s.replace(/[\\'\n\t\r]/g, function (c) {
        if (c === '\\') return '\\\\';
        if (c === "'") return "\\'";
        if (c === '\n') return '\\n';
        if (c === '\t') return '\\t';
        return '\\r';
    }) + "'";
}

// Replaces the array declaration with its rotated form and deletes the rotator
// IIFE. Order-independent: works whether the IIFE precedes or follows the decl.
export function rebuildStringArraySource(source, found, rotator, rotated) {
    var declStart = found.declRange[0];
    var iifeStart = rotator.iifeRange[0];
    var firstIsDecl = declStart < iifeStart;
    var first = firstIsDecl ? found.declRange : rotator.iifeRange;
    var second = firstIsDecl ? rotator.iifeRange : found.declRange;
    var out = source.slice(0, first[0]);
    out += firstIsDecl ? emitArrayDecl(found.arrayId, rotated) : '';
    out += source.slice(first[1], second[0]);
    out += !firstIsDecl ? emitArrayDecl(found.arrayId, rotated) : '';
    out += source.slice(second[1]);
    return out;
}

// ------------------------------------------------- static decoder inlining

// Plain index-only decoders (`function(i){ return arr[i]; }`, optionally with a
// constant offset or an aliased local) can be inlined without executing them.
// Anything richer is refused rather than sandbox-run.
export function inlineDecoderCalls(source, arrayId) {
    var found = findDecoderDecl(source, arrayId);
    if (!found) return { source: source, decoderName: null, inlined: 0, total: 0, refusal: 'decoder declaration not found' };
    var index = analyzeDecoderBody(found.body, found.params, arrayId);
    if (!index) {
        return {
            source: source,
            decoderName: found.name,
            inlined: 0,
            total: 0,
            refusal: 'decoder is not a plain array index (execution required)'
        };
    }
    var sites = findDecoderCallSites(source, found.name, found.range);
    var literals = currentArrayLiterals(source, arrayId);
    if (!literals) return { source: source, decoderName: found.name, inlined: 0, total: sites.sites.length, refusal: 'array literals unreadable' };
    var out = '';
    var cursor = 0;
    var inlined = 0;
    var events = sites.sites.slice();
    if (!sites.hasUnresolved && sites.sites.length && sites.sites.every(function (s) { return decodeIndex(s.arg, index, literals) !== null; })) {
        events.push({ range: found.range, arg: null }); // decoder decl removal
    }
    events.sort(function (a, b) { return a.range[0] - b.range[0]; });
    for (var i = 0; i < events.length; i++) {
        var ev = events[i];
        if (ev.range[0] < cursor) continue;
        out += source.slice(cursor, ev.range[0]);
        if (ev.arg === null) {
            // decoder declaration removed
        } else {
            var decoded = decodeIndex(ev.arg, index, literals);
            if (decoded !== null) {
                out += jsQuote(decoded);
                inlined++;
            } else {
                out += source.slice(ev.range[0], ev.range[1]);
            }
        }
        cursor = ev.range[1];
    }
    out += source.slice(cursor);
    return { source: out, decoderName: found.name, inlined: inlined, total: sites.sites.length };
}

function decodeIndex(callArg, indexShape, literals) {
    var effective = callArg + (indexShape.sign === '-' ? -indexShape.offset : indexShape.offset);
    if (effective < 0 || effective >= literals.length) return null;
    return literals[effective];
}

function findDecoderDecl(source, arrayId) {
    var needle = arrayId.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    var patterns = [
        '(?:var|let|const)\\s+([\\w$]+)\\s*=\\s*function\\s*\\(([^)]*)\\)\\s*\\{\\s*(?:var\\s+[\\w$]+\\s*=\\s*' + needle + '\\s*;\\s*)?([^}]*' + needle + '\\s*\\[[^\\]]+\\][^}]*)\\}\\s*;',
        'function\\s+([\\w$]+)\\s*\\(([^)]*)\\)\\s*\\{\\s*(?:var\\s+[\\w$]+\\s*=\\s*' + needle + '\\s*;\\s*)?([^}]*' + needle + '\\s*\\[[^\\]]+\\][^}]*)\\}'
    ];
    for (var p = 0; p < patterns.length; p++) {
        var re = new RegExp(patterns[p], 'ms');
        var match = re.exec(source);
        if (match) {
            return {
                name: match[1],
                params: match[2].split(',').map(function (s) { return s.trim(); }).filter(Boolean),
                body: match[3],
                range: [match.index, match.index + match[0].length]
            };
        }
    }
    return null;
}

function analyzeDecoderBody(body, params, arrayId) {
    if (!params.length) return null;
    var p0 = params[0];
    var openCount = 0;
    for (var i = 0; i < body.length; i++) if (body[i] === '[') openCount++;
    if (openCount !== 1) return null;
    var match = new RegExp('([\\w$]+)\\s*\\[\\s*([\\w$]+)\\s*(?:([+-])\\s*(0x[0-9a-fA-F]+|\\d+))?\\s*\\]').exec(body);
    if (!match) return null;
    // The base may be the array itself or a local alias bound to it.
    var alias = new RegExp('var\\s+([\\w$]+)\\s*=\\s*' + arrayId.replace(/[.*+?^${}()|[\]\\\\]/g, '\\\\$&') + '\\s*;').exec(body);
    var baseOk = match[1] === arrayId || (alias && alias[1] === match[1]);
    if (!baseOk) return null;
    if (match[2] !== p0) return null;
    var offset = match[4] !== undefined ? parseIntLiteral(match[4]) : 0;
    if (offset === null || offset < 0) return null;
    if (!/^\s*(?:var\s+[\w$]+\s*=\s*[\w$]+\s*;\s*)?return\s+(?:[\w$]+\s*=\s*)?$/.test(body.slice(0, match.index))) return null;
    if (/[\w$\s=]\s*;/.test(body.slice(match.index + match[0].length).replace(/\s*\]\s*;?\s*$/, '')) && !/^\s*\]\s*;?\s*$/.test(body.slice(match.index + match[0].length))) return null;
    return { param: p0, offset: offset || 0, sign: match[3] || '+' };
}

function findDecoderCallSites(source, decoderName, decoderRange) {
    var re = new RegExp(decoderName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g');
    var sites = [];
    var hasUnresolved = false;
    var match;
    while ((match = re.exec(source))) {
        re.lastIndex = match.index + match[0].length;
        var start = match.index;
        var end = match.index + match[0].length;
        if (start >= decoderRange[0] && start < decoderRange[1]) continue;
        if (start > 0 && /[\w$]/.test(source[start - 1])) continue;
        if (end < source.length && /[\w$]/.test(source[end])) continue;
        var before = start;
        while (before > 0 && /\s/.test(source[before - 1])) before--;
        if (before > 0 && source[before - 1] === '.') {
            hasUnresolved = true;
            continue;
        }
        var open = end;
        while (open < source.length && /\s/.test(source[open])) open++;
        if (source[open] !== '(') {
            hasUnresolved = true;
            continue;
        }
        var close = open + 1;
        var depth = 1;
        while (close < source.length && depth > 0) {
            if (source[close] === '(') depth++;
            else if (source[close] === ')') depth--;
            if (depth === 0) break;
            close++;
        }
        if (close >= source.length) {
            hasUnresolved = true;
            continue;
        }
        var argText = source.slice(open + 1, close).trim();
        var arg = parseIntLiteral(argText);
        if (arg === null) {
            hasUnresolved = true;
            continue;
        }
        sites.push({ range: [start, close + 1], arg: arg });
    }
    return { sites: sites, hasUnresolved: hasUnresolved };
}

function currentArrayLiterals(source, arrayId) {
    var found = findStringArray(source);
    return found && found.arrayId === arrayId ? found.literals : null;
}

// Full static string-array stage: rotate + rebuild, then attempt inlining.
export function transformStringArray(source) {
    var found = findStringArray(source);
    if (!found) return null;
    var rotator = findRotator(source, found.arrayId);
    if (!rotator) return null;
    var sim = simulateRotation(found.literals, rotator.pivotValue);
    var rebuilt = rebuildStringArraySource(source, found, rotator, sim.rotated);
    var inline = inlineDecoderCalls(rebuilt, found.arrayId);
    if (inline.source === source) return null;
    return inline.source;
}

export function detectStringArray(source) {
    var found = findStringArray(source);
    if (!found) return null;
    var rotator = findRotator(source, found.arrayId);
    if (!rotator) return null;
    return {
        tool: 'string-array',
        arrayId: found.arrayId,
        literals: found.literals.length,
        pivot: rotator.pivotValue
    };
}
