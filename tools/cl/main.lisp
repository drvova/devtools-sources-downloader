;;;; main.lisp — CLI dispatch. Also usable as the saved-image toplevel.

(in-package :vovas.tools)

(defun print-usage ()
  (format t "usage: vovas <command>~@
  smoke           end-to-end selftest of the CDP client~@
  engine [name] [args]~@
                  list every callable engine function, or call one with a~@
                  JSON argument array and print its answer~@
  unpack <capture.json> [--out DIR]~@
                  run the export engine over a capture and write the files~@
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
          ((string= cmd "smoke")
           (if (smoke-test) 0 1))
          ((string= cmd "engine")
           (engine-command (rest args)))
          ((string= cmd "unpack")
           (unpack-command (rest args)))
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
