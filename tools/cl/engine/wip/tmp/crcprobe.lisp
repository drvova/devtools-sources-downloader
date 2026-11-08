(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-asd (truename "tools/cl/engine/zip.asd"))
(asdf:load-system :vovas-engine.zip)

(in-package :vovas.engine.zip)

(let ((b (make-array 3 :element-type '(unsigned-byte 8)
                       :initial-contents (list #xFF #x41 #x42))))
  (format t "direct call: ~s~%"
          (handler-case (sb-ext:octets-to-string b :start 0 :end 3
                                                   :external-format :utf-8)
            (sb-int:character-decoding-error () :caught-by-supertype)))
  (format t "decode-name: ~s~%"
          (handler-case (decode-name b 0 3)
            (zip-error (e) (list :zip-error (zip-error-message e)))
            (error (e) (list :other (type-of e))))))

(in-package :vovas.engine.gate)
(format t "signals-containing-p base64 -> ~s~%"
        (signals-containing-p
         (lambda () (vovas.engine.zip:build-zip
                     (list (list :path "bad.bin" :base64 "!!!!")) 0))
         "invalid base64 payload"))
(format t "signals of that -> ~s~%"
        (signals (lambda () (vovas.engine.zip:build-zip
                             (list (list :path "bad.bin" :base64 "!!!!")) 0))))
