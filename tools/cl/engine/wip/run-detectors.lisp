;;;; run-detectors.lisp — run the layer detector's gate and exit 0/1.
;;;;
;;;; Each load step is its OWN top-level form on purpose. LOAD reads one form
;;;; at a time, so a form mentioning `vovas.engine.detectors:` before the system
;;;; that defines the package has been loaded dies with "package does not
;;;; exist" - which reads like a broken port rather than a load-order mistake.
;;;;
;;;; Usage: sbcl --script tools/cl/engine/wip/run-detectors.lisp

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd
 (truename "tools/cl/vovas-engine.asd"))

(asdf:load-asd
 (truename "tools/cl/engine/detectors.asd"))

(asdf:load-system :vovas-engine.detectors)

(let ((ok (vovas.engine.gate::run-detectors-gate :verbose t)))
  (format t "~&~%detectors gate: ~a~%" (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
