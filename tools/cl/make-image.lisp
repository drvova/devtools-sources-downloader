;;;; make-image.lisp — build the standalone executable:
;;;;   sbcl --noinform --non-interactive --script tools/cl/make-image.lisp
;;;; Produces tools/cl/vovas.exe; the image finds the repo root by walking up
;;;; from its own location, so it works from anywhere inside the checkout.

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))

(let ((dir (uiop:pathname-directory-pathname
            (uiop:truename* (or *load-pathname* (uiop:getcwd))))))
  (push dir asdf:*central-registry*))

(ql:quickload :vovas-tools :silent t)

(sb-ext:save-lisp-and-die
 (uiop:merge-pathnames* "vovas.exe"
                        (uiop:pathname-directory-pathname
                         (uiop:truename* *load-pathname*)))
 :executable t
 :toplevel (lambda () (uiop:quit (vovas.tools:main))))
