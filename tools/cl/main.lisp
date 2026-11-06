;;;; main.lisp — CLI dispatch. Also usable as the saved-image toplevel.

(in-package :vovas.tools)

(defun print-usage ()
  (format t "usage: vovas <command>~@
  build           wasm engine + bundle, then verify dist/~@
  check [--fast]  the gate (lint, cargo test, clippy; --fast skips js/build/e2e)~@
  pack            zip dist/ into dist-<version>.zip~@
  smoke           end-to-end selftest of the CDP client~@
  panel           verify the extension's DevTools panel registers~@
  download [url]  press Download All in the real panel and verify the archive~@
  version         print versions~%~
~%~
REPL use: sbcl --load tools/cl/run.lisp, then (vcdp:launch) (vcdp:tabs)~@
(vcdp:use \"example\") (vcdp:eval* \"document.title\") (vcdp:shot)~%"))

(defun main ()
  "Dispatch on the first command-line argument. Returns a process exit code."
  (let* ((args (uiop:command-line-arguments))
         (cmd (first args)))
    (handler-case
        (cond
          ((null cmd)
           (print-usage)
           2)
          ((string= cmd "build")
           (build))
          ((string= cmd "check")
           (check :fast (member "--fast" (rest args) :test #'string=)))
          ((string= cmd "pack")
           (pack))
          ((string= cmd "smoke")
           (if (smoke-test) 0 1))
          ((string= cmd "panel")
           (panel-check))
          ((string= cmd "download")
           (download-check :url (or (second args) "https://example.com")))
          ((string= cmd "version")
           (format t "vovas-tools on ~a ~a (~a)~%"
                   (lisp-implementation-type)
                   (lisp-implementation-version)
                   (machine-type))
           0)
          (t
           (format t "[vovas] unknown command: ~a~%" cmd)
           (print-usage)
           2))
      (error (e)
        (format t "[vovas] error: ~a~%" e)
        1))))
