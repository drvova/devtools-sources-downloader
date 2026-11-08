;;; Does the jsfuck port WORK, measured with a small budget?
;;;
;;; The runner exceeds 60s on a 38-character expression. Two candidates: the port
;;; loops, or 2,000,000 parse nodes in unoptimised SBCL simply takes minutes. This
;;; separates them by cutting the budget to 20,000 and timing the same inputs. If
;;; they answer correctly and fast, the port is right and the budget is the cost.
(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode"
                "chipz" "salza2") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner" "digest"
             "bundler" "text" "beautify" "detectors" "sourcemaps" "packers"
             "wasm" "jscbytecode" "v8codecache" "zip" "jsfuck"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/lb-~a.fasl" f))))

(format t "~&budget BEFORE: nodes=~a depth=~a~%"
        vovas.engine.jsfuck::*max-parse-nodes* vovas.engine.jsfuck::*max-parse-depth*)
(setf vovas.engine.jsfuck::*max-parse-nodes* 20000
      vovas.engine.jsfuck::*max-parse-depth* 800)
(format t "budget NOW:    nodes=~a depth=~a~%" vovas.engine.jsfuck::*max-parse-nodes* vovas.engine.jsfuck::*max-parse-depth*)

(dolist (src '("[]+[]" "[][(![]+[])[+!+[]]+(!![]+[])[+[]]]"))
  (let ((t0 (get-internal-real-time)))
    (handler-case
        (format t "  ~a  (~a chars) => ~s  [~,3f s]~%"
                (if (> (length src) 26) (concatenate 'string (subseq src 0 24) "..") src)
                (length src)
                (vovas.engine.jsfuck:decode-jsfuck src)
                (/ (- (get-internal-real-time) t0) internal-time-units-per-second))
      (error (e) (format t "  ~a => ERROR ~a~%" (subseq src 0 (min 24 (length src))) e)))))
(format t "~&done~%")
(sb-ext:exit :code 0)
