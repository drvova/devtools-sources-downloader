;;;; wasm.lisp — the WebAssembly module layer, ported from wasm.rs.
;;;;
;;;; A binary wasm module is: the magic `\0asm`, a little-endian u32 version,
;;;; then a flat run of sections. Each section is an id byte, a ULEB128 byte
;;;; length, and that many payload bytes. Everything an investigator wants —
;;;; imports, exports, function names from the name section, string constants
;;;; out of data segments — lives inside those payloads.
;;;;
;;;; THREE PROPERTIES OF THE ORIGINAL ARE DELIBERATE AND ARE KEPT:
;;;;
;;;;   FAIL SOFT. A module with a truncated header, an overrunning section, or
;;;;   an entry that runs off the end of its section does not raise. It yields
;;;;   a partially decoded module plus a NOTE naming what went wrong, because
;;;;   the caller (the archive writer) still wants the sections that did parse.
;;;;   The gate pins the note strings, so "it failed softly" cannot quietly
;;;;   become "it failed silently".
;;;;
;;;;   TWO DIFFERENT BOUNDS. Section entry loops stop at the SECTION end
;;;;   (`cursor < end`), but the LEB and name READS inside them are bounded by
;;;;   the MODULE length, not the section end — that is the Rust's shape, since
;;;;   it calls `leb(bytes, ..)` and `wasm_name(bytes, ..)` on the whole slice.
;;;;   Reproduced here on purpose, and the asymmetry is observable: an export
;;;;   whose index LEB straddles the section boundary reads those bytes from the
;;;;   next section rather than failing. The section is still reported as
;;;;   partially decoded only if a READ fails, not because a read crossed the
;;;;   boundary. Every walker therefore takes an explicit LIMIT argument instead
;;;;   of closing over a slice, and each call site says which bound it means. A
;;;;   port that bounded everything by the section end would be *stricter* than
;;;;   the original; the gate pins the truncation cases on the side where the
;;;;   two agree (a section that overruns the module, and an entry with no bytes
;;;;   left at all), and the docstring on each walker says which reads are which.
;;;;
;;;;   INTEGERS, NOT f64. The Rust accumulates LEB values into an f64 and
;;;;   compares counts as f64 (`let mut i = 0f64`). Exact integers are used
;;;;   here. The two can only disagree past 2^53, and every value that large
;;;;   already fails the `size > remaining` bound, so the port cannot accept a
;;;;   module the Rust rejected. The one visible difference is `count as u32`
;;;;   for the function count, which SATURATES in Rust: a declared count above
;;;;   2^32 becomes 4294967295 there. `(min count #xFFFFFFFF)` reproduces it
;;;;   rather than leaking a bignum into the JSON.

(defpackage :vovas.engine.wasm
  (:use :cl)
  (:export
   ;; the detector and the parser
   #:detect-wasm-module
   #:parse-wasm-module
   ;; the vocabulary the wire format uses
   #:section-name
   #:kind-name
   ;; LEB128 + names, exported because they are the whole low-level contract
   #:read-uleb128
   #:read-sleb128
   #:wasm-name
   #:scan-printable-strings
   ;; the parsed module
   #:wasm-module-info
   #:wasm-module-info-p
   #:wasm-module-info-version
   #:wasm-module-info-sections
   #:wasm-module-info-imports
   #:wasm-module-info-exports
   #:wasm-module-info-module-name
   #:wasm-module-info-function-count
   #:wasm-module-info-data-strings
   #:wasm-module-info-notes
   #:function-names
   #:type-names
   #:function-name-pairs
   #:type-name-pairs
   #:module-info-wire
   ;; the section / import / export / data records
   #:wasm-section
   #:wasm-section-id
   #:wasm-section-name
   #:wasm-section-offset
   #:wasm-section-size
   #:wasm-section-custom-name
   #:wasm-import
   #:wasm-import-module
   #:wasm-import-field
   #:wasm-import-kind
   #:wasm-export
   #:wasm-export-name
   #:wasm-export-kind
   #:wasm-export-index))

(in-package :vovas.engine.wasm)

;;; ---------------------------------------------------------------------------
;;; Constants
;;; ---------------------------------------------------------------------------

(defparameter *wasm-magic* (vector 0 97 115 109)
  "`\\0asm` as octets. A parameter, not a constant: DEFCONSTANT on a vector
mints a fresh object per compile and reloading the file then signals
DEFCONSTANT-UNEQL for identical bytes.")

(defparameter *wasm-min-string* 4
  "Shortest data-segment run worth reporting. Three characters of printable
noise appear in almost any binary; four is where the original drew the line.")

;;; ---------------------------------------------------------------------------
;;; The records
;;;
;;; Field order and names follow the Rust structs, because these serialise
;;; straight into wasm-info.json and the artifact's key names are part of the
;;; contract (`moduleName`, `dataStrings` are read by name in the Rust test).
;;; ---------------------------------------------------------------------------

(defstruct (wasm-section (:constructor make-wasm-section))
  (id 0 :type integer)
  (name "" :type string)
  ;; Offset of the section PAYLOAD (just past the length LEB), not of the id
  ;; byte. The Rust sets `offset: at` after advancing past the LEB, and the
  ;; gate pins the exact offsets of both fixtures so this cannot drift.
  (offset 0 :type integer)
  (size 0 :type integer)
  ;; NIL, not "", when the section is not custom: `skip_serializing_if =
  ;; "Option::is_none"` means the key is ABSENT from the JSON, and an empty
  ;; string would serialise as a present-but-empty customName.
  (custom-name nil))

(defstruct (wasm-import (:constructor make-wasm-import (module field kind)))
  (module "" :type string)
  (field "" :type string)
  (kind "" :type string))

(defstruct (wasm-export (:constructor make-wasm-export (name kind index)))
  (name "" :type string)
  (kind "" :type string)
  (index 0 :type integer))

(defstruct (wasm-module-info (:constructor make-wasm-module-info))
  (version 0 :type integer)
  (sections '())
  (imports '())
  (exports '())
  ;; Hash tables keyed by function/type index. The Rust uses BTreeMap, i.e.
  ;; ASCENDING INDEX ORDER when iterated, and the test reads `.values()` and
  ;; expects that order. A hash table has no order, so the accessors below sort;
  ;; an insertion-ordered list would have put index 2 before index 0 whenever
  ;; the name section listed them that way.
  (fn-names (make-hash-table :test #'eql) :type hash-table)
  (ty-names (make-hash-table :test #'eql) :type hash-table)
  (module-name nil)
  (function-count 0 :type integer)
  (data-strings '())
  (notes '()))

;;; ---------------------------------------------------------------------------
;;; The vocabulary
;;; ---------------------------------------------------------------------------

(defun section-name (id)
  "`sectionName(id)`: the spec's section name, or `unknown-<n>` for an id the
binary format does not define. Ids 13+ are not assigned, and reporting one as
`unknown-13` is how a malformed or future module stays legible instead of being
mislabelled as the nearest known section."
  (case id
    (0 "custom") (1 "type") (2 "import") (3 "function") (4 "table")
    (5 "memory") (6 "global") (7 "export") (8 "start") (9 "element")
    (10 "code") (11 "data") (12 "dataCount")
    (t (format nil "unknown-~d" id))))

(defun kind-name (kind)
  "`kindName(kind)`: the external-kind byte as a word — 0 func, 1 table,
2 memory, 3 global. Anything else keeps its DECIMAL FORM (7 rather than
`unknown-7`), which is what `other.to_string()` does for a u8; a word would lose
the byte that is the only useful thing about an out-of-range kind."
  (case kind
    (0 "func") (1 "table") (2 "memory") (3 "global")
    (t (princ-to-string kind))))

;;; ---------------------------------------------------------------------------
;;; LEB128
;;;
;;; Wasm encodes every length, count and index as LEB128: seven payload bits per
;;; byte, high bit set means "more bytes follow". Both readers below are the
;;; single implementation of that format in this port; nothing else shifts bytes
;;; by hand.
;;;
;;; The failure answer is `(values nil nil)`, never an exception: every caller
;;; in this module turns a failed read into a NOTE or a partial decode, which is
;;; the whole fail-soft contract. NIL as the value is unambiguous because 0 is
;;; true in Lisp, so a zero-length LEB reads as `(values 0 next)`.
;;; ---------------------------------------------------------------------------

(defun read-uleb128 (bytes at limit)
  "Read an UNSIGNED LEB128 at AT, never touching index LIMIT or beyond.
Returns `(values value next-index)`, or `(values nil nil)` if the encoding runs
past LIMIT or exceeds six bytes.

The six-byte ceiling is the original's `shift > 35` guard, reached before the
seventh byte is consumed: shifts 0,7,14,21,28,35 are read, a continuation bit on
the byte at shift 35 aborts. This is what stops a run of 0x80 filler from
spinning forever while the value grows without bound — the wrong implementation
here is not a wrong number, it is a hang."
  (let ((value 0) (shift 0) (i at))
    (loop
      (when (or (>= i limit) (> shift 35))
        (return (values nil nil)))
      (let ((b (aref bytes i)))
        (incf i)
        (incf value (ash (logand b #x7F) shift))
        (when (zerop (logand b #x80))
          (return (values value i)))
        (incf shift 7)))))

(defun read-sleb128 (bytes at limit)
  "Read a SIGNED LEB128 at AT. Same byte discipline as `read-uleb128`, with the
final byte's sign bit (0x40) extended: a value whose last byte is 0x7f reads as
-1, not 127.

The section walkers need only the unsigned reader — lengths, counts and indices
are all unsigned, and an `i32.const` inside an init-expression is only SKIPPED,
never valued. This exists because the format defines both and because the
natural mistake for the next consumer (decoding a constant expression) is to
reuse the unsigned reader, where 0x7f would silently become 127 and every
negative constant would be wrong by one bias. The gate pins the spec's own
examples."
  (let ((value 0) (shift 0) (i at))
    (loop
      (when (or (>= i limit) (> shift 35))
        (return (values nil nil)))
      (let ((b (aref bytes i)))
        (incf i)
        (incf value (ash (logand b #x7F) shift))
        (incf shift 7)
        (when (zerop (logand b #x80))
          ;; Sign-extend to the width actually consumed.
          (when (logtest b #x40)
            (decf value (ash 1 shift)))
          (return (values value i)))))))

;;; ---------------------------------------------------------------------------
;;; Names
;;; ---------------------------------------------------------------------------

(defun printable-name-byte-p (b)
  "The name-section byte class: tab, LF, CR, and 0x20..0x7E inclusive.

0x7F (DEL) is NOT in the set — the Rust range is `0x20..0x7f`, exclusive at the
top — and the gate pins that boundary by feeding a DEL into a custom section
name. A port written from the comment 'printable ASCII' instead of from the
range accepts it and produces a name the original refused."
  (or (= b 9) (= b 10) (= b 13) (and (>= b #x20) (<= b #x7E))))

(defun wasm-name (bytes at limit)
  "A wasm name: a ULEB128 byte length then that many UTF-8 bytes.
Returns `(values string next-index)` or `(values nil nil)`.

Only the ASCII subset of UTF-8 is accepted, and a single byte outside the class
REJECTS THE WHOLE NAME rather than being dropped or replaced. That is the
original's `return None; // names are valid UTF-8; refuse garbage`, and it is
the right call for an investigator tool: a name with bytes replaced would be a
name that does not exist in the module."
  (multiple-value-bind (len next) (read-uleb128 bytes at limit)
    (when (null next)
      (return-from wasm-name (values nil nil)))
    (let ((stop (+ next len)))
      (when (> stop limit)
        (return-from wasm-name (values nil nil)))
      (let ((out (make-string len)))
        (loop for i from 0 below len
              for b = (aref bytes (+ next i))
              do (if (printable-name-byte-p b)
                     (setf (char out i) (code-char b))
                     (return-from wasm-name (values nil nil))))
        (values out stop)))))

(defun wasm-limits (bytes at limit)
  "Skip a memory/table `limits` record at AT: one flag byte, a ULEB128 minimum,
and — when the flag's bit 0 is set — a ULEB128 maximum. Returns the index past
the record, or NIL.

The flag byte is fetched with an explicit bound check because the Rust uses
`bytes.get(at)?`: a missing byte is a failure, not index 0."
  (when (>= at limit)
    (return-from wasm-limits nil))
  (let ((flag (aref bytes at)))
    (multiple-value-bind (minimum next) (read-uleb128 bytes (1+ at) limit)
      (declare (ignore minimum))
      (when (null next)
        (return-from wasm-limits nil))
      (if (logtest flag 1)
          (multiple-value-bind (maximum next2) (read-uleb128 bytes next limit)
            (declare (ignore maximum))
            next2)
          next))))

;;; ---------------------------------------------------------------------------
;;; Printable runs out of a data segment
;;; ---------------------------------------------------------------------------

(defun scan-printable-strings (bytes at end min)
  "Every run of printable ASCII (0x20..0x7E) in BYTES[AT,END) at least MIN
characters long, deduplicated WITHIN this call, in first-appearance order.

The trailing run is flushed after the loop, not only on a non-printable byte: a
segment that ends with a string and no NUL after it is the common case for a
hand-built module, and dropping it would lose the last string in every such
module."
  (let ((out '()) (seen (make-hash-table :test #'equal)) (run '()))
    (labels ((flush ()
               (when (>= (length run) min)
                 (let ((text (coerce (nreverse run) 'string)))
                   (setf run '())
                   (unless (gethash text seen)
                     (setf (gethash text seen) t)
                     (push text out))))
               (setf run '())))
      (loop for i from at below end
            for b = (aref bytes i)
            do (if (and (>= b #x20) (<= b #x7E))
                   (push (code-char b) run)
                   (flush)))
      (flush)
      (nreverse out))))

;;; ---------------------------------------------------------------------------
;;; The name section (custom section 0, named "name")
;;;
;;; Subsection ids: 0 module name, 1 function names, 2 local names, 4 type
;;; names. Only 0, 1 and 4 carry anything this layer reports; 2 (locals) is
;;; recognised and abandoned, because its entries are (funcidx, count, pairs) —
;;; a shape this walker cannot read with the name-pair loop — and the original
;;; stops at the first one rather than mis-parse the rest as global names.
;;; ---------------------------------------------------------------------------

(defun parse-name-subsection (bytes start end info)
  "Walk the name section's subsections in BYTES[START,END), filling INFO's
module name and function/type name tables.

Every read here is bounded by END — the section end — unlike the section
walkers, whose reads are bounded by the module length. That asymmetry is the
Rust's: this function receives a SLICE of the payload, so its `bytes.len()` is
the section end. Getting it the other way round would let a name subsection
read into the section that follows it."
  (let ((at start))
    (loop while (< at end)
          do (let* ((id (aref bytes at))
                    (after-id (1+ at)))
               (multiple-value-bind (size next) (read-uleb128 bytes after-id end)
                 ;; A header that cannot be read ends the walk: the Rust
                 ;; `return`s from the whole function here, not just this
                 ;; subsection, so the subsections after it are not read either.
                 (unless next
                   (return))
                 (when (> size (- end next))
                   (return))
                 (let ((body-end (+ next size)))
                   (case id
                     (0 (multiple-value-bind (name name-end)
                            (wasm-name bytes next body-end)
                          (declare (ignore name-end))
                          (when name
                            (setf (wasm-module-info-module-name info) name))))
                     ((1 2 4) (parse-name-pairs bytes next body-end id info)))
                   (setf at body-end)))))
    at))

(defun parse-name-pairs (bytes start end id info)
  "The (count, then (index, name) pairs) body shared by subsection ids 1
(function names), 2 (locals) and 4 (type names).

A failed index or name ENDS THE SECTION rather than the whole walk: the Rust
`break`s out of the pair loop and then advances past the subsection, so the
subsections after a damaged one are still read. Id 2 stores no names at all —
local names are a different shape — so it breaks after the first pair, which is
exactly what the original does with its comment `not recovered`."
  (multiple-value-bind (count next) (read-uleb128 bytes start end)
    (when (null next)
      ;; No usable count: the subsection is skipped, the walk continues.
      (return-from parse-name-pairs nil))
    (let ((cursor next) (i 0))
      (block pairs
        (loop while (and (< i count) (< cursor end))
              do (multiple-value-bind (index after-index)
                     (read-uleb128 bytes cursor end)
                   (unless after-index (return-from pairs nil))
                   (setf cursor after-index)
                   (multiple-value-bind (name after-name)
                       (wasm-name bytes cursor end)
                     (unless after-name (return-from pairs nil))
                     (setf cursor after-name)
                     (case id
                       (1 (setf (gethash index (wasm-module-info-fn-names info))
                                name))
                       (4 (setf (gethash index (wasm-module-info-ty-names info))
                                name)))
                     (when (= id 2)
                       (return-from pairs nil))
                     (incf i))))))
    nil))

;;; ---------------------------------------------------------------------------
;;; Section walkers
;;;
;;; Each returns T when the section was consumed to its declared end (or ran out
;;; of entries cleanly), NIL when an entry could not be read. NIL becomes the
;;; "partially decoded" note; whatever entries were read stay in the info,
;;; because a half-decoded export table is more useful to an investigator than
;;; nothing at all.
;;;
;;; The LIMIT passed to every LEB/name read below is the MODULE length, matching
;;; the Rust, which reads from the whole `bytes` slice even while walking inside
;;; a section.
;;; ---------------------------------------------------------------------------

(defun decode-custom-section (bytes start end info section)
  "Id 0: a custom section is a name plus opaque bytes. The name is recorded, and
a section literally named `name` is handed to the name-subsection walker.

ONE DELIBERATE DIVERGENCE, recorded rather than copied. The Rust reads this name
against the whole module (`wasm_name(bytes, cursor)`), then slices
`&bytes[name_end..end]` — so a custom name whose declared length overruns its own
section but not the module makes that slice PANIC, which is neither the soft
failure the module documents nor something a caller can catch. Bounding the name
read by END here makes the same input a clean `NIL` name and an empty name
walker. Every valid module reads identically; only the panic case differs, and it
differs by not crashing."
  (multiple-value-bind (name name-end) (wasm-name bytes start end)
    (when name
      (setf (wasm-section-custom-name section) name)
      (when (string= name "name")
        (parse-name-subsection bytes name-end end info))))
  t)

(defun decode-import-section (bytes start end info)
  "Id 2: `count` then (module, field, kind, kind-specific descriptor).

The descriptor skip is where a careless port desynchronises: kind 0 is an index
(typeidx), kind 1 a table (elemtype byte, then limits), kind 2 a memory
(limits), kind 3 a global (valtype byte + mutability byte). Only kinds 1, 2 and
3 are length-checked here; the Rust lets kind 3 overshoot `end` by two bytes and
relies on the next bounds check to fail, which this reproduces."
  (let ((limit (length bytes)))
    (multiple-value-bind (count next) (read-uleb128 bytes start limit)
      (when (null next)
        (return-from decode-import-section t))
      (let ((cursor next) (i 0))
        (loop while (and (< i count) (< cursor end))
              do (multiple-value-bind (module module-end) (wasm-name bytes cursor limit)
                   (unless module-end (return-from decode-import-section nil))
                   (setf cursor module-end)
                   (multiple-value-bind (field field-end) (wasm-name bytes cursor limit)
                     (unless field-end (return-from decode-import-section nil))
                     (setf cursor field-end)
                     (when (>= cursor limit)
                       (return-from decode-import-section nil))
                     (let ((kind (aref bytes cursor)))
                       (incf cursor)
                       (case kind
                         (0 (multiple-value-bind (index index-end)
                                (read-uleb128 bytes cursor limit)
                              (declare (ignore index))
                              (unless index-end
                                (return-from decode-import-section nil))
                              (setf cursor index-end)))
                         (1 (incf cursor)                  ; elemtype byte
                            (let ((after (wasm-limits bytes cursor limit)))
                              (unless after (return-from decode-import-section nil))
                              (setf cursor after)))
                         (2 (let ((after (wasm-limits bytes cursor limit)))
                              (unless after (return-from decode-import-section nil))
                              (setf cursor after)))
                         (3 (incf cursor 2))               ; valtype + mutability
                         (t nil))
                       (push (make-wasm-import module field (kind-name kind))
                             (wasm-module-info-imports info))
                       (incf i)))))))
    t))

(defun decode-function-section (bytes start end info)
  "Id 3: `count` type indices. Only the count is reported.
`count as u32` saturates in Rust at 4294967295; `min` reproduces that so the
field never carries a bignum the JSON writer would print as a longer number than
the original."
  (declare (ignore end))
  (multiple-value-bind (count next) (read-uleb128 bytes start (length bytes))
    (declare (ignore next))
    (when count
      (setf (wasm-module-info-function-count info)
            (min count #xFFFFFFFF))))
  t)

(defun decode-export-section (bytes start end info)
  "Id 7: `count` then (name, kind byte, index). The export index is a u32 in the
format and is kept as an integer; names are the ASCII-restricted wasm name."
  (let ((limit (length bytes)))
    (multiple-value-bind (count next) (read-uleb128 bytes start limit)
      (when (null next)
        (return-from decode-export-section t))
      (let ((cursor next) (e 0))
        (loop while (and (< e count) (< cursor end))
              do (multiple-value-bind (name name-end) (wasm-name bytes cursor limit)
                   (unless name-end (return-from decode-export-section nil))
                   (setf cursor name-end)
                   (when (>= cursor limit)
                     (return-from decode-export-section nil))
                   (let ((kind-byte (aref bytes cursor)))
                     (incf cursor)
                     (multiple-value-bind (index index-end)
                         (read-uleb128 bytes cursor limit)
                       (unless index-end
                         (return-from decode-export-section nil))
                       (setf cursor index-end)
                       (push (make-wasm-export name (kind-name kind-byte) index)
                             (wasm-module-info-exports info))
                       (incf e)))))))
    t))

(defun skip-init-expression (bytes cursor end limit)
  "Skip one constant expression and return the index of the byte after its 0x0B
`end` opcode, or END when the expression cannot be walked.

Only 0x23 / 0x24 (global.get / global.set), 0x41 (i32.const) and 0x42
(i64.const) carry an immediate; each immediate is a LEB and is skipped blindly,
unsigned, because its VALUE is irrelevant here. A LEB that fails to read sets
the cursor to END and stops, which turns the caller's next `read-uleb128` into a
failure — the same path a byte-wise truncation takes."
  (block skip
    (loop while (< cursor end)
          do (let ((op (aref bytes cursor)))
               (incf cursor)
               (when (= op #x0B)
                 (return-from skip cursor))
               (when (member op '(#x23 #x24 #x41 #x42))
                 (multiple-value-bind (value next) (read-uleb128 bytes cursor limit)
                   (declare (ignore value))
                   (if next
                       (setf cursor next)
                       (return-from skip end))))))
    end))

(defun decode-data-section (bytes start end info)
  "Id 11: `count` then data segments. A segment is a flag ULEB, an optional
memory index (flag 2), an init expression, and a byte vector whose printable
runs are harvested.

Two bounds, and the difference is the point: the segment loop and the init
expression stop at END (the section), while every LEB read — including the
segment size after the expression — is bounded by the MODULE length. The
segment's own bytes are bounded against END (`seg_size > end - cursor`), so a
declared segment cannot scan into the next section."
  (let ((limit (length bytes)))
    (multiple-value-bind (count next) (read-uleb128 bytes start limit)
      (when (null next)
        (return-from decode-data-section t))
      (let ((cursor next) (s 0))
        (loop while (and (< s count) (< cursor end))
              do (multiple-value-bind (flag flag-end) (read-uleb128 bytes cursor limit)
                   (unless flag-end (return-from decode-data-section nil))
                   (setf cursor flag-end)
                   ;; Flags 0 (active, memory 0) and 2 (active, explicit memory)
                   ;; carry an init expression; 1 (passive) and 3+ do not.
                   (when (or (zerop flag) (= flag 2))
                     (when (= flag 2)
                       (multiple-value-bind (memidx memidx-end)
                           (read-uleb128 bytes cursor limit)
                         (declare (ignore memidx))
                         (unless memidx-end
                           (return-from decode-data-section nil))
                         (setf cursor memidx-end)))
                     (setf cursor (skip-init-expression bytes cursor end limit)))
                   (multiple-value-bind (seg-size seg-end)
                       (read-uleb128 bytes cursor limit)
                     (unless seg-end (return-from decode-data-section nil))
                     (setf cursor seg-end)
                     (when (> seg-size (- end cursor))
                       (return-from decode-data-section nil))
                     (dolist (found (scan-printable-strings
                                     bytes cursor (+ cursor seg-size)
                                     *wasm-min-string*))
                       ;; Deduplicated across ALL segments, not just within one:
                       ;; the same string in two segments is one finding.
                       (unless (member found (wasm-module-info-data-strings info)
                                       :test #'string=)
                         (push found (wasm-module-info-data-strings info))))
                     (incf cursor seg-size)
                     (incf s))))))
    t))

(defun decode-section (bytes id start end info section)
  "Dispatch one section to its walker. Every section this layer does not read
(type, table, memory, global, start, element, code, dataCount) is CONSUMED, not
walked: returning T is what tells the caller the section was accounted for, so
the walk continues at `end` rather than guessing an offset."
  (case id
    (0 (decode-custom-section bytes start end info section))
    (2 (decode-import-section bytes start end info))
    (3 (decode-function-section bytes start end info))
    (7 (decode-export-section bytes start end info))
    (11 (decode-data-section bytes start end info))
    (t t)))

;;; ---------------------------------------------------------------------------
;;; Detection
;;; ---------------------------------------------------------------------------

(defun octet-view (bytes)
  "BYTES as a `(vector (unsigned-byte 8))`, or NIL when it cannot be one.

The Rust takes `&[u8]`, so the type is never in question there; here an octet
vector, a general vector of small integers, a list and a string all arrive at
the same door. Coercing once at the entry points means every reader below can
use `aref` without a per-call type test, and it means a caller holding a list of
bytes is not silently answered \"not a wasm module\" for a type mismatch that
looks like a content verdict."
  (cond
    ((null bytes) nil)
    ((and (vectorp bytes)
          (subtypep (array-element-type bytes) '(unsigned-byte 8)))
     bytes)
    ;; A STRING is how Lisp usually carries byte data that happens to be ASCII
    ;; (a fixture read with the default character element type, a literal
    ;; `"\0asm..."`). `coerce` cannot do this — it signals, not converts — so an
    ;; octet string that was almost right would read as "not a wasm module"
    ;; instead of as content. Every character is range-checked: a character
    ;; above 255 is not a byte and the whole string is refused rather than
    ;; truncated.
    ((stringp bytes)
     (let ((out (make-array (length bytes) :element-type '(unsigned-byte 8))))
       (loop for c across bytes
             for i from 0
             for code = (char-code c)
             do (if (<= code 255)
                    (setf (aref out i) code)
                    (return-from octet-view nil)))
       out))
    ((typep bytes 'sequence)
     (handler-case (coerce bytes '(vector (unsigned-byte 8)))
       (error () nil)))
    (t nil)))

(defun detect-wasm-module (bytes)
  "Does BYTES look like a binary wasm module? The magic in the first four bytes
AND at least eight bytes of total length.

The length floor is eight, not four: a module is magic plus a four-byte version,
so four magic bytes alone are a header fragment and parsing one would read a
version out of whatever follows. The Rust test pins exactly this — `[0u8; 4]`
and `[]` are both rejected — and the gate pins the 8-byte boundary itself."
  (let ((bytes (octet-view bytes)))
    (and bytes
         (>= (length bytes) 8)
         (loop for i from 0 below 4
               always (eql (aref bytes i) (aref *wasm-magic* i))))))

;;; ---------------------------------------------------------------------------
;;; The module
;;; ---------------------------------------------------------------------------

(defun add-note (info text)
  "Record a soft failure. Notes are the only channel by which a damaged module
reports itself, so every site that abandons work calls this."
  (push text (wasm-module-info-notes info)))

(defun module-info-put-name (table index name)
  "Store NAME under INDEX, replacing any previous name for that index — the
BTreeMap `insert` semantics. Replacing rather than ignoring matters when a name
section lists the same index twice."
  (setf (gethash index table) name))

(defun function-name-pairs (info)
  "The function names as an alist `((index . name) ...)` in ASCENDING INDEX
order, which is what iterating a `BTreeMap<u32, String>` yields."
  (sort (loop for index being the hash-keys of (wasm-module-info-fn-names info)
                using (hash-value name)
              collect (cons index name))
        #'< :key #'car))

(defun type-name-pairs (info)
  "Type names, same ordering contract as `function-name-pairs`."
  (sort (loop for index being the hash-keys of (wasm-module-info-ty-names info)
                using (hash-value name)
              collect (cons index name))
        #'< :key #'car))

(defun function-names (info)
  "The function names alone, in ascending index order — the Rust test's
`info.function_names.values()`."
  (mapcar #'cdr (function-name-pairs info)))

(defun type-names (info)
  "The type names alone, in ascending index order."
  (mapcar #'cdr (type-name-pairs info)))

(defun parse-wasm-module (bytes)
  "Parse a binary wasm module into a `wasm-module-info`, or NIL when BYTES is not
a wasm module at all.

The walk is a straight left-to-right advance: id, size LEB, payload, repeat.
Two failure modes are notes, not answers: a header LEB that cannot be read ends
the walk with `truncated section header at <offset>`, and a section whose
declared size overruns the module ends it with `section <name> overruns the
module`. In both cases the sections already read are returned — a caller that
got six good sections out of a truncated file is better served than one that got
nothing.

After the walk, exports named by NAME backfill the function-name table: a
`func` export is a function name the module itself publishes, and reading it is
strictly better than the name section alone. An index the name section already
named keeps that name, so the name section wins over the export, which is the
Rust's `if !function_names.contains_key`."
  (let ((bytes (octet-view bytes)))
    (unless (detect-wasm-module bytes)
      (return-from parse-wasm-module nil))
    (let ((info (make-wasm-module-info))
          (limit (length bytes)))
      (setf (wasm-module-info-version info)
            (logior (aref bytes 4)
                    (ash (aref bytes 5) 8)
                    (ash (aref bytes 6) 16)
                    (ash (aref bytes 7) 24)))
      (let ((at 8))
        (loop while (< at limit)
              do (let ((id (aref bytes at)))
                   (incf at)
                   (multiple-value-bind (size next) (read-uleb128 bytes at limit)
                     (if (null next)
                         (progn
                           ;; `at` has already advanced past the id byte, and
                           ;; the note reports that offset, not the id's.
                           (add-note info
                                     (format nil "truncated section header at ~d" at))
                           (return))
                         (progn
                           (setf at next)
                           (if (> size (- limit at))
                               (progn
                                 (add-note info
                                           (format nil "section ~a overruns the module"
                                                   (section-name id)))
                                 (return))
                               (let* ((end (+ at size))
                                      (section (make-wasm-section
                                                :id id
                                                :name (section-name id)
                                                :offset at
                                                :size size))
                                      (whole (decode-section bytes id at end info
                                                             section)))
                                 (unless whole
                                   (add-note info
                                             (format nil "section ~a partially decoded"
                                                     (wasm-section-name section))))
                                 (push section (wasm-module-info-sections info))
                                 (setf at end)))))))))
      ;; Export backfill, in DECLARATION order so that when two exports name
      ;; the same index the first one wins, as it does with the Rust's ordered
      ;; loop.
      (dolist (export (reverse (wasm-module-info-exports info)))
        (when (and (string= (wasm-export-kind export) "func")
                   (null (gethash (wasm-export-index export)
                                  (wasm-module-info-fn-names info))))
          (module-info-put-name (wasm-module-info-fn-names info)
                                (wasm-export-index export)
                                (wasm-export-name export))))
      (setf (wasm-module-info-sections info)
            (nreverse (wasm-module-info-sections info))
            (wasm-module-info-imports info)
            (nreverse (wasm-module-info-imports info))
            (wasm-module-info-exports info)
            (nreverse (wasm-module-info-exports info))
            (wasm-module-info-data-strings info)
            (nreverse (wasm-module-info-data-strings info))
            (wasm-module-info-notes info)
            (nreverse (wasm-module-info-notes info)))
      info)))

;;; ---------------------------------------------------------------------------
;;; The wire shape
;;; ---------------------------------------------------------------------------

(defun module-info-wire (info)
  "INFO in the shape `pipeline.rs` writes to `wasm-info.json`: an alist of
camelCase keys. Not a JSON encoder — the toolchain has one — but the KEY NAMES
and the absent-versus-empty decisions are the artifact contract (the Rust test
reads `moduleName` and `dataStrings` by name), so they are spelled once here.

`customName` is omitted for a non-custom section, matching
`skip_serializing_if = \"Option::is_none\"`; `moduleName` is present with a null
value when the module has no name, matching `Option<String>` without that
attribute. `functionNames`/`typeNames` become objects keyed by the DECIMAL index,
which is how a `BTreeMap<u32, String>` serialises."
  (flet ((name-object (pairs)
           (mapcar (lambda (pair)
                     (cons (princ-to-string (car pair)) (cdr pair)))
                   pairs)))
    (list (cons "version" (wasm-module-info-version info))
          (cons "moduleName" (wasm-module-info-module-name info))
          (cons "sections"
                (mapcar (lambda (section)
                          (append
                           (list (cons "id" (wasm-section-id section))
                                 (cons "name" (wasm-section-name section))
                                 (cons "offset" (wasm-section-offset section))
                                 (cons "size" (wasm-section-size section)))
                           (when (wasm-section-custom-name section)
                             (list (cons "customName"
                                         (wasm-section-custom-name section))))))
                        (wasm-module-info-sections info)))
          (cons "imports"
                (mapcar (lambda (import)
                          (list (cons "module" (wasm-import-module import))
                                (cons "field" (wasm-import-field import))
                                (cons "kind" (wasm-import-kind import))))
                        (wasm-module-info-imports info)))
          (cons "exports"
                (mapcar (lambda (export)
                          (list (cons "name" (wasm-export-name export))
                                (cons "kind" (wasm-export-kind export))
                                (cons "index" (wasm-export-index export))))
                        (wasm-module-info-exports info)))
          (cons "functionNames" (name-object (function-name-pairs info)))
          (cons "typeNames" (name-object (type-name-pairs info)))
          (cons "dataStrings" (copy-list (wasm-module-info-data-strings info)))
          (cons "notes" (copy-list (wasm-module-info-notes info))))))
