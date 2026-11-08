;;;; pe6.lisp — does the suite's loaded packers behave like the source says?
;;;;
;;;; A predicate that answers correctly in one load and incorrectly in another
;;;; means two different definitions are in play. This asks the same two
;;;; questions through the umbrella system that the gate uses.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)

(let ((s "var f = function(a) { while (true) { a = a + 1; } };"))
  (format t "~&IN-SUITE looks-like-rotator-p => ~a~%"
          (vovas.engine.packers::looks-like-rotator-p s))
  (format t "IN-SUITE base-decode-token a_ 62 => ~a~%"
          (vovas.engine.packers::base-decode-token "a_" 62))
  (format t "IN-SUITE unpack-with 10 3 => ~s~%"
          (vovas.engine.packers::unpack-with "10 3" 4 '("a" "b" "c" "d"))))

(finish-output)
