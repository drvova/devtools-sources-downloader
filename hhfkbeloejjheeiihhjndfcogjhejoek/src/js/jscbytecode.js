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
const JSC_LENGTH_MASK = 0x07ffffff;
const JSC_IS_8_BIT = 0x08000000;
const JSC_RECORD_HEADER = 12;
const JSC_STRING_LIMIT = 4096;
const JSC_HASH_MASK = 0x00ffffff;

// RapidHash secret from WTF's rapidhash.h — constant, not build specific.
const WTF_SECRET = [0x2d358dccaa6c78a5n, 0x8bb84b93962eacc9n, 0x4b33a62ed433d4a3n];
const HASH_64 = 0xffffffffffffffffn;

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
            first =
                (BigInt(bytes[0]) << 56n) |
                (BigInt(bytes[length >> 1]) << 32n) |
                BigInt(bytes[length - 1]);
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
            seed = rapidMix(
                read64(bytes, at) ^ secret[2],
                read64(bytes, at + 8) ^ seed ^ secret[1],
            );
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
        rapidMix((product & HASH_64) ^ secret[0] ^ BigInt(length), (product >> 64n) ^ secret[1]) &
            BigInt(JSC_HASH_MASK),
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
        bodyOffset: bodyOffset,
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
        if ((bytes[at + 3] & 0x07) !== 0 || bytes[at + 7] !== 0x00) {
            at++;
            continue;
        }
        var flags = u32(bytes, at);
        var stored = u32(bytes, at + 4);
        var length = flags & JSC_LENGTH_MASK;
        // bit 27 is the IS-8-BIT flag: set means one-byte characters
        var width = flags & JSC_IS_8_BIT ? 1 : 2;
        var byteLength = length * width;
        if (!length || length > JSC_STRING_LIMIT || at + JSC_RECORD_HEADER + byteLength > len) {
            at++;
            continue;
        }
        var charAt = at + JSC_RECORD_HEADER;
        var raw = bytes.subarray(charAt, charAt + byteLength);
        var hash = wtfStringHash(raw);
        if (hash === stored) {
            var text = '';
            var ok = true;
            if (width === 1) {
                for (var c = 0; c < length; c++) {
                    var b = raw[c];
                    if (b < 0x20 || b >= 0x7f) {
                        ok = false;
                        break;
                    }
                    text += String.fromCharCode(b);
                }
            } else {
                for (var w = 0; w < length; w++) {
                    var unit = raw[w * 2] | (raw[w * 2 + 1] << 8);
                    if (unit < 0x20 || unit >= 0x7f) {
                        ok = false;
                        break;
                    }
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

// ---------------------------------------------------------------
// Structure recovery: the cached-function tree (from the unbuned
// oracle). A module's payload is an object graph: a
// CachedFunctionExecutable record at 0x20 names call/construct code
// blocks; each block's fdecls/fexprs arrays name child executables;
// the walk ends at the functions the module defines. Every block
// binds only when its instruction stream opens on `enter`, walks
// exactly its declared length under the opcode table, and ends on a
// transfer of control — a coincidence in the bytes fails closed.
// ---------------------------------------------------------------

const JSC_OPCODE_SOURCE = `0 tail_call_varargs 6 1
1 call_varargs 7 1
2 iterator_next 9 1
3 construct_varargs 7 1
4 super_construct_varargs 7 1
5 iterator_open 8 1
6 async_iterator_open 8 1
7 instanceof 6 1
8 set_private_brand 2 1
9 check_private_brand 2 1
10 new_reg_exp_shared 3 1
11 put_by_id 4 1
12 construct 5 1
13 super_construct 5 1
14 tail_call 4 1
15 call_direct_eval 8 1
16 create_generator 2 1
17 create_async_generator 2 1
18 create_promise 2 1
19 catch 2 1
20 new_array_with_size 2 1
21 new_array_buffer 3 1
22 get_by_id 4 1
23 get_length 3 1
24 profile_type 5 1
25 profile_control_flow 1 1
26 new_array_with_species 4 1
27 call 5 1
28 call_ignore_result 3 1
29 async_iterator_next 7 1
30 resolve_scope 5 1
31 get_from_scope 7 1
32 put_to_scope 6 1
33 create_this 3 1
34 new_object 2 1
35 new_array 4 1
36 put_private_name 4 1
37 get_private_name 4 1
38 get_by_val_with_this 5 1
39 get_by_val 4 1
40 put_by_val 4 1
41 put_by_val_direct 4 1
42 in_by_val 3 1
43 enumerator_next 5 1
44 enumerator_in_by_val 6 1
45 enumerator_has_own_property 6 1
46 enumerator_put_by_val 7 1
47 to_this 3 1
48 enumerator_get_by_val 7 1
49 get_by_id_direct 4 1
50 jneq_ptr 3 1
51 iterator_close_check 4 1
52 get_argument 3 0
53 get_from_arguments 4 0
54 get_prototype_of 3 0
55 get_internal_field 4 0
56 get_by_id_with_this 5 0
57 to_object 4 0
58 in_by_id 3 0
59 has_private_name 3 0
60 has_private_brand 3 0
61 put_by_id_with_this 5 0
62 del_by_id 4 0
63 put_by_val_with_this 5 0
64 del_by_val 4 0
65 put_getter_by_id 4 0
66 put_setter_by_id 4 0
67 put_getter_setter_by_id 5 0
68 put_getter_by_val 4 0
69 put_setter_by_val 4 0
70 define_data_property 4 0
71 define_accessor_property 5 0
72 jmp 1 0
73 jtrue 2 0
74 jfalse 2 0
75 jeq_null 2 0
76 jneq_null 2 0
77 jundefined_or_null 2 0
78 jnundefined_or_null 2 0
79 jeq_ptr 3 0
80 jeq 3 0
81 jstricteq 3 0
82 jneq 3 0
83 jnstricteq 3 0
84 jless 3 0
85 jlesseq 3 0
86 jgreater 3 0
87 jgreatereq 3 0
88 jnless 3 0
89 jnlesseq 3 0
90 jngreater 3 0
91 jngreatereq 3 0
92 jbelow 3 0
93 jbeloweq 3 0
94 loop_hint 0 0
95 switch_imm 2 0
96 switch_char 2 0
97 switch_string 2 0
98 new_func 3 0
99 new_func_exp 3 0
100 new_generator_func 3 0
101 new_generator_func_exp 3 0
102 new_async_func 3 0
103 new_async_func_exp 3 0
104 new_async_generator_func 3 0
105 new_async_generator_func_exp 3 0
106 set_function_name 2 0
107 ret 1 0
108 strcat 3 0
109 to_primitive 2 0
110 to_property_key 2 0
111 to_property_key_or_number 2 0
112 put_to_arguments 3 0
113 push_with_scope 3 0
114 create_lexical_environment 4 0
115 create_generator_frame_environment 4 0
116 get_parent_scope 2 0
117 throw 1 0
118 throw_static_error 2 0
119 debug 2 0
120 get_property_enumerator 2 0
121 unreachable 0 0
122 create_rest 2 0
123 yield 2 0
124 check_traps 0 0
125 log_shadow_chicken_prologue 1 0
126 log_shadow_chicken_tail 2 0
127 resolve_scope_for_hoisting_func_decl_in_eval 3 0
128 put_internal_field 3 0
129 nop 0 0
130 super_sampler_begin 0 0
131 wide16 0 0
132 super_sampler_end 0 0
133 wide32 0 0
134 enter 0 0
135 get_scope 1 0
136 create_direct_arguments 1 0
137 create_scoped_arguments 2 0
138 create_cloned_arguments 1 0
139 new_promise 1 0
140 new_generator 1 0
141 new_async_function_generator 1 0
142 argument_count 1 0
143 check_tdz 2 0
144 new_array_with_spread 4 0
145 spread 2 0
146 new_reg_exp 2 0
147 mov 2 0
148 eq 3 0
149 neq 3 0
150 stricteq 3 0
151 nstricteq 3 0
152 less 3 0
153 lesseq 3 0
154 greater 3 0
155 greatereq 3 0
156 below 3 0
157 beloweq 3 0
158 mod 3 0
159 pow 3 0
160 urshift 3 0
161 add 5 0
162 mul 5 0
163 div 5 0
164 sub 5 0
165 bitand 5 0
166 bitor 5 0
167 bitxor 5 0
168 lshift 4 0
169 rshift 4 0
170 eq_null 2 0
171 neq_null 2 0
172 to_string 2 0
173 is_empty 2 0
174 typeof_is_undefined 2 0
175 typeof_is_object 2 0
176 typeof_is_function 2 0
177 is_undefined_or_null 2 0
178 is_boolean 2 0
179 is_number 2 0
180 is_big_int 2 0
181 is_object 2 0
182 is_callable 2 0
183 is_constructor 2 0
184 inc 2 0
185 dec 2 0
186 negate 4 0
187 not 2 0
188 identity_with_profile 3 0
189 typeof 2 0
190 is_cell_with_type 3 0
191 has_structure_with_flags 3 0
192 to_number 3 0
193 to_numeric 3 0
194 bitnot 3 0
195 unsigned 3 0
196 llint_entry 0 0
197 llint_vm_entry_to_javascript 0 0
198 llint_vm_entry_to_native 0 0
199 llint_program_prologue 0 0
200 llint_eval_prologue 0 0
201 llint_module_program_prologue 0 0
202 llint_function_for_call_prologue 0 0
203 llint_function_for_construct_prologue 0 0
204 llint_function_for_call_arity_check 0 0
205 llint_function_for_construct_arity_check 0 0
206 llint_generic_return_point 0 0
207 llint_throw_from_slow_path_trampoline 0 0
208 llint_throw_during_call_trampoline 0 0
209 llint_native_call_trampoline 0 0
210 llint_native_construct_trampoline 0 0
211 llint_internal_function_call_trampoline 0 0
212 llint_internal_function_construct_trampoline 0 0
213 llint_default_call_trampoline 0 0
214 llint_unlinked_call_trampoline 0 0
215 llint_virtual_call_trampoline 0 0
216 llint_virtual_construct_trampoline 0 0
217 llint_virtual_tail_call_trampoline 0 0
218 llint_polymorphic_normal_call_trampoline 0 0
219 llint_polymorphic_closure_call_trampoline 0 0
220 checkpoint_osr_exit_from_inlined_call_trampoline 0 0
221 checkpoint_osr_exit_trampoline 0 0
222 normal_osr_exit_trampoline 0 0
223 array_sort_comparator_return_trampoline 0 0
224 fuzzer_return_early_from_loop_hint 0 0
225 loop_osr_entry_gate 0 0
226 llint_get_host_call_return_value 0 0
227 llint_handle_uncaught_exception 0 0
228 op_call_return_location 0 0
229 op_call_ignore_result_return_location 0 0
230 op_construct_return_location 0 0
231 op_super_construct_return_location 0 0
232 op_call_varargs_return_location 0 0
233 op_construct_varargs_return_location 0 0
234 op_super_construct_varargs_return_location 0 0
235 op_get_by_id_return_location 0 0
236 op_async_iterator_open_return_location 0 0
237 op_get_by_id_direct_return_location 0 0
238 op_get_length_return_location 0 0
239 op_get_by_val_return_location 0 0
240 op_put_by_id_return_location 0 0
241 op_put_by_val_return_location 0 0
242 op_put_by_val_direct_return_location 0 0
243 op_in_by_id_return_location 0 0
244 op_in_by_val_return_location 0 0
245 op_instanceof_return_location 0 0
246 op_enumerator_get_by_val_return_location 0 0
247 op_enumerator_put_by_val_return_location 0 0
248 op_enumerator_in_by_val_return_location 0 0
249 op_iterator_open_return_location 0 0
250 op_iterator_next_return_location 0 0
251 op_async_iterator_next_return_location 0 0
252 op_call_direct_eval_slow_return_location 0 0
253 js_to_wasm_wrapper_entry 0 0
254 wasm_to_wasm_ipint_wrapper_entry 0 0
255 wasm_to_js_wrapper_entry 0 0
256 ipint_trampoline 0 0
257 ipint_entry 0 0
258 ipint_catch_entry 0 0
259 ipint_catch_all_entry 0 0
260 ipint_table_catch_entry 0 0
261 ipint_table_catch_ref_entry 0 0
262 ipint_table_catch_all_entry 0 0
263 ipint_table_catch_allref_entry 0 0
264 js_trampoline_op_call 0 0
265 js_trampoline_op_call_ignore_result 0 0
266 js_trampoline_op_construct 0 0
267 js_trampoline_op_super_construct 0 0
268 js_trampoline_op_call_varargs 0 0
269 js_trampoline_op_construct_varargs 0 0
270 js_trampoline_op_super_construct_varargs 0 0
271 js_trampoline_op_iterator_next 0 0
272 js_trampoline_op_iterator_open 0 0
273 js_trampoline_op_async_iterator_open 0 0
274 js_trampoline_op_async_iterator_next 0 0
275 js_trampoline_op_call_direct_eval_slow 0 0
276 js_trampoline_llint_function_for_call_arity_check_untag 0 0
277 js_trampoline_llint_function_for_call_arity_check_tag 0 0
278 js_trampoline_llint_function_for_construct_arity_check_untag 0 0
279 js_trampoline_llint_function_for_construct_arity_check_tag 0 0
280 wasm_trampoline_wasm_ipint_call 0 0
281 wasm_trampoline_wasm_ipint_tail_call 0 0
282 wasm_throw_from_slow_path_trampoline 0 0
283 wasm_throw_from_fault_handler_trampoline_reg_instance 0 0
284 wasm_ipint_call_return_location 0 0
285 llint_return_to_host 0 0
286 llint_cloop_did_return_from_js_1 0 0
287 llint_cloop_did_return_from_js_2 0 0
288 llint_cloop_did_return_from_js_3 0 0
289 llint_cloop_did_return_from_js_4 0 0
290 llint_cloop_did_return_from_js_5 0 0
291 llint_cloop_did_return_from_js_6 0 0
292 llint_cloop_did_return_from_js_7 0 0
293 llint_cloop_did_return_from_js_8 0 0
294 llint_cloop_did_return_from_js_9 0 0
295 llint_cloop_did_return_from_js_10 0 0
296 llint_cloop_did_return_from_js_11 0 0
297 llint_cloop_did_return_from_js_12 0 0
298 llint_cloop_did_return_from_js_13 0 0
299 llint_cloop_did_return_from_js_14 0 0
300 llint_cloop_did_return_from_js_15 0 0
301 llint_cloop_did_return_from_js_16 0 0
302 llint_cloop_did_return_from_js_17 0 0
303 llint_cloop_did_return_from_js_18 0 0
304 llint_cloop_did_return_from_js_19 0 0
305 llint_cloop_did_return_from_js_20 0 0
306 llint_cloop_did_return_from_js_21 0 0
307 llint_cloop_did_return_from_js_22 0 0
308 llint_cloop_did_return_from_js_23 0 0
309 llint_cloop_did_return_from_js_24 0 0
310 llint_cloop_did_return_from_js_25 0 0
311 llint_cloop_did_return_from_js_26 0 0
312 llint_cloop_did_return_from_js_27 0 0
313 llint_cloop_did_return_from_js_28 0 0
314 llint_cloop_did_return_from_js_29 0 0
315 llint_cloop_did_return_from_js_30 0 0
316 llint_cloop_did_return_from_js_31 0 0
317 llint_cloop_did_return_from_js_32 0 0
318 llint_cloop_did_return_from_js_33 0 0
319 llint_cloop_did_return_from_js_34 0 0
320 llint_cloop_did_return_from_js_35 0 0
321 llint_cloop_did_return_from_js_36 0 0
322 llint_cloop_did_return_from_js_37 0 0
`;

// id -> [name, operand bytes including metadata, has metadata]
var JSC_OPCODE_TABLE = null;
export function jscOpcodeTable() {
    if (JSC_OPCODE_TABLE) return JSC_OPCODE_TABLE;
    var table = {};
    var rows = JSC_OPCODE_SOURCE.split('\n');
    for (var i = 0; i < rows.length; i++) {
        var parts = rows[i].trim().split(/\s+/);
        if (parts.length < 4) continue;
        table[parts[0]] = [
            parts[1],
            parseInt(parts[2], 10) + parseInt(parts[3], 10),
            parts[3] === '1',
        ];
    }
    JSC_OPCODE_TABLE = table;
    return table;
}

const JSC_WIDE16 = 0x83;
const JSC_WIDE32 = 0x85;
const JSC_ENTER_OPCODE = 134;
const JSC_ARRAY_ORDER = ['steps', 'instr', 'consts', 'cscr', 'idents', 'fdecls', 'fexprs'];
const JSC_ARRAY_SPANS = { steps: 4, instr: 1, idents: 4, fdecls: 4, fexprs: 4 };
const JSC_BLOCK_GAPS = [4, 0x38, 0x28, 16];
const JSC_TERMINAL_OPS = {
    ret: 1,
    jmp: 1,
    ret_undefined: 1,
    checkpoint_osr_exit_from_in_call: 1,
    throw: 1,
    rethrow: 1,
    unreachable: 1,
    tail_call_varargs: 1,
    call_varargs: 1,
    call: 1,
    tail_call: 1,
    call_direct: 1,
    tail_call_direct: 1,
    call_eval: 1,
    call_ignore_result: 1,
    construct: 1,
    construct_varargs: 1,
    jneq_ptr: 1,
    direct_tail_call: 1,
};

function varint(bytes, at) {
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

function svarint(bytes, at) {
    var pair = varint(bytes, at);
    if (!pair) return null;
    var value = pair[0];
    return [(value >> 1) ^ -(value & 1), pair[1]];
}

export function parseJscTail(bytes, at) {
    if (at < 8 || at + 8 > bytes.length) return null;
    var flags = bytes[at];
    if (flags & ~0x05) return null;
    var cursor = at + 1;
    var pair = varint(bytes, cursor);
    if (!pair || pair[0] >= 0x2000000) return null;
    var recordOffset = pair[0];
    cursor = pair[1];
    if (flags & 1) {
        pair = varint(bytes, cursor);
        if (!pair || pair[0] > 1 << 24) return null;
        cursor = pair[1];
    }
    var arrays = {};
    for (var i = 0; i < JSC_ARRAY_ORDER.length; i++) {
        var name = JSC_ARRAY_ORDER[i];
        pair = varint(bytes, cursor);
        if (!pair || pair[0] > 0x2000000) return null;
        var count = pair[0];
        cursor = pair[1];
        var start = 0;
        if (count) {
            pair = svarint(bytes, cursor);
            if (!pair || Math.abs(pair[0]) > 0x2000000) return null;
            start = pair[0];
            cursor = pair[1];
        }
        arrays[name] = [count, start];
    }
    var extras = 0;
    if (flags & 4) {
        pair = svarint(bytes, cursor);
        if (!pair) return null;
        extras = pair[0];
        cursor = pair[1];
    }
    return {
        flags: flags,
        recordOffset: recordOffset,
        arrays: arrays,
        extras: extras,
        scalarsAt: cursor,
    };
}

function walkJscOps(bytes, start, length, table) {
    var offset = start;
    var end = start + length;
    var ops = [];
    while (offset < end) {
        if (offset >= bytes.length) return null;
        var first = bytes[offset];
        var op;
        if (first === JSC_WIDE16 || first === JSC_WIDE32) {
            if (offset + 2 > bytes.length) return null;
            op = table[bytes[offset + 1]];
            if (!op) return null;
            offset += 2 + op[1] * (first === JSC_WIDE16 ? 2 : 4);
        } else {
            op = table[first];
            if (!op) return null;
            offset += 1 + op[1];
        }
        if (offset > end) return null;
        ops.push([offset, first, op[0]]);
    }
    return ops.length ? ops : null;
}

// Bind a code block whose record sits at `record`. Candidates are
// tried at each fixed record-size gap; a candidate survives only when
// every positive array packs before the record, the stream opens on
// `enter`, walks exactly, and ends on a transfer of control.
export function bindJscBlock(bytes, record, table) {
    var candidates = [];
    for (var g = 0; g < JSC_BLOCK_GAPS.length; g++) {
        var gap = JSC_BLOCK_GAPS[g];
        var tail = parseJscTail(bytes, record + gap);
        if (!tail) continue;
        var instr = tail.arrays.instr;
        if (!instr[0]) continue;
        var packedEnd = 0;
        var hasPositive = false;
        var rejected = false;
        for (var name in tail.arrays) {
            var entry = tail.arrays[name];
            if (!entry[0] || entry[1] < 0) continue;
            var span = JSC_ARRAY_SPANS[name];
            var end = entry[1] + entry[0] * (span || 1);
            if (end > tail.recordOffset) {
                rejected = true;
                break;
            }
            if (span) {
                hasPositive = true;
                if (end > packedEnd) packedEnd = end;
            }
        }
        if (rejected) continue;
        var region = record - tail.recordOffset;
        if (region < 0x20 || region > record) continue;
        var streamAt = region + instr[1];
        if (streamAt < 0 || streamAt >= bytes.length) continue;
        if (bytes[streamAt] !== JSC_ENTER_OPCODE) continue;
        var ops = walkJscOps(bytes, streamAt, instr[0], table);
        if (!ops) continue;
        if (!JSC_TERMINAL_OPS[ops[ops.length - 1][2]]) continue;
        candidates.push({
            record: record,
            gap: gap,
            region: region,
            instrAt: streamAt,
            instrLength: instr[0],
            opCount: ops.length,
            tail: tail,
            tight: !hasPositive || packedEnd === tail.recordOffset,
        });
    }
    candidates.sort(function (a, b) {
        return a.tight === b.tight ? a.gap - b.gap : a.tight ? -1 : 1;
    });
    return candidates;
}

// Names stored inline in a module (a shared-table ordinal does not
// resolve inside a lone chunk, so it reports as `<ordinal N>`).
function readJscInlineString(bytes, at) {
    if (at < 0 || at + 12 > bytes.length) return null;
    var length = u32(bytes, at) & 0xffffff;
    if (!length || length > 4096) return null;
    if (at + 12 + length > bytes.length) return null;
    var text = '';
    for (var i = 0; i < length; i++) {
        var b = bytes[at + 12 + i];
        if (b < 0x20 || b >= 0x7f) return null;
        text += String.fromCharCode(b);
    }
    return text;
}

// ---------------------------------------------------------------
// Shared bytecode string table (EncoderStringTable). A
// `--compile --bytecode` build serializes one table for the whole
// binary and every chunk refers to a string of four or more
// characters by ordinal. Layout: a count, one offset per ordinal
// (from the table start, 4-aligned), then per string a length and
// flag word (length bits 0-30, the eight-bit flag at bit 31),
// StringImpl::hash() over the characters, then the characters.
// Every record is hash checked, so an edited payload yields fewer
// strings, never wrong ones.
//
// Divergence from the unbuned oracle, deliberate: the oracle
// appends valid records to a dense list, so one corrupt record
// shifts every later ordinal and can mis-name a function; this
// reader keeps one slot per ordinal (holes stay undefined), so a
// broken record leaves an unresolvable placeholder, never a wrong
// name.
export function readJscSharedTable(bytes, offset, length) {
    var empty = { strings: [], count: 0, resolved: 0, offset: offset, length: length };
    if (!bytes || offset < 0 || length < 8 || offset + length > bytes.length) return empty;
    var count = u32(bytes, offset);
    if (count < 1 || count > 0x400000 || 4 + count * 4 > length) return empty;
    var end = offset + length;
    var strings = [];
    var resolved = 0;
    for (var ordinal = 0; ordinal < count; ordinal++) {
        var recordAt = u32(bytes, offset + 4 + ordinal * 4);
        var at = offset + recordAt;
        if (recordAt % 4 || recordAt < 8 || at + 8 > end) continue;
        var flags = u32(bytes, at);
        var stored = u32(bytes, at + 4);
        var textLength = flags & 0x7fffffff;
        var width = (flags >>> 31) & 1 ? 1 : 2;
        var byteLength = textLength * width;
        if (!textLength || at + 8 + byteLength > end) continue;
        var chars = bytes.subarray(at + 8, at + 8 + byteLength);
        if (wtfStringHash(chars) !== stored) continue;
        var text = '';
        if (width === 1) {
            for (var c = 0; c < textLength; c++) text += String.fromCharCode(chars[c]);
        } else {
            for (var u = 0; u < textLength; u++)
                text += String.fromCharCode(chars[u * 2] | (chars[u * 2 + 1] << 8));
        }
        strings[ordinal] = text;
        resolved++;
    }
    return { strings: strings, count: count, resolved: resolved, offset: offset, length: length };
}

// Content-addressed table discovery: a zip of loose assets carries
// no module graph, so the table is located by validating its own
// structure. A candidate is a real table when its window fits, the
// first/middle/last ordinals resolve in-window, their offsets
// ascend (records are laid out in ordinal order), and every probed
// record hash-checks. Returns the sparse read, or null.
export function findJscSharedTable(bytes) {
    if (!bytes || bytes.length < 24) return null;
    for (var at = 0; at + 16 <= bytes.length; at += 4) {
        var count = u32(bytes, at);
        if (count < 8 || count > 0x200000) continue;
        if (at + 4 + count * 4 + 8 > bytes.length) continue;
        var probes = [0, count >> 1, count - 1];
        var lastOffset = -1;
        var ok = true;
        for (var p = 0; p < probes.length; p++) {
            var recordAt = u32(bytes, at + 4 + probes[p] * 4);
            var rec = at + recordAt;
            if (recordAt % 4 || recordAt < 8 || rec + 8 > bytes.length || recordAt <= lastOffset) {
                ok = false;
                break;
            }
            lastOffset = recordAt;
            var flags = u32(bytes, rec);
            var stored = u32(bytes, rec + 4);
            var textLength = flags & 0x7fffffff;
            var width = (flags >>> 31) & 1 ? 1 : 2;
            var byteLength = textLength * width;
            if (!textLength || rec + 8 + byteLength > bytes.length) {
                ok = false;
                break;
            }
            if (wtfStringHash(bytes.subarray(rec + 8, rec + 8 + byteLength)) !== stored) {
                ok = false;
                break;
            }
        }
        if (!ok) continue;
        var read = readJscSharedTable(bytes, at, bytes.length - at);
        if (read.resolved >= probes.length) {
            return {
                strings: read.strings,
                count: read.count,
                resolved: read.resolved,
                offset: at,
                length: read.length,
            };
        }
    }
    return null;
}

export function decodeJscSlot(bytes, fieldAt, slot, shared, depth) {
    if (slot === 0x7fffffff || slot === 0xffffffff) return '';
    if (depth === undefined) depth = 0;
    var tag = slot & 3;
    if (tag === 1) {
        var length = (slot >>> 2) & 3;
        var text = '';
        for (var i = 0; i < length; i++)
            text += String.fromCharCode((slot >>> (8 * (i + 1))) & 0xff);
        return text;
    }
    if (tag === 2) {
        var ordinal = slot >>> 2;
        if (shared && ordinal < shared.length && shared[ordinal] !== undefined)
            return shared[ordinal];
        return '<ordinal ' + ordinal + '>';
    }
    if (tag === 0 && depth < 3) {
        // field-relative pointer (signed 32-bit): the target is either
        // another slot (recursed) or an inline string record (fallback)
        var signed = slot | 0;
        var target = fieldAt + signed;
        if (target > 0 && target + 4 <= bytes.length) {
            var inner = u32(bytes, target);
            if ((inner & 3) <= 2) {
                var decoded = decodeJscSlot(bytes, target, inner, shared, depth + 1);
                if (decoded.indexOf('<offset') !== 0) return decoded;
            }
            var record = readJscInlineString(bytes, target);
            if (record !== null) return record;
        }
        if (target > 0) return '<offset ' + signed + '>';
    }
    if (tag === 3) return '<slot ' + slot.toString(16) + '>';
    return '';
}

export function instantiateJscExec(bytes, record, shared) {
    if (record < 0x20 || record + 32 > bytes.length) return null;
    var header = u32(bytes, record);
    var present = {
        call: header & 1,
        construct: (header >>> 1) & 1,
        name: (header >>> 2) & 1,
        tdz: (header >>> 3) & 1,
        rare: (header >>> 4) & 1,
        metadata: (header >>> 5) & 1,
    };
    var parsed = { record: record, parseMode: (header >>> 16) & 0xff, present: present };
    var cursor = record + 4;
    if (present.metadata) cursor += 4;
    var table = jscOpcodeTable();
    var view = bytes;
    function i32(at) {
        return view[at] | (view[at + 1] << 8) | (view[at + 2] << 16) | (view[at + 3] << 24);
    }
    for (var key = 0; key < 2; key++) {
        var kind = key === 0 ? 'call' : 'construct';
        if (!present[kind]) continue;
        if (cursor + 4 > bytes.length) return null;
        var fieldAt = cursor;
        var value = i32(cursor);
        cursor += 4;
        if (value === -1) {
            parsed[kind + 'Empty'] = true;
            continue;
        }
        if (fieldAt + value < 0x20 || fieldAt + value >= bytes.length) continue;
        parsed[kind + 'Blocks'] = bindJscBlock(bytes, fieldAt + value, table);
    }
    if (present.name) {
        if (cursor + 4 > bytes.length) return null;
        var nameSlot = u32(bytes, cursor);
        parsed.name = decodeJscSlot(bytes, cursor, nameSlot, shared);
        cursor += 4;
    }
    if (present.tdz) cursor += 4;
    if (present.rare) cursor += 4;
    parsed.end = cursor;
    return parsed;
}

function jscBlockChildren(bytes, block) {
    var children = [];
    var region = block.region;
    var kinds = ['fdecls', 'fexprs'];
    for (var k = 0; k < kinds.length; k++) {
        var entry = block.tail.arrays[kinds[k]];
        if (!entry[0]) continue;
        var base = region + entry[1];
        for (var index = 0; index < entry[0]; index++) {
            var slotAt = base + index * 4;
            if (slotAt + 4 > bytes.length) break;
            var delta =
                bytes[slotAt] |
                (bytes[slotAt + 1] << 8) |
                (bytes[slotAt + 2] << 16) |
                (bytes[slotAt + 3] << 24);
            children.push([kinds[k], slotAt + delta]);
        }
    }
    return children;
}

// CachedTypes GenericCacheEntry (the first 16 bytes of every payload):
// stamp, tag (the format word), reserved callee-locals, payload size
// (== blob length). The CacheEntry tail follows; its m_codeBlock slot
// at +0x2C is field-relative and names the root code block record.
// Tag 0 = Program (bun --bytecode's cjs default), 1 = Module (esm).
function parseJscCacheEntry(bytes) {
    if (!bytes || bytes.length < 0x30) return null;
    var tag = u32(bytes, 4);
    if (tag !== 0 && tag !== 1) return null;
    if (u32(bytes, 12) !== bytes.length) return null;
    var slot = u32(bytes, 0x2c) | 0;
    if (slot <= 0 || slot === -1) return null;
    var record = 0x2c + slot;
    if (record < 0x30 || record + 0x38 >= bytes.length) return null;
    return { tag: tag, codeBlockRecord: record };
}

// Decode a module's whole cached-function tree. One bad slot is
// counted, not raised: a corrupt slot must not discard the rest.
// Program payloads (tag 0) root at the CacheEntry's code block; module
// payloads keep the classic root-executable walk, byte-identical with
// the pinned fixtures.
export function analyzeJscModule(bytes, shared) {
    var stats = {
        valid: false,
        rootName: null,
        rootParseMode: null,
        nodes: 0,
        blocks: 0,
        ops: 0,
        bindFailed: 0,
        functions: [],
    };
    var pending = [];
    var seenBlocks = {};
    var seenExec = {};
    var entry = parseJscCacheEntry(bytes);
    if (entry && entry.tag === 0) {
        var program = null;
        var candidates = bindJscBlock(bytes, entry.codeBlockRecord, jscOpcodeTable());
        for (var ci = 0; ci < candidates.length; ci++) {
            if (candidates[ci].gap === 0x38) {
                program = candidates[ci];
                break;
            }
        }
        if (!program) return stats;
        stats.rootName = decodeJscSlot(bytes, 0x1c, u32(bytes, 0x1c), shared) || null;
        stats.rootParseMode = 0;
        stats.nodes = 1;
        stats.functions.push({
            name: stats.rootName,
            kind: 'root',
            record: program.record,
            callBlock: {
                region: program.region,
                instrAt: program.instrAt,
                instrLength: program.instrLength,
                opCount: program.opCount,
                gap: program.gap,
            },
            constructBlock: null,
        });
        pending.push(program);
    } else {
        var root = instantiateJscExec(bytes, 0x20, shared);
        if (!root) return stats;
        stats.rootName = root.name;
        stats.rootParseMode = root.parseMode;
        stats.nodes = 1;
        stats.functions.push({
            name: root.name === undefined ? null : root.name,
            kind: 'root',
            record: root.record,
            callBlock: null,
            constructBlock: null,
        });
        var rootEntry = stats.functions[0];
        seenExec[root.record] = 1;
        for (var kind = 0; kind < 2; kind++) {
            var key = kind === 0 ? 'call' : 'construct';
            var blocks = root[key + 'Blocks'];
            if (!blocks) {
                if (root.present[key] && !root[key + 'Empty']) stats.bindFailed++;
                continue;
            }
            pending = pending.concat(blocks);
            var best = blocks[0];
            if (best)
                rootEntry[key === 'call' ? 'callBlock' : 'constructBlock'] = {
                    region: best.region,
                    instrAt: best.instrAt,
                    instrLength: best.instrLength,
                    opCount: best.opCount,
                    gap: best.gap,
                };
        }
    }
    while (pending.length) {
        var block = pending.pop();
        var identity = block.record + ':' + block.gap;
        if (seenBlocks[identity]) continue;
        seenBlocks[identity] = 1;
        stats.blocks += 1;
        stats.ops += block.opCount;
        var children = jscBlockChildren(bytes, block);
        for (var c = 0; c < children.length; c++) {
            var target = children[c][1];
            if (target < 0x20 || target >= bytes.length - 32) {
                stats.bindFailed++;
                continue;
            }
            var child = instantiateJscExec(bytes, target, shared);
            if (!child) {
                stats.bindFailed++;
                continue;
            }
            var fn = {
                name: child.name === undefined ? null : child.name,
                kind: children[c][0],
                record: child.record,
                callBlock: null,
                constructBlock: null,
            };
            if (child.record in seenExec) {
                // already walked; but this parent gives it its kind label once
            } else {
                seenExec[child.record] = 1;
                stats.nodes += 1;
                stats.functions.push(fn);
            }
            for (var k2 = 0; k2 < 2; k2++) {
                var key2 = k2 === 0 ? 'call' : 'construct';
                var blocks2 = child[key2 + 'Blocks'];
                if (!blocks2) {
                    if (child.present[key2] && !child[key2 + 'Empty']) stats.bindFailed++;
                    continue;
                }
                pending = pending.concat(blocks2);
                var best2 = blocks2[0];
                if (best2)
                    fn[key2 === 'call' ? 'callBlock' : 'constructBlock'] = {
                        region: best2.region,
                        instrAt: best2.instrAt,
                        instrLength: best2.instrLength,
                        opCount: best2.opCount,
                        gap: best2.gap,
                    };
            }
        }
    }
    stats.valid = stats.blocks > 0 && stats.bindFailed === 0;
    stats.functions.sort(function (a, b) {
        return a.record - b.record;
    });
    return stats;
}
