;;;; verify-gates.lisp — prove every gate in the list is actually callable.
;;;;
;;;; run-all-gates holds (name . #'function) pairs. A typo in a name compiles
;;;; fine - `#'undefined-thing` is a legitimate form - and only surfaces as a
;;;; generic ERROR verdict when that gate finally runs. An agent caught exactly
;;;; this risk in its own prose report: it had written the hyphenated
;;;; "run-jsc-byte-code-gate" while the real symbol is "run-jscbytecode-gate".
;;;;
;;;; NOT fboundp: `#'f` stores the FUNCTION OBJECT, so the cdr is a function and
;;;; fboundp rejects it ("Invalid function name"). A function-designator is
;;;; valid when it is either a symbol naming a definition or a function, and that
;;;; is what this checks.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(defun callable-designator-p (thing)
  (or (functionp thing)
      (and (symbolp thing) (fboundp thing))))

(let ((all-ok t)
      (count 0))
  (dolist (gate (vovas.engine.gate::gate-list))
    (incf count)
    (let ((name (car gate))
          (fn (cdr gate)))
      (cond
        ((callable-designator-p fn)
         (format t "~&  ok       ~a -> ~a~%"
                 name
                 (if (functionp fn) "a function object" fn)))
        (t
         (setf all-ok nil)
         (format t "~&  MISSING  ~a -> ~s is not callable~%" name fn)))))
  (format t "~&~%~a gate entries checked, ~a~%"
          count
          (if all-ok "every entry is callable" "SOME ENTRIES ARE NOT CALLABLE"))
  (sb-ext:exit :code (if all-ok 0 1)))
