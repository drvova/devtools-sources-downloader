;;; The programs are all instant (11/11 in 0.000s). So the hang is in the gate's
;;; other work: 35 expressions and 10 detection cases. Time each family separately
;;; to find which one spins.
(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "cl-unicode"
                "chipz" "salza2") :silent t)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner" "digest"
             "bundler" "text" "beautify" "detectors" "sourcemaps" "packers"
             "wasm" "jscbytecode" "v8codecache" "zip" "jsfuck"))
  (load (compile-file (format nil "tools/cl/engine/~a.lisp" f)
                      :output-file (format nil "C:/Users/bigmo/AppData/Local/Temp/p2-~a.fasl" f))))

(let* ((path "unpack-rs/tests/fixtures/jsfuck-oracle.json")
       (json (com.inuoe.jzon:parse
              (with-open-file (s path :external-format :utf-8)
                (let ((str (make-array (file-length s) :element-type 'character)))
                  (subseq str 0 (read-sequence str s))))))
       (fams (gethash "families" json)))
  (dolist (fam '("expressions" "detection"))
    (let ((cases (gethash fam fams)))
      (format t "~&== ~a ==~%" fam)
      (loop for k being the hash-keys of cases using (hash-value v)
            do (let* ((src (gethash "source" v))
                      (t0 (get-internal-real-time))
                      (r (handler-case (progn (vovas.engine.jsfuck:detect-jsfuck src)
                                              (vovas.engine.jsfuck:decode-jsfuck src)
                                              "ok")
                           (error (e) "err")))
                      (dt (/ (- (get-internal-real-time) t0) internal-time-units-per-second)))
                 (when (> dt 0.5)
                   (format t "  SLOW ~a ~a chars ~,2f s (~a)~%" k (length src) dt r))
                 (when (> dt 5.0)
                   (format t "  ^^^ ABOVE IS THE CULPRIT~%")))))))
(sb-ext:exit :code 0)
