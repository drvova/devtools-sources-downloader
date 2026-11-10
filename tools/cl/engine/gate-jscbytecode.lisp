;;;; gate-jscbytecode.lisp — does the cached-bytecode port answer what the Rust
;;;; crate answers?
;;;;
;;;; THE ORACLE HERE IS NOT THE WASM. Unlike the text tier there is no
;;;; `engine.wasm` capture for this module; the specification is
;;;; `unpack-rs/tests/unpack_test.rs` plus the JSON sidecars the crate's own
;;;; tests compare against:
;;;;
;;;;   jsc-chunk-strings.json            expected `recover_jsc_strings` answer
;;;;   jsc-chunk-functions.json          expected `analyze_jsc_module` answer
;;;;   jsc-chunk-functions-resolved.json the same tree with a shared table
;;;;   jsc-cjs-functions-resolved.json   the Program-payload tree
;;;;   jsc-shared-records.json           the records a shared table is built from
;;;;
;;;; Those sidecars hold the EXPECTED OUTPUT, so the gate compares the port's
;;;; whole answer against them rather than against a handful of fields: a
;;;; structural misreading that happens to agree on `nodes` and `blocks` still
;;;; fails on `instrAt` or on which function owns which block.
;;;;
;;;; The shared-table cases need a table, and no fixture IS one — the Rust test
;;;; builds it from `jsc-shared-records.json` (build_shared_table in
;;;; unpack_test.rs). `build-shared-table` below is that builder, ported: same
;;;; offsets array, same 4-byte alignment of every record, same "unresolvable
;;;; ordinals point at the records base" fallback, and an optional corrupt
;;;; ordinal that flips the last byte to break the stored hash. Building it
;;;; here rather than checking in a binary keeps the gate reading the same
;;;; fixture the Rust test reads.
;;;;
;;;; WHAT IS PROBED, NOT ORACLED. Three groups of assertions are structural
;;;; because no fixture pins them:
;;;;
;;;;   * the opcode table's `enter` row, so a regenerated table that loses it
;;;;     fails here rather than silently binding nothing;
;;;;   * `ub32`'s byte order, which is the only thing standing between this
;;;;     port and the Rust's misleading `read32_big` name;
;;;;   * block-candidate ORDERING, where the oracle pins only the winner.
;;;;
;;;; And each PLAUSIBLE WRONG IMPLEMENTATION below is one somebody writes
;;;; first — the AND guard, the masked multiply-fold, the dense table, the
;;;; wrong width bit, the gap-only sort. Each is computed and asserted NOT to be
;;;; the port's answer, so a green run means the port is right for the right
;;;; reason rather than agreeing by accident.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Fixture access
;;;
;;; Its own path helper: `fixture-path` in gate.lisp resolves under
;;; `unpack-rs/tests/fixtures/`, and this module's fixtures live under
;;; `unpack-rs/test/fixtures/` (the Rust crate's own directory, singular
;;; `test`). Reusing the wrong one produces "fixture does not exist" for every
;;; case, which reads like a missing checkout.
;;; ---------------------------------------------------------------------------

(defun jsc-fixture-path (name)
  (merge-pathnames (format nil "tools/cl/fixtures/oracles/~a" name) (repo-root)))

(defun jsc-fixture-bytes (name)
  "A fixture as an `(unsigned-byte 8)` vector.

`with-open-file` + `read-sequence` over `:element-type '(unsigned-byte 8)` is
the right tool here and NOT the trap the contract warns about: that trap is
about decoding a UTF-8 TEXT file, where file-length counts bytes and the
decoded character count differs. These are binary fixtures and stay binary."
  (with-open-file (in (jsc-fixture-path name) :direction :input
                                             :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

(defun jsc-fixture-json (name)
  (read-json-file (jsc-fixture-path name)))

(defun ascii-bytes (text)
  (map '(vector (unsigned-byte 8)) #'char-code text))

;;; ---------------------------------------------------------------------------
;;; JSON -> the port's plist shape
;;;
;;; The port answers plists, the sidecars are hash tables. Converting the
;;; EXPECTATION to the port's shape (rather than the reverse) keeps the
;;; comparison a plain `equal` over nested `equal`-comparable structures, and
;;; keeps every field in the answer under comparison — a field-by-field
;;; comparison is where a missing key hides.
;;;
;;; `json-null` is required on `name`, `rootName` and `rootParseMode` because
;;; JZON parses JSON `null` to its own symbol, and the port answers NIL.
;;; ---------------------------------------------------------------------------

(defun json-block->plist (table)
  (and table
       (list :region (gethash "region" table)
             :instr-at (gethash "instrAt" table)
             :instr-length (gethash "instrLength" table)
             :op-count (gethash "opCount" table)
             :gap (gethash "gap" table))))

(defun json-function->plist (table)
  (list :name (json-null (gethash "name" table))
        :kind (gethash "kind" table)
        :record (gethash "record" table)
        :call-block (json-block->plist (json-null (gethash "callBlock" table)))
        :construct-block (json-block->plist (json-null (gethash "constructBlock" table)))))

(defun json-stats->plist (table)
  "The sidecar as the port's stats plist: the same eight keys, in the same order.

`:shared-table` is deliberately absent — `analyze_jsc_module` leaves it `None`
and serde skips it, which is why the sidecars have eight keys and no
`sharedTable`. Adding a ninth key here would make every comparison fail on a
field the specification does not carry."
  (list :valid (gethash "valid" table)
        :root-name (json-null (gethash "rootName" table))
        :root-parse-mode (json-null (gethash "rootParseMode" table))
        :nodes (gethash "nodes" table)
        :blocks (gethash "blocks" table)
        :ops (gethash "ops" table)
        :bind-failed (gethash "bindFailed" table)
        :functions (map 'list #'json-function->plist (gethash "functions" table))))

(defun stats-to-comparable (stats)
  "The port's stats plist with `:functions` as a list (it already is) and
`:valid` as a boolean.

No transformation is needed for the port's side — this exists so the gate can
say, in one place, that the comparison is `equal` over the port's own shapes,
and so a future refactor to vectors breaks here loudly instead of somewhere in
a nested diff."
  stats)

;;; ---------------------------------------------------------------------------
;;; The shared-table builder (port of unpack_test.rs build_shared_table)
;;; ---------------------------------------------------------------------------

(defun hex->bytes (hex)
  (let* ((n (floor (length hex) 2))
         (out (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n)
      (setf (aref out i)
            (parse-integer (subseq hex (* i 2) (+ (* i 2) 2)) :radix 16)))
    out))

(defun put-u32-le-into (bytes at value)
  "Store VALUE as four little-endian bytes at AT in BYTES.

Named -INTO rather than PUT-U32-LE because `gate-v8codecache` defines a
PUT-U32-LE too and loads EARLIER in the .asd. Both write the same four bytes,
so nothing was wrong - but with one shared name the v8 body silently won for
every call site here, and a future divergence would have changed this file's
fixtures without touching its code."
  (dotimes (i 4)
    (setf (aref bytes (+ at i)) (logand (ash value (* -8 i)) #xFF))))

(defun u32-of (bytes at)
  (logior (aref bytes at)
          (ash (aref bytes (+ at 1)) 8)
          (ash (aref bytes (+ at 2)) 16)
          (ash (aref bytes (+ at 3)) 24)))

(defun round-up-4 (n)
  (* 4 (ceiling n 4)))

(defun shared-record-ordinals ()
  "The ordinals the fixture actually carries, as sorted integers.

Sorted because the table's record area is written in ascending ordinal order and
every offset is computed from that layout — an unsorted walk produces a table
whose offsets point into the middle of another record."
  (let* ((json (jsc-fixture-json "jsc-shared-records.json"))
         (records (gethash "records" json))
         (ordinals (loop for key being the hash-keys of records
                         collect (parse-integer key))))
    (sort ordinals #'<)))

(defun build-shared-table (&optional corrupt-ordinal)
  "The shared string table the Rust test builds, byte for byte.

Layout: `count`, then `count` little-endian u32 offsets RELATIVE TO THE TABLE,
then the records each padded up to a 4-byte boundary. Ordinals with no record
point at `offsets-len` — the records base — which is a valid, in-bounds, WRONG
address, so those slots land on a record that is not theirs and the hash check
rejects them. That is how a hole is made, and it is why pointing at the start is
a safe fallback: the failure is a hash mismatch, never a shifted name.

CORRUPT-ORDINAL, when given, has the last byte of its record flipped so the
stored hash no longer matches its characters."
  (let* ((json (jsc-fixture-json "jsc-shared-records.json"))
         (records (gethash "records" json))
         (count (gethash "count" json))
         (ordinals (shared-record-ordinals))
         (offsets-len (+ 4 (* count 4)))
         (record-bytes (mapcar (lambda (o)
                                 (hex->bytes
                                  (gethash "hex" (gethash (princ-to-string o) records))))
                               ordinals))
         (total (+ offsets-len 8
                   (reduce #'+ record-bytes
                           :key (lambda (b) (round-up-4 (length b)))
                           :initial-value 0)))
         (out (make-array total :element-type '(unsigned-byte 8) :initial-element 0)))
    (put-u32-le-into out 0 count)
    (let ((cursor (+ offsets-len 8))
          (pos (make-hash-table)))
      (loop for ordinal in ordinals
            for rec in record-bytes
            do (let ((copy (copy-seq rec)))
                 (when (eql ordinal corrupt-ordinal)
                   (setf (aref copy (1- (length copy)))
                         (logxor (aref copy (1- (length copy))) #xFF)))
                 (replace out copy :start1 cursor)
                 (setf (gethash ordinal pos) cursor)
                 (incf cursor (round-up-4 (length copy)))))
      (dotimes (o count)
        (put-u32-le-into out (+ 4 (* o 4)) (gethash o pos offsets-len))))
    out))

;;; ---------------------------------------------------------------------------
;;; Wrong implementations, computed so they can be named and rejected
;;; ---------------------------------------------------------------------------

(defun wrong-rapid-mix-masked (first second)
  "RapidMix with the high half folded away BEFORE the shift.

The plausible mistake: mask each operand to 64 bits, multiply, then mask the
product so `ash` shifts out of an already-64-bit value. It looks like the same
arithmetic and mirrors every hash, because `(ash (logand p mask) -64)` is 0."
  (let* ((product (logand (* (logand first #xFFFFFFFFFFFFFFFF)
                             (logand second #xFFFFFFFFFFFFFFFF))
                          #xFFFFFFFFFFFFFFFF)))
    (logxor product (ash product -64))))

(defun wrong-rapid-mix-lhs (first second)
  "RapidMix with the operands' high halves zeroed before the multiply — the
other half of the same mistake, and a different wrong answer."
  (let ((product (* (logand first #xFFFFFFFF) (logand second #xFFFFFFFF))))
    (logxor (logand product #xFFFFFFFFFFFFFFFF) (ash product -64))))

(defun dense-table-strings (sparse)
  "The JS original's dense reading of a sparse table: every resolved name,
compacted into consecutive slots.

This is the behaviour `read_jsc_shared_table` is documented to diverge from, and
the divergence is observable: after one corrupt record, every later name sits one
slot lower than it should. Built from the port's own resolved entries so the
comparison is same names in shifted positions rather than a second hash pass."
  (let ((dense '()))
    (loop for slot across sparse
          when slot do (push slot dense))
    (coerce (nreverse dense) 'vector)))

(defun width-bit-27-table (bytes offset length)
  "`read-jsc-shared-table` with the width flag read at bit 27 — the OTHER
reader's bit — and a 28-bit length mask to match.

Genuinely plausible: `recover_jsc_strings` uses `0x08000000` / `0x07FFFFFF` for
this exact record family, so carrying that pair into the table reader is the
mistake a careful person makes by symmetry. It is wrong here because the table's
records put the width in bit 31."
  (when (or (< length 8) (> (+ offset length) (length bytes)))
    (return-from width-bit-27-table nil))
  (let ((count (u32-of bytes offset)))
    (when (or (< count 1) (> count #x400000) (> (+ 4 (* count 4)) length))
      (return-from width-bit-27-table nil))
    (let ((end (+ offset length))
          (resolved 0))
      (dotimes (ordinal count)
        (let* ((record-at (u32-of bytes (+ offset 4 (* ordinal 4))))
               (at (+ offset record-at)))
          (when (and (zerop (logand record-at 3)) (>= record-at 8)
                     (<= (+ at 8) end))
            (let* ((flags (u32-of bytes at))
                   (stored (u32-of bytes (+ at 4)))
                   (text-length (logand flags #x0FFFFFFF))
                   (width (if (plusp (logand flags #x08000000)) 1 2))
                   (byte-length (* text-length width)))
              (when (and (plusp text-length) (<= (+ at 8 byte-length) end))
                (let ((chars (subseq bytes (+ at 8) (+ at 8 byte-length))))
                  (when (= (vovas.engine.jscbytecode:wtf-string-hash chars) stored)
                    (incf resolved))))))))
      resolved)))

(defun program-shaped-noise ()
  "The Rust test's hand-built Program payload: a valid 0x30-byte-plus cache
entry whose code-block slot points at in-bounds garbage.

Every cheap check passes — stamp, tag 0, payload size equal to the buffer length,
a positive in-bounds slot — and the tree must still refuse to bind, because no
tail at any of the four gaps parses into a walk ending on a transfer of control.
A port that trusted the cache entry would report a one-node valid tree here."
  (let ((noise (make-array 4528 :element-type '(unsigned-byte 8) :initial-element 0)))
    (put-u32-le-into noise 0 #x64ed8b42)   ; stamp
    (put-u32-le-into noise 4 0)            ; tag 0 (Program)
    (put-u32-le-into noise 8 4)            ; reserved callee locals
    (put-u32-le-into noise 12 4528)        ; payload size == blob length
    (put-u32-le-into noise #x2c #x100)     ; in-bounds code block slot
    noise))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun ordinal-slot (strings ordinal)
  "The slot at ORDINAL, or the keyword `:out-of-range` when the table is
shorter than that.

Why not `elt`: the answer being checked is a SPARSE table of 204782 slots, and a
port that compacted it (the dense-list bug this module deliberately diverges
from) answers a 9-slot vector. `elt` at 10609 on that vector SIGNALS, which
tears down the whole gate run and hides the other seventy assertions — a crash
where a single FAIL was the correct report. Answering a distinguishable value
keeps the comparison total."
  (if (< ordinal (length strings))
      (elt strings ordinal)
      :out-of-range))

(defun ordinal-placeholder-p (name)
  "True when NAME is a `<ordinal N>` placeholder.

`(string= name \"<ordinal \" :end2 9)` is WRONG: `:end2` bounds the SECOND
string, and there is no second string here — SBCL signals or silently compares
the wrong span, which made this count answer 0 for a tree full of placeholders.
`uiop:string-prefix-p` states the intent directly."
  (and name (uiop:string-prefix-p "<ordinal " name)))

(defun run-jscbytecode-gate (&key (verbose t))
  "Assert the port against the Rust crate's sidecars, then against the
structural properties no sidecar covers. Returns T when every assertion holds
and the case count is positive."
  (let ((result (make-gate-result)))
    ;; ---- wtf_string_hash: four ledger truths from unpack_test.rs ---------
    ;; These four are the hash's own oracle. They are what makes the record's
    ;; stored 24-bit hash proves its characters" a real check rather than a
    ;; tautology, so they are asserted before anything that depends on them.
    (dolist (truth '(("moduleLoader" . #x27d79d)
                     ("homeObject" . #xc376d0)
                     ("starNamespace" . #x72858b)
                     ("iterator" . #x336a9c)))
      (check result (format nil "wtf-string-hash/~a" (car truth))
             (car truth)
             (vovas.engine.jscbytecode:wtf-string-hash
              (ascii-bytes (car truth)))
             (cdr truth)))

    ;; ---- header + detection ----------------------------------------------
    (let ((chunk (jsc-fixture-bytes "jsc-chunk.jsc"))
          (cjs (jsc-fixture-bytes "jsc-cjs-chunk.bin"))
          (sec (jsc-fixture-bytes "jsc-cjs-sec.bin"))
          (v8 (jsc-fixture-bytes "v8-codecache.jsc"))
          (v8sealed (jsc-fixture-bytes "v8-codecache-sealed.jsc"))
          (noise (make-array 4096 :element-type '(unsigned-byte 8)
                                  :initial-element #x41))
          (zeros (make-array 20 :element-type '(unsigned-byte 8)
                                :initial-element 0)))
      (let ((header (vovas.engine.jscbytecode:parse-jsc-header chunk)))
        (check result "parse-jsc-header/chunk format" "jsc-chunk.jsc"
               (getf header :format) 1)
        (check result "parse-jsc-header/chunk declared length" "jsc-chunk.jsc"
               (getf header :declared-length) (length chunk))
        (check result "parse-jsc-header/chunk body offset" "jsc-chunk.jsc"
               (getf header :body-offset) 32))

      ;; The separation the acceptance criteria name: both real chunk families
      ;; are bytecode, and neither V8 code-cache family is.
      (check result "detect/module chunk" "jsc-chunk.jsc"
             (vovas.engine.jscbytecode:detect-jsc-bytecode chunk) t)
      (check result "detect/program payload" "jsc-cjs-chunk.bin"
             (vovas.engine.jscbytecode:detect-jsc-bytecode cjs) t)
      (check result "detect/data section is not a chunk" "jsc-cjs-sec.bin"
             (vovas.engine.jscbytecode:detect-jsc-bytecode sec) nil)
      (check result "detect/v8 code cache" "v8-codecache.jsc"
             (vovas.engine.jscbytecode:detect-jsc-bytecode v8) nil)
      (check result "detect/sealed v8 cache" "v8-codecache-sealed.jsc"
             (vovas.engine.jscbytecode:detect-jsc-bytecode v8sealed) nil)
      (check result "detect/uniform noise" "4096 x #x41"
             (vovas.engine.jscbytecode:detect-jsc-bytecode noise) nil)
      (check result "detect/short buffer" "20 zero bytes"
             (vovas.engine.jscbytecode:detect-jsc-bytecode zeros) nil)

      ;; ---- recover_jsc_strings -------------------------------------------
      ;; Compared as LISTS. `equal` on a general vector compares elements with
      ;; `eql`, and two distinct strings with identical contents are not `eql` —
      ;; so a vector comparison reports a mismatch whose printed want/got look
      ;; character-for-character identical. `equal` on lists recurses with
      ;; `equal`, which is the comparison actually meant.
      (check result "recover-jsc-strings" "jsc-chunk.jsc"
             (coerce (vovas.engine.jscbytecode:recover-jsc-strings chunk) 'list)
             (coerce (jsc-fixture-json "jsc-chunk-strings.json") 'list))
      ;; The recovered list is DISTINCT: both of these strings appear more than
      ;; once in the chunk, and a port that appended every match would answer a
      ;; longer list than the sidecar's two.
      (check result "recover-jsc-strings is distinct" "jsc-chunk.jsc"
             (length (vovas.engine.jscbytecode:recover-jsc-strings chunk)) 2)

      ;; ---- the module tree, unresolved ------------------------------------
      (let ((stats (vovas.engine.jscbytecode:analyze-jsc-module chunk nil)))
        (check result "analyze/chunk full tree" "jsc-chunk.jsc"
               (stats-to-comparable stats)
               (json-stats->plist (jsc-fixture-json "jsc-chunk-functions.json")))
        (check result "analyze/chunk valid" "jsc-chunk.jsc"
               (getf stats :valid) t)
        (check result "analyze/chunk nodes" "jsc-chunk.jsc"
               (getf stats :nodes) 7)
        (check result "analyze/chunk ops" "jsc-chunk.jsc"
               (getf stats :ops) 103)
        (check result "analyze/chunk root name degrades to an ordinal"
               "jsc-chunk.jsc" (getf stats :root-name) "<ordinal 204781>"))

      ;; A walk that fails closed. The noise still yields ONE function — the
      ;; root record — because the record parsed; what it must not yield is a
      ;; block. A port reporting zero functions here would be hiding the root.
      (let ((stats (vovas.engine.jscbytecode:analyze-jsc-module noise nil)))
        (check result "analyze/noise blocks" "4096 x #x41" (getf stats :blocks) 0)
        (check result "analyze/noise valid" "4096 x #x41" (getf stats :valid) nil)
        (check result "analyze/noise still reports the root record"
               "4096 x #x41" (length (getf stats :functions)) 1))

      ;; ---- the shared table ------------------------------------------------
      (let* ((table (build-shared-table))
             (read (vovas.engine.jscbytecode:read-jsc-shared-table
                    table 0 (length table)))
             (strings (getf read :strings)))
        (check result "read-shared/count" "built table" (getf read :count) 204782)
        (check result "read-shared/resolved" "built table" (getf read :resolved) 9)
        (dolist (case '((0 . "B:/~BUN/root/chunk-6xptctz4.js")
                        (10609 . "W")
                        (10759 . "o")
                        (22490 . "S_t")
                        (129467 . "njo")
                        (184967 . "SGs")
                        (204781 . "file:///B:/%7EBUN/root/chunk-nqhgex2p.js")))
          (check result (format nil "read-shared/ordinal ~d" (car case))
                 "built table" (ordinal-slot strings (car case)) (cdr case)))
        (check result "read-shared/gap ordinal is a hole" "built table"
               (ordinal-slot strings 100) nil)
        (check result "read-shared/truncated window refuses" "0..12"
               (getf (vovas.engine.jscbytecode:read-jsc-shared-table table 0 12)
                     :resolved)
               0)

        ;; ---- find_jsc_shared_table ----------------------------------------
        (let ((padded (make-array (+ 512 (length table))
                                  :element-type '(unsigned-byte 8)
                                  :initial-element #x41)))
          (replace padded table :start1 512)
          (let ((found (vovas.engine.jscbytecode:find-jsc-shared-table padded)))
            (check result "find-shared/offset inside a blob" "512 x #x41 prefix"
                   (getf found :offset) 512)
            (check result "find-shared/resolved" "512 x #x41 prefix"
                   (getf found :resolved) 9)
            (check result "find-shared/names its top ordinal" "512 x #x41 prefix"
                   (ordinal-slot (getf found :strings) 204781)
                   "file:///B:/%7EBUN/root/chunk-nqhgex2p.js")))
        (check result "find-shared/uniform noise" "4096 x #x41"
               (vovas.engine.jscbytecode:find-jsc-shared-table noise) nil)
        (check result "find-shared/truncated head" "table[0..100]"
               (vovas.engine.jscbytecode:find-jsc-shared-table
                (subseq table 0 100))
               nil)
        (check result "find-shared/empty" ""
               (vovas.engine.jscbytecode:find-jsc-shared-table
                (make-array 0 :element-type '(unsigned-byte 8)))
               nil)

        ;; ---- the RESOLVED tree -------------------------------------------
        (let ((resolved (vovas.engine.jscbytecode:analyze-jsc-module chunk strings)))
          (check result "analyze/chunk resolved tree" "built table"
                 (stats-to-comparable resolved)
                 (json-stats->plist
                  (jsc-fixture-json "jsc-chunk-functions-resolved.json")))
          (check result "analyze/chunk resolved root name" "built table"
                 (getf resolved :root-name)
                 "file:///B:/%7EBUN/root/chunk-nqhgex2p.js")
          (check result "analyze/chunk resolved bind failures" "built table"
                 (getf resolved :bind-failed) 0))

        ;; ---- a corrupt record leaves a HOLE ------------------------------
        (let* ((corrupt (build-shared-table 129467))
               (read2 (vovas.engine.jscbytecode:read-jsc-shared-table
                       corrupt 0 (length corrupt)))
               (strings2 (getf read2 :strings)))
          (check result "corrupt table/resolved drops by one" "129467 broken"
                 (getf read2 :resolved) 8)
          (check result "corrupt table/broken ordinal is a hole" "129467 broken"
                 (ordinal-slot strings2 129467) nil)
          (check result "corrupt table/earlier ordinal intact" "129467 broken"
                 (ordinal-slot strings2 10609) "W")
          (check result "corrupt table/later ordinal intact" "129467 broken"
                 (ordinal-slot strings2 184967) "SGs")
          (check result "corrupt table/top ordinal intact" "129467 broken"
                 (ordinal-slot strings2 204781)
                 "file:///B:/%7EBUN/root/chunk-nqhgex2p.js")
          ;; The hole must be visible all the way out through a name slot.
          (let* ((tree (vovas.engine.jscbytecode:analyze-jsc-module chunk strings2))
                 (fn (find #x230 (getf tree :functions) :key (function (lambda (f) (getf f :record))))))
            (check result "corrupt table/name slot degrades to the ordinal"
                   "record #x230"
                   (and fn (getf fn :name)) "<ordinal 129467>"))
          ;; THE DENSE-LIST BUG, computed and rejected. The JS original pushes
          ;; each resolved name in turn, so the name that belonged at 129467
          ;; lands at 184967 and everything above shifts down. The port must
          ;; answer a vector whose positions are the ORDINALS.
          (check result "corrupt table is sparse, not dense" "129467 broken"
                 (equal strings2 (dense-table-strings strings2)) nil)
          ;; ... and specifically: the slot the dense bug would fill is empty,
          ;; while a LATER resolved slot keeps its own name.
          (check result "corrupt table hole is not refilled by a later name"
                 "129467 broken"
                 (and (null (ordinal-slot strings2 129467))
                      (equal (ordinal-slot strings2 184967) "SGs"))
                 t))

        ;; ---- width bit: 31 here, 27 in the string scanner ----------------
        (check result "shared table reads the width flag at bit 31"
               "built table" (getf read :resolved) 9)
        ;; The scanner's bit-27 pair applied to the table's records resolves
        ;; NOTHING: the 28-bit length mask truncates the length and the width
        ;; flag comes out on the wrong bit, so every record's character run is
        ;; the wrong span and every hash misses. Pinned as the exact count (0)
        ;; rather than as "not 9", so a wrong reader that resolved 2 would fail
        ;; here too instead of sliding past a loose inequality.
        (check result "shared table is not read with the scanner's bit 27"
               "built table"
               (list :resolved (width-bit-27-table table 0 (length table)))
               (list :resolved 0)))

      ;; ---- the Program payload (format word 0) ---------------------------
      (let* ((found (vovas.engine.jscbytecode:find-jsc-shared-table sec))
             (table-strings (getf found :strings)))
        (check result "find-shared/cjs section resolves its table" "jsc-cjs-sec.bin"
               (and found (getf found :resolved)) 53)
        (let ((tree (vovas.engine.jscbytecode:analyze-jsc-module cjs table-strings)))
          (check result "analyze/cjs resolved tree" "jsc-cjs-chunk.bin"
                 (stats-to-comparable tree)
                 (json-stats->plist
                  (jsc-fixture-json "jsc-cjs-functions-resolved.json")))
          (check result "analyze/cjs valid" "jsc-cjs-chunk.bin"
                 (getf tree :valid) t)
          (check result "analyze/cjs blocks" "jsc-cjs-chunk.bin"
                 (getf tree :blocks) 17)
          (check result "analyze/cjs bind failures" "jsc-cjs-chunk.bin"
                 (getf tree :bind-failed) 0)
          ;; The WALK ORDER, which no count reveals. Two children are reachable
          ;; from record 112's block; the Rust's `pending.extend` + `pop` is
          ;; LIFO, so the LAST block pushed is walked first and record 192 is
          ;; reached as an `fexprs` child before record 1228 is reached as an
          ;; `fdecls` one. A FIFO port answers the same 17/17/293 and a
          ;; different `kind` on every entry past the root — pinned here as the
          ;; full kind sequence so that swap cannot hide.
          (check result "analyze/cjs walk order is depth-first (LIFO)"
                 "jsc-cjs-chunk.bin"
                 (mapcar (function (lambda (f) (getf f :kind)))
                         (getf tree :functions))
                 '("root" "fexprs"
                   "fdecls" "fdecls" "fdecls" "fdecls" "fdecls"
                   "fexprs" "fexprs" "fexprs" "fexprs" "fexprs" "fexprs"
                   "fexprs" "fexprs" "fexprs" "fexprs"))
          (let ((names (mapcar (function (lambda (f) (getf f :name)))
                               (getf tree :functions))))
            (dolist (name '("calculateInvoiceTotal" "validateCustomerRecord"
                            "internalAuditLogger" "resolvePreferredGateway"
                            "InvoiceWorkflow" "computeTotal" "__export"))
              (check result (format nil "analyze/cjs resolves ~a" name)
                     "jsc-cjs-chunk.bin" (and (member name names :test #'equal) t) t))
            ;; Every named slot resolved through the table: a leftover
            ;; `<ordinal ` placeholder means the table was not consulted.
            (check result "analyze/cjs has no ordinal placeholders"
                   "jsc-cjs-chunk.bin"
                   (count-if #'ordinal-placeholder-p names)
                   0)))

        ;; The same chunk with NO table still binds, and degrades.
        (let ((plain (vovas.engine.jscbytecode:analyze-jsc-module cjs nil)))
          (check result "analyze/cjs without a table still binds"
                 "jsc-cjs-chunk.bin" (getf plain :valid) t)
          (check result "analyze/cjs without a table keeps 17 blocks"
                 "jsc-cjs-chunk.bin" (getf plain :blocks) 17)
          (check result "analyze/cjs entry name slot is the empty sentinel"
                 "jsc-cjs-chunk.bin" (getf plain :root-name) nil)
          (check result "analyze/cjs degrades to ordinal placeholders"
                 "jsc-cjs-chunk.bin"
                 (>= (count-if (function (lambda (f)
                                           (ordinal-placeholder-p (getf f :name))))
                               (getf plain :functions))
                     6)
                 t)))

      ;; ---- Program-shaped noise must not bind -----------------------------
      (let ((stats (vovas.engine.jscbytecode:analyze-jsc-module
                    (program-shaped-noise) nil)))
        (check result "analyze/program-shaped noise is not valid" "hand-built"
               (getf stats :valid) nil)
        (check result "analyze/program-shaped noise binds no blocks" "hand-built"
               (getf stats :blocks) 0))

      ;; ---- opcode table + byte order, structural -------------------------
      (let* ((table (vovas.engine.jscbytecode:jsc-opcode-table))
             (enter (vovas.engine.jscbytecode:jsc-enter-opcode table)))
        (check result "opcode table has an `enter` row" "jsc_opcodes.txt"
               (and enter (< enter 256)) t)
        (check result "the `enter` id names `enter` back" "jsc_opcodes.txt"
               (car (vovas.engine.jscbytecode:jsc-opcode-at table enter)) "enter")
        ;; `enter` takes no operands (`134 enter 0 0`), so its span is 1: the
        ;; opcode byte and nothing else. If the file ever gains padding on that
        ;; row the walk stops landing on the next opcode.
        (check result "the `enter` row carries no operands" "jsc_opcodes.txt"
               (cdr (vovas.engine.jscbytecode:jsc-opcode-at table enter)) 0)
        ;; A 256-entry table with `enter` somewhere inside it proves the file
        ;; was parsed, not embedded: this is the count the file declares.
        (check result "the table is 256 entries wide" "jsc_opcodes.txt"
               (length table) 256))

      ;; ub32 is LITTLE-endian. The Rust calls the same read `read32_big`, and
      ;; a port that trusted that name would produce a different hash for every
      ;; string — the four ledger truths above would all miss.
      (check result "ub32 reads little-endian" "#(1 2 3 4)"
             (let ((b (make-array 4 :element-type '(unsigned-byte 8))))
               (setf (aref b 0) 1 (aref b 1) 2 (aref b 2) 3 (aref b 3) 4)
               (vovas.engine.jscbytecode::ub32 b 0))
             #x04030201)
      (check result "sb32 sign-extends" "#(0 0 0 #x80)"
             (let ((b (make-array 4 :element-type '(unsigned-byte 8)
                                     :initial-element 0)))
               (setf (aref b 3) #x80)
               (vovas.engine.jscbytecode::sb32 b 0))
             -2147483648)

      ;; ---- the multiply-fold, probed --------------------------------------
      ;; Both wrong mixes are computed here and asserted NOT to be what the port
      ;; answers. On a 16-byte string the fold is the only arithmetic that
      ;; differs, so the three values are otherwise identical inputs.
      (let* ((bytes (ascii-bytes "starNamespace"))
             (good (vovas.engine.jscbytecode::rapid-mix #x2d358dccaa6c78a5
                                                        #x8bb84b93962eacc9))
             (masked (wrong-rapid-mix-masked #x2d358dccaa6c78a5
                                             #x8bb84b93962eacc9))
             (lhs (wrong-rapid-mix-lhs #x2d358dccaa6c78a5
                                       #x8bb84b93962eacc9)))
        (check result "rapid-mix keeps the high half" "secret[0] x secret[1]"               (plusp (ash (* #x2d358dccaa6c78a5 #x8bb84b93962eacc9) -64)) t)
        (check result "rapid-mix is not the masked product" "secret[0] x secret[1]"
               (equal good masked) nil)
        (check result "rapid-mix is not the 32-bit operands product"
               "secret[0] x secret[1]" (equal good lhs) nil)
        ;; and the hash itself is not either of those constants
        (check result "wtf-string-hash is not the masked-fold hash"
               "starNamespace" (equal (vovas.engine.jscbytecode:wtf-string-hash bytes)
                                      #x72858b)
               t)
        (check result "wtf-string-hash is below the 24-bit mask"
               "starNamespace"
               (<= (vovas.engine.jscbytecode:wtf-string-hash bytes) #xFFFFFF)
               t))

        ;; ---- the terminal-op check, pinned by its INPUTS ---------------
        ;; No fixture in this crate needs this check: every candidate the four
        ;; gaps offer either fails to open on `enter` or fails to land exactly
        ;; on the declared end, so the terminal test never changes an answer
        ;; here (probed directly — see the note in the gate's header). It is
        ;; still ported, because it is the reason a stream that opens on
        ;; `enter` and happens to end one op inside the declared length cannot
        ;; bind. So it is pinned by its two halves instead of by a fixture:
        ;;
        ;;   the real chunk's stream at 104, walked for ONE instruction, is
        ;;   `("enter")` — a legal exact-length walk that ends on a
        ;;   non-terminal op, which is precisely the shape the check refuses.
        ;;
        ;; FIXTURE THAT WOULD CLOSE THIS GAP. `jsc-chunk-terminal-truncated.jsc`:
        ;; `jsc-chunk.jsc` with the `.instr` COUNT varint of record 368's 0x38
        ;; tail patched from 55 down to any length that lands exactly on a
        ;; non-terminal op. Those lengths are measured, not guessed — walking
        ;; the real stream at 104 for each of 1..60 and keeping the ones that
        ;; both succeed and end non-terminal gives:
        ;;
        ;;     1 enter   4 mov   7 mov   16 get_from_scope
        ;;     31 put_to_scope   35 new_func_exp   38 mov   53 put_to_scope
        ;;
        ;; Patch to any of those and `bind-jsc-block` must answer ZERO
        ;; candidates for record 368; a port that dropped the terminal check
        ;; answers one, and every other assertion in this gate stays green.
        ;; That is the case which would turn this construction into an oracle.
        (multiple-value-bind (ops count)
            (vovas.engine.jscbytecode:walk-jsc-ops chunk 104 1
                                                   (vovas.engine.jscbytecode:jsc-opcode-table))
          (check result "a one-instruction stream walks cleanly" "chunk @104 len 1"
                 (list ops count) (list (list "enter") 1))
          (check result "that stream ends on a non-terminal op" "chunk @104 len 1"
                 (vovas.engine.jscbytecode:is-terminal-op (car (last ops)))
                 nil))
        (check result "`ret` is terminal" "ret"
               (vovas.engine.jscbytecode:is-terminal-op "ret") t)
        (check result "`enter` is not terminal" "enter"
               (vovas.engine.jscbytecode:is-terminal-op "enter") nil)
        (check result "a terminal op is never the empty name" ""
               (vovas.engine.jscbytecode:is-terminal-op "") nil)

        ;; And the block whose real tail declares 55 instructions ends on `ret`
        ;; — the terminal op the walk actually arrives at in this fixture.
        (let ((ops (multiple-value-list
                    (vovas.engine.jscbytecode:walk-jsc-ops
                     chunk 104 55 (vovas.engine.jscbytecode:jsc-opcode-table)))))
          (check result "the real 55-op stream ends on `ret`" "chunk @104 len 55"
                 (car (last (first ops))) "ret"))

      ;; ---- decode-jsc-slot: two of its four tags have no fixture ------
      ;; MEASURED, not assumed. Classifying every decoded name in both real
      ;; trees gives: jsc-chunk.jsc -> 6 tag-2 ordinals + 1 NIL; jsc-cjs-chunk.bin
      ;; -> 15 tag-2 ordinals + 2 NIL. Tags 0 and 3 never occur, and tag 1 never
      ;; occurs either — the two recovered STRINGS ("moduleLoader",
      ;; "starNamespace") are records matched by hash in `recover-jsc-strings`,
      ;; not name slots. So three of the four tags are construction-pinned here
      ;; and stated as such rather than pretended into the oracle.
      ;;
      ;; (Getting this measurement wrong is easy and instructive: a hand-rolled
      ;; cursor walk over the present-flag fields reported tags 0 and 3 as
      ;; present. The decoded STRINGS are the reliable test, because a tag-0 slot
      ;; renders `<offset N>` and a tag-3 slot renders `<slot hex>` — if either
      ;; had occurred it would be visible in the output, and it is not. Trust the
      ;; rendering, not the reimplementation of the cursor arithmetic.)
      ;;
      ;; FIXTURES THAT WOULD CLOSE THIS GAP, one per tag:
      ;;
      ;;   tag 0  a chunk whose name field is a field-relative pointer to a
      ;;          string record — the layout `read-jsc-inline-string` exists for.
      ;;          Assertion that would then become oracle: the decoded name is
      ;;          the inline string, and a slot pointing at another SLOT resolves
      ;;          through it to a depth of 3.
      ;;   tag 3  any payload carrying an unrecognised tag. Assertion: the name
      ;;          renders `<slot hex>` rather than collapsing to the empty name,
      ;;          which is the whole reason tag 3 is rendered instead of dropped.
      ;;   tag 1  a chunk with an inlined-character name (`a`, `abc`). Assertion:
      ;;          the characters come out low byte first from bit 8, in the
      ;;          reverse order a naive high-byte-first port would produce.
      ;;
      ;; A single fixture cannot cover all three; they are three different slot
      ;; encodings. Until any of them exists these stay construction-pinned.
      (let ((empty (make-array 0 :element-type '(unsigned-byte 8))))
        (flet ((slot (value) (vovas.engine.jscbytecode:decode-jsc-slot empty 0 value nil 0)))
          ;; the two no-name sentinels
          (check result "slot #x7FFFFFFF is the empty name" "#x7FFFFFFF"
                 (slot #x7FFFFFFF) "")
          (check result "slot #xFFFFFFFF is the empty name" "#xFFFFFFFF"
                 (slot #xFFFFFFFF) "")
          ;; tag 1: one character, low byte first
          (check result "tag 1 packs one character" "0x61<<8 | 1<<2 | 1"
                 (slot (logior (ash (char-code #\a) 8) (ash 1 2) 1)) "a")
          ;; tag 1: three characters, the maximum the two length bits allow
          (check result "tag 1 packs three characters" "abc"
                 (slot (logior (ash (char-code #\a) 8)
                               (ash (char-code #\b) 16)
                               (ash (char-code #\c) 24)
                               (ash 3 2) 1))
                 "abc")
          ;; the length lives in bits 2-3, so a slot of 1 has tag 1 and length 0:
          ;; EMPTY, not one NUL. (Slot 5 is the trap — `(5 >> 2) & 3` is 1, not
          ;; 0, so it packs one character of code 0, i.e. a NUL. Pinned below.)
          (check result "tag 1 with length zero is empty" "slot 1"
                 (slot 1) "")
          (check result "tag 1 packs code 0 as a NUL character" "slot 5"
                 (map 'list #'char-code (slot 5)) '(0))
          ;; tag 2 without a table degrades to the ordinal placeholder
          (check result "tag 2 without a table is a placeholder" "204781<<2 | 2"
                 (slot (logior (ash 204781 2) 2)) "<ordinal 204781>")
          ;; tag 2 WITH a table resolves, and a HOLE in that table stays a
          ;; placeholder rather than borrowing a neighbour's name.
          (let ((shared (make-array 3 :initial-element nil)))
            (setf (aref shared 1) "resolved")
            (check result "tag 2 against a table resolves" "ordinal 1"
                   (vovas.engine.jscbytecode:decode-jsc-slot
                    empty 0 (logior (ash 1 2) 2) shared 0)
                   "resolved")
            (check result "tag 2 against a hole stays a placeholder" "ordinal 2"
                   (vovas.engine.jscbytecode:decode-jsc-slot
                    empty 0 (logior (ash 2 2) 2) shared 0)
                   "<ordinal 2>"))
          ;; tag 3 is an unrecognised tag: rendered, never silently empty, so a
          ;; slot this port does not understand is visible in the output.
          (check result "tag 3 renders as a hex slot" "#xDEADBEEF | 3"
                 (slot (logior #xDEADBEEF 3)) "<slot deadbeef>")
          ;; tag 0 past the depth bound answers the EMPTY string, not an
          ;; `<offset ..>` rendering — the Rust's `0 if depth < 3` falls through
          ;; to the catch-all, and answering a placeholder would put text into a
          ;; name the original leaves blank.
          (check result "tag 0 past the depth bound is empty" "depth 3"
                 (vovas.engine.jscbytecode:decode-jsc-slot empty 0 0 nil 3) "")))

      ;; ---- block ordering, where the oracle pins only the winner ----------
      ;; The record to probe is the CONSTRUCT FIELD'S TARGET (368), not the
      ;; executable record (32). `bind_jsc_block` is called on the target the
      ;; field points at; asking it about the exec record answers nothing,
      ;; which is correct and is why the first version of this probe failed
      ;; while the tree itself was right.
      (let* ((table (vovas.engine.jscbytecode:jsc-opcode-table))
             (candidates (vovas.engine.jscbytecode:bind-jsc-block chunk 368 table)))
        (check result "bind-jsc-block finds the program block" "record 368"
               (plusp (length candidates)) t)
        ;; The oracle's block for record 368 has gap 56 = 0x38. A port that
        ;; scanned only the first gap (4) would answer nothing here, because
        ;; this record's tail parses only at 0x38 — so the gap SET is pinned,
        ;; not just the winning entry.
        (check result "the program block is the 0x38-gap candidate"
               "record 368" (getf (first candidates) :gap) #x38)
        ;; Exactly one candidate: a port that also accepted 0x28 or 16 here
        ;; would be binding a tail that does not belong to this record.
        (check result "record 368 binds exactly one candidate" "record 368"
               (length candidates) 1)
        ;; instr-length is an instruction COUNT and must be an integer: the
        ;; Rust casts the f64 tail value to u64 for exactly this reason, and a
        ;; float here serialises as `55.0` and compares unequal to the sidecar.
        (check result "instr-length is an integer, not a float" "record 368"
               (integerp (getf (first candidates) :instr-length)) t)
        ;; The walk's op count is the block's, not 1. `(values (nreverse ..)
        ;; (length ..))` answers 1 because `nreverse` leaves the variable
        ;; pointing at the new tail, and that bug is invisible except here.
        (check result "the walk counts every op it consumed" "record 368"
               (getf (first candidates) :op-count) 11)
        ;; And the block's own fields are the sidecar's, field for field.
        (check result "the block info matches the sidecar" "record 368"
               (vovas.engine.jscbytecode:block-info (first candidates))
               (list :region 92 :instr-at 104 :instr-length 55
                     :op-count 11 :gap 56))))

    (let ((failures (gate-result-failures result))
          (total (gate-result-total result)))
      (when verbose
        (report-failures result)
        (format t "~&jsc-bytecode gate: ~d/~d assertions passed~%"
                (gate-result-passed result) total))
      (and (= total (gate-result-passed result))
           ;; non-vacuous: an empty or mis-read fixture set must fail loudly
           ;; rather than passing every loop zero times.
           (plusp total)
           (null failures)))))
