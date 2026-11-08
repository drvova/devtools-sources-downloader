;;;; probe-bad-gate-name.lisp — does a wrong gate name fail at COMPILE time?
;;;;
;;;; This matters for how much the verify-gates check is worth. `#'name` is a
;;;; compile-time reference: if a mangled name fails to compile, then the fact
;;;; that the system LOADS at all is itself the proof, and a run-time callable
;;;; check adds little. If it compiles and fails only when called, then the
;;;; run-time check is the one that earns its place.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(format t "~&== compiling a defun that references a mangled gate name ==~%")
(handler-case
    (multiple-value-bind (fn warnings-p failure-p)
        (compile nil '(lambda () (list (cons "x" #'run-jsc-byte-code-gate))))
      (declare (ignore fn))
      (format t "  compiled. warnings=~a failure=~a~%" warnings-p failure-p)
      (format t "  => a wrong name does NOT stop compilation~%"))
  (warning (w)
    (format t "  WARNING: ~a~%" w))
  (error (e)
    (format t "  ERROR: ~a~%" e)
    (format t "  => a wrong name is caught at compile time~%")))

(format t "~%== and if compiled, does CALLING it fail? ==~%")
(handler-case
    (let ((fn (compile nil '(lambda () (cons "x" #'run-jsc-byte-code-gate)))))
      (funcall fn)
      (format t "  called fine - which would mean the name resolved~%"))
  (error (e)
    (format t "  call-time ERROR: ~a~%" (type-of e))))

(finish-output)
