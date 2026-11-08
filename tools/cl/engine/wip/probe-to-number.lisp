;;;; probe-to-number.lisp — measure to-number against js_string_to_number.
;;;;
;;;; An agent reported that to-number does not port js_string_to_number: it falls
;;;; back to READ-FROM-STRING with an error->0 handler, so every non-numeric string
;;;; answers 0 where the Rust answers NaN. This prints both columns so the claim
;;;; is evidence rather than an assertion.
;;;;
;;;; It matters because `+(![]+[])` in a JSFuck program is ToNumber("false"), and
;;;; the shipped engine answers NaN while the port answers 0 - so the JSFuck
;;;; interpreter would compute a different string from the same source.

;;; Loads util + number DIRECTLY rather than :vovas-engine. The full system
;;; includes transforms, which a parallel agent is actively editing; a probe that
;;; cannot run because of an unrelated half-written file is not evidence, and an
;;; earlier run of this one reported "1 of 36 wrong" against exactly that noise.
(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode")
              :silent t)
(dolist (f '("package" "util" "number"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/pn-~a.fasl" f))))

(defparameter *cases*
  ;; (input . what the RUST answers, from jsnumber.rs's js_string_to_number)
  ;;
  ;; EVERY DECIMAL IS WRITTEN AS A DOUBLE (`d0`). A plain numeral like 0.001 is a
  ;; SINGLE-FLOAT in Lisp, and widening it to double answers
  ;; 0.0010000000474974513d0 - a DIFFERENT value from the one the parser produces
  ;; for "0.001". That made a correct case report as wrong, and it would silently
  ;; corrupt any float expectation written without the suffix.
  '(("" . 0d0)
    ("   " . 0d0)
    ("0" . 0d0) ("1" . 1d0) ("-1" . -1d0) ("+1" . 1d0)
    ("12.5" . 12.5d0) (".5" . 0.5d0) ("5." . 5d0)
    ("1e3" . 1000d0) ("1E3" . 1000d0) ("1e+3" . 1000d0) ("1e-3" . 0.001d0)
    ("0x1f" . 31d0) ("0X1F" . 31d0) ("-0x10" . -16d0)
    ("Infinity" . :inf) ("-Infinity" . :-inf) ("+Infinity" . :inf)
    ("NaN" . :nan)
    ("1e1000" . :inf)
    ;; the shapes that must be NaN
    ("false" . :nan) ("true" . :nan) ("undefined" . :nan) ("null" . :nan)
    ("abc" . :nan) ("1,2" . :nan) ("0xzz" . :nan) ("0x" . :nan)
    ("1e" . :nan) ("1e+" . :nan) ("- 1" . :nan) (" " . 0d0)
    (" " . 0d0) ("1 2" . :nan) ("--1" . :nan)))

(defun describe-value (v)
  "Normalise a value for COMPARISON, not for display.

The expected column is written as plain Lisp numerals, so `12.5` in the table is
a RATIONAL and `12.5d0` from the port is a DOUBLE. Comparing them is false even
though the numbers are equal, which made three correct cases look wrong. Coercing
both sides to double-float (and normalising NaN / infinity to keywords) is what
makes the comparison about the value."
  (cond ((sb-ext:float-nan-p v) :nan)
        ((sb-ext:float-infinity-p v) (if (plusp v) :inf :-inf))
        (t (coerce v 'double-float))))

(defun normalise-want (w)
  "The expected value in the same shape `describe-value` produces."
  (if (keywordp w) w (coerce w 'double-float)))

(defun same-value-p (got want)
  "Numerically equal, NOT `equal`.

`equal` on floats compares representation, so a value coerced from a rational and
the same value parsed from text compare UNEQUAL even when their bit patterns are
identical - which is how a correct case reported as wrong here. Numbers are
compared with `=`, and the two keyword sentinels for NaN and infinity with `eq`."
  (cond ((and (keywordp got) (keywordp want)) (eq got want))
        ((or (keywordp got) (keywordp want)) nil)
        (t (= got want))))

(let ((bad 0))
  (format t "~&~%~10a  ~8a  ~8a  ~a~%" "input" "want" "got" "verdict")
  (dolist (case *cases*)
    (let* ((input (car case))
           (want (cdr case))
           (got (describe-value (vovas.engine.number:to-number input)))
           (ok (same-value-p got (normalise-want want))))
      (unless ok (incf bad))
      (format t "~10a  ~8a  ~8a  ~a~%"
              (format nil "~s" input) want got (if ok "ok" "*** WRONG ***"))))
  (format t "~&~%~a of ~a cases wrong~%" bad (length *cases*))
  (sb-ext:exit :code (if (zerop bad) 0 1)))
