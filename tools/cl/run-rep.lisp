(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "tools/cl/vovas-engine.asd" (uiop:getcwd)))
(asdf:load-system :vovas-engine)
(dolist (f '(vovas.engine.gate::run-report-gate
             vovas.engine.gate::run-report-table-gate))
  (handler-case (format t "~&~a -> ~a~%" f (funcall f))
    (error (e) (format t "~&~a ERROR: ~a~%" f e))))
