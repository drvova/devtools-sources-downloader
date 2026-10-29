// WebAssembly module layer: detect a binary wasm module by its magic,
// walk its sections, and recover what an investigator actually wants —
// imports, exports, function names from the name section, and string
// constants from data segments. Unknown or truncated structure is
// reported as a note, never a crash.

const WASM_MAGIC = [0x00, 0x61, 0x73, 0x6d];
const WASM_SECTION_NAMES = {
    0: 'custom',
    1: 'type',
    2: 'import',
    3: 'function',
    4: 'table',
    5: 'memory',
    6: 'global',
    7: 'export',
    8: 'start',
    9: 'element',
    10: 'code',
    11: 'data',
    12: 'dataCount',
};
const WASM_KIND_NAMES = { 0: 'func', 1: 'table', 2: 'memory', 3: 'global' };
const WASM_MIN_STRING = 4;

export function detectWasmModule(bytes) {
    if (!bytes || bytes.length < 8) return false;
    return (
        bytes[0] === WASM_MAGIC[0] &&
        bytes[1] === WASM_MAGIC[1] &&
        bytes[2] === WASM_MAGIC[2] &&
        bytes[3] === WASM_MAGIC[3]
    );
}

function leb(bytes, at) {
    var value = 0;
    var shift = 0;
    while (true) {
        if (at >= bytes.length || shift > 35) return null;
        var b = bytes[at];
        at += 1;
        value += (b & 0x7f) * Math.pow(2, shift);
        if (!(b & 0x80)) return [value, at];
        shift += 7;
    }
}

// A wasm name: LEB length + UTF-8 bytes.
function wasmName(bytes, at) {
    var pair = leb(bytes, at);
    if (!pair) return null;
    var length = pair[0];
    at = pair[1];
    if (at + length > bytes.length) return null;
    var text = '';
    for (var i = 0; i < length; i++) {
        var b = bytes[at + i];
        if (b === 0x09 || b === 0x0a || b === 0x0d || (b >= 0x20 && b < 0x7f))
            text += String.fromCharCode(b);
        else return null; // names are valid UTF-8; refuse garbage
    }
    return [text, at + length];
}

function limits(bytes, at) {
    var flag = bytes[at];
    at += 1;
    var pair = leb(bytes, at);
    if (!pair) return null;
    if (flag & 1) {
        var pair2 = leb(bytes, pair[1]);
        if (!pair2) return null;
        return [true, pair2[1]];
    }
    return [true, pair[1]];
}

function scanPrintableStrings(bytes, at, end, min) {
    var out = [];
    var seen = {};
    var run = '';
    for (var i = at; i < end; i++) {
        var b = bytes[i];
        if (b >= 0x20 && b < 0x7f) {
            run += String.fromCharCode(b);
        } else {
            if (run.length >= min && !seen[run]) {
                seen[run] = 1;
                out.push(run);
            }
            run = '';
        }
    }
    if (run.length >= min && !seen[run]) out.push(run);
    return out;
}

function parseNameSubsection(payload, info) {
    var at = 0;
    while (at < payload.length) {
        var id = payload[at];
        at += 1;
        var pair = leb(payload, at);
        if (!pair) return;
        var size = pair[0];
        at = pair[1];
        if (at + size > payload.length) return;
        var body = payload.subarray(at, at + size);
        var cursor = 0;
        try {
            if (id === 0) {
                var named = wasmName(body, 0);
                if (named) info.moduleName = named[0];
            } else if (id === 1 || id === 2 || id === 4) {
                var countPair = leb(body, cursor);
                if (!countPair) {
                    at += size;
                    continue;
                }
                var count = countPair[0];
                cursor = countPair[1];
                for (var i = 0; i < count && cursor < body.length; i++) {
                    var indexPair = leb(body, cursor);
                    if (!indexPair) break;
                    cursor = indexPair[1];
                    var namePair = wasmName(body, cursor);
                    if (!namePair) break;
                    cursor = namePair[1];
                    if (id === 1) info.functionNames[indexPair[0]] = namePair[0];
                    else if (id === 4) info.typeNames[indexPair[0]] = namePair[0];
                    // id 2 = locals: (funcidx, count, pairs) — not recovered
                    if (id === 2) break;
                }
            }
        } catch (_) {
            /* subsection is best-effort */
        }
        at += size;
    }
}

export function parseWasmModule(bytes) {
    var info = {
        version: bytes[4] | (bytes[5] << 8) | (bytes[6] << 16) | (bytes[7] << 24),
        sections: [],
        imports: [],
        exports: [],
        functionNames: {},
        typeNames: {},
        moduleName: null,
        functionCount: 0,
        dataStrings: [],
        notes: [],
    };
    var at = 8;
    while (at < bytes.length) {
        var id = bytes[at];
        at += 1;
        var pair = leb(bytes, at);
        if (!pair) {
            info.notes.push('truncated section header at ' + at);
            break;
        }
        var size = pair[0];
        at = pair[1];
        if (at + size > bytes.length) {
            info.notes.push('section ' + (WASM_SECTION_NAMES[id] || id) + ' overruns the module');
            break;
        }
        var end = at + size;
        var section = {
            id: id,
            name: WASM_SECTION_NAMES[id] || 'unknown-' + id,
            offset: at,
            size: size,
        };
        info.sections.push(section);
        var cursor = at;
        try {
            if (id === 0) {
                var named = wasmName(bytes, cursor);
                if (named) {
                    section.customName = named[0];
                    if (named[0] === 'name')
                        parseNameSubsection(bytes.subarray(named[1], end), info);
                }
            } else if (id === 2) {
                var countPair = leb(bytes, cursor);
                if (countPair) {
                    cursor = countPair[1];
                    for (var i = 0; i < countPair[0] && cursor < end; i++) {
                        var modPair = wasmName(bytes, cursor);
                        if (!modPair) break;
                        cursor = modPair[1];
                        var fieldPair = wasmName(bytes, cursor);
                        if (!fieldPair) break;
                        cursor = fieldPair[1];
                        var kind = bytes[cursor];
                        cursor += 1;
                        var entry = {
                            module: modPair[0],
                            field: fieldPair[0],
                            kind: WASM_KIND_NAMES[kind] || kind,
                        };
                        if (kind === 0) {
                            var t = leb(bytes, cursor);
                            if (!t) break;
                            cursor = t[1];
                        } else if (kind === 1) {
                            cursor += 1;
                            var l = limits(bytes, cursor);
                            if (!l) break;
                            cursor = l[0];
                        } else if (kind === 2) {
                            var l2 = limits(bytes, cursor);
                            if (!l2) break;
                            cursor = l2[0];
                        } else if (kind === 3) {
                            cursor += 2;
                        }
                        info.imports.push(entry);
                    }
                }
            } else if (id === 3) {
                var fnPair = leb(bytes, cursor);
                if (fnPair) info.functionCount = fnPair[0];
            } else if (id === 7) {
                var expPair = leb(bytes, cursor);
                if (expPair) {
                    cursor = expPair[1];
                    for (var e = 0; e < expPair[0] && cursor < end; e++) {
                        var namePair = wasmName(bytes, cursor);
                        if (!namePair) break;
                        cursor = namePair[1];
                        var kindByte = bytes[cursor];
                        cursor += 1;
                        var idxPair = leb(bytes, cursor);
                        if (!idxPair) break;
                        cursor = idxPair[1];
                        info.exports.push({
                            name: namePair[0],
                            kind: WASM_KIND_NAMES[kindByte] || kindByte,
                            index: idxPair[0],
                        });
                    }
                }
            } else if (id === 11) {
                var segPair = leb(bytes, cursor);
                if (segPair) {
                    cursor = segPair[1];
                    for (var s = 0; s < segPair[0] && cursor < end; s++) {
                        var flagPair = leb(bytes, cursor);
                        if (!flagPair) break;
                        cursor = flagPair[1];
                        var flag = flagPair[0];
                        if (flag === 0 || flag === 2) {
                            if (flag === 2) {
                                var memPair = leb(bytes, cursor);
                                if (!memPair) break;
                                cursor = memPair[1];
                            }
                            // active segment: skip the init-expr (ends at the 0x0b end byte)
                            while (cursor < end) {
                                var op = bytes[cursor];
                                cursor += 1;
                                if (op === 0x0b) break;
                                if (op === 0x41 || op === 0x42) {
                                    var skip = leb(bytes, cursor);
                                    if (!skip) {
                                        cursor = end;
                                        break;
                                    }
                                    cursor = skip[1];
                                } else if (op === 0x23 || op === 0x24) {
                                    var skip2 = leb(bytes, cursor);
                                    if (!skip2) {
                                        cursor = end;
                                        break;
                                    }
                                    cursor = skip2[1];
                                }
                            }
                        }
                        var sizePair = leb(bytes, cursor);
                        if (!sizePair) break;
                        cursor = sizePair[1];
                        if (cursor + sizePair[0] > end) break;
                        var found = scanPrintableStrings(
                            bytes,
                            cursor,
                            cursor + sizePair[0],
                            WASM_MIN_STRING,
                        );
                        for (var f = 0; f < found.length; f++) {
                            if (info.dataStrings.indexOf(found[f]) < 0)
                                info.dataStrings.push(found[f]);
                        }
                        cursor += sizePair[0];
                    }
                }
            }
        } catch (_) {
            info.notes.push('section ' + section.name + ' partially decoded');
        }
        at = end;
    }
    // named exports are richer than the name section alone
    for (var x = 0; x < info.exports.length; x++) {
        var exp = info.exports[x];
        if (exp.kind === 'func' && !info.functionNames[exp.index])
            info.functionNames[exp.index] = exp.name;
    }
    return info;
}
