;;;; run-beautify.lisp — run the beautify gate and exit 0 on pass, 1 on fail.
;;;;
;;;;     sbcl --script tools/cl/engine/wip/run-beautify.lisp
;;;;
;;;; Each form is separate on purpose (contract rule 1): LOAD reads one top-level
;;;; form at a time, so any form that NAMES a package must come after the form
;;;; that loads the system. A `(progn (require :asdf) ... :vovas.engine.gate/x)`
;;;; would die at read time with "package does not exist" before anything ran.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

;; Both system definitions must be REGISTERED, not just the module's: the
;; module depends on `vovas-engine`, and ASDF resolves that dependency by
;; searching its registry. Loading only beautify.asd fails with
;; "Component \"vovas-engine\" not found" long before any code runs.
(asdf:load-asd
 (truename (merge-pathnames "tools/cl/vovas-engine.asd"
                            (uiop:getcwd))))

(asdf:load-asd
 (truename (merge-pathnames "tools/cl/engine/beautify.asd"
                            (uiop:getcwd))))

(asdf:load-system :vovas-engine.beautify)

;; Force a recompile of a stale fasl: without this an edit to beautify.lisp is
;; silently ignored when ASDF decides the fasl is current, and the gate happily
;; reports the previous build's results.
(asdf:compile-system :vovas-engine.beautify :force t)

(let ((ok (vovas.engine.gate::run-beautify-gate :verbose t)))
  (format t "~&~%beautify gate: ~a~%" (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
