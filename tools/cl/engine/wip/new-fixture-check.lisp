;;;; new-fixture-check.lisp — the two SAMPLES that changed in commit 5fe53bc.
;;;;
;;;; `bundle` went 110 -> 197 characters (the webpack map form) and
;;;; `stringArray` went 128 -> 426 (a real rotator IIFE). Both are inputs to
;;;; `detectLayers`, so both outputs had to be re-checked against the
;;;; regenerated oracle rather than assumed unchanged.
;;;;
;;;; This prints the port's answer beside the oracle's for every one of the 17
;;;; inputs, so a changed case is visible rather than inferred from a green
;;;; gate.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-system :cl-ppcre)

(asdf:load-system :com.inuoe.jzon)

(load "tools/cl/engine/package.lisp")

(load "tools/cl/engine/util.lisp")

(load "tools/cl/engine/gate.lisp")

(load "tools/cl/engine/detectors.lisp")

(load "tools/cl/engine/gate-detectors.lisp")

(in-package :vovas.engine.gate)

(let* ((sources (detector-sources))
       (expectations (detect-layers-expectations))
       (mismatches 0))
  (dolist (key '("bundle" "stringArray" "evalLayer" "packed" "jsfuck" "plain"))
    (let* ((text (gethash key sources))
           (want (and (gethash key expectations)
                      (oracle-findings (gethash key expectations))))
           (got (with-fixture-seams
                  key
                  (lambda () (safe-detect-layers text)))))
      (unless (findings= (if (listp got) got '()) (or '() want))
        (incf mismatches))
      (format t "~&~a (~a chars)~%  got  ~a~%  want ~a~%"
              key (length text)
              (if (listp got) (findings->string got) got)
              (findings->string want))))
  (format t "~&~%mismatches in this sample: ~a~%" mismatches)
  (format t "verdict: ~a~%" (if (zerop mismatches) "MATCH" "MISMATCH"))
  (finish-output))
