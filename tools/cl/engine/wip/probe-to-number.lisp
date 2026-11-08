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

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(defparameter *cases*
  ;; (input . what the RUST answers, from jsnumber.rs's js_string_to_number)
  '(("" . 0)
    ("   " . 0)
    ("0" . 0) ("1" . 1) ("-1" . -1) ("+1" . 1)
    ("12.5" . 12.5) (".5" . 0.5) ("5." . 5)
    ("1e3" . 1000) ("1E3" . 1000) ("1e+3" . 1000) ("1e-3" . 0.001)
    ("0x1f" . 31) ("0X1F" . 31) ("-0x10" . -16)
    ("Infinity" . :inf) ("-Infinity" . :-inf) ("+Infinity" . :inf)
    ("NaN" . :nan)
    ("1e1000" . :inf)
    ;; the shapes that must be NaN
    ("false" . :nan) ("true" . :nan) ("undefined" . :nan) ("null" . :nan)
    ("abc" . :nan) ("1,2" . :nan) ("0xzz" . :nan) ("0x" . :nan)
    ("1e" . :nan) ("1e+" . :nan) ("- 1" . :nan) (" " . 0)
    (" " . 0) ("1 2" . :nan) ("--1" . :nan)))

(defun describe-value (v)
  (cond ((sb-ext:float-nan-p v) :nan)
        ((sb-ext:float-infinity-p v) (if (plusp v) :inf :-inf))
        (t (if (= v (truncate v)) (truncate v) v))))

(let ((bad 0))
  (format t "~&~%~10a  ~8a  ~8a  ~a~%" "input" "want" "got" "verdict")
  (dolist (case *cases*)
    (let* ((input (car case))
           (want (cdr case))
           (got (describe-value (vovas.engine.number:to-number input)))
           (ok (equal got want)))
      (unless ok (incf bad))
      (format t "~10a  ~8a  ~8a  ~a~%"
              (format nil "~s" input) want got (if ok "ok" "*** WRONG ***"))))
  (format t "~&~%~a of ~a cases wrong~%" bad (length *cases*))
  (sb-ext:exit :code (if (zerop bad) 0 1)))
