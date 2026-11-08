;;;; run-jscbytecode.lisp — run the cached-bytecode module's gate and exit 0/1.
;;;;
;;;; Each load step is its OWN top-level form: LOAD reads one form at a time, so
;;;; a form naming `vovas.engine.jscbytecode:` before the system that defines the
;;;; package has loaded dies with "package does not exist" - which reads like a
;;;; broken port rather than a load-order mistake.
;;;;
;;;; Usage: sbcl --script tools/cl/engine/wip/run-jscbytecode.lisp

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd
 (truename "tools/cl/vovas-engine.asd"))

(asdf:load-asd
 (truename "tools/cl/engine/jscbytecode.asd"))

(asdf:load-system :vovas-engine.jscbytecode)

(let ((ok (vovas.engine.gate::run-jscbytecode-gate :verbose t)))
  (format t "~&~%jsc-bytecode gate: ~a~%" (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
