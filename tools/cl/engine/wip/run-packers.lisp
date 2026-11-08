;;;; run-packers.lisp — load the packer module and run its gate.
;;;;
;;;;   sbcl --script tools/cl/engine/wip/run-packers.lisp
;;;;
;;;; Exit code 0 when the gate passes, 1 otherwise, so this is a CI step without
;;;; a wrapper.
;;;;
;;;; Load order is load-bearing twice over. LOAD reads and evaluates ONE
;;;; top-level form at a time, so:
;;;;   - a form mentioning `asdf:` before `(require :asdf)` dies instantly;
;;;;   - a form mentioning `vovas.engine.gate:` before the system exists reads
;;;;     the package name as a symbol in the CL package and dies with "package
;;;;     does not exist".
;;;; Every foreign-package reference therefore lives in its own late form.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))

(asdf:load-system :vovas-engine)

(asdf:load-asd (truename "tools/cl/engine/packers.asd"))

(asdf:load-system :vovas-engine.packers)

(let ((ok (handler-case (vovas.engine.gate::run-packers-gate :verbose t)
            (error (e)
              (format t "~&PACKERS GATE ERROR: ~a~%" e)
              nil))))
  (format t "~&~a~%" (if ok "PASS packers" "FAIL packers"))
  (sb-ext:exit :code (if ok 0 1)))
