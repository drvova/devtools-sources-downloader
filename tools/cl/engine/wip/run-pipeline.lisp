;;;; run-pipeline.lisp — run the pipeline gate and exit 0/1.
;;;;
;;;; Each load step is its OWN top-level form. LOAD reads one form at a time, so
;;;; a form mentioning `vovas.engine.pipeline:` before the system that defines
;;;; the package has been loaded dies with "package does not exist" — which
;;;; reads like a broken port rather than a load-order mistake.
;;;;
;;;; Usage: sbcl --script tools/cl/engine/wip/run-pipeline.lisp

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd
 (truename "tools/cl/vovas-engine.asd"))

(asdf:load-asd
 (truename "tools/cl/engine/pipeline.asd"))

(asdf:load-system :vovas-engine.pipeline)

(let ((ok (vovas.engine.gate::run-pipeline-gate :verbose t)))
  (format t "~&~%pipeline gate: ~a~%" (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
