;;;; run-engine.lisp — load the engine port and run its gates.
;;;;
;;;;   sbcl --script tools/cl/run-engine.lisp          all gates
;;;;   sbcl --script tools/cl/run-engine.lisp text     the text gate only
;;;;   sbcl --script tools/cl/run-engine.lisp probe    one-off probes
;;;;
;;;; Exit code is 0 when every gate passes, 1 otherwise, so this is usable as a
;;;; CI step without a wrapper.
;;;;
;;;; The dispatch sits in its OWN top-level form, after `(load-engine)`, and
;;;; that is load-bearing: LOAD reads and evaluates one top-level form at a
;;;; time, so a form that mentions `vovas.engine.gate:` interned its symbols
;;;; before the system existed and the file died with "package does not exist".
;;;; Keeping the load in an earlier form is what makes the read order correct.

(require :asdf)

(defparameter *engine-dir*
  (uiop:pathname-directory-pathname (or *load-truename* *default-pathname-defaults*)))

(defun load-quicklisp ()
  "Load quicklisp if it is not already available, from the standard location."
  (unless (find-package :ql)
    (let ((setup (merge-pathnames "quicklisp/setup.lisp"
                                  (user-homedir-pathname))))
      (if (probe-file setup)
          (load setup)
          (error "quicklisp not found at ~a" setup)))))

(defun load-engine ()
  (load-quicklisp)
  (asdf:load-asd (merge-pathnames "vovas-engine.asd" *engine-dir*))
  (asdf:load-system :vovas-engine))

(load-engine)

(let ((args (uiop:command-line-arguments)))
  (cond
    ((member "probe" args :test #'string=)
     (vovas.engine.gate::probe)
     (sb-ext:exit :code 0))
    (t
     (unless (vovas.engine.gate::gate-can-fail-p)
       (format t "~&FATAL: the gate harness cannot report a failure~%")
       (sb-ext:exit :code 1))
     (let ((ok (if (member "text" args :test #'string=)
                   (vovas.engine.gate:run-text-gate)
                   (vovas.engine.gate:run-all-gates))))
       (sb-ext:exit :code (if ok 0 1))))))
