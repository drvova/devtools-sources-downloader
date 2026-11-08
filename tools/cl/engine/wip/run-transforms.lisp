;;;; run-transforms.lisp — load the engine and run the peel chain's gate.
;;;;
;;;;   sbcl --script tools/cl/engine/wip/run-transforms.lisp
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
;;;;
;;;; The gate file is compiled into the system by transforms.asd, so nothing is
;;;; compiled here: this runner must not leave a .fasl behind.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))

(asdf:load-system :vovas-engine)

(asdf:load-asd (truename "tools/cl/engine/transforms.asd"))

(asdf:load-system :vovas-engine.transforms)

(let ((ok (handler-case (vovas.engine.gate::run-transforms-gate :verbose t)
            (error (e)
              (format t "~&TRANSFORMS GATE ERROR: ~a~%" e)
              nil))))
  (format t "~&~a~%" (if ok "PASS transforms" "FAIL transforms"))
  (sb-ext:exit :code (if ok 0 1)))
