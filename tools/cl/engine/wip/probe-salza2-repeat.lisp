;;;; probe-salza2-repeat.lisp — is deflate-raw deterministic across repeats?
;;;;
;;;; The zip gate reports DIFFERENT assertions failing on each run of identical
;;;; code: a 65535-entry archive readable, then a corrupted-byte CRC check, then a
;;;; clean 140/140. The module has no randomness and no clock. The only external
;;;; component is salza2, so this asks the narrow question: does compressing the
;;;; same bytes twice in one image give the same octets?
;;;;
;;;; If it does not, the gate's intermittent failures are salza2 state, not the
;;;; port, and every assertion built on deflated bytes is unreliable.
;;;; If it does, the variance is in the LOAD and the private-fasl run is the proof.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(ql:quickload '("cl-ppcre" "com.inuoe.jzon" "ironclad" "babel" "chipz" "salza2"
                "cl-unicode")
              :silent t)

(defparameter *fork-dir*
  (merge-pathnames (format nil "vovas-probe-~a/" (get-universal-time))
                   (uiop:temporary-directory)))

(ensure-directories-exist *fork-dir*)
(dolist (f '("package" "util" "number" "transforms" "decoders" "scanner"
             "digest" "bundler" "text" "beautify" "detectors" "sourcemaps"
             "packers" "wasm" "jscbytecode" "v8codecache" "zip"))
  (let ((out (merge-pathnames (format nil "~a.fasl" f) *fork-dir*)))
    (compile-file (format nil "tools/cl/engine/~a.lisp" f) :output-file out)
    (load out)))

(let* ((payload (sb-ext:string-to-octets
                 (with-output-to-string (s)
                   (dotimes (i 400) (format s "line ~a of a repetitive body~%" i)))))
       (first-run (vovas.engine.zip::deflate-raw payload)))
  (format t "~&payload ~a bytes -> deflate ~a bytes~%" (length payload) (length first-run))
  (format t "repeat in the same image:~%")
  (let ((all-same t))
    (dotimes (i 5)
      (let ((again (vovas.engine.zip::deflate-raw payload)))
        (unless (equalp again first-run) (setf all-same nil))
        (format t "  attempt ~a: ~a bytes, identical to first = ~a~%"
                (1+ i) (length again) (equalp again first-run))))
    (format t "~%deflate is ~a~%" (if all-same
                                     "deterministic across repeats in one image"
                                     "NOT deterministic - salza2 carries state")))

  ;; and the round trip, many times
  (format t "~%inflate round trips:~%")
  (let ((ok 0))
    (dotimes (i 5)
      (handler-case
          (let ((back (vovas.engine.zip::inflate-raw (vovas.engine.zip::deflate-raw payload))))
            (when (equalp back payload) (incf ok)))
        (error (e) (format t "  attempt ~a errored: ~a~%" (1+ i) e))))
    (format t "  ~a/5 round trips identical~%" ok))
  (sb-ext:exit :code 0))
