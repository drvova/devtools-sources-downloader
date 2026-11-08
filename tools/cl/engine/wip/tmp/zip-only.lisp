(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(ql:quickload :cl-unicode :silent t)
(asdf:load-system :vovas-engine)

(asdf:load-asd (truename "tools/cl/engine/zip.asd"))
(asdf:load-system :vovas-engine.zip)

(let ((ok (vovas.engine.gate::run-zip-gate :verbose t)))
  (format t "~&~%zip gate: ~a~%" (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
