;;;; compile-check.lisp — load the engine system and report every error plainly.
;;;; Used during development: it prints the condition without a backtrace so the
;;;; first real compile error is visible instead of buried under 40 frames.

(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(handler-bind ((error (lambda (e)
                        (format t "~&=== ERROR ===~%~a~%" e)
                        (sb-ext:exit :code 1))))
  (asdf:load-system :vovas-engine :force t)
  (format t "~&=== LOADED OK ===~%")
  (sb-ext:exit :code 0))
