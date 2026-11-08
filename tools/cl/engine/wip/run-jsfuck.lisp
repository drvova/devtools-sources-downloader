;;;; run-jsfuck.lisp — load the JSFuck module and run its gate.
;;;;
;;;;   sbcl --script tools/cl/engine/wip/run-jsfuck.lisp
;;;;
;;;; Exit code 0 when the gate passes, 1 otherwise, so this is a CI step with no
;;;; wrapper.
;;;;
;;;; LOAD ORDER IS LOAD-BEARING, TWICE OVER. `load` reads and evaluates ONE
;;;; top-level form at a time, so:
;;;;   - a form mentioning `asdf:` before `(require :asdf)` dies instantly;
;;;;   - a form mentioning `vovas.engine.gate:` before the system exists reads
;;;;     the package name as a symbol in the CL package and dies with "package
;;;;     does not exist".
;;;; Every foreign-package reference therefore lives in its own late form, and
;;;; nothing below is wrapped in a PROGN.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))

(asdf:load-system :vovas-engine)

(asdf:load-asd (truename "tools/cl/engine/jsfuck.asd"))

(asdf:load-system :vovas-engine.jsfuck)

;; The gate is called through its own package and NOT through `vovas.engine.gate:`
;; exports: the gate function is deliberately not exported from `package.lisp`,
;; which the integrator owns. A `::` reference is the contract the other runners
;; use, and it means a missing definition fails as UNDEFINED-FUNCTION at this
;; call rather than at load time.
(let ((ok (handler-case (vovas.engine.gate::run-jsfuck-gate :verbose t)
            (error (e)
              (format t "~&JSFUCK GATE ERROR: ~a~%" e)
              nil))))
  (format t "~&~a~%" (if ok "PASS jsfuck" "FAIL jsfuck"))
  (sb-ext:exit :code (if ok 0 1)))
