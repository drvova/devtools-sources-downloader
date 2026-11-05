;;;; run.lisp — dev entry point.
;;;;   sbcl --script tools/cl/run.lisp build|check|pack|smoke|version
;;;;   sbcl --load tools/cl/run.lisp   (interactive REPL with everything loaded)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((dir (uiop:pathname-directory-pathname
            (uiop:truename* (or *load-pathname* (uiop:getcwd))))))
  (push dir asdf:*central-registry*))

(ql:quickload :vovas-tools :silent t)

(if (uiop:command-line-arguments)
    (uiop:quit (vovas.tools:main))
    (progn
      (format t "; vovas-tools loaded.~%")
      (format t "; try: (vcdp:smoke-test)  (vcdp:launch)  (vcdp:tabs)  (vcdp:eval* \"document.title\")~%")
      (values)))
