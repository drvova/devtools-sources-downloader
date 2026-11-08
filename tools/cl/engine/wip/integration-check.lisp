;;;; integration-check.lisp — do the seams pick up the REAL packers module?
;;;;
;;;; The whole reason the four foreign calls are seams is that this slice must
;;;; work before and after its neighbours land. This harness proves the "after"
;;;; half: load the real `vovas.engine.packers`, load this port, and the packer
;;;; and string-array findings must appear from the real detectors with no edit
;;;; to detectors.lisp - and the ambient oracle comparison must still match.

(require :asdf)

(load "C:/Users/bigmo/quicklisp/setup.lisp")

(asdf:load-system :cl-ppcre)

(asdf:load-system :com.inuoe.jzon)

(load "tools/cl/engine/package.lisp")

(load "tools/cl/engine/util.lisp")

(load "tools/cl/engine/gate.lisp")

(load "tools/cl/engine/decoders.lisp")

(load "tools/cl/engine/scanner.lisp")

(load "tools/cl/engine/packers.lisp")

(load "tools/cl/engine/detectors.lisp")

(load "tools/cl/engine/gate-detectors.lisp")

(format t "~&-- seams resolved after the real packers module loaded --%")
(format t "packer         => ~s~%" (vovas.engine.detectors:resolve-provider :packer))
(format t "string-array   => ~s~%" (vovas.engine.detectors:resolve-provider :string-array))
(format t "eval-payloads  => ~s~%" (vovas.engine.detectors:resolve-provider :eval-payloads))
(format t "jsfuck         => ~s~%" (vovas.engine.detectors:resolve-provider :jsfuck))
(format t "missing-stages => ~s~%" (vovas.engine.detectors:missing-stages))

(format t "~&-- real detector answers on the fixtures --%")
(let* ((*read-default-float-format* 'double-float)
       (sources (vovas.engine.gate::detector-sources)))
  (dolist (key '("packed" "stringArray"))
    (format t "~a detect-packer        => ~s~%"
            key
            (let ((text (gethash key sources)))
              (multiple-value-bind (base words)
                  (let ((p (vovas.engine.packers:detect-packer text)))
                    (values (getf p :base) (getf p :words)))
                (list :base base :words words))))
    (format t "~a detect-string-array  => ~s~%"
            key
            (vovas.engine.packers:detect-string-array (gethash key sources))))
  (format t "~&-- detect-layers with the real packers wired --%")
  (dolist (key '("packed" "stringArray" "plain"))
    (format t "~a => ~s~%" key
            (mapcar (lambda (f) (list (getf f :tool) (getf f :score) (getf f :detail)))
                    (vovas.engine.detectors:detect-layers (gethash key sources))))))

(let ((ok (vovas.engine.gate::run-detectors-gate :verbose t)))
  (format t "~&~%detectors gate (with real packers loaded): ~a~%"
          (if ok "PASS" "FAIL"))
  (finish-output)
  (sb-ext:exit :code (if ok 0 1)))
