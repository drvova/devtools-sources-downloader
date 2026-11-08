;;;; probe-packers-empty-word.lisp — the empty-word substitution, isolated.
;;;;
;;;; The suite reports "unpack_with keeps the token at an empty word": expected
;;;; "a 1", got "a ". Reading the code, the guard `(plusp (length ...))` is
;;;; present, so either base-decode-token mis-indexes, or the words list is not
;;;; what the probe thinks. This prints every intermediate so the answer is
;;;; visible rather than inferred.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(let ((payload "0 1")
      (base 4)
      (words '("a" "")))
  (format t "~&payload=~s base=~a words=~s~%" payload base words)
  (format t "words count = ~a~%" (length words))
  (dolist (tok '("0" "1"))
    (format t "  token ~s -> index ~a~%" tok
            (vovas.engine.packers::base-decode-token tok base)))
  (format t "unpack-with => ~s~%" (vovas.engine.packers::unpack-with payload base words))
  (format t "expected    => \"a 1\" (token kept at an empty word)~%")
  ;; the sibling probes for comparison
  (format t "~%past-the-end => ~s (expect \"10 d\")~%"
          (vovas.engine.packers::unpack-with "10 3" 4 '("a" "b" "c" "d")))
  (format t "normal       => ~s (expect \"a b\")~%"
          (vovas.engine.packers::unpack-with "0 1" 4 '("a" "b"))))
(finish-output)
