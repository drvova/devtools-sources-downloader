;;; Time each real oracle program separately.
;;;
;;; The 34-char expression answers in 22 nodes. The real programs are 563-3342
;;; chars, so the question is whether cost grows with the node budget or
;;; super-linearly with input. Each program is timed independently and abandoned
;;; at 20 seconds, so one pathological case cannot hide the rest.
(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode"
                "chipz" "salza2") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner" "digest"
             "bundler" "text" "beautify" "detectors" "sourcemaps" "packers"
             "wasm" "jscbytecode" "v8codecache" "zip" "jsfuck"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/pf-~a.fasl" f))))
(setf vovas.engine.jsfuck::*max-parse-nodes* 200000
      vovas.engine.jsfuck::*max-parse-depth* 500)

(let* ((path "unpack-rs/tests/fixtures/jsfuck-oracle.json")
       (json (com.inuoe.jzon:parse
              (with-open-file (s path :external-format :utf-8)
                (let ((str (make-array (file-length s) :element-type 'character)))
                  (subseq str 0 (read-sequence str s))))))
       (progs (gethash "programs" (gethash "families" json))))
  (loop for k being the hash-keys of progs using (hash-value v)
        do (let* ((src (gethash "source" v))
                  (len (length src))
                  (t0 (get-internal-real-time))
                  (res (handler-case (vovas.engine.jsfuck:decode-jsfuck src)
                         (error (e) (format nil "ERR ~a" (subseq (format nil "~a" e) 0 40)))))
                  (dt (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
             (format t "~&  ~a~20t~a chars~30t~,3f s~45t~s~%"
                     k len dt (if (stringp res) res (getf res :value))))))
(sb-ext:exit :code 0)
