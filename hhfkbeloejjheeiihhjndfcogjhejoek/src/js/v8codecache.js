// V8 code-cache reader for the DevTools export pipeline.
//
// A cached-data blob (vm.Script#createCachedData, node's compile cache, or a
// JSCeal-sealed .jsc once inflated) opens with the magic 0xC0DE0000 | N where
// the low half is the external-reference-table size of the build that wrote
// it — so the magic identifies the FAMILY, never a fixed word. Behind the
// header sits a serialized V12 payload: bytecode plus one-byte string frames
// (`0x52` tag, a map byte, the StringImpl hash, the length, the characters).
// Recovering those strings is what makes a sealed blob readable without the
// exact V8 build that produced it.
//
// Ground truth on this box: node v24.19.0 writes magic 0xC0DE0689 with the
// source fragment 'hi from cache' framed as 52 62 <hash> 0d000000 and the
// script name 'evalmachine.<anonymous>' as 52 63 <hash> 17000000.

const V8_MAGIC_FAMILY = 0xC0DE0000;
const V8_MAGIC_MASK = 0xFFFF0000;
const V8_MIN_EXT_REFS = 1;
const V8_MAX_EXT_REFS = 0x4000;

// Full magics observed per node line; the low half drifts across subminors
// (v24.19.0 writes 0x0689), so a miss falls back to the family + payload fit.
const V8_KNOWN_MAGICS = {
    0xC0DE0563: 'node18',
    0xC0DE05CC: 'node20',
    0xC0DE0628: 'node22',
    0xC0DE0688: 'node24'
};

const V11_HEADER_SIZE = 24; // node18/20: version_hash, source_hash, flag_hash, payload_length, checksum
const V12_HEADER_SIZE = 32; // node22+:  ... , ro_snapshot_checksum, payload_length, checksum
const V8_MAX_PAYLOAD = 256 * 1024 * 1024;
const V8_STRING_MIN = 2;
const V8_STRING_MAX = 1 << 24;

// JSCeal seals its payload with raw brotli; there is no magic, so the sealed
// route is tried whenever a blob is neither a plain V8 cache nor JSC bytecode.
const BROTLI_WINDOW_MAX_BYTES = 64 * 1024 * 1024;

function u32(bytes, at) {
    return (bytes[at] | (bytes[at + 1] << 8) | (bytes[at + 2] << 16) | (bytes[at + 3] << 24)) >>> 0;
}
export function detectV8CodeCache(bytes) {
    if (!bytes || bytes.length < V12_HEADER_SIZE) return false;
    var magic = u32(bytes, 0);
    // The & operator yields a SIGNED int32 (bit31 set on the 0xC0DE family),
    // so compare the family via an unsigned shift, never via & against the
    // positive literal.
    if ((magic >>> 16) !== (V8_MAGIC_FAMILY >>> 16)) return false;
    var extRefs = magic & 0xFFFF;
    return extRefs >= V8_MIN_EXT_REFS && extRefs <= V8_MAX_EXT_REFS;
}

export function parseV8CodeCache(bytes) {
    if (!detectV8CodeCache(bytes)) return null;
    var magic = u32(bytes, 0);
    var known = V8_KNOWN_MAGICS[magic] || null;
    // The header layout switched at node22: V11 keeps payload_length at +16,
    // V12 inserts the read-only snapshot checksum there. The payload always
    // ends exactly at the blob end, so the layout whose length fits wins.
    var v11Payload = u32(bytes, 16);
    var v12Payload = u32(bytes, 20);
    var format, payloadLength, payloadOffset;
    if (v12Payload + V12_HEADER_SIZE === bytes.length) {
        format = 'v12';
        payloadLength = v12Payload;
        payloadOffset = V12_HEADER_SIZE;
    } else if (v11Payload + V11_HEADER_SIZE === bytes.length) {
        format = 'v11';
        payloadLength = v11Payload;
        payloadOffset = V11_HEADER_SIZE;
    } else {
        return null;
    }
    if (payloadLength > V8_MAX_PAYLOAD || payloadOffset + payloadLength > bytes.length) return null;
    return {
        tool: 'v8-code-cache',
        magic: magic,
        magicHex: '0x' + magic.toString(16),
        runtime: known || ('unknown build (' + V8_MAGIC_FAMILY.toString(16) + ' family, ' + (magic & 0xFFFF) + ' external refs)'),
        format: format,
        versionHash: u32(bytes, 4),
        sourceHash: u32(bytes, 8),
        flagHash: u32(bytes, 12),
        payloadOffset: payloadOffset,
        payloadLength: payloadLength,
        strings: extractV8Strings(bytes, payloadOffset, payloadOffset + payloadLength)
    };
}

// One-byte string frames inside the serialized payload. The map byte carries
// per-build flags (0x62 and 0x63 both occur in one node24 blob), so the scan
// accepts the small observed set and lets length + printability filter noise.
export function extractV8Strings(bytes, from, to) {
    var out = [];
    var seen = {};
    var end = Math.min(to !== undefined ? to : bytes.length, bytes.length);
    for (var i = (from || 0); i + 10 <= end; i++) {
        if (bytes[i] !== 0x52) continue;
        var map = bytes[i + 1];
        if (map !== 0x61 && map !== 0x62 && map !== 0x63) continue;
        var length = u32(bytes, i + 6);
        if (length < V8_STRING_MIN || length >= V8_STRING_MAX) continue;
        var charAt = i + 10;
        if (charAt + length > end) continue;
        var printable = true;
        var chars = '';
        for (var c = 0; c < length; c++) {
            var b = bytes[charAt + c];
            if (b < 0x20 || b >= 0x7f) { printable = false; break; }
            chars += String.fromCharCode(b);
        }
        if (!printable) continue;
        if (seen[chars]) continue;
        seen[chars] = true;
        out.push(chars);
        i = charAt + length - 1;
    }
    return out;
}

// Brotli inflation through the platform stream. The panel (Chrome >= 135)
// serves DecompressionStream('br'); node's undici rejects 'br', so callers
// outside the browser inject their own inflator and the default returns
// null when the platform has none — a refusal, never a silent skip.
export async function inflateBrotli(bytes, inflateImpl) {
    if (typeof inflateImpl === 'function') {
        try { return await inflateImpl(bytes); } catch (_) { return null; }
    }
    if (typeof DecompressionStream !== 'function') return null;
    try {
        var stream = new DecompressionStream('br');
        var chunks = [];
        var writer = stream.writable.getWriter();
        var reader = stream.readable.getReader();
        var pumping = reader.read().then(function pump(result) {
            if (result.done) return;
            chunks.push(result.value);
            return reader.read().then(pump);
        });
        await writer.write(bytes);
        await writer.close();
        await pumping;
        var total = 0;
        for (var i = 0; i < chunks.length; i++) total += chunks[i].length;
        var out = new Uint8Array(total);
        var at = 0;
        for (var j = 0; j < chunks.length; j++) { out.set(chunks[j], at); at += chunks[j].length; }
        return out.length ? out : null;
    } catch (err) {
        return null;
    }
}

// JSCeal-sealed .jsc: brotli around a V8 code cache. Returns null when the
// bytes are not that shape, so the JSC-bytecode detector gets its turn.
export async function parseSealedV8(bytes, options) {
    var opts = options || {};
    if (!bytes || !bytes.length || detectV8CodeCache(bytes)) return null;
    if (bytes.length > BROTLI_WINDOW_MAX_BYTES) return null;
    var inflated = await inflateBrotli(bytes, opts.inflate);
    if (!inflated || !detectV8CodeCache(inflated)) return null;
    var parsed = parseV8CodeCache(inflated);
    if (!parsed) return null;
    return {
        tool: 'jsc-sealed-v8',
        detail: 'brotli-sealed V8 code cache',
        inflatedBytes: inflated.length,
        cache: parsed
    };
}
