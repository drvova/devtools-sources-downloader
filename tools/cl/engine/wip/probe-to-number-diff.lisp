;;;; probe-to-number-diff.lisp — DIFFERENTIAL probe: the Lisp port vs real Rust.
;;;;
;;;; The sibling probe-to-number.lisp compares the port against expectations
;;;; TYPED INTO A LISP TABLE. Those expectations are a human reading of
;;;; jsnumber.rs, and a misreading there passes on both sides. That is exactly how
;;;; the hex-overflow divergence survived its 36 cases: `0x10000000000000000`
;;;; overflows u64, so `u64::from_str_radix` fails and Rust answers NaN, while the
;;;; port's `parse-integer` answered 1.8e19 — and no table entry asked.
;;;;
;;;; This probe holds NO expectations. It pipes a corpus into
;;;; `to-number-oracle.exe` (js_string_to_number compiled standalone by rustc —
;;;; see tools/cl/engine/wip/out/to-number-oracle.rs) and runs the same corpus
;;;; through the port, then reports every disagreement. The Rust is the
;;;; specification, so nothing here can drift from it.
;;;;
;;;; The corpus deliberately includes shapes no encoder emits. The purpose is to
;;;; find where the two differ, not to demonstrate agreement on safe inputs.
;;;;
;;;; Rebuild the oracle with:
;;;;   rustc -O -o tools/cl/engine/wip/out/to-number-oracle.exe \
;;;;         tools/cl/engine/wip/out/to-number-oracle.rs
;;;;
;;;; Run: sbcl --script tools/cl/engine/wip/probe-to-number-diff.lisp
;;;; Exit 0 when the columns are identical.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

;; util + number loaded DIRECTLY, not through :vovas-engine: the full system pulls
;; in transforms, which a parallel agent edits, and a probe that cannot run because
;; of an unrelated half-written file is not evidence.
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode")
              :silent t)

(dolist (f '("package" "util" "number"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/pd-~a.fasl" f))))

(defparameter *oracle*
  "tools/cl/engine/wip/out/to-number-oracle.exe")

(defparameter *scratch*
  "C:/Users/bigmo/AppData/Local/Temp/pd-cases.txt")

(defparameter *corpus*
  (list
   ;; --- trimming, empty ---------------------------------------------------
   "" " " "   " "\t" "\n" "\r" (string #\u000B) (string #\u000C)
   (string #\u00A0) (string #\uFEFF) (string #\u1680) (string #\u3000)
   (string #\u2028) (string #\u2029) (string #\u202F) (string #\u205F)
   (concatenate 'string (string #\u00A0) "1" (string #\u00A0))
   (concatenate 'string (string #\uFEFF) "42")
   " \t\n 7 \r\n "
   ;; --- signs -------------------------------------------------------------
   "0" "-0" "+0" "1" "-1" "+1" "007" "-007" "+007"
   "- 1" "+ 1" "--1" "++1" "-+1" "+-1" "-" "+" "-." "+."
   ;; --- plain decimals ----------------------------------------------------
   "12.5" ".5" "5." "0.5" ".0" "0.0" "1.0" "-0.5" "-.5" "-5."
   "." "-." "0..5" "1.2.3" "1..2"
   "123456789012345678901234567890"
   "0.0000001" "0.000001" "1e-7"
   ;; --- exponent forms ----------------------------------------------------
   "1e3" "1E3" "1e+3" "1e-3" ".5e2" "5.e2" "1.e3" ".e3"
   "1e" "1e+" "1e-" "1ee3" "1e3e" "1e3.5" "1e+e3" "e3"
   "1e1000" "-1e1000" "+1e1000" "1e-1000" "1E1000" "1e999999999999999999"
   "1e+308" "1e309" "1e-323" "1e-324" "5e-324"
   ;; --- named values ------------------------------------------------------
   "Infinity" "-Infinity" "+Infinity" "infinity" "INFINITY"
   "Inf" "inf" "-Inf" "NaN" "-NaN" "+NaN" "nan" "NAN"
   "Infinitye" "NaN1" "Infinity1" "infin"
   ;; --- hex ---------------------------------------------------------------
   "0x1f" "0X1F" "0x1F" "-0x10" "+0x10" "0x0" "0x00" "0X"
   "0x" "0xzz" "0xg" "0x1g" "0x 1" "0 x1" "00x1" "0xx1"
   "0x7FFFFFFFFFFFFFFF" "0xFFFFFFFFFFFFFFFF"
   ;; the overflow class: u64::from_str_radix FAILS, so Rust answers NaN
   "0x10000000000000000" "0xFFFFFFFFFFFFFFFFF" "-0x10000000000000000"
   "0x00000000000000000001" "0xfffffffffffffffff"
   ;; --- junk --------------------------------------------------------------
   "false" "true" "undefined" "null" "abc" "1,2" "1 2" "1 2 3" "1abc" "abc1"
   "1_000" "1'000" (string #\uFF11) "0x1f " " 0x1f"
   "1\n" "\n1" "1\t2" "0b101" "0o17" "1/2" "1:2" "1" "  1  "))

(defun escape-case (text)
  "Escape a case for the line protocol: backslash, newline, tab, CR.

Written with CHAR= rather than a CASE over character literals. `#\\` immediately
followed by `)` is read as the character backslash and then a CLOSING PAREN, so
the clause `(#\\) ...)` ends at the paren and the list is closed twice — an
"unmatched close parenthesis" four lines further down, which points at the wrong
place. Naming the codes sidesteps the reader entirely."
  (with-output-to-string (s)
    (loop for c across text
          for code = (char-code c)
          do (cond
               ((= code 92) (write-string "\\\\" s))
               ((= code 10) (write-string "\\n" s))
               ((= code 9) (write-string "\\t" s))
               ((= code 13) (write-string "\\r" s))
               (t (write-char c s))))))

(defun rust-column (inputs)
  "Run INPUTS through the Rust oracle via a file, answering a list of verdict
strings in order. A file rather than argv because Windows argv cannot carry a
newline and the corpus contains one."
  (with-open-file (out *scratch* :direction :output :if-exists :supersede
                            :external-format :utf-8)
    (dolist (a inputs) (write-string (escape-case a) out) (write-char #\Newline out)))
  (let ((raw (uiop:run-program (list (namestring *oracle*))
                               :input *scratch*
                               :output :string
                               :external-format :utf-8
                               :ignore-error-status t)))
    (loop for line in (uiop:split-string raw :separator '(#\Newline))
          when (plusp (length line))
            collect (subseq line 0 (or (position #\Tab line) (length line))))))

(defun lisp-verdict (value)
  "The port's answer in the same vocabulary the Rust oracle prints: BIT PATTERNS
for finite values, keywords for the non-finite shapes.

Bits, not text. A text comparison tests the two formatters as much as the two
parsers — Rust's `{:?}` prints `1000.0` where SBCL prints `1000.0d0` — and on the
first run that buried three real divergences under 36 formatting false alarms. A
bit pattern IS the value, and it keeps -0.0 distinguishable from +0.0."
  (cond
    ((sb-ext:float-nan-p value) "NAN")
    ((sb-ext:float-infinity-p value) (if (plusp value) "INF" "-INF"))
    ;; LOWERCASE to match the oracle's `{:#018x}`. `~16,'0x` prints UPPERCASE, so
    ;; an earlier version reported all 69 finite cases as different while their
    ;; bits were identical — an `equal` on text that never looked at a value.
    (t (string-downcase
        (format nil "0x~16,'0x"
                (ldb (byte 64 0) (sb-kernel:double-float-bits value)))))))

(let ((inputs *corpus*)
      (bad 0)
      (total 0)
      (rows '()))
  (let ((rust (rust-column inputs)))
    (when (/= (length inputs) (length rust))
      (format t "~&COLUMN LENGTH MISMATCH: ~a inputs, ~a rust lines~%"
              (length inputs) (length rust))
      (setf bad 1))
    (loop for input in inputs
          for want in rust
          do (let* ((got (lisp-verdict (vovas.engine.number:to-number input)))
                    (ok (string= got want)))
               (incf total)
               (unless ok (incf bad))
               (push (list input want got ok) rows)))
    (format t "~&~%~10a ~20a ~20a ~a~%" "input" "rust" "lisp" "verdict")
    (dolist (row (reverse rows))
      (format t "~10a ~20a ~20a ~a~%"
              (format nil "~s" (first row)) (second row) (third row)
              (if (fourth row) "ok" "*** WRONG ***")))
    (format t "~&~%~a of ~a cases differ~%" bad total)
    (sb-ext:exit :code (if (zerop bad) 0 1))))
