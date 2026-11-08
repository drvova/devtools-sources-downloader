(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)
(let* ((nbsp (string (code-char #xA0)))
       (t1 (concatenate 'string "a(" nbsp "/)/ g)"))
       (t2 "a( /)/ g)"))
  (format t "~&t1 chars: ~s~%" (map 'list #'char-code t1))
  (format t "t1 balanced: ~a~%" (vovas.engine.scanner:find-balanced t1 1))
  (format t "t2 balanced: ~a~%" (vovas.engine.scanner:find-balanced t2 1))
  ;; walk manually
  (format t "regex-start at 2 (nbsp) = ~a~%"
          (vovas.engine.scanner::regex-start-p t1 2))
  (format t "regex-start at 2 (space)= ~a~%"
          (vovas.engine.scanner::regex-start-p t2 2))
  (format t "skip-regex t1 from 2 = ~a~%" (vovas.engine.scanner::skip-regex t1 2))
  (format t "skip-regex t2 from 2 = ~a~%" (vovas.engine.scanner::skip-regex t2 2)))
(finish-output)
