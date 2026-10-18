// JavaScriptCore cached-bytecode string recovery for the DevTools export pipeline.
//
// A Bun --bytecode chunk opens with a five-word header: a build-rotating
// stamp, the format word 1, a version, the declared length (always the exact
// blob length) and the body offset 0x20. Never pin the stamp — acceptance is
// the format word OR the declared-length match (G:/unbened/unbuned.py,
// parse_bytecode_header, proven over every module of a shipping build).
//
// Inside the body, every compiler string is a 12-byte record: a flag word
// (length in bits 0-26, the two-byte flag at bit 27), the 24-bit
// StringImpl::hash() of the raw little-endian character bytes, then a 4-byte
// ordinal — followed by the characters. The hash is the proof: a printable
// run is noise, a candidate whose stored hash matches its characters is a
// real record, and its length says exactly where it ends.
//
// Ground truth on this box: chunk 0000-chunk-nqhgex2p.jsc (2104 bytes,
// format 1, version 4) yields exactly ['moduleLoader', 'starNamespace'].

const JSC_HEADER_SIZE = 32;
const JSC_FORMAT_WORD = 1;
const JSC_LENGTH_MASK = 0x07FFFFFF;
const JSC_IS_8_BIT = 0x08000000;
const JSC_RECORD_HEADER = 12;
const JSC_STRING_LIMIT = 4096;
const JSC_HASH_MASK = 0x00FFFFFF;

// RapidHash secret from WTF's rapidhash.h — constant, not build specific.
const WTF_SECRET = [
    0x2d358dccaa6c78a5n,
    0x8bb84b93962eacc9n,
    0x4b33a62ed433d4a3n
];
const HASH_64 = 0xFFFFFFFFFFFFFFFFn;

function u32(bytes, at) {
    return (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)) >>> 0;
}

function rapidMix(first, second) {
    // BigInt keeps the full 128-bit product: masking before the shift would
    // fold zero into the high half and mirror every value (unbuned lesson).
    var product = first * second;
    return (product & HASH_64) ^ (product >> 64n);
}

function read64(bytes, at) {
    var value = 0n;
    for (var i = 7; i >= 0; i--) value = (value << 8n) | BigInt(bytes[at + i]);
    return value;
}

function read32Big(bytes, at) {
    var value = 0n;
    for (var i = 3; i >= 0; i--) value = (value << 8n) | BigInt(bytes[at + i]);
    return value;
}

// WTF::StringImpl::hash(): RapidHash over the raw character bytes, low 24
// bits, zero replaced by 0x800000. Verified against every record of a
// shipping build (241,333 eight-bit and 11,888 sixteen-bit table records).
export function wtfStringHash(bytes) {
    var length = bytes.length;
    var secret = WTF_SECRET;
    var seed = rapidMix(secret[0], secret[1]) ^ BigInt(length);
    var first, second;
    if (length <= 16) {
        if (length >= 4) {
            var delta = length >= 8 ? 4 : 0;
            first = (read32Big(bytes, 0) << 32n) | read32Big(bytes, length - 4);
            second = (read32Big(bytes, delta) << 32n) | read32Big(bytes, length - 4 - delta);
        } else if (length) {
            first = (BigInt(bytes[0]) << 56n) | (BigInt(bytes[length >> 1]) << 32n) | BigInt(bytes[length - 1]);
            second = 0n;
        } else {
            first = 0n;
            second = 0n;
        }
    } else {
        var remaining = length;
        var at = 0;
        if (remaining > 48) {
            var see1 = seed;
            var see2 = seed;
            while (true) {
                seed = rapidMix(read64(bytes, at) ^ secret[0], read64(bytes, at + 8) ^ seed);
                see1 = rapidMix(read64(bytes, at + 16) ^ secret[1], read64(bytes, at + 24) ^ see1);
                see2 = rapidMix(read64(bytes, at + 32) ^ secret[2], read64(bytes, at + 40) ^ see2);
                at += 48;
                remaining -= 48;
                if (remaining < 48) break;
            }
            seed ^= see1 ^ see2;
        }
        if (remaining > 16) {
            seed = rapidMix(read64(bytes, at) ^ secret[2], read64(bytes, at + 8) ^ seed ^ secret[1]);
            if (remaining > 32) {
                seed = rapidMix(read64(bytes, at + 16) ^ secret[2], read64(bytes, at + 24) ^ seed);
            }
        }
        first = read64(bytes, at + remaining - 16);
        second = read64(bytes, at + remaining - 8);
    }
    first ^= secret[1];
    second ^= seed;
    var product = first * second;
    var value = Number(
        rapidMix((product & HASH_64) ^ secret[0] ^ BigInt(length), (product >> 64n) ^ secret[1]) & BigInt(JSC_HASH_MASK)
    );
    return value || 0x800000;
}

export function parseJscHeader(bytes) {
    if (!bytes || bytes.length < JSC_HEADER_SIZE) return null;
    var formatWord = u32(bytes, 4);
    var version = u32(bytes, 8);
    var declaredLength = u32(bytes, 12);
    var bodyOffset = u32(bytes, 16);
    if (formatWord !== JSC_FORMAT_WORD && declaredLength !== bytes.length) return null;
    return {
        tool: 'jsc-bytecode',
        stamp: u32(bytes, 0),
        format: formatWord,
        version: version,
        declaredLength: declaredLength,
        bodyOffset: bodyOffset
    };
}

export function detectJscBytecode(bytes) {
    return parseJscHeader(bytes) !== null;
}

// Scan candidates with the same prefilter the proven extractor uses: the top
// length bits clear in the flag byte (bits 24-26) and a zero top byte on the
// stored hash (24-bit hash, little endian), then prove each candidate by
// hashing its characters. Distinct strings in order of appearance.
export function recoverJscStrings(bytes) {
    if (!bytes || !bytes.length) return [];
    var strings = [];
    var seen = {};
    var at = 0;
    var len = bytes.length;
    while (at + JSC_RECORD_HEADER <= len) {
        // prefilter: bits 24-26 of the flag word clear (top byte & 0x07 == 0)
        if ((bytes[at + 3] & 0x07) !== 0 || bytes[at + 7] !== 0x00) { at++; continue; }
        var flags = u32(bytes, at);
        var stored = u32(bytes, at + 4);
        var length = flags & JSC_LENGTH_MASK;
        // bit 27 is the IS-8-BIT flag: set means one-byte characters
        var width = (flags & JSC_IS_8_BIT) ? 1 : 2;
        var byteLength = length * width;
        if (!length || length > JSC_STRING_LIMIT || at + JSC_RECORD_HEADER + byteLength > len) { at++; continue; }
        var charAt = at + JSC_RECORD_HEADER;
        var raw = bytes.subarray(charAt, charAt + byteLength);
        var hash = wtfStringHash(raw);
        if (hash === stored) {
            var text = '';
            var ok = true;
            if (width === 1) {
                for (var c = 0; c < length; c++) {
                    var b = raw[c];
                    if (b < 0x20 || b >= 0x7f) { ok = false; break; }
                    text += String.fromCharCode(b);
                }
            } else {
                for (var w = 0; w < length; w++) {
                    var unit = raw[w * 2] | (raw[w * 2 + 1] << 8);
                    if (unit < 0x20 || unit >= 0x7f) { ok = false; break; }
                    text += String.fromCharCode(unit);
                }
            }
            if (ok && !seen[text]) {
                seen[text] = true;
                strings.push(text);
            }
            at = charAt + byteLength;
        } else {
            at++;
        }
    }
    return strings;
}
