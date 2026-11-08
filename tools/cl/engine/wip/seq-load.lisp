(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner"
             "digest" "bundler" "text" "gate"))
  (format t "~&--- ~a~%" f)
  (handler-case
      (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)))
    (error (e) (format t "### ~a FAILED: ~a~%" f e) (sb-ext:exit :code 1))))
(format t "~&ALL LOADED~%")
(finish-output)
