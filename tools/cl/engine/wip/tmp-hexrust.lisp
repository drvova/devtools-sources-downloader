(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode") :silent t)
(dolist (f '("package" "util" "number"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/hx-~a.fasl" f))))
(dolist (s '("0xFFFFFFFFFFFFFFFF" "0x10000000000000000" "0xFFFFFFFFFFFFFFFFF"
             "0xfffffffffffffffff" "0x7FFFFFFFFFFFFFFF" "-0x10000000000000000"
             "0x00000000000000000001"))
  (format t "~&~a -> ~s~%" s (vovas.engine.number:to-number s)))
