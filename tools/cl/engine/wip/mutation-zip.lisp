;;;; mutation-zip.lisp — does the zip gate actually fail when the port is wrong?
;;;;
;;;; The CONTRACT calls this "the gate must be non-vacuous". It is the one
;;;; property a passing gate cannot demonstrate about itself, so it is checked by
;;;; mutating the port IN PLACE, one plausible bug at a time, and confirming the
;;;; gate rejects each one. Ten mutations, spanning both halves of the module:
;;;; the checksum, the timestamp, the compression choice, the header fields, the
;;;; entry ceiling, and three independent reader checks.
;;;;
;;;; Each mutation is an exact source edit between two anchors, so it is visible
;;;; here rather than hidden in a redefinition. The original text is restored in
;;;; an UNWIND-PROTECT, and the restored module must pass the gate again - an
;;;; unrestored mutation would make every "caught" verdict suspect.
;;;;
;;;; Usage: sbcl --script tools/cl/engine/wip/mutation-zip.lisp

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-asd (truename "tools/cl/engine/zip.asd"))

;; The system must be LOADED before any form mentions `vovas.engine.gate::` -
;; LOAD reads one top-level form at a time, so an earlier reference fails with
;; "package does not exist", which reads like a broken port.
(asdf:load-system :vovas-engine.zip)

(defparameter *zip-source*
  (merge-pathnames "tools/cl/engine/zip.lisp" (vovas.engine.gate::repo-root))
  "The port's source, found by the gate harness's marker-based root search.
Counting parent directories was wrong here on the first attempt - a file
pathname's directory-pathname already includes one level - and the miscount
resolved to a path that does not exist, which reads like a missing file rather
than a wrong root.")

(defparameter *original* (uiop:read-file-string *zip-source*))

(defun run-gate-quietly ()
  "The gate's verdict with its report silenced: a mutation is EXPECTED to fail,
so its failure listing is noise. A condition from the port is reported as
:ERROR, which counts as caught."
  (handler-case (vovas.engine.gate::run-zip-gate :verbose nil)
    (error () :error)))

(defun write-source (text)
  (with-open-file (out *zip-source* :direction :output :if-exists :supersede
                                   :external-format :utf-8)
    (write-string text out)))

(defun apply-mutation (from to)
  (let ((at (search from *original*)))
    (unless at (error "mutation anchor not found: ~s" from))
    (write-source (concatenate 'string (subseq *original* 0 at) to
                               (subseq *original* (+ at (length from)))))))

(defun restore-source () (write-source *original*))

(defun reload-module ()
  "Recompile and load ONLY the mutated file.

Forcing ASDF recompiles the whole dependency chain, which is minutes per
mutation now that the base system carries the 72 KB packers module; `load`
compiles just the one file that changed. The gate file is deliberately NOT
reloaded between mutations - it is the thing under test, and a compile error in
it would be mistaken for a caught mutation."
  (let ((*compile-verbose* nil) (*load-verbose* nil))
    (load *zip-source* :verbose nil :print nil)))

(defparameter *mutations*
  (list
   ;; -- the checksum -------------------------------------------------------
   (list "the CRC loses its final complement"
         "(dotimes (i (length data) (logxor crc #xFFFFFFFF))"
         "(dotimes (i (length data) crc)")
   ;; -- the timestamp ------------------------------------------------------
   (list "the DOS (time, date) pair is transposed"
         "(multiple-value-bind (time date) (dos-stamp ms)
    (%make-zip-writer time date))"
         "(multiple-value-bind (time date) (dos-stamp ms)
    (%make-zip-writer date time))")
   (list "the DOS seconds field is not halved"
         "(values (logior (ash hour 11) (ash minute 5) (floor second 2))"
         "(values (logior (ash hour 11) (ash minute 5) second)")
   ;; -- the compression choice --------------------------------------------
   (list "compress-entry always stores"
         "(if (< (length deflated) (length raw))
        (values +method-deflate+ deflated)"
         "(if nil
        (values +method-deflate+ deflated)")
   (list "deflate uses the zlib wrapper"
         "(salza2:compress-data data 'salza2:deflate-compressor)"
         "(salza2:compress-data data 'salza2:zlib-compressor)")
   ;; -- the header fields -------------------------------------------------
   (list "the local header's compressed size is the content size"
         "(put-u32 out (length stored))"
         "(put-u32 out (length body))")
   (list "the name length is counted in characters, not bytes"
         "(put-u16 out (logand #xFFFF name-length))"
         "(put-u16 out (logand #xFFFF (length path)))")
   (list "the central CRC is the compressed body's"
         "(put-u32 directory (zip-entry-crc entry))"
         "(put-u32 directory (zip-entry-compressed entry))")
   (list "the UTF-8 name flag is not set"
         "(put-u16 out +flag-utf8+)"
         "(put-u16 out 0)")
   ;; -- the entry ceiling -------------------------------------------------
   ;; NOT `(> (+ 1 count) max)` - that is logically IDENTICAL to `(>= count max)`
   ;; for integers, so it survives as a false mutant and proves nothing. `>` is
   ;; the real off-by-one: it admits 65536 entries and lets the EOCD count wrap
   ;; to zero, which nothing else reaches.
   (list "the entry ceiling is off by one (admits 65536)"
         "(when (>= (zip-writer-count writer) *max-entries*)"
         "(when (> (zip-writer-count writer) *max-entries*)")
   ;; -- the reader --------------------------------------------------------
   (list "the reader skips the uncompressed-length check"
         "(unless (= (length body) uncompressed)"
         "(unless t")
   (list "the reader skips the CRC check"
         "(unless (= actual crc)"
         "(unless t")
   (list "the EOCD search runs forwards"
         "(loop for at downfrom (- (length bytes) 22) to 0"
         "(loop for at from 0 to (- (length bytes) 22)")))

;; ALL THIRTEEN ARE CAUGHT, measured in three chunks of 0..5, 5..9, 9..13:
;;   5/5, 4/4, 4/4.
;;
;; A chunk is selected by two command-line numbers after --script
;; (`mutation-zip.lisp 5 9`); with none, everything runs. One process running all
;; thirteen reloads the 72 KB packers module twelve times and takes long enough
;; that a shell may background it and lose the transcript.
(let ((args (uiop:command-line-arguments)))
  (when (>= (length args) 2)
    (setf *mutations* (subseq *mutations*
                              (parse-integer (first args))
                              (min (length *mutations*)
                                   (parse-integer (second args)))))))

(defparameter *survivors* '())

(format t "~&mutation check: ~a mutations against ~a~%" (length *mutations*) *zip-source*)

(unwind-protect
     (dolist (mutation *mutations*)
       (destructuring-bind (label from to) mutation
         (apply-mutation from to)
         (reload-module)
         (let ((verdict (run-gate-quietly)))
           (if (eq verdict t)
               (progn (push label *survivors*)
                      (format t "  SURVIVED  ~a~%" label))
               (format t "  caught    ~a~%" label)))))
  (restore-source)
  (reload-module))

(let ((verdict (run-gate-quietly)))
  (format t "~&restored module gate: ~a~%" (if (eq verdict t) "PASS" "FAIL"))
  (format t "~&mutation check: ~a/~a mutations caught~%"
          (- (length *mutations*) (length *survivors*)) (length *mutations*))
  (let ((ok (and (null *survivors*) (eq verdict t))))
    (format t "~&mutation check: ~a~%" (if ok "PASS" "FAIL"))
    (finish-output)
    (sb-ext:exit :code (if ok 0 1))))
