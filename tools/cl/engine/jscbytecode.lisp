;;;; jscbytecode.lisp — JavaScriptCore cached-bytecode string recovery and the
;;;; cached-function tree walk, ported from `unpack-rs/src/jscbytecode.rs`.
;;;;
;;;; Three things this module answers, and each has a different kind of proof:
;;;;
;;;;   STRINGS.  Every compiler string in a Bun `--bytecode` chunk is stored as
;;;;   a 12-byte record — a flag word, the low 24 bits of
;;;;   `WTF::StringImpl::hash()` over the characters, then the characters. The
;;;;   hash is a SECOND, INDEPENDENT witness: a byte run is only a string when
;;;;   hashing the characters it claims to hold reproduces the stored hash, so
;;;;   a false positive needs a 24-bit collision rather than a plausible-looking
;;;;   length field. That is why `wtf-string-hash` is part of the wire contract
;;;;   and is gate-pinned against four ledger truths.
;;;;
;;;;   STRUCTURE.  A cached function record points (field-relative, signed
;;;;   32-bit) at its code block; the block opens with a variable-length tail
;;;;   describing seven arrays, one of which is the instruction stream. A block
;;;;   is only BELIEVED when the stream opens on `enter`, walks to exactly the
;;;;   declared length under the opcode table, and ends on a transfer of
;;;;   control. Three independent conditions, so a misread offset does not
;;;;   quietly produce a shorter op list.
;;;;
;;;;   NAMES.  A name slot is a tagged word: immediately-inlined characters, an
;;;;   ordinal into a shared string table, a field-relative pointer to another
;;;;   slot, or a literal. Ordinals only resolve when a shared table was found,
;;;;   so a lone chunk degrades to `<ordinal N>` placeholders instead of
;;;;   inventing names — the degradation is deliberate and asserted.
;;;;
;;;; ===========================================================================
;;;; FIVE THINGS THE RUST SOURCE DOES NOT SAY OUT LOUD
;;;; ===========================================================================
;;;;
;;;; 1. THE OPCODE TABLE IS READ, NEVER RESTATED. `jsc_enter_opcode()` searches
;;;;    `jsc_opcodes.txt` for the row called `enter` rather than hardcoding
;;;;    134, because 134 is a property of that file — a constant here would be a
;;;;    second copy free to disagree the moment the table is regenerated. This
;;;;    port does the same: `jsc-enter-opcode` reads the table and the gate
;;;;    asserts the row it finds really is named `enter`. The table is parsed
;;;;    from `unpack-rs/src/jsc_opcodes.txt` at first use (not embedded), which
;;;;    means this port cannot drift from the Rust's `include_str!` copy: both
;;;;    read the same bytes.
;;;;
;;;; 2. THE HEADER GUARD IS AN `OR`, NOT AN `AND`. `parse_jsc_header` rejects a
;;;;    buffer only when the format word is not 1 AND the declared length is not
;;;;    the buffer length. A "both must agree" port — the obvious reading — is
;;;;    WRONG: it throws away `formatWord == 1` chunks carrying a stale length,
;;;;    and it throws away the Program payloads (`formatWord` 0) that
;;;;    `bun --bytecode` emits by default for cjs. Both directions are
;;;;    mutation-probed in the gate, because this is exactly the kind of thing
;;;;    that passes on the first fixture and fails on the second.
;;;;
;;;; 3. `read32_big` IS A LIE IN THE ORIGINAL. It reads a LITTLE-endian u32
;;;;    (the comment in the Rust admits it: "Same misleading name as the JS").
;;;;    A port that "fixed" the name into a big-endian read would produce a
;;;;    different hash for every string and fail all four ledger truths, so the
;;;;    helper here is `ub32` and the misleading alias does not exist.
;;;;
;;;; 4. THE TWO WIDTH FLAGS ARE NOT THE SAME BIT AND NOT THE SAME MASK.
;;;;    `recover_jsc_strings` reads the is-8-bit flag at bit 27 of a 28-bit
;;;;    length field (`0x08000000`, `0x07FFFFFF`); the shared-table reader reads
;;;;    it at bit 31 of a 31-bit length (`#x80000000`, `#x7FFFFFFF`); the inline
;;;;    string reader masks with 24 bits (`#xFFFFFF`) and has no width flag at
;;;;    all — it is byte-per-character. Three different layouts for the same
;;;;    conceptual record, which is why they are three separate readers here
;;;;    rather than one parameterised one.
;;;;
;;;; 5. `read_jsc_shared_table` PUSHES BYTE VALUES, NOT PRINTABLE ONES. Unlike
;;;;    `recover_jsc_strings`, which rejects anything outside `0x20..0x7f`, the
;;;;    shared-table reader accepts every byte and pushes it as a character, so
;;;;    a "string" there can hold control bytes. That is the original's
;;;;    behaviour and is preserved: the hash already vouched for the bytes, and
;;;;    filtering after the fact would silently drop real table entries.
;;;;
;;;; ARITHMETIC UNITS. The Rust computes the tail geometry in `f64`
;;;; (`record_offset`, `instr.0`, `instr.1`) and then casts to integers. Every
;;;; one of those values is bounded by `0x20000000` (2^29) by an explicit guard
;;;; in `parse_jsc_tail`, and 2^29 is exactly representable in a double, as is
;;;; every integer below 2^53. So the f64 round-trip is the identity on every
;;;; value that survives the guards, and this port uses exact integers
;;;; throughout — no float ever enters the geometry. `>=`/`=` comparisons on
;;;; those doubles therefore become the same integer comparisons, including the
;;;; `packed_end == record_offset` "tight" test.
;;;;
;;;; WHAT IS NOT HERE. `JscStats.shared_table` is filled by the PIPELINE
;;;; (`pipeline.rs:313`), not by `analyze_jsc_module`, which leaves it `None`
;;;; and serde skips it — which is why the sidecar JSON carries eight keys and
;;;; no `sharedTable`. This port's stats plist carries those same eight keys, so
;;;; the whole tree compares equal to the sidecar rather than "equal once you
;;;; ignore a field".

(defpackage :vovas.engine.jscbytecode
  (:use :cl)
  (:export
   ;; header + detection
   #:parse-jsc-header
   #:detect-jsc-bytecode
   ;; string recovery
   #:wtf-string-hash
   #:recover-jsc-strings
   ;; opcode table (read from jsc_opcodes.txt, never restated)
   #:jsc-opcode-table
   #:jsc-opcode-at
   #:jsc-enter-opcode
   #:jsc-array-span
   #:is-terminal-op
   ;; varints, tail geometry, the op walk
   #:varint
   #:svarint
   #:parse-jsc-tail
   #:walk-jsc-ops
   #:bind-jsc-block
   ;; shared string table
   #:read-jsc-shared-table
   #:find-jsc-shared-table
   ;; slots, records, the tree walk
   #:decode-jsc-slot
   #:read-jsc-inline-string
   #:parse-jsc-cache-entry
   #:instantiate-jsc-exec
   #:jsc-block-children
   #:analyze-jsc-module
   #:block-info
   ;; block accessors, so a caller never reaches into the plist by hand
   #:jsc-block-region
   #:jsc-block-instr-at
   #:jsc-block-instr-length
   #:jsc-block-op-count
   #:jsc-block-gap
   #:jsc-block-tight-p))

(in-package :vovas.engine.jscbytecode)

;;; ---------------------------------------------------------------------------
;;; Constants
;;;
;;; `defparameter` for anything a reload must be allowed to re-bind, and for the
;;; secret vector in particular: a literal vector inside a `defconstant` is a
;;; fresh object per compile, which is exactly the DEFCONSTANT-UNEQL trap the
;;; contract records.
;;; ---------------------------------------------------------------------------

(defparameter *jsc-header-size* 32)

;; The format word a Module payload carries. Program payloads carry 0 and are
;; accepted by the LENGTH half of the guard instead — see note 2 above.
(defparameter *jsc-format-word* 1)

(defparameter *jsc-length-mask* #x07FFFFFF)
(defparameter *jsc-is-8-bit* #x08000000)
(defparameter *jsc-record-header* 12)
(defparameter *jsc-string-limit* 4096)
(defparameter *jsc-hash-mask* #x00FFFFFF)
(defparameter *u64-mask* #xFFFFFFFFFFFFFFFF)

;; RapidHash's secret, from WTF's `rapidhash.h`. Constant, not build specific:
;; it is a hardcoded table in the C++ header, which is why the four ledger
;; hashes below are stable across JSC versions.
(defparameter *wtf-secret*
  (vector #x2d358dccaa6c78a5
          #x8bb84b93962eacc9
          #x4b33a62ed433d4a3))

;; The `enter` opcode's own byte value is NOT here: it is read out of
;; `jsc_opcodes.txt`. What IS here is the pair of "wide" prefixes, which are
;; not opcodes at all but a marker that the following byte is the opcode and
;; every operand is scaled by 2 or 4.
(defparameter *jsc-wide16* #x83)
(defparameter *jsc-wide32* #x85)

;; Order matters: the tail lists its seven arrays in this order and each one's
;; presence shifts every later varint.
(defparameter *jsc-array-order*
  '(:steps :instr :consts :cscr :idents :fdecls :fexprs))

;; The four record sizes a code block's tail may sit at, relative to the
;; function record. Only these: the record layouts are fixed by CachedTypes, and
;; a scan over arbitrary offsets would bind garbage.
(defparameter *jsc-block-gaps* '(4 #x38 #x28 16))

;; Ops after which control no longer falls through. A block that does not end on
;; one of these is not a block — it is a walk that ran out of declared length
;; mid-expression, which is what a misread tail looks like.
(defparameter *jsc-terminal-ops*
  '("ret" "jmp" "ret_undefined" "checkpoint_osr_exit_from_in_call" "throw"
    "rethrow" "unreachable" "tail_call_varargs" "call_varargs" "call" "tail_call"
    "call_direct" "tail_call_direct" "call_eval" "call_ignore_result" "construct"
    "construct_varargs" "jneq_ptr" "direct_tail_call"))

(defparameter *jsc-child-kinds* '((:fdecls . "fdecls") (:fexprs . "fexprs")))

;;; ---------------------------------------------------------------------------
;;; Little-endian loads
;;;
;;; `aref` on an out-of-range index signals, which is the behaviour we want:
;;; every caller below proves the bounds before it loads, exactly as the Rust
;;; does, and a bounds violation is a port bug rather than a fixture property.
;;; ---------------------------------------------------------------------------

(declaim (inline ub8))
(defun ub8 (bytes at)
  "One byte. Named for its width so the three readers' layouts stay readable."
  (aref bytes at))

(defun ub32 (bytes at)
  "Little-endian u32 at AT. This is what the Rust calls both `u32` and the
misleading `read32_big`; the little-endian reading is the only one."
  (logior (aref bytes at)
          (ash (aref bytes (+ at 1)) 8)
          (ash (aref bytes (+ at 2)) 16)
          (ash (aref bytes (+ at 3)) 24)))

(defun sb32 (bytes at)
  "Little-endian SIGNED 32-bit at AT. The block and child pointers are
field-relative and routinely negative, so this is not interchangeable with
`ub32`."
  (let ((value (ub32 bytes at)))
    (if (logbitp 31 value) (- value #x100000000) value)))

(defun ub64 (bytes at)
  "Little-endian u64 at AT. The RapidHash reads are all 8-byte and unaligned."
  (logior (ub32 bytes at) (ash (ub32 bytes (+ at 4)) 32)))

;;; ---------------------------------------------------------------------------
;;; WTF::StringImpl::hash()
;;; ---------------------------------------------------------------------------

(defun rapid-mix (first second)
  "RapidHash's 128-bit multiply-fold.

The FULL product must survive: masking either operand to 64 bits before the
multiply, or masking the product before the shift, folds zero into the high half
and mirrors every hash. This is the one place in the module where a bignum is
required rather than merely convenient — `(* first second)` on two 64-bit values
is a 128-bit intermediate, and SBCL keeps it exact."
  (let ((product (* first second)))
    (logxor (logand product *u64-mask*) (ash product -64))))

(defun wtf-string-hash (bytes)
  "`WTF::StringImpl::hash()`: RapidHash over the raw character bytes, low 24
bits, with zero replaced by `#x800000`.

BYTES are the CHARACTER bytes, not the record: the caller has already skipped
the record header. The zero-to-`#x800000` substitution exists because the stored
hash is used as a truthy sentinel upstream; a stored hash of 0 therefore encodes
a real hash of `#x800000`, and a port that returned the raw 0 would reject every
string whose hash happened to fold there.

The three-way split is RapidHash's tail handling and it is not cosmetic:
`<= 16` bytes use an overlapping-word construction, `> 16` bytes use the 48-byte
stripe loop, and the two disagree on every input if swapped."
  (let* ((length (length bytes))
         (secret *wtf-secret*)
         (seed (logxor (rapid-mix (aref secret 0) (aref secret 1)) length))
         (first 0)
         (second 0))
    (if (<= length 16)
        (cond
          ((>= length 4)
           ;; 4..16 bytes: two overlapping pairs of 4-byte reads, the second
           ;; pair offset by 4 only when there are at least 8 bytes to reach.
           (let ((delta (if (>= length 8) 4 0)))
             (setf first (logior (ash (ub32 bytes 0) 32)
                                 (ub32 bytes (- length 4))))
             (setf second (logior (ash (ub32 bytes delta) 32)
                                  (ub32 bytes (- length 4 delta))))))
          ((plusp length)
           ;; 1..3 bytes: single bytes only, no 4-byte read is in bounds.
           (setf first (logior (ash (ub8 bytes 0) 56)
                               (ash (ub8 bytes (ash length -1)) 32)
                               (ub8 bytes (- length 1))))
           (setf second 0))
          (t (setf first 0 second 0)))
        ;; 17+ bytes.
        (let ((remaining length)
              (at 0))
          (when (> remaining 48)
            ;; Three independent lanes over 48-byte stripes. They are mixed
            ;; into separate accumulators on purpose: a single accumulator
            ;; serialises the multiplies and produces a different hash.
            (let ((see1 seed)
                  (see2 seed))
              (loop
                (setf seed (rapid-mix (logxor (ub64 bytes at) (aref secret 0))
                                      (logxor (ub64 bytes (+ at 8)) seed)))
                (setf see1 (rapid-mix (logxor (ub64 bytes (+ at 16)) (aref secret 1))
                                      (logxor (ub64 bytes (+ at 24)) see1)))
                (setf see2 (rapid-mix (logxor (ub64 bytes (+ at 32)) (aref secret 2))
                                      (logxor (ub64 bytes (+ at 40)) see2)))
                (incf at 48)
                (decf remaining 48)
                (when (< remaining 48) (return)))
              (setf seed (logxor seed see1 see2))))
          (when (> remaining 16)
            (setf seed (rapid-mix (logxor (ub64 bytes at) (aref secret 2))
                                  (logxor (ub64 bytes (+ at 8)) seed (aref secret 1))))
            (when (> remaining 32)
              (setf seed (rapid-mix (logxor (ub64 bytes (+ at 16)) (aref secret 2))
                                    (logxor (ub64 bytes (+ at 24)) seed)))))
          ;; The tail is the LAST two words of the buffer, whatever the stripe
          ;; loop consumed — hence the `+ at -16`, which is the only expression
          ;; here that is not obviously in bounds.
          (setf first (ub64 bytes (- (+ at remaining) 16)))
          (setf second (ub64 bytes (- (+ at remaining) 8)))))
    (setf first (logxor first (aref secret 1)))
    (setf second (logxor second seed))
    (let* ((product (* first second))
           (value (logand (rapid-mix
                           (logxor (logand product *u64-mask*)
                                   (aref secret 0)
                                   length)
                           (logxor (ash product -64) (aref secret 1)))
                          *jsc-hash-mask*)))
      (if (zerop value) #x800000 value))))

;;; ---------------------------------------------------------------------------
;;; Header
;;; ---------------------------------------------------------------------------

(defun parse-jsc-header (bytes)
  "A five-word chunk header as a plist, or NIL. A chunk is a Module when its
format word is 1, or — the half everyone forgets — anything at all whose word at
offset 12 states the buffer's own length.

That disjunction is the whole detector. `bun --bytecode` emits Program payloads
with format word 0 and an exact length, and the real Module chunk in the fixture
carries format word 1 with an exact length; a single guard covering both is what
lets one entry point accept both. Requiring the two to AGREE instead drops every
Program payload, and requiring only the format word drops them too."
  (when (< (length bytes) *jsc-header-size*)
    (return-from parse-jsc-header nil))
  (let ((format-word (ub32 bytes 4))
        (declared-length (ub32 bytes 12)))
    (when (and (/= format-word *jsc-format-word*)
               (/= declared-length (length bytes)))
      (return-from parse-jsc-header nil))
    (list :stamp (ub32 bytes 0)
          :format format-word
          :version (ub32 bytes 8)
          :declared-length declared-length
          :body-offset (ub32 bytes 16))))

(defun detect-jsc-bytecode (bytes)
  "True when BYTES opens on a cached-bytecode chunk header. Deliberately one
line over `parse-jsc-header`: two detectors over the same guard would be two
places to fix when the guard changes."
  (and (parse-jsc-header bytes) t))

;;; ---------------------------------------------------------------------------
;;; String recovery
;;; ---------------------------------------------------------------------------

(defun decode-printable-raw (bytes at byte-length width)
  "The characters at AT as a string, or NIL when any character is outside
`0x20..0x7e`.

The printability test is not a heuristic bolted on afterwards: it is part of
what makes a record a STRING here. A 4-byte length field in a binary tail will
occasionally hash-match a run of binary noise, and refusing non-printable
characters is what keeps such a run out of the answer. The same filter is
NOT applied by the shared-table reader, which trusts the table's own framing —
see note 5 in the file header.

The 2-byte case shifts the second byte up by 8 rather than decoding UTF-16: the
record stores one ASCII character per 16-bit unit, and anything outside ASCII
fails the range test before it could be misread as a surrogate."
  (if (= width 1)
      (with-output-to-string (out)
        (dotimes (i byte-length)
          (let ((byte (ub8 bytes (+ at i))))
            (unless (<= #x20 byte #x7e) (return-from decode-printable-raw nil))
            (write-char (code-char byte) out))))
      (with-output-to-string (out)
        (dotimes (i (/ byte-length 2))
          (let ((unit (logior (ub8 bytes (+ at (* i 2)))
                              (ash (ub8 bytes (+ at (* i 2) 1)) 8))))
            (unless (<= #x20 unit #x7e) (return-from decode-printable-raw nil))
            (write-char (code-char unit) out))))))

(defun recover-jsc-strings (bytes)
  "Every distinct compiler string in BYTES, in order of first appearance.

The scan is a byte-by-byte slide, not a record walk: a chunk interleaves string
records with code and tables, so there is no framing to follow. Each candidate
is cheaply REJECTED first — bits 24..26 of the flag word must be clear and the
stored hash's top byte must be zero — and only survivors pay for a hash. That
prefilter is what makes a 1-in-256 hit rate affordable on a multi-megabyte blob;
dropping it does not change the ANSWER, only the time, which is why it is not
mutation-probed and the hash check is.

On a hit the cursor jumps past the whole record, so a string's characters are
never rescanned as candidate flags. On a miss it advances one byte — a record can
begin at any alignment."
  (when (zerop (length bytes))
    (return-from recover-jsc-strings nil))
  (let ((strings '())
        (seen (make-hash-table :test #'equal))
        (len (length bytes))
        (at 0))
    (loop while (<= (+ at *jsc-record-header*) len) do
      (if (or (plusp (logand (ub8 bytes (+ at 3)) #x07))
              (plusp (ub8 bytes (+ at 7))))
          (incf at)
          (let* ((flags (ub32 bytes at))
                 (stored (ub32 bytes (+ at 4)))
                 (length (logand flags *jsc-length-mask*))
                 (width (if (plusp (logand flags *jsc-is-8-bit*)) 1 2))
                 (byte-length (* length width))
                 (char-at (+ at *jsc-record-header*)))
            (if (or (zerop length)
                    (> length *jsc-string-limit*)
                    (> (+ char-at byte-length) len))
                (incf at)
                (if (/= (wtf-string-hash (subseq bytes char-at (+ char-at byte-length)))
                        stored)
                    (incf at)
                    (let ((text (decode-printable-raw bytes char-at byte-length width)))
                      (when (and text (not (gethash text seen)))
                        (setf (gethash text seen) t)
                        (push text strings))
                      (setf at (+ char-at byte-length))))))))
    (nreverse strings)))

;;; ---------------------------------------------------------------------------
;;; The opcode table
;;;
;;; Read from `unpack-rs/src/jsc_opcodes.txt` — the same file the Rust reaches
;;; with `include_str!` — so the two copies of the engine cannot disagree about
;;; what opcode 134 is. The file is located at first use rather than at load:
;;; a compiled-and-loaded system should not fail because a data file moved, and
;;; a lazy load lets the gate name the exact paths it tried.
;;; ---------------------------------------------------------------------------

(defparameter *jsc-opcode-relative-path* "unpack-rs/src/jsc_opcodes.txt")

(defparameter *jsc-opcode-path* nil
  "Resolved path to `jsc_opcodes.txt`, cached after the first successful search.")

(defparameter *jsc-opcode-table* nil
  "256-entry vector of (NAME . OPERAND-BYTES) or NIL, cached. Parsed once.")

(defun split-whitespace (line)
  "LINE split on runs of whitespace, empty pieces dropped.

Not `(read-from-string)`: the row's second column is an opcode NAME whose case
is part of the table's identity (`enter` must compare equal to `enter`, not to
`ENTER`), and `read` would intern it as an uppercase symbol."
  (let ((tokens '())
        (start nil))
    (loop for i from 0 below (length line)
          for c = (char line i)
          for space = (member c '(#\Space #\Tab #\Return #\Newline #\Page))
          do (cond
               ((and space start)
                (push (subseq line start i) tokens)
                (setf start nil))
               ((and (not space) (null start))
                (setf start i))))
    (when start (push (subseq line start) tokens))
    (nreverse tokens)))

(defun parse-integer-token (token)
  "TOKEN as an integer, or NIL when it is not one.

Mirrors the Rust's `let Ok(n) = .. else { continue }`: a malformed row is
skipped rather than aborting the table, because a table that loses one row is a
table that reports one opcode as unknown, and that is strictly better than an
engine that will not start. The `junk-allowed nil` is what makes this strict
enough to be worth having — `parse-integer` alone would happily accept `12abc`."
  (handler-case
      (multiple-value-bind (value end)
          (parse-integer token :junk-allowed nil)
        (if (and value (= end (length token))) value nil))
    (error () nil)))

(defun jsc-opcode-file-candidates ()
  "Every path the search will try, in order, so a failure can name them all.

The three starting points exist because `*load-truename*` is the FASL when
ASDF compiled this file and the source when it did not; neither is reliable on
its own, and a wrong starting point produces \"no such file\" for a file that is
right there."
  (let ((starts (remove nil
                        (list (ignore-errors *load-truename*)
                              (ignore-errors *compile-file-truename*)
                              (ignore-errors (uiop:getcwd))
                              *default-pathname-defaults*))))
    (labels ((walk-up (start)
               (let ((dir (uiop:pathname-directory-pathname (pathname start))))
                 (loop with seen = '()
                       for candidate = (merge-pathnames *jsc-opcode-relative-path* dir)
                       when (probe-file candidate)
                         return candidate
                       do (let ((parent (uiop:pathname-parent-directory-pathname dir)))
                            (when (or (null parent) (member parent seen :test #'equal))
                              (return nil))
                            (push parent seen)
                            (setf dir parent))))))
      (remove-duplicates (mapcar #'walk-up starts) :test #'equal))))

(defun load-jsc-opcode-table ()
  "Parse `jsc_opcodes.txt` into a 256-entry vector.

Each row is `ID NAME OPERAND PAD`, and the stored operand size is
`OPERAND + PAD` — the padding is part of the instruction's span in the stream,
so dropping it walks every op one or more bytes short. Rows with an id past 255
are ignored (the table is indexed by one byte)."
  (let ((path (or (and *jsc-opcode-path* (probe-file *jsc-opcode-path*))
                  (first (jsc-opcode-file-candidates)))))
    (unless path
      (error "jsc_opcodes.txt not found; looked for ~s under these roots: ~s"
             *jsc-opcode-relative-path*
             (mapcar (lambda (p) (uiop:pathname-directory-pathname (pathname p)))
                     (remove nil (list (ignore-errors *load-truename*)
                                       (ignore-errors *compile-file-truename*)
                                       (ignore-errors (uiop:getcwd)))))))
    (setf *jsc-opcode-path* (pathname path))
    (let ((table (make-array 256 :initial-element nil)))
      (with-open-file (in path :direction :input :external-format :utf-8)
        (loop for line = (read-line in nil :eof)
              until (eq line :eof)
              do (let ((tokens (split-whitespace line)))
                   (when (>= (length tokens) 4)
                     (let ((id (parse-integer-token (nth 0 tokens)))
                           (operand (parse-integer-token (nth 2 tokens)))
                           (pad (parse-integer-token (nth 3 tokens))))
                       (when (and id operand pad (< id 256))
                         (setf (aref table id)
                               (cons (nth 1 tokens) (+ operand pad)))))))))
      table)))

(defun jsc-opcode-table ()
  "The opcode table, parsed on first use and then cached.

Caching is not an optimisation: `bind-jsc-block` consults it for every candidate
at every gap, and re-reading a 323-line file per instruction made the tree walk
a disk benchmark. It is also a single point of truth — `jsc-enter-opcode` and
`walk-jsc-ops` must see the SAME table, which a second parse could not guarantee
if the file changed underneath."
  (or *jsc-opcode-table* (setf *jsc-opcode-table* (load-jsc-opcode-table))))

(defun jsc-opcode-at (table id)
  "`(NAME . OPERAND-BYTES)` for opcode ID, or NIL when the table has no such
row. NIL is meaningful: `walk-jsc-ops` treats it as a walk failure, so an
unknown opcode cannot silently be assumed to be one byte long."
  (and (<= 0 id 255) (aref table id)))

(defun jsc-enter-opcode (&optional (table (jsc-opcode-table)))
  "The byte value of `enter`, READ OUT OF THE TABLE.

This is the one constant the Rust source is careful not to restate, and the
reason is concrete: the walker's first test is `bytes[stream_at] == enter`, so a
hardcoded id that drifts from the table does not fail loudly — it binds nothing
and the scan reports an empty tree for a valid chunk. NIL means the table has no
`enter` row at all, in which case no op stream can be walked."
  (loop for id from 0 below 256
        for info = (aref table id)
        when (and info (string= (car info) "enter"))
          return id))

(defun jsc-array-span (name)
  "Element size in bytes for a tail array, or NIL for the two arrays whose
elements are not fixed-size (`consts`, `cscr` carry their own tagged encoding).

NIL is load-bearing twice over: the packing check falls back to a span of 1 for
those arrays, and they do NOT count towards `has_positive`, because their extent
is not something this code can verify and pretending otherwise would let a
misread tail look tight."
  (case name
    (:steps 4)
    (:instr 1)
    (:idents 4)
    (:fdecls 4)
    (:fexprs 4)
    (t nil)))

(defun is-terminal-op (name)
  "True when NAME ends a block. String-compared, because the names come from the
table file and are not keywords."
  (and (member name *jsc-terminal-ops* :test #'string=) t))

;;; ---------------------------------------------------------------------------
;;; Varints
;;; ---------------------------------------------------------------------------

(defun varint (bytes at)
  "Unsigned LEB128 at AT as `(values VALUE NEXT-AT)`, or NIL on a malformed
run.

The `shift > 35` ceiling is the Rust's: it allows at most six groups, which caps
the value below 2^42. Without it a truncated buffer of `#x80` bytes would loop
until it ran off the end instead of at the next byte, and the caller would see a
huge value rather than a rejection."
  (let ((value 0)
        (shift 0)
        (cursor at))
    (loop
      (when (or (>= cursor (length bytes)) (> shift 35))
        (return-from varint nil))
      (let ((byte (ub8 bytes cursor)))
        (incf cursor)
        (incf value (ash (logand byte #x7F) shift))
        (when (zerop (logand byte #x80))
          (return-from varint (values value cursor)))
        (incf shift 7)))))

(defun svarint (bytes at)
  "Zig-zag signed varint: `(values SIGNED NEXT-AT)` or NIL.

`(logxor (ash value -1) (- (logand value 1)))` is the Rust's
`(v >> 1) ^ -(v & 1)`. `ash` with a negative count is an ARITHMETIC shift in
Common Lisp, so the top bit is replicated and negative halves come out negative
— which matters, because a negative array start is exactly what the packing check
below is looking for."
  (multiple-value-bind (value next) (varint bytes at)
    (when value
      (values (logxor (ash value -1) (- (logand value 1))) next))))

;;; ---------------------------------------------------------------------------
;;; The code block tail
;;; ---------------------------------------------------------------------------

(defun parse-jsc-tail (bytes at)
  "A code block's array table as `(:record-offset N :arrays (...))`, or NIL.

Layout: a flags byte, the record-relative offset of the function record, an
optional extra varint (flag 1), then seven (count, start-if-nonzero) pairs in
`*jsc-array-order*`, then an optional signed varint (flag 4).

Two guards here are doing real work rather than being defensive noise:

  - `at < 8` rejects a tail whose record offset could not be positive.
  - every value is bounded by `2^29`. That bound is what makes this port's
    integer geometry exact (see the file header), and it is also what stops a
    run of zero bytes from reading as a valid table with a huge record offset."
  (when (or (< at 8) (> (+ at 8) (length bytes)))
    (return-from parse-jsc-tail nil))
  (let ((flags (ub8 bytes at)))
    (when (plusp (logand flags (lognot #x05)))
      (return-from parse-jsc-tail nil))
    (let ((cursor (1+ at)))
      (multiple-value-bind (record-offset next) (varint bytes cursor)
        (unless record-offset (return-from parse-jsc-tail nil))
        (when (>= record-offset #x20000000) (return-from parse-jsc-tail nil))
        (setf cursor next)
        (when (plusp (logand flags 1))
          (multiple-value-bind (extra next) (varint bytes cursor)
            (unless extra (return-from parse-jsc-tail nil))
            (when (> extra (ash 1 24)) (return-from parse-jsc-tail nil))
            (setf cursor next)))
        (let ((arrays '()))
          (dolist (name *jsc-array-order*)
            (multiple-value-bind (count next) (varint bytes cursor)
              (unless count (return-from parse-jsc-tail nil))
              (when (> count #x20000000) (return-from parse-jsc-tail nil))
              (setf cursor next)
              (let ((start 0))
                (unless (zerop count)
                  (multiple-value-bind (s next) (svarint bytes cursor)
                    (unless s (return-from parse-jsc-tail nil))
                    (when (> (abs s) #x20000000) (return-from parse-jsc-tail nil))
                    (setf start s)
                    (setf cursor next)))
                (push (list :name name :count count :start start) arrays))))
          (when (plusp (logand flags 4))
            (multiple-value-bind (extra next) (svarint bytes cursor)
              (declare (ignore next))
              (unless extra (return-from parse-jsc-tail nil))))
          (list :record-offset record-offset :arrays (nreverse arrays)))))))

(defun tail-array (tail name)
  "The `(:name :count :start)` entry for NAME in TAIL, or NIL."
  (find name (getf tail :arrays) :key (lambda (entry) (getf entry :name))))

;;; ---------------------------------------------------------------------------
;;; The op walk
;;; ---------------------------------------------------------------------------

(defun walk-jsc-ops (bytes start length table)
  "Walk the instruction stream at START for exactly LENGTH instructions.

Answers `(values OP-NAMES COUNT)` in stream order, or NIL when the walk fails —
and fails here means any of: running off the buffer, an opcode with no table
row, or an operand span that overshoots the declared end. Empty also counts as
failure (`None` in the Rust), because a block with no instructions is not a
block.

The wide prefixes are why this is not a `1 + operand_bytes` loop: `#x83` and
`#x85` do not consume operands themselves, they say that the NEXT byte is the
opcode and that every one of its operands is 2 or 4 bytes wide. Getting that
multiplier wrong still lands on `enter`-ish bytes often enough to bind a few
nonsense blocks, which is precisely what the terminal-op check then rejects."
  (let ((offset start)
        (end (+ start length))
        (names '()))
    (loop while (< offset end) do
      (when (>= offset (length bytes))
        (return-from walk-jsc-ops nil))
      (let ((first (ub8 bytes offset)))
        (if (or (= first *jsc-wide16*) (= first *jsc-wide32*))
            (let ((info (jsc-opcode-at table
                                       (progn
                                         (when (> (+ offset 2) (length bytes))
                                           (return-from walk-jsc-ops nil))
                                         (ub8 bytes (+ offset 1))))))
              (unless info (return-from walk-jsc-ops nil))
              (incf offset (+ 2 (* (cdr info) (if (= first *jsc-wide16*) 2 4))))
              (push (car info) names))
            (let ((info (jsc-opcode-at table first)))
              (unless info (return-from walk-jsc-ops nil))
              (incf offset (+ 1 (cdr info)))
              (push (car info) names))))
      (when (> offset end)
        (return-from walk-jsc-ops nil)))
    (when (null names)
      (return-from walk-jsc-ops nil))
    ;; LENGTH FIRST. `nreverse` is destructive and leaves `names` pointing at
    ;; the list's new TAIL, so `(values (nreverse names) (length names))`
    ;; answers the reversed list and then a count of 1 — the walk's op count is
    ;; exactly what the sidecar compares, so this read as "every block has one
    ;; instruction" rather than as a bug in a helper.
    (let ((count (length names)))
      (values (nreverse names) count))))

;;; ---------------------------------------------------------------------------
;;; Block candidates
;;; ---------------------------------------------------------------------------

(defun jsc-block-region (block) (getf block :region))
(defun jsc-block-instr-at (block) (getf block :instr-at))
(defun jsc-block-instr-length (block) (getf block :instr-length))
(defun jsc-block-op-count (block) (getf block :op-count))
(defun jsc-block-gap (block) (getf block :gap))
(defun jsc-block-tight-p (block) (getf block :tight))

(defun binding-candidate (bytes record gap tail table enter)
  "The candidate at GAP for RECORD, or NIL when the framing does not hold.

Split out of `bind-jsc-block` so each rejection is a single `when` at a visible
indentation rather than a seven-deep nest. Returns the candidate plist."
  (let ((instr (tail-array tail :instr)))
    (unless (and instr (plusp (getf instr :count)))
      (return-from binding-candidate nil))
    (let ((packed-end 0)
          (has-positive nil))
      (dolist (entry (getf tail :arrays))
        (let ((count (getf entry :count))
              (start (getf entry :start)))
          (unless (or (zerop count) (minusp start))
            (let* ((span (jsc-array-span (getf entry :name)))
                   (end (+ start (* count (or span 1)))))
              ;; An array that runs past the record it describes is a misread
              ;; count, not a long array: reject the whole gap.
              (when (> end (getf tail :record-offset))
                (return-from binding-candidate nil))
              (when span
                (setf has-positive t)
                (when (> end packed-end)
                  (setf packed-end end)))))))
      (let ((region (- record (getf tail :record-offset))))
        (unless (and (>= region 32) (<= region record))
          (return-from binding-candidate nil))
        (let ((stream-at (+ region (getf instr :start))))
          (unless (and (>= stream-at 0)
                       (< stream-at (length bytes))
                       (= (ub8 bytes stream-at) enter))
            (return-from binding-candidate nil))
          (multiple-value-bind (ops count)
              (walk-jsc-ops bytes stream-at (getf instr :count) table)
            (unless (and ops (is-terminal-op (car (last ops))))
              (return-from binding-candidate nil))
            (list :record record
                  :gap gap
                  :region region
                  :instr-at stream-at
                  :instr-length (getf instr :count)
                  :op-count count
                  :tail tail
                  :tight (or (not has-positive)
                             (= packed-end (getf tail :record-offset))))))))))

(defun bind-jsc-block (bytes record table &optional enter)
  "Every code block whose function record sits at RECORD, best first.

A candidate survives only when ALL of these hold, and each one rejects a
different way of being wrong:

  1. the tail parses at one of the four fixed gaps;
  2. the `instr` array is non-empty (no instructions, no block);
  3. every positive-size array PACKS before the record — an array that runs past
     the record it describes is a misread count, not a long array;
  4. the region `record - record_offset` is at least 32 and no larger than the
     record itself (a window, not a guess);
  5. the stream opens on the `enter` opcode;
  6. the walk consumes exactly the declared length;
  7. the last op is a transfer of control.

Ordering: tight candidates first, then smallest gap. `tight` means every
positive-size array ends exactly at `record_offset` — the arrays and the record
abut with no slack — which is the strongest available signal that the framing is
right. Stability matters here (the Rust's `sort_by` is stable and so is
`stable-sort`), because two candidates at the same gap with the same tightness
must keep table order: the caller takes the FIRST one as the block."
  (let ((enter (or enter (jsc-enter-opcode)))
        (candidates '()))
    (when enter
      (dolist (gap *jsc-block-gaps*)
        (let ((tail (parse-jsc-tail bytes (+ record gap))))
          (when tail
            (let ((candidate (binding-candidate bytes record gap tail table enter)))
              (when candidate
                (push candidate candidates)))))))
    (stable-sort (nreverse candidates)
                 (lambda (a b)
                   (cond ((and (getf a :tight) (not (getf b :tight))) t)
                         ((and (not (getf a :tight)) (getf b :tight)) nil)
                         (t (< (getf a :gap) (getf b :gap))))))))

(defun block-info (candidate)
  "A candidate reduced to the five fields that cross the wire, in the sidecar's
key order. `:instr-length` is an integer here for the same reason the Rust
casts it to u64: it is a COUNT of instructions, and a float would serialise as
`55.0` and read back as a different JSON number."
  (list :region (getf candidate :region)
        :instr-at (getf candidate :instr-at)
        :instr-length (getf candidate :instr-length)
        :op-count (getf candidate :op-count)
        :gap (getf candidate :gap)))

;;; ---------------------------------------------------------------------------
;;; Inline strings and name slots
;;; ---------------------------------------------------------------------------

(defun read-jsc-inline-string (bytes at)
  "A string stored INLINE at AT as `(24-BIT LENGTH, 12-BYTE HEADER, BYTES)`, or
NIL.

Note the 24-bit length mask — narrower than either of the other two record
layouts (note 4 in the file header) — and that there is no width flag: these are
byte-per-character, which is why no `* 2` appears here."
  (when (or (minusp at) (> (+ at 12) (length bytes)))
    (return-from read-jsc-inline-string nil))
  (let ((length (logand (ub32 bytes at) #xFFFFFF)))
    (when (or (zerop length) (> length 4096))
      (return-from read-jsc-inline-string nil))
    (when (> (+ at 12 length) (length bytes))
      (return-from read-jsc-inline-string nil))
    (with-output-to-string (out)
      (dotimes (i length)
        (let ((byte (ub8 bytes (+ at 12 i))))
          (unless (<= #x20 byte #x7e)
            (return-from read-jsc-inline-string nil))
          (write-char (code-char byte) out))))))

(defun decode-jsc-slot (bytes field-at slot shared depth)
  "One name slot, decoded. Slots are tagged on their low two bits:

  tag 1  up to three characters inlined directly in the word, low byte first
         from bit 8 — the cheapest case and the one that makes a slot like
         `#x00` mean \"empty\" rather than \"character NUL\".
  tag 2  an ORDINAL into the shared string table. With no table this answers
         `<ordinal N>`, which is how a lone chunk stays readable instead of
         inventing names; with a table but a HOLE at N it answers the same
         placeholder, so a corrupt record can never shift a later name down.
  tag 0  a FIELD-RELATIVE signed 32-bit pointer. The target may be another slot
         (recursed, bounded by DEPTH) or an inline string record.
  tag 3  an unrecognised tag, rendered as `<slot hex>` so it is visible in the
         output rather than silently empty.

The two sentinel words (`#x7FFFFFFF`, `#xFFFFFFFF`) mean \"no name\" and answer
the empty string; the root function record uses one of them, which is why a
Program payload's `rootName` is NIL rather than a placeholder."
  (when (or (= slot #x7FFFFFFF) (= slot #xFFFFFFFF))
    (return-from decode-jsc-slot ""))
  (case (logand slot 3)
    (1
     (let ((length (logand (ash slot -2) 3)))
       (with-output-to-string (out)
         (dotimes (i length)
           (write-char (code-char (logand (ash slot (* -8 (1+ i))) #xFF)) out)))))
    (2
     (let ((ordinal (ash slot -2)))
       (if (and shared (< ordinal (length shared)) (elt shared ordinal))
           (elt shared ordinal)
           (format nil "<ordinal ~d>" ordinal))))
    (0
     (if (>= depth 3)
         ;; The Rust's match arm is `0 if depth < 3`; a tag-0 slot past the
         ;; depth bound therefore falls through to the catch-all, which is the
         ;; EMPTY string — not an `<offset ..>` rendering. Answering a
         ;; placeholder here would put text into a name that the original leaves
         ;; blank, and the difference is visible in any name containing a
         ;; pointer cycle.
         ""
         (let* ((signed (if (logbitp 31 slot) (- slot #x100000000) slot))
                (target (+ field-at signed)))
           (when (and (plusp target) (<= (+ target 4) (length bytes)))
             (let* ((inner (ub32 bytes target))
                    (target-slot-p (<= (logand inner 3) 2)))
               (when target-slot-p
                 (let ((decoded (decode-jsc-slot bytes target inner shared (1+ depth))))
                   ;; A nested `<offset ..>` means the recursion did not resolve
                   ;; either; fall through and try the inline-string reading of
                   ;; the same address before giving up on it.
                   (unless (and (>= (length decoded) 7)
                                (string= decoded "<offset" :end2 7))
                     (return-from decode-jsc-slot decoded))))
               (let ((record (read-jsc-inline-string bytes target)))
                 (when record (return-from decode-jsc-slot record)))))
           (if (plusp target) (format nil "<offset ~d>" signed) ""))))
    (3 (format nil "<slot ~(~x~)>" slot))
    (otherwise "")))

;;; ---------------------------------------------------------------------------
;;; Shared string table
;;; ---------------------------------------------------------------------------

(defun empty-shared-table (offset length)
  "The refusal shape. `:strings` empty rather than filled with NILs, so a caller
can tell \"nothing resolved\" from \"a table of NILs\"."
  (list :strings nil :count 0 :resolved 0 :offset offset :length length))

(defun read-jsc-shared-table (bytes offset length)
  "Read the shared string table at OFFSET, limited to LENGTH bytes.

Layout: a u32 count, then one u32 per ordinal giving the record's offset
RELATIVE TO OFFSET, then the records. Every slot starts as a hole and is filled
only when its record's stored hash matches its characters — so a table with one
corrupt record answers that one slot NIL and leaves every other ordinal at its
own index. That sparse behaviour is the documented divergence from the JS
original, whose dense `push` shifted every later name down by one.

`record_at` must be 4-aligned and at least 8 (the count word plus one offset),
which is what keeps the offsets array from reading itself as a record.

Refusal conditions are all-or-nothing: a length below 8, a window past the
buffer, a count outside `1..=2^22`, or an offsets array that does not fit. A
truncated window answering a HALF-populated table would look like a chunk with
missing names rather than a bad call, so it answers nothing at all."
  (when (or (< length 8) (> (+ offset length) (length bytes)))
    (return-from read-jsc-shared-table (empty-shared-table offset length)))
  (let ((count (ub32 bytes offset)))
    (when (or (< count 1) (> count #x400000) (> (+ 4 (* count 4)) length))
      (return-from read-jsc-shared-table (empty-shared-table offset length)))
    ;; A VECTOR, not a list. The real table's count is 204782, and `nth` over a
    ;; list is linear: filling it took long enough to look like a hang before
    ;; this was a vector. Hole-vs-filled is unchanged — a hole is still NIL.
    (let ((end (+ offset length))
          (strings (make-array count :initial-element nil))
          (resolved 0))
      (dotimes (ordinal count)
        (let* ((record-at (ub32 bytes (+ offset 4 (* ordinal 4))))
               (at (+ offset record-at)))
          (when (and (zerop (logand record-at 3))
                     (>= record-at 8)
                     (<= (+ at 8) end))
            (let* ((flags (ub32 bytes at))
                   (stored (ub32 bytes (+ at 4)))
                   (text-length (logand flags #x7FFFFFFF))
                   (width (if (plusp (logand (ash flags -31) 1)) 1 2))
                   (byte-length (* text-length width)))
              (when (and (plusp text-length)
                         (<= (+ at 8 byte-length) end))
                (let ((chars (subseq bytes (+ at 8) (+ at 8 byte-length))))
                  (when (= (wtf-string-hash chars) stored)
                    (setf (aref strings ordinal)
                          (if (= width 1)
                              (map 'string #'code-char chars)
                              (with-output-to-string (out)
                                (dotimes (i text-length)
                                  (write-char
                                   (code-char (logior (aref chars (* i 2))
                                                      (ash (aref chars (1+ (* i 2))) 8)))
                                   out)))))
                    (incf resolved))))))))
      (list :strings strings :count count :resolved resolved
            :offset offset :length length))))

(defun find-jsc-shared-table (bytes)
  "Locate a shared string table anywhere inside BYTES, or NIL.

A zip of loose assets carries no module graph, so there is no reference to
follow — the table is found by validating its own structure at every 4-aligned
candidate. The prefilter is a count in `8..=2^21` plus an offsets array that fits
in the remaining bytes; then three PROBES (first, middle, last ordinal) must each
land on a 4-aligned, in-bounds, hash-matching record at a STRICTLY INCREASING
offset. Strict increase is what rejects a run of identical offsets, which is the
shape a zeroed table takes.

A candidate that passes the probes is then read in full and accepted only when
its resolved count covers all three probes — the full read can still refuse the
window for reasons the probes did not check, and answering a table whose probes
resolved but whose `resolved` count is short would be answering a different
table than the one found."
  (when (< (length bytes) 24)
    (return-from find-jsc-shared-table nil))
  (let ((at 0))
    (loop while (<= (+ at 16) (length bytes)) do
      (let ((count (ub32 bytes at)))
        (if (or (< count 8)
                (> count #x200000)
                (> (+ at 4 (* count 4) 8) (length bytes)))
            (incf at 4)
            (let ((probes (list 0 (ash count -1) (1- count)))
                  (last-offset -1)
                  (ok t))
              (dolist (probe probes)
                (when ok
                  (let* ((record-at (ub32 bytes (+ at 4 (* probe 4))))
                         (rec (+ at record-at)))
                    (if (or (plusp (logand record-at 3))
                            (< record-at 8)
                            (> (+ rec 8) (length bytes))
                            (<= record-at last-offset))
                        (setf ok nil)
                        (progn
                          (setf last-offset record-at)
                          (let* ((flags (ub32 bytes rec))
                                 (stored (ub32 bytes (+ rec 4)))
                                 (text-length (logand flags #x7FFFFFFF))
                                 (width (if (plusp (logand (ash flags -31) 1)) 1 2))
                                 (byte-length (* text-length width)))
                            (if (or (zerop text-length)
                                    (> (+ rec 8 byte-length) (length bytes)))
                                (setf ok nil)
                                (unless (= (wtf-string-hash
                                            (subseq bytes (+ rec 8)
                                                    (+ rec 8 byte-length)))
                                           stored)
                                  (setf ok nil)))))))))
              (when ok
                (let ((read (read-jsc-shared-table bytes at (- (length bytes) at))))
                  (when (>= (getf read :resolved) (length probes))
                    (return-from find-jsc-shared-table read))))
              (incf at 4)))))
    nil))

;;; ---------------------------------------------------------------------------
;;; Cached function records
;;; ---------------------------------------------------------------------------

(defun parse-jsc-cache-entry (bytes)
  "`(values TAG RECORD)` for a CachedTypes GenericCacheEntry, or NIL.

The first 16 bytes are stamp, tag, reserved callee-locals, payload size. Two
things are checked beyond the tag: the payload size at offset 12 must EQUAL the
buffer length (this is how a truncated download is refused), and the word at
`#x2c` must be a positive field-relative slot pointing at a record with room for
its 0x38-byte body.

TAG 0 is Program, TAG 1 is Module. `analyze-jsc-module` only takes the Program
path, because `bun --bytecode`'s cjs default is a Program payload whose tree is
rooted directly at this record rather than at an instantiated executable."
  (when (< (length bytes) #x30)
    (return-from parse-jsc-cache-entry nil))
  (let ((tag (ub32 bytes 4)))
    (when (and (/= tag 0) (/= tag 1))
      (return-from parse-jsc-cache-entry nil))
    (when (/= (ub32 bytes 12) (length bytes))
      (return-from parse-jsc-cache-entry nil))
    (let ((slot (sb32 bytes #x2c)))
      (when (or (<= slot 0) (= slot -1))
        (return-from parse-jsc-cache-entry nil))
      (let ((record (+ #x2c slot)))
        (when (or (< record #x30) (>= (+ record #x38) (length bytes)))
          (return-from parse-jsc-cache-entry nil))
        (values tag record)))))

(defun instantiate-jsc-exec (bytes record shared)
  "A cached function record instantiated as a plist of its presence flags, its
bound code blocks and its decoded name, or NIL when the record is out of bounds.

The header word's SIX bits each say whether a field is present, and the fields
appear in bit order (`call`, `construct`, `name`, ...) with a `metadata` word in
front when bit 5 is set — so the cursor advances through the record in a
presence-dependent order. Reading them positionally instead of conditionally is
the classic misread here, and it produces a plausible-looking block from the
wrong field.

`-1` in a block field is not a pointer: it is \"present but empty\", and it is
kept distinct from \"absent\" because `analyze-jsc-module` counts a present,
non-empty field that failed to bind as a `bindFailed` while an empty one is
entirely normal."
  (when (or (< record #x20) (> (+ record 32) (length bytes)))
    (return-from instantiate-jsc-exec nil))
  (let* ((header (ub32 bytes record))
         (present (list :call (plusp (logand header 1))
                        :construct (plusp (logand (ash header -1) 1))
                        :name (plusp (logand (ash header -2) 1))
                        :tdz (plusp (logand (ash header -3) 1))
                        :rare (plusp (logand (ash header -4) 1))
                        :metadata (plusp (logand (ash header -5) 1))))
         (cursor (+ record 4))
         (table (jsc-opcode-table))
         (call-blocks nil)
         (call-empty nil)
         (construct-blocks nil)
         (construct-empty nil))
    (when (getf present :metadata)
      (incf cursor 4))
    (dotimes (kind 2)
      (let* ((is-call (= kind 0))
             (flag (if is-call (getf present :call) (getf present :construct))))
        (when flag
          (when (> (+ cursor 4) (length bytes))
            (return-from instantiate-jsc-exec nil))
          (let* ((field-at cursor)
                 (value (sb32 bytes cursor)))
            (incf cursor 4)
            (cond
              ((= value -1)
               (if is-call (setf call-empty t) (setf construct-empty t)))
              (t
               (let ((target (+ field-at value)))
                 ;; A target outside the buffer is skipped WITHOUT setting the
                 ;; blocks, which is what makes the field count as failed to
                 ;; bind above rather than as absent.
                 (when (and (>= target #x20) (< target (length bytes)))
                   (if is-call
                       (setf call-blocks (bind-jsc-block bytes target table))
                       (setf construct-blocks (bind-jsc-block bytes target table)))))))))))
    (let ((name nil))
      (when (getf present :name)
        (when (> (+ cursor 4) (length bytes))
          (return-from instantiate-jsc-exec nil))
        (setf name (decode-jsc-slot bytes cursor (ub32 bytes cursor) shared 0)))
      (list :record record
            :parse-mode (logand (ash header -16) #xFF)
            :present present
            :call-blocks call-blocks
            :call-empty call-empty
            :construct-blocks construct-blocks
            :construct-empty construct-empty
            :name name))))

(defun jsc-block-children (bytes block)
  "`(KIND . TARGET)` for every function declaration and expression a block
declares, in `fdecls` then `fexprs` order.

The delta is a SIGNED 32-bit field-relative offset from the slot's own address.
A slot address that came out negative reads as delta 0 (the JS reads through a
negative index as `undefined`, which coerces to 0), and the resulting target then
fails the caller's `>= 0x20` gate — so the child is counted as a bind failure
rather than silently dropped. That is the original's behaviour and it is kept:
the failure is visible in `bindFailed`."
  (let ((children '())
        (region (getf block :region)))
    (dolist (pair *jsc-child-kinds*)
      (let ((entry (tail-array (getf block :tail) (car pair))))
        (when (and entry (plusp (getf entry :count)))
          (let ((base (+ region (getf entry :start))))
            (dotimes (index (getf entry :count))
              (let ((slot-at (+ base (* index 4))))
                (when (> (+ slot-at 4) (length bytes))
                  (return))
                (let ((delta (if (>= slot-at 0) (sb32 bytes slot-at) 0)))
                  (push (cons (cdr pair) (+ slot-at delta)) children))))))))
    (nreverse children)))

;;; ---------------------------------------------------------------------------
;;; The tree walk
;;; ---------------------------------------------------------------------------

(defun new-jsc-stats ()
  "The stats plist in the sidecar's key order. Eight keys, and no
`:shared-table` — that field belongs to the pipeline, not the analyzer."
  (list :valid nil
        :root-name nil
        :root-parse-mode nil
        :nodes 0
        :blocks 0
        :ops 0
        :bind-failed 0
        :functions '()))

(defun analyze-jsc-module (bytes &optional shared)
  "Decode a module's whole cached-function tree.

Two rootings, chosen by the cache entry's tag:

  Program (tag 0)  the tree roots at the CacheEntry's code-block record, the
                   best block at the 0x38 gap; the entry's own name slot at
                   `#x1c` supplies `rootName`, and the parse mode is 0.
  otherwise        the tree roots at an instantiated executable at `#x20`,
                   whose name and parse mode come from its own header.

Then the walk: pop a block, count it, and for each declared child instantiate the
record and push ITS blocks. Two details are the original's, not this port's:

  - `seen_blocks` is keyed on `record:gap`, so the same record reached at a
    different gap is a DIFFERENT block and is walked again.
  - a child's blocks are attached to the function entry only when that child was
    FRESH. The JS mutates the same object reference, so a seen child's
    `callBlock` is recorded nowhere; a port that attached it to the first entry
    with the same record would move a block between functions and still produce
    a plausible tree. The sidecar's `callBlock: null` entries for repeated
    records are the proof of that behaviour, not an accident.

`valid` requires both a non-empty walk AND zero bind failures: a partial tree is
reported as invalid rather than as a smaller valid one."
  (let ((stats (new-jsc-stats))
        (pending '())
        (seen-blocks (make-hash-table :test #'equal))
        (seen-exec (make-hash-table :test #'eql)))
    (flet ((push-function (name kind record)
             (setf (getf stats :functions)
                   (append (getf stats :functions)
                           (list (list :name name :kind kind :record record
                                       :call-block nil :construct-block nil))))
             (1- (length (getf stats :functions))))
           (attach-blocks (child pushed-at)
             (dotimes (kind 2)
               (let* ((is-call (= kind 0))
                      (blocks (if is-call
                                  (getf child :call-blocks)
                                  (getf child :construct-blocks)))
                      (present (if is-call
                                   (getf (getf child :present) :call)
                                   (getf (getf child :present) :construct)))
                      (empty (if is-call
                                 (getf child :call-empty)
                                 (getf child :construct-empty))))
                 ;; NIL blocks with a present, non-empty field is a binding
                 ;; failure — distinct from an absent field, and distinct from
                 ;; an empty one.
                 (cond
                   ((null blocks)
                    (when (and present (not empty))
                      (incf (getf stats :bind-failed))))
                   (t
                    ;; LIFO, matching the Rust's `pending.extend(blocks)` then
                    ;; `pending.pop()`. Pushing each block onto the FRONT in
                    ;; order leaves the LAST block at the head, which is what
                    ;; `pop` takes — and visit ORDER is observable: when two
                    ;; parents reach the same child record, whichever block is
                    ;; walked first is the one that decides that child's `kind`.
                    ;; FIFO here would answer the same counts and a different
                    ;; `kind`, which no fixture in this crate happens to notice.
                    (dolist (b blocks)
                      (push b pending))
                    (when (and pushed-at blocks)
                      (let ((slot (if is-call :call-block :construct-block)))
                        (setf (getf (nth pushed-at (getf stats :functions)) slot)
                              (block-info (first blocks)))))))))))
      (multiple-value-bind (tag code-block-record) (parse-jsc-cache-entry bytes)
        (cond
          ((eql tag 0)
           (let* ((candidates (bind-jsc-block bytes code-block-record
                                              (jsc-opcode-table)))
                  (program (find #x38 candidates :key #'jsc-block-gap)))
             ;; No Program block at the only gap a CacheEntry can use means the
             ;; payload is not a cached program after all: answer the empty
             ;; stats rather than a tree rooted at a guess.
             (when program
               (let ((root-name (decode-jsc-slot bytes #x1c (ub32 bytes #x1c)
                                                 shared 0)))
                 (setf (getf stats :root-name)
                       (if (zerop (length root-name)) nil root-name))
                 (setf (getf stats :root-parse-mode) 0)
                 (setf (getf stats :nodes) 1)
                 (push-function (getf stats :root-name) "root" (getf program :record))
                 (setf (getf (first (getf stats :functions)) :call-block)
                       (block-info program))
                 (push program pending)))))
          (t
           (let ((root (instantiate-jsc-exec bytes #x20 shared)))
             (when root
               (setf (getf stats :root-name) (getf root :name))
               (setf (getf stats :root-parse-mode) (getf root :parse-mode))
               (setf (getf stats :nodes) 1)
               (push-function (getf root :name) "root" (getf root :record))
               (setf (gethash (getf root :record) seen-exec) t)
               (attach-blocks root 0))))))
      (loop while pending do
        (let* ((block (pop pending))
               (identity (format nil "~d:~d" (getf block :record) (getf block :gap))))
          (unless (gethash identity seen-blocks)
            (setf (gethash identity seen-blocks) t)
            (incf (getf stats :blocks))
            (incf (getf stats :ops) (getf block :op-count))
            (dolist (child-pair (jsc-block-children bytes block))
              (let ((kind (car child-pair))
                    (target (cdr child-pair)))
                (if (or (< target #x20)
                        (>= target (- (length bytes) 32)))
                    (incf (getf stats :bind-failed))
                    (let ((child (instantiate-jsc-exec bytes target shared)))
                      (if (null child)
                          (incf (getf stats :bind-failed))
                          (let ((fresh (not (gethash (getf child :record) seen-exec)))
                                (pushed-at nil))
                            (when fresh
                              (setf (gethash (getf child :record) seen-exec) t)
                              (incf (getf stats :nodes))
                              (setf pushed-at
                                    (push-function (getf child :name) kind
                                                   (getf child :record))))
                            (attach-blocks child pushed-at))))))))))
      (setf (getf stats :valid)
            (and (plusp (getf stats :blocks))
                 (zerop (getf stats :bind-failed))))
      (setf (getf stats :functions)
            (stable-sort (getf stats :functions)
                         (lambda (a b)
                           (< (getf a :record) (getf b :record)))))
      stats)))
