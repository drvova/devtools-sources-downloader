;;;; Does `seam/real-jsfuck-decoder-answers-nil` actually have teeth?
;;;;
;;;; The new assertion is inside a branch that only runs when the sibling is
;;;; loaded, so a green main-gate run cannot prove it works. This loads the
;;;; sibling, then REPLACES its exported decoder with one that always answers a
;;;; string, and requires the gate to go RED. If it stays green the assertion is
;;;; decorative and must be rewritten.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)
(asdf:load-asd (truename "tools/cl/engine/jsfuck.asd"))
(asdf:load-system :vovas-engine.jsfuck)
(asdf:load-asd (truename "tools/cl/engine/transforms.asd"))
(asdf:load-system :vovas-engine.transforms)

(defun quiet-gate ()
  (handler-case
      (let ((*standard-output* (make-broadcast-stream)))
        (vovas.engine.gate::run-transforms-gate :verbose nil))
    (error () nil)))

(format t "~&baseline (real decoder) -> ~a~%" (quiet-gate))

(let ((original (symbol-function 'vovas.engine.jsfuck:decode-jsfuck)))
  ;; a decoder that always "succeeds", which is precisely what the shipped one
  ;; did NOT do on the oracle input
  (setf (symbol-function 'vovas.engine.jsfuck:decode-jsfuck)
        (lambda (text)
          (declare (ignore text))
          (list :value "(always-decoded)" :captured nil)))
  (format t "mutant (always decodes) -> ~a  (want NIL)~%"
          (quiet-gate))
  (setf (symbol-function 'vovas.engine.jsfuck:decode-jsfuck) original))

(format t "~&restored -> ~a~%" (quiet-gate))
