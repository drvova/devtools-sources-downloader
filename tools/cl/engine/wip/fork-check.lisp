;;;; fork-check.lisp — is zip's failure in the code or in the load?
;;;;
;;;; Three consecutive runs of the same unchanged gate produced three DIFFERENT
;;;; failures (deflate size, then name flag, then a clean pass). The module has no
;;;; randomness and no clock, so the variance cannot come from the code. The
;;;; remaining candidate is the LOAD: ASDF's cache here is shared with agents that
;;;; are concurrently compiling :vovas-engine, and a run that loads a half-written
;;;; fasl reports the other process's failure as its own.
;;;;
;;;; This compiles every component into a PRIVATE directory under the system temp
;;;; dir and loads from there, so the shared cache is never consulted.
;;;;
;;;; THE DISPATCH IS ITS OWN TOP-LEVEL FORM. LOAD reads one form at a time, so a
;;;; form mentioning vovas.engine.gate: in the SAME form as the compile loop dies
;;;; at read time with "Package VOVAS.ENGINE.GATE does not exist" - the trap this
;;;; repo has hit three times.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "chipz" "salza2"
                "cl-unicode")
              :silent t)

(defparameter *fork-dir*
  (merge-pathnames (format nil "vovas-fork-~a/" (get-universal-time))
                   (uiop:temporary-directory)))

(defun fork-load ()
  (ensure-directories-exist *fork-dir*)
  (format t "~&private fasl dir: ~a~%" *fork-dir*)
  (dolist (f '("package" "util" "number" "transforms" "decoders" "scanner"
               "digest" "bundler" "text" "beautify" "detectors" "sourcemaps"
               "packers" "wasm" "jscbytecode" "v8codecache" "zip" "gate"
               "gate-beautify" "gate-detectors" "gate-sourcemaps" "gate-packers"
               "gate-wasm" "gate-jscbytecode" "gate-v8codecache" "gate-zip"))
    (let ((src (format nil "tools/cl/engine/~a.lisp" f))
          (out (merge-pathnames (format nil "~a.fasl" f) *fork-dir*)))
      (compile-file src :output-file out)
      (load out))))

(fork-load)

(format t "~&loaded from the private dir; running the zip gate three times in ONE image~%")
(dotimes (i 3)
  (let ((ok (handler-case (vovas.engine.gate::run-zip-gate :verbose nil)
              (error (e)
                (format t "~&  run ~a SIGNALLED: ~a~%" (1+ i) e)
                :signalled))))
    (format t "  run ~a: ~a~%" (1+ i) (if (eq ok :signalled) "ERROR" (if ok "PASS" "FAIL")))))
(sb-ext:exit :code 0)
