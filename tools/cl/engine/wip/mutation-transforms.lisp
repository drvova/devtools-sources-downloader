;;;; mutation-transforms.lisp — prove run-transforms-gate is not vacuous.
;;;;
;;;; Loads the system, then redefines one port function at a time with a
;;;; plausible wrong implementation and requires the GATE TO FAIL. Nothing on
;;;; disk is edited; the package is already loaded so a redefinition takes effect
;;;; for the next call, and `peel-text` reaches every one of these by SYMBOL.
;;;;
;;;; A mutant that the gate still passes is a hole in the gate, so the script
;;;; reports each one and exits 1 if any mutant survives.

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-system :vovas-engine)
(asdf:load-asd (truename "tools/cl/engine/transforms.asd"))
(asdf:load-system :vovas-engine.transforms)

(defun gate-passes-p ()
  (handler-case
      (let ((*standard-output* (make-broadcast-stream)))
        (vovas.engine.gate::run-transforms-gate :verbose nil))
    (error () nil)))

(defvar *baseline* nil)

(defun try-mutant (name package symbol maker)
  (let ((original (symbol-function (find-symbol symbol package))))
    (setf (symbol-function (find-symbol symbol package)) (funcall maker original))
    (let ((passes (gate-passes-p)))
      (setf (symbol-function (find-symbol symbol package)) original)
      (format t "~&  ~a ~a~%"
              (if passes "SURVIVED" "killed  ") name)
      (not passes))))

(defun run-mutations ()
  (setf *baseline* (gate-passes-p))
  (format t "~&baseline passes: ~a~%" *baseline*)
  (let ((survivors 0)
        (mutants
          (list
           ;; 1. eval payloads joined with a comma instead of \n;\n
           (list "eval join uses a comma"
                 "VOVAS.ENGINE.TRANSFORMS" "UNWRAP-EVAL"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (text)
                     (let ((payloads (vovas.engine.transforms:collect-eval-payloads text)))
                       (when payloads
                         (format nil "~{~a~^, ~}"
                                 (mapcar #'vovas.engine.transforms:eval-payload-code
                                         payloads)))))))
           ;; 2. peel-text forgets the seen-digest set
           (list "peel-text has no digest dedupe"
                 "VOVAS.ENGINE.TRANSFORMS" "PEEL-TEXT"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (text &optional max-depth)
                     (declare (ignore max-depth))
                     (let* ((current text)
                            (stages '())
                            (outputs '()))
                       (dotimes (depth 8)
                         (let ((findings (vovas.engine.detectors:detect-layers current))
                               (produced nil)
                               (used nil))
                           (unless findings (return))
                           (dolist (finding findings)
                             (let ((candidate (vovas.engine.transforms:apply-transform
                                               (getf finding :tool) current)))
                               (when (and candidate (plusp (length candidate)))
                                 (unless produced
                                   (setf produced candidate used (getf finding :tool))))))
                           (unless produced (return))
                           (push (vovas.engine.transforms:make-text-stage
                                  :depth (1+ depth) :tool used
                                  :input-bytes (vovas.engine.util:utf16-length current)
                                  :output-bytes (vovas.engine.util:utf16-length produced)
                                  :digest (vovas.engine.digest:sha256-hex produced)
                                  :source-url nil)
                                 stages)
                           (push produced outputs)
                           (setf current produced)))
                       (vovas.engine.transforms:make-peel-result
                        :stages (nreverse stages) :outputs (nreverse outputs)
                        :final current
                        :refusals (vovas.engine.transforms:collect-refusals text))))))
           ;; 3. ToUint16 uses rem: -1 stays -1
           (list "to-uint16 uses rem"
                 "VOVAS.ENGINE.TRANSFORMS" "TO-UINT16"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (value)
                     (if (not (vovas.engine.transforms::double-finite-p value))
                         0
                         (rem (truncate value) 65536)))))
           ;; 4. printable-ratio counts bytes
           (list "printable-ratio counts bytes"
                 "VOVAS.ENGINE.TRANSFORMS" "PRINTABLE-RATIO"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (text)
                     (let ((bytes (sb-ext:string-to-octets text :external-format :utf-8)))
                       (if (zerop (length bytes))
                           0d0
                           (/ (coerce (count-if (lambda (b) (and (>= b 32) (/= b 127)))
                                                bytes)
                                      'double-float)
                              (coerce (length bytes) 'double-float)))))))
           ;; 5. gzip-format accepts a two-byte body
           (list "gzip-format accepts len 2"
                 "VOVAS.ENGINE.TRANSFORMS" "GZIP-FORMAT"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (bytes)
                     (let ((n (length bytes)))
                       (when (>= n 2)
                         (cond ((and (= (aref bytes 0) #x1f) (= (aref bytes 1) #x8b)) :gzip)
                               ((and (= (aref bytes 0) #x78)
                                     (member (aref bytes 1) '(#x01 #x9c #xda))) :deflate)
                               (t nil)))))))
           ;; 6. source URL never reported
           (list "source-url always nil"
                 "VOVAS.ENGINE.TRANSFORMS" "SOURCE-URL-OF"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (text) (declare (ignore text)) nil)))
           ;; 7. is-literal-only-arg always true -> expressions get joined wrongly
           (list "is-literal-only-arg always true"
                 "VOVAS.ENGINE.TRANSFORMS" "IS-LITERAL-ONLY-ARG"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (arg) (declare (ignore arg)) t)))
           ;; 8. hex escapes decode \u only (drop the \x pass)
           (list "unwrap-hex-escapes drops the \\x pass"
                 "VOVAS.ENGINE.TRANSFORMS" "UNWRAP-HEX-ESCAPES"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (text)
                     (when (cl-ppcre:scan "\\\\x[0-9a-fA-F]{2}" text)
                       (vovas.engine.transforms::replace-matches
                        (cl-ppcre:create-scanner "\\\\u([0-9a-fA-F]{4})") text
                        #'vovas.engine.transforms::hex-escape-replacement)))))
           ;; 9. js-parse-int understands 0x, like Number::parseInt
           (list "js-parse-int honours 0x"
                 "VOVAS.ENGINE.TRANSFORMS" "JS-PARSE-INT"
                 (lambda (original)
                   (declare (ignore original))
                   (lambda (text)
                     (let ((trimmed (string-left-trim '(#\Space #\Tab) text)))
                       (if (and (>= (length trimmed) 2)
                                (string= (subseq trimmed 0 2) "0x"))
                           65d0
                           (vovas.engine.number:parse-int text))))))
           ;; 10. refusals never collected
           (list "collect-refusals answers nil"
                 "VOVAS.ENGINE.TRANSFORMS" "COLLECT-REFUSALS"
                 (lambda (original) (declare (ignore original))
                   (lambda (text) (declare (ignore text)) nil))))))
    (dolist (mutant mutants)
      (unless (try-mutant (first mutant) (second mutant) (third mutant) (fourth mutant))
        (incf survivors)))
    (format t "~&~a/~a mutants killed~%" (- (length mutants) survivors) (length mutants))
    (and *baseline* (zerop survivors))))

(let ((ok (run-mutations)))
  (format t "~&~a~%" (if ok "PASS mutations" "FAIL mutations"))
  (sb-ext:exit :code (if ok 0 1)))
