(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)
;; Every gate, via the harness's own list. A gate that throws is a FAIL, not a
;; crash, so one broken slice cannot hide the others (gate.lisp's contract).
(let ((ok (vovas.engine.gate:run-all-gates)))
  (format t "~&~%ALL GATES: ~a~%" (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
