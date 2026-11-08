(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)
(let* ((o (vovas.engine.gate::read-json-file
           "C:/Users/bigmo/Downloads/vovas-devtools-soruce-downloader/unpack-rs/tests/fixtures/stack-profile.json"))
       (name (or (second uiop:*command-line-arguments*) "nextjs-react-webpack"))
       (e (gethash name o))
       (snap (gethash "snapshot" e))
       (want (vovas.engine.gate::strip-clock-text (gethash "profileText" e)))
       (got (let ((p (vovas.engine.panel.stackprofile:analyze snap)))
              (setf (getf p :generated-at) 0)
              (vovas.engine.gate::strip-clock-text
               (vovas.engine.gate::plist-to-json-text p)))))
  (format t "~&case ~a: want ~a, got ~a~%" name (length want) (length got))
  (let ((n (min (length want) (length got))) (at nil))
    (dotimes (i n) (unless (char= (char want i) (char got i)) (setf at i) (return)))
    (if at
        (format t "~&diff@~a~%  want: ...~a~%  got:  ...~a~%"
                at (subseq want (max 0 (- at 70)) (min (length want) (+ at 80)))
                (subseq got (max 0 (- at 70)) (min (length got) (+ at 80))))
        (format t "~&prefix same; length differs~%"))))
(finish-output)
