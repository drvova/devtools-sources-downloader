// Recursive JavaScript unpacker for the DevTools export pipeline.
//
// The loop is the same shape as DSchalla/DeScrypt (detect -> route -> transform
// -> re-detect -> repeat until the payload stops changing), but it runs entirely
// in the DevTools panel: no Python, no sandbox, no toolchain. Source maps the
// page already publishes are the only network access.
//
// Every stage is a bounded pure transform over text, so the engine is testable
// outside the browser (see test/unpack.test.mjs).

import * as beautifyNamespace from 'js-beautify';
import { decodeJsfuck, detectJsfuck } from './jsfuck.js';
import { detectV8CodeCache, parseV8CodeCache, parseSealedV8 } from './v8codecache.js';
import { parseJscHeader, detectJscBytecode, recoverJscStrings, analyzeJscModule } from './jscbytecode.js';
import { detectWasmModule, parseWasmModule } from './wasm.js';
import {
    detectAaencode, detectJjencode, detectJsfiretruck, detectObfuscatorIo,
    detectPacker, detectStringArray, transformStringArray, unpackPacker
} from './packers.js';

const jsBeautify = beautifyNamespace.js || (beautifyNamespace.default && beautifyNamespace.default.js);

export const LIMITS = {
    maxDepth: 8,
    maxAssetBytes: 8 * 1024 * 1024,
    maxBeautifyBytes: 2 * 1024 * 1024,
    maxModules: 400,
    maxSources: 400,
    maxMapBytes: 32 * 1024 * 1024,
    minPayloadLength: 24
};

// ---------------------------------------------------------------- digests

export async function sha256Hex(text) {
    var bytes = new TextEncoder().encode(text);
    if (globalThis.crypto && globalThis.crypto.subtle) {
        var digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
        return Array.from(new Uint8Array(digest)).map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
    }
    // FNV-1a fallback: still detects "did this stage change anything".
    var hash = 0x811c9dc5;
    for (var i = 0; i < bytes.length; i++) {
        hash ^= bytes[i];
        hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return 'fnv1a' + hash.toString(16).padStart(8, '0');
}

// Digest for binary assets (V8 caches, JSC bytecode) where TextEncoder would
// mangle byte values above 0x7F into multi-byte sequences.
export async function sha256HexBytes(bytes) {
    if (!bytes || !bytes.length) return null;
    if (globalThis.crypto && globalThis.crypto.subtle) {
        var digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
        return Array.from(new Uint8Array(digest)).map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
    }
    var fnv = 0x811c9dc5;
    for (var i = 0; i < bytes.length; i++) {
        fnv ^= bytes[i];
        fnv = Math.imul(fnv, 0x01000193) >>> 0;
    }
    return 'fnv1a' + fnv.toString(16).padStart(8, '0');
}

// Sync routing for resource collection: a script-shaped binary (V8 code cache,
// JSC bytecode) or a .jsc/.bc URL goes down the bytes path, everything else
// stays text. Brotli-sealed blobs without an extension are not routed here —
// they reach unpackBinaryAsset only when named like a script cache.
export function looksBinaryScript(url, bytes) {
    if (/\.(jsc|bc|wasm)(\?|$)/i.test(String(url || ''))) return true;
    return !!(bytes && bytes.length >= 8 && detectWasmModule(bytes))
        || !!(bytes && bytes.length >= 32 && (detectV8CodeCache(bytes) || detectJscBytecode(bytes)));
}

// ------------------------------------------------------- scanner primitives
// One string/comment aware walker feeds literal extraction, balanced-region
// slicing and module splitting, so the three consumers cannot disagree.

function skipQuoted(text, index, quote) {
    var j = index + 1;
    while (j < text.length) {
        var ch = text[j];
        if (ch === '\\') { j += 2; continue; }
        if (ch === quote) return j + 1;
        if (ch === '\n' && quote !== '`') return j;
        j++;
    }
    return text.length;
}

function skipTemplate(text, index) {
    var j = index + 1;
    while (j < text.length) {
        var ch = text[j];
        if (ch === '\\') { j += 2; continue; }
        if (ch === '`') return j + 1;
        if (ch === '$' && text[j + 1] === '{') {
            var close = findBalanced(text, j + 1);
            j = close > 0 ? close : j + 2;
            continue;
        }
        j++;
    }
    return text.length;
}

function skipLineComment(text, index) {
    var nl = text.indexOf('\n', index);
    return nl < 0 ? text.length : nl + 1;
}

function skipBlockComment(text, index) {
    var end = text.indexOf('*/', index + 2);
    return end < 0 ? text.length : end + 2;
}

function isRegexStart(text, index) {
    var j = index - 1;
    while (j >= 0 && /\s/.test(text[j])) j--;
    if (j < 0) return true;
    return !/[\w$)\]]/.test(text[j]);
}

function skipRegex(text, index) {
    var j = index + 1;
    var inClass = false;
    while (j < text.length) {
        var ch = text[j];
        if (ch === '\\') { j += 2; continue; }
        if (ch === '\n') return index + 1;
        if (ch === '[') inClass = true;
        else if (ch === ']') inClass = false;
        else if (ch === '/' && !inClass) {
            j++;
            while (j < text.length && /[a-z]/i.test(text[j])) j++;
            return j;
        }
        j++;
    }
    return index + 1;
}

export function collectStringLiterals(text, options) {
    var opts = options || {};
    var minLength = opts.minLength || 0;
    var out = [];
    var i = 0;
    while (i < text.length) {
        var ch = text[i];
        if (ch === '"' || ch === "'" || ch === '`') {
            var end = ch === '`' ? skipTemplate(text, i) : skipQuoted(text, i, ch);
            var raw = text.slice(i + 1, ch === '`' ? end - 1 : end - 1);
            var decoded = decodeEscapes(raw);
            if (decoded.length >= minLength) out.push({ start: i, end: end, quote: ch, raw: raw, value: decoded });
            i = end;
            continue;
        }
        if (ch === '/' && text[i + 1] === '/') { i = skipLineComment(text, i); continue; }
        if (ch === '/' && text[i + 1] === '*') { i = skipBlockComment(text, i); continue; }
        if (ch === '/' && isRegexStart(text, i)) { i = skipRegex(text, i); continue; }
        i++;
    }
    return out;
}

export function findBalanced(text, openIndex) {
    var open = text[openIndex];
    var close = open === '{' ? '}' : open === '[' ? ']' : open === '(' ? ')' : null;
    if (!close) return -1;
    var depth = 0;
    var i = openIndex;
    while (i < text.length) {
        var ch = text[i];
        if (ch === '"' || ch === "'" || ch === '`') { i = ch === '`' ? skipTemplate(text, i) : skipQuoted(text, i, ch); continue; }
        if (ch === '/' && text[i + 1] === '/') { i = skipLineComment(text, i); continue; }
        if (ch === '/' && text[i + 1] === '*') { i = skipBlockComment(text, i); continue; }
        if (ch === '/' && isRegexStart(text, i)) { i = skipRegex(text, i); continue; }
        if (ch === open) depth++;
        else if (ch === close) {
            depth--;
            if (depth === 0) return i + 1;
        }
        i++;
    }
    return -1;
}

// ------------------------------------------------------------- decoders

export function decodeEscapes(raw) {
    var out = '';
    for (var i = 0; i < raw.length; i++) {
        var ch = raw[i];
        if (ch !== '\\') { out += ch; continue; }
        var next = raw[i + 1];
        i++;
        if (next === 'n') out += '\n';
        else if (next === 'r') out += '\r';
        else if (next === 't') out += '\t';
        else if (next === 'b') out += '\b';
        else if (next === 'f') out += '\f';
        else if (next === 'v') out += '\v';
        else if (next === '0') out += '\0';
        else if (next === 'x') { out += String.fromCharCode(parseInt(raw.substr(i + 1, 2), 16) || 0); i += 2; }
        else if (next === 'u') {
            if (raw[i + 1] === '{') {
                var close = raw.indexOf('}', i + 2);
                out += String.fromCodePoint(parseInt(raw.slice(i + 2, close), 16) || 0);
                i = close;
            } else {
                out += String.fromCharCode(parseInt(raw.substr(i + 1, 4), 16) || 0);
                i += 4;
            }
        } else if (next === '\n') { /* line continuation */ }
        else if (next >= '0' && next <= '7') {
            var octal = next;
            while (octal.length < 3 && raw[i + 1] >= '0' && raw[i + 1] <= '7') octal += raw[++i];
            out += String.fromCharCode(parseInt(octal, 8));
        } else out += next;
    }
    return out;
}

export function decodeBase64ToBytes(base64) {
    var normalized = String(base64).replace(/\s+/g, '').replace(/-/g, '+').replace(/_/g, '/');
    while (normalized.length % 4) normalized += '=';
    var binary;
    try { binary = atob(normalized); }
    catch (_) { return null; }
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

export function bytesToText(bytes) {
    try {
        return new TextDecoder('utf-8', { fatal: false }).decode(bytes);
    } catch (_) {
        var out = '';
        for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
        return out;
    }
}

export function printableRatio(text) {
    if (!text.length) return 0;
    var printable = 0;
    for (var i = 0; i < text.length; i++) {
        var code = text.charCodeAt(i);
        if (code === 9 || code === 10 || code === 13 || (code >= 32 && code !== 127)) printable++;
    }
    return printable / text.length;
}

export async function inflateBytes(bytes, format) {
    if (typeof DecompressionStream !== 'function') return null;
    try {
        var stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream(format));
        var buffer = await new Response(stream).arrayBuffer();
        return new Uint8Array(buffer);
    } catch (_) {
        return null;
    }
}

function gzipFormat(bytes) {
    if (bytes.length > 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) return 'gzip';
    if (bytes.length > 2 && bytes[0] === 0x78 && (bytes[1] === 0x01 || bytes[1] === 0x9c || bytes[1] === 0xda)) return 'deflate';
    return null;
}

// ------------------------------------------------------------- detectors

const KEYWORD_GAIN = /(?:function|return|var |let |const |window\.|document\.|prototype|undefined|null|true|false)/g;
const BASE64_LITERAL = /(?:atob\s*\(\s*)?["']([A-Za-z0-9+/=_-]{40,})["']/g;
const HEX_ESCAPE = /\\x[0-9a-fA-F]{2}/g;
const UNICODE_PERCENT = /%u[0-9a-fA-F]{4}/g;
const CHARCODE_CALL = /String\s*\.\s*fromCharCode\s*\(([\d\s,]{7,})\)/g;
const EVAL_HEAD = /(?:^|[^\w$.])eval\s*\(/g;
const FUNCTION_HEAD = /(?:^|[^\w$.])(?:new\s+)?Function\s*\(/g;
const SOURCE_URL_COMMENT = /\/\/[#@]\s*sourceURL\s*=\s*(\S+)/;

function countMatches(text, regex) {
    regex.lastIndex = 0;
    var count = 0;
    while (regex.exec(text)) count++;
    return count;
}

function gain(text) {
    KEYWORD_GAIN.lastIndex = 0;
    return countMatches(text, KEYWORD_GAIN);
}

function longestBase64Literal(text) {
    BASE64_LITERAL.lastIndex = 0;
    var best = null;
    var match;
    while ((match = BASE64_LITERAL.exec(text))) {
        if (!best || match[1].length > best.length) best = match[1];
    }
    return best;
}

// Scores the obfuscation layers actually present. Highest score wins the stage.
export function detectLayers(text) {
    var findings = [];
    var evalHeads = countMatches(text, EVAL_HEAD);
    var fnHeads = countMatches(text, FUNCTION_HEAD);
    // The collector is the single source of truth for what eval()/Function() can
    // yield; the detector must not re-derive that gate or it routes nothing.
    var payloads = (evalHeads || fnHeads) ? collectEvalPayloads(text) : [];
    if (payloads.length) {
        findings.push({ tool: 'eval-unwrap', score: 0.7 + Math.min(0.3, payloads.length / 20), detail: evalHeads + ' eval() / ' + fnHeads + ' Function() call(s)' });
    }
    var base64 = longestBase64Literal(text);
    if (base64) findings.push({ tool: 'base64', score: 0.5 + Math.min(0.3, base64.length / 4000), detail: base64.length + ' char literal' });
    var hexEscapes = countMatches(text, HEX_ESCAPE);
    if (hexEscapes > 8 && hexEscapes * 4 > text.length * 0.15) findings.push({ tool: 'hex-escape', score: 0.6, detail: hexEscapes + ' \\x escapes' });
    if (countMatches(text, UNICODE_PERCENT) > 8) findings.push({ tool: 'unescape', score: 0.6, detail: '%uXXXX encoding' });
    if (countMatches(text, CHARCODE_CALL)) findings.push({ tool: 'charcode', score: 0.65, detail: 'String.fromCharCode list' });
    var reversed = text.split('').reverse().join('');
    if (gain(reversed) > gain(text) + 2) findings.push({ tool: 'reverse', score: 0.45, detail: 'reversed source' });
    var rot13 = text.replace(/[a-zA-Z]/g, function (c) { return String.fromCharCode((c <= 'Z' ? 90 : 122) >= c.charCodeAt(0) + 13 ? c.charCodeAt(0) + 13 : c.charCodeAt(0) - 13); });
    if (gain(rot13) > gain(text) + 2) findings.push({ tool: 'rot13', score: 0.42, detail: 'rot13 source' });
    // Self-contained detectors: each one both detects and routes (its own
    // predicate is the collector), so the transform never guesses.
    var packer = detectPacker(text);
    if (packer) findings.push({ tool: 'packer', score: 0.9, detail: 'Dean Edwards packer, base ' + packer.base + ', ' + packer.words.length + ' words' });
    var jsf = detectJsfuck(text);
    if (jsf.detected) findings.push({ tool: 'jsfuck', score: 0.95, detail: 'jsfuck, purity ' + (jsf.purity * 100).toFixed(1) + '%' });
    var stringArray = detectStringArray(text);
    if (stringArray) findings.push({ tool: 'string-array', score: 0.8, detail: 'string array ' + stringArray.arrayId + ', ' + stringArray.literals + ' literals' });
    findings.sort(function (a, b) { return b.score - a.score; });
    return findings;
}

// ------------------------------------------------------------- transforms

export function collectEvalPayloads(text) {
    var payloads = [];
    var seen = new Set();
    function push(head, code, end) {
        if (seen.has(code)) return;
        seen.add(code);
        payloads.push({ head: head, code: code, end: end });
    }
    var evalHeads = [];
    EVAL_HEAD.lastIndex = 0;
    var match;
    while ((match = EVAL_HEAD.exec(text))) evalHeads.push(match.index + match[0].lastIndexOf('eval'));
    for (var i = 0; i < evalHeads.length; i++) {
        var parenIdx = text.indexOf('(', evalHeads[i]);
        if (parenIdx < 0) continue;
        var close = findBalanced(text, parenIdx);
        if (close < 0) continue;
        var arg = text.slice(parenIdx + 1, close - 1);
        var parts = collectStringLiterals(arg, { minLength: 0 });
        // A packer usually passes one literal, or literals joined by '+' / commas.
        if (parts.length && isLiteralOnlyArg(arg)) {
            var joined = parts.map(function (p) { return p.value; }).join('');
            if (joined.length >= LIMITS.minPayloadLength) push(evalHeads[i], joined, close);
            continue;
        }
        // eval(expression) keeps the expression as the payload so the next pass can
        // peel it (atob, decodeURIComponent, a function call, a base64 literal, ...).
        if (arg.length >= LIMITS.minPayloadLength) push(evalHeads[i], arg, close);
    }
    // Function(...) payloads: the body is the last string argument.
    FUNCTION_HEAD.lastIndex = 0;
    while ((match = FUNCTION_HEAD.exec(text))) {
        var fp = text.indexOf('(', match.index + match[0].length - 1);
        if (fp < 0) continue;
        var fclose = findBalanced(text, fp);
        if (fclose < 0) continue;
        var args = collectStringLiterals(text.slice(fp + 1, fclose - 1), { minLength: 0 });
        if (!args.length) continue;
        var body = args[args.length - 1].value;
        if (body.length >= LIMITS.minPayloadLength) push(match.index, body, fclose);
    }
    payloads.sort(function (a, b) { return a.head - b.head; });
    return payloads;
}

// True when everything left after removing the string literals is punctuation and
// whitespace, i.e. the argument is a concatenation of literals rather than an expression.
function isLiteralOnlyArg(arg) {
    return arg.replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`/g, '')
        .replace(/\s+/g, '')
        .replace(/[+(),]/g, '') === '';
}

function unwrapEval(text) {
    var payloads = collectEvalPayloads(text);
    if (!payloads.length) return null;
    return payloads.map(function (p) { return p.code; }).join('\n;\n');
}

function unwrapBase64(text) {
    var literal = longestBase64Literal(text);
    if (!literal) return null;
    var bytes = decodeBase64ToBytes(literal);
    if (!bytes || !bytes.length) return null;
    var format = gzipFormat(bytes);
    if (format) {
        return { needsInflate: format, bytes: bytes };
    }
    var decoded = bytesToText(bytes);
    if (printableRatio(decoded) < 0.85) return null;
    return { text: decoded };
}

function unwrapHexEscapes(text) {
    if (!countMatches(text, HEX_ESCAPE)) return null;
    return text
        .replace(/\\x([0-9a-fA-F]{2})/g, function (_, hex) { return String.fromCharCode(parseInt(hex, 16)); })
        .replace(/\\u([0-9a-fA-F]{4})/g, function (_, hex) { return String.fromCharCode(parseInt(hex, 16)); });
}

function unwrapUnescape(text) {
    var windows = text.replace(/%u([0-9a-fA-F]{4})/g, function (_, hex) { return '%' + encodeURIComponent(String.fromCharCode(parseInt(hex, 16))).slice(1); });
    try {
        return decodeURIComponent(windows);
    } catch (_) {
        return null;
    }
}

function unwrapCharcode(text) {
    var out = text.replace(CHARCODE_CALL, function (_, numbers) {
        var codes = numbers.split(',').map(function (part) { return parseInt(part.trim(), 10); }).filter(function (n) { return Number.isFinite(n); });
        if (codes.length < 7) return '';
        return JSON.stringify(codes.map(function (n) { return String.fromCharCode(n); }).join(''));
    });
    return out === text ? null : out;
}

function unwrapReverse(text) {
    return text.split('').reverse().join('');
}

function unwrapRot13(text) {
    return text.replace(/[a-zA-Z]/g, function (c) {
        var base = c <= 'Z' ? 65 : 97;
        return String.fromCharCode((c.charCodeAt(0) - base + 13) % 26 + base);
    });
}

async function applyTransform(tool, text) {
    if (tool === 'eval-unwrap') return unwrapEval(text);
    if (tool === 'base64') {
        var result = unwrapBase64(text);
        if (!result) return null;
        if (result.needsInflate) {
            var inflated = await inflateBytes(result.bytes, result.needsInflate);
            return inflated ? bytesToText(inflated) : null;
        }
        var inflatedText = result.text;
        var asBytes = decodeBase64ToBytes(text.trim());
        if (asBytes) {
            var nested = gzipFormat(asBytes);
            if (nested) {
                var inner = await inflateBytes(asBytes, nested);
                if (inner) return bytesToText(inner);
            }
        }
        return inflatedText;
    }
    if (tool === 'hex-escape') return unwrapHexEscapes(text);
    if (tool === 'unescape') return unwrapUnescape(text);
    if (tool === 'charcode') return unwrapCharcode(text);
    if (tool === 'reverse') return unwrapReverse(text);
    if (tool === 'rot13') return unwrapRot13(text);
    if (tool === 'packer') return unpackPacker(text);
    if (tool === 'string-array') return transformStringArray(text);
    if (tool === 'jsfuck') {
        var decoded = decodeJsfuck(text);
        return decoded && typeof decoded.value === 'string' ? decoded.value : null;
    }
    return null;
}

// Shell encodings whose payload only exists at RUNTIME: detected and reported,
// never transformed. The string-array pass covers the static slice of
// obfuscator.io output, so it is reported only when it did NOT match.
function collectRefusals(text) {
    var refusals = [];
    var aa = detectAaencode(text);
    if (aa) refusals.push(aa);
    var jj = detectJjencode(text);
    if (jj) refusals.push(jj);
    var ft = detectJsfiretruck(text);
    if (ft) refusals.push(ft);
    var ob = detectObfuscatorIo(text);
    if (ob && !detectStringArray(text)) refusals.push({ tool: 'obfuscator-io', detail: ob.detail + ' (runtime shell; static string-array pass did not match)' });
    return refusals;
}

// The detect -> route -> transform -> re-detect loop, one layer per iteration.
// `outputs[i]` is the text produced by stage i; `stages[i]` is its metadata, so a
// caller can write real layer artifacts without inflating the JSON report.
export async function peelText(text, options) {
    var opts = options || {};
    var maxDepth = opts.maxDepth || LIMITS.maxDepth;
    var stages = [];
    var outputs = [];
    var refusals = collectRefusals(text);
    var current = text;
    var seen = new Set([await sha256Hex(current)]);
    for (var depth = 0; depth < maxDepth; depth++) {
        var findings = detectLayers(current);
        if (!findings.length) break;
        var produced = null;
        var usedTool = null;
        for (var f = 0; f < findings.length; f++) {
            var candidate = await applyTransform(findings[f].tool, current);
            if (candidate && candidate.length && candidate !== current) {
                var digest = await sha256Hex(candidate);
                if (!seen.has(digest)) {
                    produced = candidate;
                    usedTool = findings[f].tool;
                    seen.add(digest);
                    break;
                }
            }
        }
        if (!produced) break;
        stages.push({
            depth: depth + 1,
            tool: usedTool,
            inputBytes: current.length,
            outputBytes: produced.length,
            digest: await sha256Hex(produced),
            sourceUrl: (produced.match(SOURCE_URL_COMMENT) || [])[1] || null
        });
        outputs.push(produced);
        current = produced;
    }
    return { stages: stages, outputs: outputs, final: current, refusals: refusals };
}

// ------------------------------------------------------------- beautifier

const CODE_SIGNAL = /(?:^|[^\w$])(?:function|return|var|let|const|class|new|typeof|window\.|document\.|module\.exports|exports\.|prototype)\b|=>/;

export function looksMinified(text) {
    var probe = text.length > 200000 ? text.slice(0, 200000) : text;
    if (!CODE_SIGNAL.test(probe)) return false;
    var lines = probe.split('\n');
    if (lines.length < 4) return true;
    var longest = 0;
    for (var i = 0; i < lines.length; i++) if (lines[i].length > longest) longest = lines[i].length;
    return longest > 500 || probe.length / lines.length > 220;
}

export function beautifyJs(text, maxBytes) {
    var limit = maxBytes || LIMITS.maxBeautifyBytes;
    if (text.length > limit || typeof jsBeautify !== 'function') return text;
    try {
        return jsBeautify(text, { indent_size: 2, preserve_newlines: false, max_preserve_newlines: 1, end_with_newline: true, brace_style: 'collapse,preserve-inline' });
    } catch (_) {
        return text;
    }
}

// ------------------------------------------------------- bundle modules

export function extractBundleModules(text, maxModules) {
    var cap = maxModules || LIMITS.maxModules;
    var mapStart = text.indexOf('__webpack_modules__');
    var openIndex = -1;
    if (mapStart >= 0) {
        openIndex = text.indexOf('{', mapStart);
    } else {
        var pushMatch = /\[\s*\[[^\]]*\]\s*,\s*\{/.exec(text);
        if (pushMatch) openIndex = text.indexOf('{', pushMatch.index);
    }
    if (openIndex < 0) return [];
    var end = findBalanced(text, openIndex);
    if (end < 0) return [];
    var body = text.slice(openIndex + 1, end - 1);
    var modules = [];
    var cursor = 0;
    var header = /(?:^|[,\s])(\d{1,7})\s*:\s*(?:function\s*\(([^)]*)\)|(?:\(([^)]*)\)|([\w$]+))\s*=>)/g;
    var match;
    while ((match = header.exec(body)) && modules.length < cap) {
        var keyIndex = body.indexOf(match[1], match.index);
        var braceIndex = body.indexOf('{', header.lastIndex);
        if (braceIndex < 0) continue;
        var arrowless = body.slice(header.lastIndex, braceIndex);
        var isExpressionBody = arrowless.indexOf('=>') >= 0 && arrowless.trim().length > 0 && arrowless.indexOf(')') !== -1 && body[braceIndex - 1] === ')';
        var regionEnd = isExpressionBody ? -1 : findBalanced(body, braceIndex);
        if (regionEnd < 0) continue;
        var slice = body.slice(keyIndex, regionEnd);
        modules.push({ id: match[1], params: match[2] || match[3] || match[4] || '', code: slice });
        cursor = regionEnd;
        header.lastIndex = regionEnd;
    }
    if (cursor === 0) return [];
    return modules;
}

function moduleFileName(mod) {
    var url = (mod.code.match(SOURCE_URL_COMMENT) || [])[1];
    if (url) {
        var cleaned = url.replace(/^webpack(-internal)?:\/\//, '').replace(/^\.\//, '');
        return cleaned.replace(/[\\:*?"<>|]/g, '_').replace(/^\/+/, '');
    }
    return 'module-' + mod.id + '.js';
}

// --------------------------------------------------------- source maps

export function findSourceMapRef(text) {
    var index = text.lastIndexOf('sourceMappingURL');
    if (index < 0) return null;
    var lineEnd = text.indexOf('\n', index);
    var line = text.slice(index, lineEnd < 0 ? text.length : lineEnd);
    var value = line.replace(/^sourceMappingURL\s*=\s*/, '').trim();
    if (!value) return null;
    if (value.indexOf('data:') === 0) return { kind: 'inline', value: value };
    return { kind: 'external', value: value };
}

export function parseSourceMap(json) {
    var map = typeof json === 'string' ? JSON.parse(json) : json;
    var sources = map.sources || [];
    var contents = map.sourcesContent || [];
    var files = [];
    for (var i = 0; i < sources.length && files.length < LIMITS.maxSources; i++) {
        if (typeof contents[i] !== 'string' || !contents[i].length) continue;
        var path = String(sources[i])
            .replace(/^webpack:\/\//, '')
            .replace(/^webpack\/\//, '')
            .replace(/^\.\//, '')
            .replace(/\\/g, '/')
            .replace(/^\/+/, '')
            .replace(/[\\:*?"<>|]/g, '_');
        if (!path || path.charAt(path.length - 1) === '/') path += 'index.js';
        files.push({ path: path, content: contents[i] });
    }
    return { files: files, sourceRoot: map.sourceRoot || '', file: map.file || '' };
}

export function decodeInlineSourceMap(dataUri) {
    var match = /^data:([^;,]*)(;base64)?,([\s\S]*)$/.exec(dataUri);
    if (!match) return null;
    try {
        if (match[2]) return bytesToText(decodeBase64ToBytes(match[3]));
        return decodeURIComponent(match[3]);
    } catch (_) {
        return null;
    }
}

export function resolveMapUrl(scriptUrl, mapRef) {
    try {
        return new URL(mapRef, scriptUrl).href;
    } catch (_) {
        return mapRef;
    }
}

// --------------------------------------------------------- asset pipeline

export function assetSlug(url, index) {
    var cleaned = String(url || '')
        .replace(/^[a-z]+:\/\//i, '')
        .replace(/[?#].*$/, '')
        .replace(/[\\:*?"<>|]/g, '_')
        .replace(/\/+/g, '__');
    if (cleaned.length > 90) cleaned = cleaned.slice(-90);
    if (!cleaned) cleaned = 'inline';
    if (!/\.js$/i.test(cleaned)) cleaned += '.js';
    return ('000' + index).slice(-4) + '-' + cleaned;
}

function safePath(path) {
    return String(path).split('/').map(function (segment) {
        return segment.replace(/[\\:*?"<>|]/g, '_').replace(/^\.+$/, '_');
    }).join('/');
}

// Binary pass for cached-bytecode assets (V8 code cache, JSC bytecode,
// brotli-sealed V8). The detection ladder is ordered exactly like the peel
// loop: every rung is a self-contained detector, the first match routes, and
// an unrecognized blob is a reported refusal, never a silent skip.
async function unpackBinaryAsset(asset, options) {
    var opts = options || {};
    var index = opts.index == null ? 0 : opts.index;
    var zipPath = opts.zipPath || '';
    var entry = {
        url: asset.url,
        zipPath: zipPath,
        kind: 'binary',
        bytes: asset.bytes.length,
        digest: await sha256HexBytes(asset.bytes),
        stages: [],
        modules: 0,
        sources: 0,
        beautified: false,
        sourceMap: null,
        notes: []
    };
    var files = [];
    if (asset.bytes.length > LIMITS.maxAssetBytes) {
        entry.notes.push('asset exceeds unpack budget');
        return { entry: entry, files: files };
    }
    var base = (opts.pathPrefix || '_unpack') + '/' + assetSlug(asset.url, index);
    var bytes = asset.bytes;
    var strings = null;

    function cacheHeaderFile(payload) {
        files.push({ path: base + '/cache-header.json', content: JSON.stringify(payload, null, 2) });
    }
    function stringsFile(list) {
        if (list && list.length) files.push({ path: base + '/strings.json', content: JSON.stringify(list, null, 2) });
    }

    if (detectWasmModule(bytes)) {
        var wasm = parseWasmModule(bytes);
        entry.stages.push({ depth: 0, tool: 'wasm-module', detail: 'wasm module, ' + wasm.sections.length + ' sections, ' + wasm.imports.length + ' imports, ' + wasm.exports.length + ' exports, ' + Object.keys(wasm.functionNames).length + ' named functions' });
        files.push({ path: base + '/wasm-info.json', content: JSON.stringify({
            version: wasm.version, moduleName: wasm.moduleName,
            sections: wasm.sections, imports: wasm.imports, exports: wasm.exports,
            functionNames: wasm.functionNames, typeNames: wasm.typeNames,
            dataStrings: wasm.dataStrings, notes: wasm.notes
        }, null, 2) });
    }

    if (detectV8CodeCache(bytes)) {
        var cache = parseV8CodeCache(bytes);
        if (cache) {
            entry.stages.push({ depth: 0, tool: 'v8-code-cache', detail: cache.runtime + ' ' + cache.format + ', payload ' + cache.payloadLength + 'B' });
            strings = cache.strings;
            cacheHeaderFile({ shape: 'v8-code-cache', magic: cache.magicHex, runtime: cache.runtime, format: cache.format, versionHash: cache.versionHash, sourceHash: cache.sourceHash, flagHash: cache.flagHash, payloadLength: cache.payloadLength });
        }
    }
    if (!entry.stages.length && detectJscBytecode(bytes)) {
        var header = parseJscHeader(bytes);
        entry.stages.push({ depth: 0, tool: 'jsc-bytecode', detail: 'JSC bytecode v' + header.version + ', ' + header.declaredLength + 'B' });
        strings = recoverJscStrings(bytes);
        cacheHeaderFile({ shape: 'jsc-bytecode', stamp: header.stamp, format: header.format, version: header.version, declaredLength: header.declaredLength, bodyOffset: header.bodyOffset });
        var structure = analyzeJscModule(bytes);
        if (structure.blocks > 0) {
            entry.stages[entry.stages.length - 1].detail += ', ' + structure.functions.length + ' functions, ' + structure.blocks + ' blocks, ' + structure.ops + ' ops';
            entry.functions = structure.functions.length;
            files.push({ path: base + '/functions.json', content: JSON.stringify(structure, null, 2) });
        } else {
            entry.notes.push('JSC function tree did not bind (build opcode drift)');
        }
    }
    if (!entry.stages.length) {
        var sealed = await parseSealedV8(bytes, { inflate: opts.inflate });
        if (sealed) {
            entry.stages.push({ depth: 0, tool: 'jsc-sealed-v8', detail: 'brotli-sealed V8 cache, ' + sealed.inflatedBytes + 'B inflated' });
            entry.stages.push({ depth: 1, tool: 'v8-code-cache', detail: sealed.cache.runtime + ' ' + sealed.cache.format + ', payload ' + sealed.cache.payloadLength + 'B' });
            strings = sealed.cache.strings;
            cacheHeaderFile({ shape: 'jsc-sealed-v8', inflatedBytes: sealed.inflatedBytes, magic: sealed.cache.magicHex, runtime: sealed.cache.runtime, format: sealed.cache.format });
        }
    }
    stringsFile(strings);
    if (!entry.stages.length) {
        entry.notes.push('binary asset: no V8 code-cache, JSC bytecode, wasm module, or brotli-sealed shape recognized');
    }
    return { entry: entry, files: files };
}

// Full pass over one JavaScript asset. Returns the report entry plus the files
// that should be written into the export zip.
export async function unpackAsset(asset, options) {
    if (asset && asset.bytes) return unpackBinaryAsset(asset, options);
    var opts = options || {};
    var index = opts.index == null ? 0 : opts.index;
    var zipPath = opts.zipPath || '';
    var entry = {
        url: asset.url,
        zipPath: zipPath,
        kind: 'text',
        bytes: asset.content ? asset.content.length : 0,
        digest: asset.content ? await sha256Hex(asset.content) : null,
        stages: [],
        modules: 0,
        sources: 0,
        beautified: false,
        sourceMap: null,
        notes: []
    };
    var files = [];
    if (!asset.content || asset.content.length > LIMITS.maxAssetBytes) {
        if (asset.content) entry.notes.push('asset exceeds unpack budget');
        return { entry: entry, files: files };
    }
    var base = (opts.pathPrefix || '_unpack') + '/' + assetSlug(asset.url, index);
    var peeled = await peelText(asset.content, { maxDepth: opts.maxDepth });
    entry.stages = peeled.stages;
    entry.refusals = peeled.refusals;
    for (var r = 0; r < peeled.refusals.length; r++) {
        entry.notes.push('refused: ' + peeled.refusals[r].tool + ' — ' + peeled.refusals[r].detail);
    }
    var current = peeled.final;

    for (var s = 0; s < peeled.stages.length; s++) {
        var stage = peeled.stages[s];
        files.push({ path: base + '/layers/' + ('0' + stage.depth) + '-' + stage.tool + '.js', content: peeled.outputs[s].slice(0, LIMITS.maxAssetBytes) });
    }

    if (peeled.stages.length) {
        files.push({ path: base + '/00-original.js', content: asset.content });
    }

    var modules = extractBundleModules(current, opts.maxModules);
    entry.modules = modules.length;
    for (var m = 0; m < modules.length; m++) {
        files.push({ path: base + '/modules/' + safePath(moduleFileName(modules[m])), content: modules[m].code });
    }

    if (looksMinified(current)) {
        var beautified = beautifyJs(current, opts.maxBeautifyBytes);
        if (beautified !== current) {
            entry.beautified = true;
            files.push({ path: base + '/10-beautified.js', content: beautified });
        }
    }
    if (!looksMinified(current)) {
        files.push({ path: base + '/10-source.js', content: current });
    }

    var mapRef = findSourceMapRef(asset.content) || findSourceMapRef(current);
    if (mapRef) {
        entry.sourceMap = { kind: mapRef.kind, ref: mapRef.kind === 'inline' ? 'inline data URI' : mapRef.value };
        var mapJson = null;
        if (mapRef.kind === 'inline') {
            mapJson = decodeInlineSourceMap(mapRef.value);
        } else if (typeof opts.fetchText === 'function') {
            var mapUrl = resolveMapUrl(asset.url, mapRef.value);
            var fetched = await opts.fetchText(mapUrl);
            if (fetched && typeof fetched === 'string' && fetched.length <= LIMITS.maxMapBytes) mapJson = fetched;
            else entry.notes.push('source map fetch failed: ' + mapRef.value);
        }
        if (mapJson) {
            try {
                var parsed = parseSourceMap(mapJson);
                entry.sources = parsed.files.length;
                files.push({ path: base + '/source-map.json', content: mapJson });
                for (var f = 0; f < parsed.files.length; f++) {
                    files.push({ path: base + '/sources/' + safePath(parsed.files[f].path), content: parsed.files[f].content });
                }
            } catch (_) {
                entry.notes.push('source map parse failed');
            }
        }
    }

    if (!entry.stages.length && !entry.modules && !entry.sources) {
        entry.notes.push('no obfuscation layer, bundle structure, or source map content found');
    }
    return { entry: entry, files: files };
}

export async function unpackAssets(assets, options) {
    var opts = options || {};
    var report = { generatedBy: 'unpack.js', assets: [], totals: { assets: assets.length, unpacked: 0, modules: 0, sources: 0, beautified: 0 } };
    var allFiles = [];
    for (var i = 0; i < assets.length; i++) {
        var result = await unpackAsset(assets[i], {
            index: i,
            maxDepth: opts.maxDepth,
            maxModules: opts.maxModules,
            maxBeautifyBytes: opts.maxBeautifyBytes,
            fetchText: opts.fetchText,
            inflate: opts.inflate,
            pathPrefix: opts.pathPrefix,
            zipPath: assets[i].zipPath
        });
        report.assets.push(result.entry);
        for (var f = 0; f < result.files.length; f++) allFiles.push(result.files[f]);
        if (result.entry.stages.length || result.entry.sources || result.entry.modules) report.totals.unpacked++;
        report.totals.modules += result.entry.modules;
        report.totals.sources += result.entry.sources;
        if (result.entry.beautified) report.totals.beautified++;
        if (typeof opts.onProgress === 'function') opts.onProgress(i + 1, assets.length);
    }
    return { report: report, files: allFiles };
}

export async function unpackAssetsIntoZip(zip, assets, options) {
    var opts = options || {};
    var prefix = opts.pathPrefix || '_unpack';
    var result = await unpackAssets(assets, opts);
    for (var i = 0; i < result.files.length; i++) zip.file(result.files[i].path, result.files[i].content);
    result.report.generatedBy = 'unpack.js';
    result.report.root = prefix;
    result.report.unpackedAt = new Date().toISOString();
    zip.file(opts.reportPath || prefix + '/index.json', JSON.stringify(result.report, null, 2));
    return result.report;
}
