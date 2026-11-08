(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "tools/cl/vovas-engine.asd" (uiop:getcwd)))
(asdf:load-system :vovas-engine :force :all)
(format t "~&loaded~%")
(handler-case
    (format t "~&analysis result: ~a~%"
            (vovas.engine.gate::run-analysis-gate))
  (error (e) (format t "~&ERROR: ~a~%" e)))
