;;;; run-sourcemaps.lisp — load the sourcemaps slice and run its gate.
;;;;
;;;;   sbcl --script tools/cl/engine/wip/run-sourcemaps.lisp
;;;;
;;;; Exit code 0 when the gate passes, 1 otherwise, so this is usable as a CI
;;;; step with no wrapper.
;;;;
;;;; The four load steps are separate TOP-LEVEL forms on purpose. `load` reads
;;;; and evaluates one form at a time, so a form that mentions
;;;; `vovas.engine.gate:` would intern those symbols before the system existed
;;;; and the file would die with "package does not exist". Keeping each load in
;;;; its own earlier form is what makes the read order correct - see rule 1 in
;;;; wip/CONTRACT.md.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))

(asdf:load-system :vovas-engine)

(asdf:load-asd (truename "tools/cl/engine/sourcemaps.asd"))

(asdf:load-system :vovas-engine.sourcemaps)

(let ((ok (handler-case
              (vovas.engine.gate::run-sourcemaps-gate)
            (error (e)
              (format t "~&~%== sourcemaps gate ERRORED ==~%~a~%" e)
              ;; The backtrace is printed rather than swallowed: a gate that
              ;; dies mid-comparison must not read as a partial pass.
              (sb-debug:print-backtrace :count 30)
              nil))))
  (format t "~&~%sourcemaps gate: ~a~%" (if ok "PASS" "FAIL"))
  (sb-ext:exit :code (if ok 0 1)))
