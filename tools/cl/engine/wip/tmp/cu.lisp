(load "C:/Users/bigmo/quicklisp/setup.lisp")
(handler-case (progn (ql:quickload :cl-unicode :silent t) (format t "cl-unicode OK~%"))
  (error (e) (format t "FAIL ~a~%" e)))
(format t "pkg? ~a~%" (find-package :cl-unicode))
(format t "has-property? ~a~%"
        (and (find-package :cl-unicode)
             (multiple-value-bind (s st) (find-symbol "HAS-PROPERTY" :cl-unicode)
               (list s st))))
