(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode"
                "chipz" "salza2") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner" "digest"
             "bundler" "text" "beautify" "detectors" "sourcemaps" "packers"
             "wasm" "jscbytecode" "v8codecache" "zip" "jsfuck"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/tj-~a.fasl" f))))
(format t "~&loaded~%")
(dolist (pair '(("[]+[]" . 4000) ("[][(![]+[])[+!+[]]+(!![]+[])[+[]]]" . 20000)))
  (let ((src (car pair)) (budget (cdr pair)))
    (declare (ignore budget))
    (let ((t0 (get-internal-real-time)))
      (handler-case
          (let ((r (vovas.engine.jsfuck:decode-jsfuck src)))
            (format t "  ~a.. => ~s in ~,2f s~%"
                    (subseq src 0 (min 24 (length src))) r
                    (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
        (error (e) (format t "  ~a.. => ERROR ~a~%" (subseq src 0 24) e))))))
(format t "~&done~%")
(sb-ext:exit :code 0)
