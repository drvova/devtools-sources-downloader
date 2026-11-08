;;;; isolated-run.lisp — run one gate with a PRIVATE ASDF cache.
;;;;
;;;; Two agents are concurrently compiling :vovas-engine while I measure, and
;;;; they share ASDF's cache with me. A run that loads a half-written fasl
;;;; reports failures that belong to the other process's compile, not to my code -
;;;; which is exactly what three identical zip runs producing three DIFFERENT
;;;; failures looks like.
;;;;
;;;; ASDF's cache root is a special variable, so binding it gives this run its own
;;;; directory and makes the measurement independent of whoever else is building.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")

(let ((asdf:*central-registry* asdf:*central-registry*)
      ;; a private cache under the system temp dir, unique per run
      (asdf/cache:*cache-root-directory*
        (merge-pathnames (format nil "vovas-isolated-~a/"
                                 (get-universal-time))
                         (uiop:temporary-directory))))
  (format t "~&isolated cache: ~a~%" asdf/cache:*cache-root-directory*)
  (asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
  (asdf:load-system :vovas-engine)
  (let ((gate (find-symbol (or (second uiop:*command-line-arguments*)
                               "RUN-ZIP-GATE")
                           :vovas.engine.gate)))
    (format t "~&gate: ~a~%" gate)
    (let ((ok (funcall gate)))
      (format t "~&VERDICT: ~a~%" (if ok "PASS" "FAIL"))
      (sb-ext:exit :code (if ok 0 1)))))
