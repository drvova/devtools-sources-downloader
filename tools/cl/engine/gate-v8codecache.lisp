;;;; gate-v8codecache.lisp — does the code-cache reader answer what the Rust
;;;; reader answers?
;;;;
;;;; THREE KINDS OF ASSERTION, and the distinction is the point:
;;;;
;;;;   FIXTURE CASES. `unpack-rs/test/fixtures/v8-codecache.jsc` (424 bytes) and
;;;;   `v8-codecache-sealed.jsc` (264 bytes) are the oracle, and so is
;;;;   `unpack-rs/tests/unpack_test.rs`. Every assertion those tests make is made
;;;;   here, with the expected values taken from running the Rust crate against
;;;;   the same bytes rather than retyped from the test file: format "v12",
;;;;   payload_length + 32 == len, the magic 0xc0de0689, the three hashes, and
;;;;   the two framed strings.
;;;;
;;;;   SYNTHETIC BLOBS. V11 has no fixture — every fixture this repo ships is a
;;;;   node24 (V12) cache — so the V11 layout is pinned with a blob built here
;;;;   and the values cross-checked against the Rust crate on the same bytes.
;;;;   That is stated plainly rather than dressed up as an oracle: it is a
;;;;   structural pin, not an oracle case.
;;;;
;;;;   WRONG-IMPLEMENTATION PROBES. Every one below is a mistake a careful person
;;;;   makes on the first pass, and each is asserted NOT to be what the port
;;;;   answers.
;;;;
;;;; The local helper is called `expect`, not `case`: a `labels` binding named
;;;; `case` does NOT shadow CL:CASE, because a function binding never shadows a
;;;; macro. Every `(case label input got want)` call would have expanded as the
;;;; macro and failed in a way that names the helper, not the mistake.

(in-package :vovas.engine.gate)

;;; ---------------------------------------------------------------------------
;;; Fixture access
;;;
;;; The fixtures live in `unpack-rs/test/fixtures/`, NOT in
;;; `unpack-rs/tests/fixtures/` where `fixture-path` points: the Rust tests read
;;; through `CARGO_MANIFEST_DIR/test/fixtures`, and both directories exist. The
;;; wrong one reports as a missing fixture, not as a wrong path.
;;; ---------------------------------------------------------------------------

(defun v8-fixture-path (name)
  (merge-pathnames (format nil "tools/cl/fixtures/oracles/~a" name) (repo-root)))

(defun read-octets (path)
  "The file at PATH as a `(simple-array (unsigned-byte 8) (*))`.

Read into an exactly-sized vector rather than a growing one: the brotli path
hands these bytes to C through `vector-sap`, which requires a simple array.
`(file-length in)` is the byte count for a binary stream — the UTF-8/text trap in
CONTRACT.md does not apply here because this stream has no character decoding."
  (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
    (let ((out (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence out in)
      out)))

;;; ---------------------------------------------------------------------------
;;; Building synthetic blobs
;;;
;;; The little-endian writer here is deliberately NOT the port's own `u32-le`: a
;;; gate that built its inputs with the function under test could not tell a
;;; correct read from a self-consistently wrong one.
;;; ---------------------------------------------------------------------------

(defun put-u32-le (vector at value)
  "Store VALUE as four little-endian bytes at AT in VECTOR."
  (setf (aref vector at) (logand value #xFF)
        (aref vector (+ at 1)) (logand (ash value -8) #xFF)
        (aref vector (+ at 2)) (logand (ash value -16) #xFF)
        (aref vector (+ at 3)) (logand (ash value -24) #xFF))
  vector)

(defun make-blob (words &optional (payload #()))
  "The WORDS as consecutive little-endian u32s, then PAYLOAD bytes, as a simple
octet vector."
  (let* ((head (* 4 (length words)))
         (out (make-array (+ head (length payload))
                          :element-type '(unsigned-byte 8))))
    (loop for word in words
          for at from 0 by 4
          do (put-u32-le out at word))
    (replace out payload :start1 head)
    out))

(defun padded-zeros (n)
  (make-array n :element-type '(unsigned-byte 8) :initial-element 0))

(defun ascii-octets (text)
  (let ((out (make-array (length text) :element-type '(unsigned-byte 8))))
    (loop for c across text
          for k from 0
          do (setf (aref out k) (char-code c)))
    out))

(defun concat-octets (&rest parts)
  (let* ((total (reduce #'+ parts :key #'length))
         (out (make-array total :element-type '(unsigned-byte 8)))
         (at 0))
    (dolist (part parts out)
      (replace out part :start1 at)
      (incf at (length part)))))

(defun make-frame (map-byte text)
  "One string frame: 0x52, MAP-BYTE, four opaque bytes, the length at +6, then
the characters at +10.

Those four opaque bytes are not padding invented here: they are what the real
fixture holds, and the port must never read them. Putting the length at +6 — where
the Rust reads it — is what makes the frame shape right."
  (let* ((chars (ascii-octets text))
         (header (padded-zeros 10)))
    (setf (aref header 0) #x52
          (aref header 1) map-byte)
    (put-u32-le header 6 (length chars))
    (concat-octets header chars)))

(defun make-cache-blob (magic version-hash source-hash flag-hash
                        declared-length &optional (header-extra 0))
  "A 32-byte-header blob whose declared payload length puts it at DECLARED-LENGTH
in the V12 slot (+20) and HEADER-EXTRA in the V11 slot (+16). The payload is
zero-filled to make the arithmetic close, so `(+ 32 declared-length)` is the total
size."
  (let ((out (make-array (+ 32 declared-length) :element-type '(unsigned-byte 8)
                                               :initial-element 0)))
    (put-u32-le out 0 magic)
    (put-u32-le out 4 version-hash)
    (put-u32-le out 8 source-hash)
    (put-u32-le out 12 flag-hash)
    (put-u32-le out 16 header-extra)
    (put-u32-le out 20 declared-length)
    out))

;;; ---------------------------------------------------------------------------
;;; The gate
;;; ---------------------------------------------------------------------------

(defun run-v8codecache-gate (&key (verbose t))
  (let ((result (make-gate-result))
        (count 0)
        (plain (read-octets (v8-fixture-path "v8-codecache.jsc")))
        (sealed (read-octets (v8-fixture-path "v8-codecache-sealed.jsc"))))
    (labels
        ((expect (label input got want)
           (incf count)
           (check result label input got want))
         (holds (label input condition)
           "A boolean case: reports the condition text, not a bare NIL/T."
           (incf count)
           (check result label input (and condition t) t))
         (safe (label input thunk want)
           "A case whose PORT call might signal. A signalling port is recorded as
a FAILURE of this case rather than being allowed to abort the whole gate.

This exists because of the mutation check: a wrong `v8-code-cache-format` called
on a NIL cache signals a type error, and an aborting gate answers only 'something
broke' — indistinguishable from a broken gate file. With this wrapper the report
names the case and shows the condition, so a mutant is caught as a REPORTED
failure and the verdict is the same shape as a wrong value."
           (incf count)
           (handler-case (check result label input (funcall thunk) want)
             (error (e)
               (record result nil label input
                       (format nil "signalled ~a" (type-of e)) want)))))

      ;; ------------------------------------------------------------- detect
      (holds "detect/plain-fixture" "v8-codecache.jsc"
             (vovas.engine.v8codecache:detect-v8-code-cache plain))
      (expect "detect/plain-fixture-size" "fixture size" (length plain) 424)

      ;; The whole point of the module: a JSC bytecode blob is NOT a cache.
      (dolist (name '("jsc-chunk.jsc" "jsc-cjs-chunk.bin" "jsc-cjs-sec.bin"))
        (expect "detect/jsc-bytecode-is-not-a-cache" name
                (vovas.engine.v8codecache:detect-v8-code-cache
                 (read-octets (v8-fixture-path name)))
                nil))
      (expect "detect/sealed-is-not-a-plain-cache" "v8-codecache-sealed.jsc"
              (vovas.engine.v8codecache:detect-v8-code-cache sealed) nil)

      ;; The Rust asserts both of these by hand.
      (expect "detect/20-zero-bytes" 20
              (vovas.engine.v8codecache:detect-v8-code-cache (padded-zeros 20)) nil)
      (expect "detect/64-zero-bytes" 64
              (vovas.engine.v8codecache:detect-v8-code-cache (padded-zeros 64)) nil)

      ;; Every length below one V12 header is refused — including the 31-byte blob
      ;; carrying a valid magic, which a magic-only detector would accept and then
      ;; read past.
      (loop for n from 0 below 32
            do (let ((blob (padded-zeros n)))
                 (when (>= n 4) (put-u32-le blob 0 #xC0DE0688))
                 (expect (format nil "detect/too-short-~a" n) n
                         (vovas.engine.v8codecache:detect-v8-code-cache blob) nil)))

      ;; The ext-ref window, exactly: 0 out, 1 in, 0x4000 in, 0x4001 out.
      (dolist (probe '((#x0000 . nil) (#x0001 . t) (#x0563 . t) (#x0688 . t)
                       (#x4000 . t) (#x4001 . nil) (#xFFFF . nil)))
        (expect (format nil "detect/ext-refs-~4,'0x" (car probe)) (car probe)
                (vovas.engine.v8codecache:detect-v8-code-cache
                 (make-cache-blob (logior #xC0DE0000 (car probe)) 0 0 0 8))
                (if (cdr probe) t nil)))

      ;; The family comparison is on the HIGH HALF only, and a zero ext-ref count
      ;; is not a real build.
      (dolist (magic '(#xC0DF0563 #xBDDE0563 #xC0DE0000 #x0000C0DE))
        (expect (format nil "detect/family-~8,'0x" magic) magic
                (vovas.engine.v8codecache:detect-v8-code-cache
                 (make-cache-blob magic 0 0 0 8))
                nil))

      ;; -------------------------------------------------------------- parse
      ;; Every field case goes through `safe` and re-parses, rather than sharing
      ;; one `when cache` guard. With the guard, a port that answered NIL would
      ;; skip the field assertions entirely and the gate would report a single
      ;; failure for a dozen missing checks — which reads as one broken case
      ;; instead of a broken parser.
      (holds "parse/plain-is-some" "v8-codecache.jsc"
             (vovas.engine.v8codecache:parse-v8-code-cache plain))
      (safe "parse/format" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-format
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            "v12")
      (safe "parse/magic" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-magic
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            #xC0DE0689)
      (safe "parse/magic-hex" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-magic-hex
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            "0xc0de0689")
      (safe "parse/runtime" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-runtime
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            "unknown build (c0de0000 family, 1673 external refs)")
      (safe "parse/version-hash" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-version-hash
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            #xDC338CFA)
      (safe "parse/source-hash" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-source-hash
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            28)
      (safe "parse/flag-hash" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-flag-hash
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            #x5FB11F89)
      (safe "parse/payload-offset" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-payload-offset
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            32)
      (safe "parse/payload-length" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-payload-length
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            392)
      ;; the Rust test's own arithmetic assertion
      (safe "parse/payload-closes-blob" "payload_length + 32 == len"
            (lambda () (+ (vovas.engine.v8codecache:v8-code-cache-payload-length
                           (vovas.engine.v8codecache:parse-v8-code-cache plain))
                          32))
            (length plain))
      (safe "parse/strings" "v8-codecache.jsc"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-strings
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            '("hi from cache" "evalmachine.<anonymous>"))

      ;; A blob that detects but does not parse: the declared length does not
      ;; close the buffer. Detection and parsing are allowed to disagree here.
      (let ((blob (make-cache-blob #xC0DE0688 0 0 0 8 #xDEADBEEF)))
        (setf (aref blob 20) #x00 (aref blob 21) #x00
              (aref blob 22) #x00 (aref blob 23) #x00)
        (holds "parse/misfit-detects" "declared length 0 with 40 trailing bytes"
               (vovas.engine.v8codecache:detect-v8-code-cache blob))
        (expect "parse/misfit-refuses" "declared length 0 with 40 trailing bytes"
                (vovas.engine.v8codecache:parse-v8-code-cache blob) nil))

      ;; ---------------------------------------------------------- V11 layout
      ;; No fixture exists for V11 (every shipped fixture is node24/V12), so this
      ;; is a STRUCTURAL pin, not an oracle case: the blob is built to the V11
      ;; rule (payload_length at +16, 24-byte header, a +20 word that is not
      ;; length-shaped) and the expected values were confirmed by running the Rust
      ;; crate on these exact bytes.
      (let ((blob (make-blob (list #xC0DE0688 #x11111111 #x22222222 #x33333333
                                   40 #xDEADBEEF)
                             (make-array 40 :element-type '(unsigned-byte 8)
                                            :initial-element #xAA))))
        (holds "v11/detects" "synthetic v11 (64 bytes)"
               (vovas.engine.v8codecache:detect-v8-code-cache blob))
        (holds "v11/parses" "synthetic v11 (64 bytes)"
               (vovas.engine.v8codecache:parse-v8-code-cache blob))
        (flet ((of (reader)
                 (lambda () (funcall reader
                                     (vovas.engine.v8codecache:parse-v8-code-cache blob)))))
          (safe "v11/format" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-format) "v11")
          (safe "v11/payload-offset" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-payload-offset) 24)
          (safe "v11/payload-length" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-payload-length) 40)
          (safe "v11/runtime" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-runtime) "node24")
          (safe "v11/version-hash" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-version-hash) #x11111111)
          (safe "v11/source-hash" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-source-hash) #x22222222)
          (safe "v11/flag-hash" "synthetic v11"
                (of #'vovas.engine.v8codecache:v8-code-cache-flag-hash) #x33333333)
          (safe "v11/strings-empty" "synthetic v11, 0xAA payload"
                (of #'vovas.engine.v8codecache:v8-code-cache-strings) nil)))

      ;; V12 is tested FIRST. A blob whose +16 word is ALSO length-shaped must
      ;; still answer "v12"; a port that tried V11 first answers "v11".
      ;;
      ;; Built with `make-cache-blob` so the total really is 32 + declared: an
      ;; earlier hand-built version had a 28-byte header, so NEITHER layout closed
      ;; the blob and the case failed for a reason that had nothing to do with
      ;; precedence. header-extra is chosen to close the V11 rule as well
      ;; (32 + 24 == len), which is what makes the two layouts compete.
      (let ((blob (make-cache-blob #xC0DE0628 #xABCD1234 0 0 24 32)))
        (expect "layout/v12-preferred-blob-shape" "total 56"
                (length blob) 56)
        (holds "layout/v12-preferred-both-slots-close" "both slots length-shaped"
               (vovas.engine.v8codecache:parse-v8-code-cache blob))
        (flet ((of (reader)
                 (lambda () (funcall reader
                                     (vovas.engine.v8codecache:parse-v8-code-cache blob)))))
          (safe "layout/v12-preferred" "both slots length-shaped"
                (of #'vovas.engine.v8codecache:v8-code-cache-format) "v12")
          (safe "layout/v12-preferred-offset" "both slots length-shaped"
                (of #'vovas.engine.v8codecache:v8-code-cache-payload-offset) 32)
          (safe "layout/v12-preferred-runtime" "both slots length-shaped"
                (of #'vovas.engine.v8codecache:v8-code-cache-runtime) "node22")))

      ;; Known runtimes, from `v8_known_runtime`.
      (dolist (probe '((#xC0DE0563 . "node18") (#xC0DE05CC . "node20")
                       (#xC0DE0628 . "node22") (#xC0DE0688 . "node24")))
        (let ((blob (make-cache-blob (car probe) 0 0 0 8)))
          (safe (format nil "runtime/~8,'0x" (car probe)) (car probe)
                (lambda () (vovas.engine.v8codecache:v8-code-cache-runtime
                            (vovas.engine.v8codecache:parse-v8-code-cache blob)))
                (cdr probe))))

      ;; The unknown-build diagnostic: family in lowercase hex with the `0x`
      ;; stripped, ext-ref count in DECIMAL.
      (dolist (probe '((#xC0DE0689 . "unknown build (c0de0000 family, 1673 external refs)")
                       (#xC0DE00AB . "unknown build (c0de0000 family, 171 external refs)")
                       (#xC0DE4000 . "unknown build (c0de0000 family, 16384 external refs)")))
        (let ((blob (make-cache-blob (car probe) 0 0 0 8)))
          (safe (format nil "unknown-runtime/~8,'0x" (car probe)) (car probe)
                (lambda () (vovas.engine.v8codecache:v8-code-cache-runtime
                            (vovas.engine.v8codecache:parse-v8-code-cache blob)))
                (cdr probe))))

      ;; ----------------------------------------------------- extract strings
      (expect "extract/from-32-to-end" "v8-codecache.jsc 32..end"
              (vovas.engine.v8codecache:extract-v8-strings plain 32)
              '("hi from cache" "evalmachine.<anonymous>"))
      (expect "extract/from-32-to-140" "v8-codecache.jsc 32..140"
              (vovas.engine.v8codecache:extract-v8-strings plain 32 140)
              '("hi from cache"))
      (expect "extract/window-past-end-clamps" "32..100000"
              (vovas.engine.v8codecache:extract-v8-strings plain 32 100000)
              '("hi from cache" "evalmachine.<anonymous>"))
      (expect "extract/empty-buffer" ""
              (vovas.engine.v8codecache:extract-v8-strings (padded-zeros 0) 0) nil)
      (expect "extract/from-past-end" "128.."
              (vovas.engine.v8codecache:extract-v8-strings plain 128)
              '("evalmachine.<anonymous>"))

      ;; Synthetic frames for the field rejections no fixture reaches.
      (dolist (map-byte '(#x61 #x62 #x63))
        (expect (format nil "extract/map-~2,'0x-accepted" map-byte) map-byte
                (vovas.engine.v8codecache:extract-v8-strings
                 (make-frame map-byte "abcdef") 0)
                '("abcdef")))
      (dolist (map-byte '(#x60 #x64 #x00 #xFF #x52))
        (expect (format nil "extract/map-~2,'0x-rejected" map-byte) map-byte
                (vovas.engine.v8codecache:extract-v8-strings
                 (make-frame map-byte "abcdef") 0)
                nil))
      ;; length 0 and 1 are below V8_STRING_MIN
      (dolist (length '(0 1))
        (let ((frame (padded-zeros 10)))
          (setf (aref frame 0) #x52 (aref frame 1) #x61)
          (put-u32-le frame 6 length)
          (expect (format nil "extract/length-~a-rejected" length) length
                  (vovas.engine.v8codecache:extract-v8-strings frame 0) nil)))
      ;; a length that would run past the window
      (let ((frame (make-array 12 :element-type '(unsigned-byte 8)
                                 :initial-element #x41)))
        (setf (aref frame 0) #x52 (aref frame 1) #x61)
        (put-u32-le frame 6 40)
        (expect "extract/length-past-window-rejected" "len 40 inside 12 bytes"
                (vovas.engine.v8codecache:extract-v8-strings frame 0) nil))
      ;; a non-printable character run
      (let ((frame (padded-zeros 13)))
        (setf (aref frame 0) #x52 (aref frame 1) #x61)
        (put-u32-le frame 6 3)
        (setf (aref frame 10) 0 (aref frame 11) 1 (aref frame 12) 2)
        (expect "extract/non-printable-rejected" "0x00 0x01 0x02"
                (vovas.engine.v8codecache:extract-v8-strings frame 0) nil))
      ;; DEL is outside the Rust's exclusive 0x7f bound; tilde is inside. Both
      ;; directions, because a port with `(<= b #x7f)` fails only the first.
      (let ((frame (padded-zeros 13)))
        (setf (aref frame 0) #x52 (aref frame 1) #x61)
        (put-u32-le frame 6 3)
        (setf (aref frame 10) #x61 (aref frame 11) #x62 (aref frame 12) #x7F)
        (expect "extract/del-rejected" "ab + DEL 0x7f"
                (vovas.engine.v8codecache:extract-v8-strings frame 0) nil))
      (let ((frame (padded-zeros 13)))
        (setf (aref frame 0) #x52 (aref frame 1) #x61)
        (put-u32-le frame 6 3)
        (setf (aref frame 10) #x61 (aref frame 11) #x62 (aref frame 12) #x7E)
        (expect "extract/tilde-accepted" "ab~"
                (vovas.engine.v8codecache:extract-v8-strings frame 0) '("ab~")))
      ;; de-duplication keeps first-seen order
      (expect "extract/dedupes" "abc, abc, xyz"
              (vovas.engine.v8codecache:extract-v8-strings
               (concat-octets (make-frame #x61 "abc")
                              (make-frame #x62 "abc")
                              (make-frame #x63 "xyz"))
               0)
              '("abc" "xyz"))
      ;; adjacent frames: both must be found (the advance rule)
      (expect "extract/adjacent-frames" "ab then cd, back to back"
              (vovas.engine.v8codecache:extract-v8-strings
               (concat-octets (make-frame #x61 "ab") (make-frame #x61 "cd")) 0)
              '("ab" "cd"))
      ;; a frame that is the LAST thing in the buffer, with no trailing byte
      (expect "extract/frame-at-end-of-buffer" "single frame, no trailing byte"
              (vovas.engine.v8codecache:extract-v8-strings
               (make-frame #x61 "ab") 0)
              '("ab"))

      ;; ---------------------------------------------------------- the sealed
      (expect "sealed/does-not-detect-as-plain" "v8-codecache-sealed.jsc"
              (vovas.engine.v8codecache:detect-v8-code-cache sealed) nil)

      ;; `sealed_a_throwing_inflator_degrades_to_a_refusal_not_a_crash`: a
      ;; SIGNALLING injected function must be caught, not propagated.
      (expect "sealed/throwing-inflator-refuses" "inflator signals"
              (vovas.engine.v8codecache:parse-sealed-v8
               sealed (lambda (bytes) (declare (ignore bytes)) (error "not brotli")))
              nil)
      (expect "sealed/nil-inflator-refuses" "inflator returns NIL"
              (vovas.engine.v8codecache:parse-sealed-v8
               sealed (lambda (bytes) (declare (ignore bytes)) nil))
              nil)
      (expect "sealed/garbage-inflator-refuses" "64 zero bytes"
              (vovas.engine.v8codecache:parse-sealed-v8
               sealed (lambda (bytes) (declare (ignore bytes)) (padded-zeros 64)))
              nil)
      (expect "sealed/inflated-but-unparseable-refuses"
              "inflates to a magic-only blob that does not parse"
              (vovas.engine.v8codecache:parse-sealed-v8
               sealed (lambda (bytes) (declare (ignore bytes))
                       (let ((bad (padded-zeros 64)))
                         (put-u32-le bad 0 #xC0DE0688)
                         ;; neither slot closes a 64-byte blob (32+? and 24+?)
                         (put-u32-le bad 16 7)
                         (put-u32-le bad 20 9)
                         bad)))
              nil)
      (expect "sealed/empty-blob-refuses" ""
              (vovas.engine.v8codecache:parse-sealed-v8
               (padded-zeros 0) (lambda (bytes) (declare (ignore bytes)) plain))
              nil)
      (expect "sealed/plain-blob-refuses" "v8-codecache.jsc"
              (vovas.engine.v8codecache:parse-sealed-v8
               plain (lambda (bytes) (declare (ignore bytes)) plain))
              nil)

      ;; The brotli-bomb ceiling. No fixture is 64MiB, so the guard is pinned
      ;; structurally: a blob ONE BYTE past the ceiling must be refused WITHOUT
      ;; the inflator ever being called — an inflator that would happily answer
      ;; proves the refusal came from the guard and not from the decompressor.
      (let ((too-big (padded-zeros (1+ (symbol-value
                                        (intern "*BROTLI-WINDOW-MAX-BYTES*"
                                                :vovas.engine.v8codecache)))))
            (calls 0))
        (setf (aref too-big 0) #x1B)          ; not a plain cache
        (expect "sealed/oversize-refuses-without-inflating"
                "one byte past *brotli-window-max-bytes*"
                (vovas.engine.v8codecache:parse-sealed-v8
                 too-big (lambda (bytes) (declare (ignore bytes))
                           (incf calls)
                           plain))
                nil)
        (expect "sealed/oversize-never-called-the-inflator"
                "inflator call count for an oversize blob"
                calls 0)
        ;; and the ceiling itself must still be allowed through, so the guard is
        ;; not simply refusing everything: a 1-byte blob under the ceiling that
        ;; inflates to a cache parses.
        (safe "sealed/under-ceiling-still-inflates" "a 1-byte sealed blob"
              (lambda ()
                (let ((small (padded-zeros 1)))
                  (setf (aref small 0) #x1B)
                  (vovas.engine.v8codecache:sealed-v8-inflated-bytes
                   (vovas.engine.v8codecache:parse-sealed-v8
                    small (lambda (bytes) (declare (ignore bytes)) plain)))))
              424))

      ;; The injected seam with a faithful stub: works with no library at all,
      ;; which is precisely the Rust test's route.
      (let ((stub (lambda (bytes) (declare (ignore bytes)) plain)))
        (holds "sealed/stub-inflator-parses" "stub returns the plain fixture"
               (vovas.engine.v8codecache:parse-sealed-v8 sealed stub))
        (safe "sealed/stub-inflated-bytes" "stub returns the plain fixture"
              (lambda () (vovas.engine.v8codecache:sealed-v8-inflated-bytes
                          (vovas.engine.v8codecache:parse-sealed-v8 sealed stub)))
              424)
        (safe "sealed/stub-strings" "stub returns the plain fixture"
              (lambda () (vovas.engine.v8codecache:v8-code-cache-strings
                          (vovas.engine.v8codecache:sealed-v8-cache
                           (vovas.engine.v8codecache:parse-sealed-v8 sealed stub))))
              '("hi from cache" "evalmachine.<anonymous>")))

      ;; ------------------------------------------------ the REAL brotli route
      ;; Either the system decoder inflates the fixture to exactly the plain
      ;; fixture's bytes — so the sealed route parses with no injection — or no
      ;; decoder exists, and the honest assertions are that the default answers
      ;; NIL and the sealed route refuses. The branch taken is REPORTED, so a
      ;; reader can never mistake the absent case for a passing inflate.
      (if (vovas.engine.v8codecache:brotli-available-p)
          (progn
            (format t "~&  NOTE  libbrotlidec found: asserting the REAL inflate route~%")
            (let ((inflated (vovas.engine.v8codecache:inflate-brotli-default sealed)))
              (expect "brotli/default-inflates" "v8-codecache-sealed.jsc"
                      (and inflated (length inflated)) 424)
              (expect "brotli/default-bytes-equal-plain" "v8-codecache-sealed.jsc"
                      (and inflated (equalp inflated plain)) t))
            (safe "brotli/sealed-parses-without-injection" "v8-codecache-sealed.jsc"
                  (lambda () (vovas.engine.v8codecache:v8-code-cache-strings
                              (vovas.engine.v8codecache:sealed-v8-cache
                               (vovas.engine.v8codecache:parse-sealed-v8 sealed))))
                  '("hi from cache" "evalmachine.<anonymous>"))
            ;; non-brotli input is a refusal, not an error and not a zero
            (expect "brotli/default-on-plain-bytes" "v8-codecache.jsc"
                    (vovas.engine.v8codecache:inflate-brotli-default plain) nil)
            (expect "brotli/default-on-empty" ""
                    (vovas.engine.v8codecache:inflate-brotli-default (padded-zeros 0)) nil))
          (progn
            (format t "~&  NOTE  libbrotlidec ABSENT: the default brotli path is unimplemented in~%")
            (format t "        this process. Asserting it answers NIL (never invented bytes) and~%")
            (format t "        that the sealed route refuses without an injected inflator.~%")
            (expect "brotli/absent-default-answers-nil" "v8-codecache-sealed.jsc"
                    (vovas.engine.v8codecache:inflate-brotli-default sealed) nil)
            (expect "brotli/absent-sealed-refuses" "v8-codecache-sealed.jsc"
                    (vovas.engine.v8codecache:parse-sealed-v8 sealed) nil)))

      ;; --------------------------------------------- wrong implementations
      ;; Each names a plausible FIRST ATTEMPT and asserts the port does not
      ;; produce it. These survive a green fixture run by construction: the
      ;; fixture cases above are all reachable by a wrong implementation that
      ;; happens to agree on these 424 bytes.

      ;; (1) exact-magic matching instead of the high-half family test. Such a
      ;;     port refuses the real fixture, whose magic 0xc0de0689 is not one of
      ;;     the four known ones — the single most likely wrong first pass.
      (holds "probe/detect-is-not-exact-magic-matching"
             "0xc0de0689 is not a known runtime but is the family"
             (vovas.engine.v8codecache:detect-v8-code-cache plain))

      ;; (2) the frame advance. Stopping at the length instead of at the last
      ;;     character truncates or re-reads; either way the second string or its
      ;;     exact text changes.
      (expect "probe/extract-does-not-advance-by-one"
              "first string is the whole frame"
              (first (vovas.engine.v8codecache:extract-v8-strings plain 32))
              "hi from cache")
      (expect "probe/extract-does-not-skip-a-byte-after-frames"
              "the second frame is still found"
              (second (vovas.engine.v8codecache:extract-v8-strings plain 32))
              "evalmachine.<anonymous>")

      ;; (3) the printable upper bound. `(<= #x20 b #x7f)` admits DEL.
      (expect "probe/printable-upper-bound-is-exclusive"
              "ab + DEL is not a string"
              (let ((frame (padded-zeros 13)))
                (setf (aref frame 0) #x52 (aref frame 1) #x61)
                (put-u32-le frame 6 3)
                (setf (aref frame 10) #x61 (aref frame 11) #x62 (aref frame 12) #x7F)
                (vovas.engine.v8codecache:extract-v8-strings frame 0))
              nil)

      ;; (4) ignoring the TO window and scanning to the buffer end.
      (expect "probe/window-is-not-ignored"
              "32..140 yields exactly one string"
              (length (vovas.engine.v8codecache:extract-v8-strings plain 32 140))
              1)

      ;; (5) V11 tested before V12.
      (safe "probe/layout-is-not-v11-first"
            "the 424-byte fixture is v12"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-format
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            "v12")

      ;; (6) colliding the injected and default empty-output behaviours. The
      ;;     injected path must PRESERVE a zero-length answer.
      (expect "probe/injected-empty-output-is-preserved"
              "injected answers 0 bytes, not NIL"
              (let ((out (vovas.engine.v8codecache:inflate-brotli-with
                          sealed (lambda (bytes) (declare (ignore bytes))
                                   (padded-zeros 0)))))
                (and out (length out)))
              0)

      ;; (7) printing the ext-ref count in hex.
      (safe "probe/unknown-runtime-count-is-decimal"
            "0xc0de0689"
            (lambda () (vovas.engine.v8codecache:v8-code-cache-runtime
                        (vovas.engine.v8codecache:parse-v8-code-cache plain)))
            "unknown build (c0de0000 family, 1673 external refs)"))

      (when verbose
        (format t "~&v8codecache gate: ~a/~a cases match~%"
                (gate-result-passed result) (gate-result-total result))
        (report-failures result))
      ;; Both halves: every case passed, AND the gate actually ran the cases.
      ;; The floor makes a truncated gate fail loudly instead of passing on an
      ;; accidentally-empty loop.
      (and (= (gate-result-passed result) (gate-result-total result))
           (plusp count)
           (>= count 80))))
