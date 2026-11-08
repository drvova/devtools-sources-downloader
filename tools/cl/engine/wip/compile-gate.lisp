(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)
(handler-case (compile-file "tools/cl/engine/gate.lisp"
                            :output-file "C:/Users/bigmo/AppData/Local/Temp/g.fasl")
  (error (e) (format t "### ~a~%" e)))
(finish-output)
