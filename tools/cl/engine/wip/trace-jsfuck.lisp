;;; Where does the 38-char expression go?
;;;
;;; []+[] answers in 0.000s; "[][(![]+[])[+!+[]]+(!![]+[])[+[]]]" does not
;;; finish at a 20,000-node budget. That is not budget cost, so something spins.
;;; This instruments ip-charge-node to report progress, which distinguishes
;;; "slow but advancing" from "stuck at the same position".
(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode"
                "chipz" "salza2") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner" "digest"
             "bundler" "text" "beautify" "detectors" "sourcemaps" "packers"
             "wasm" "jscbytecode" "v8codecache" "zip" "jsfuck"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/tr-~a.fasl" f))))

(setf vovas.engine.jsfuck::*max-parse-nodes* 20000
      vovas.engine.jsfuck::*max-parse-depth* 800)

(let ((orig (fdefinition 'vovas.engine.jsfuck::ip-charge-node))
      (n 0))
  (setf (fdefinition 'vovas.engine.jsfuck::ip-charge-node)
        (lambda (ip)
          (incf n)
          (when (zerop (mod n 2000))
            (format t "  nodes=~a pos=~a~%" n (vovas.engine.jsfuck::interp-pos ip)))
          (funcall orig ip)))
  (let ((src "[][(![]+[])[+!+[]]+(!![]+[])[+[]]]"))
    (format t "~&source: ~a chars~%" (length src))
    (handler-case
        (format t "=> ~s after ~a nodes~%" (vovas.engine.jsfuck:decode-jsfuck src) n)
      (error (e) (format t "=> ERROR after ~a nodes: ~a~%" n e)))))
(sb-ext:exit :code 0)
