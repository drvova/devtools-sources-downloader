;;;; wip/mutate-pipeline.lisp — the gate's own falsification test.
;;;;
;;;; Run the pipeline gate, then break the port ONE plausible way at a time and
;;;; require the gate to FAIL every time. A gate reporting 255/255 proves nothing
;;;; until something is shown to move that number.
;;;;
;;;; Each mutation is a wrong implementation somebody could actually write — an
;;;; off-by-one, a PCRE-ish regex anchor, a missing guard, or a tidy-up that
;;;; "fixes" an inherited quirk — not a corrupted one. Between mutations the
;;;; module is RELOADED from source, so each mutation is measured against a
;;;; clean port rather than against the previous mutation.
;;;;
;;;; Usage: sbcl --script tools/cl/engine/wip/mutate-pipeline.lisp

(require :asdf)
(load "C:/Users/bigmo/quicklisp/setup.lisp")
(asdf:load-asd (truename "tools/cl/vovas-engine.asd"))
(asdf:load-asd (truename "tools/cl/engine/pipeline.asd"))
(asdf:load-system :vovas-engine.pipeline)

(defparameter *pipeline-mutations*
  (list
   ;; --- assetSlug -------------------------------------------------------
   (list "assetSlug: PCRE `$` instead of `\\z` (strips a trailing-newline query)"
         (lambda ()
           (setf vovas.engine.pipeline::*scheme-re* nil)
           (vovas.engine.pipeline:asset-slug "x" 0)   ; ensures scanners exist
           (setf vovas.engine.pipeline::*query-re*
                 (cl-ppcre:create-scanner "[?#].*$"))
           (setf vovas.engine.pipeline::*js-ext-re*
                 (cl-ppcre:create-scanner "\\.js$" :case-insensitive-mode t))))
   (list "assetSlug: index padded on the left, not suffixed"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline:asset-slug)))
             (setf (symbol-function 'vovas.engine.pipeline:asset-slug)
                   (lambda (url &optional (index 0))
                     (let ((slug (funcall original url index)))
                       (concatenate 'string
                                    (or (cl-ppcre:scan-to-strings "^(\\d{4})" slug)
                                        "0000")
                                    slug)))))))
   (list "assetSlug: no four-digit prefix"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline:asset-slug)))
             (setf (symbol-function 'vovas.engine.pipeline:asset-slug)
                   (lambda (url &optional (index 0))
                     (subseq (funcall original url index) 5))))))
   ;; --- the text pass ---------------------------------------------------
   (list "text: `bytes` from the octet count instead of UTF-16 units"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-text-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-text-asset)
                   (lambda (asset opts)
                     (let ((result (funcall original asset opts)))
                       (setf (getf (vovas.engine.pipeline:asset-result-entry result) :bytes)
                             (length (sb-ext:string-to-octets
                                      (or (vovas.engine.pipeline:asset-content asset) "")
                                      :external-format :utf-8)))
                       result))))))
   (list "text: digest of the empty string instead of no digest"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-text-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-text-asset)
                   (lambda (asset opts)
                     (let ((result (funcall original asset opts)))
                       (when (zerop (length (or (vovas.engine.pipeline:asset-content asset) "")))
                         (setf (getf (vovas.engine.pipeline:asset-result-entry result) :digest)
                               (vovas.engine.digest:sha256-hex "")))
                       result))))))
   (list "text: `refusals` key dropped (the binary branch's shape)"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-text-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-text-asset)
                   (lambda (asset opts)
                     (let ((result (funcall original asset opts)))
                       (setf (vovas.engine.pipeline:asset-result-entry result)
                             (loop for (k v) on (vovas.engine.pipeline:asset-result-entry result)
                                   by #'cddr
                                   unless (eq k :refusals) append (list k v)))
                       result))))))
   (list "text: layer artifacts zero-padded to two digits"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-text-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-text-asset)
                   (lambda (asset opts)
                     (let ((result (funcall original asset opts)))
                       (dolist (file (vovas.engine.pipeline:asset-result-files result))
                         (let* ((path (vovas.engine.pipeline:file-path file))
                                (at (search "/layers/" path)))
                           (when (and at (char= (char path (+ at 8)) #\0))
                             ;; `layers/01-` -> `layers/001-`: the shape a
                             ;; `~2,'0d` format would produce, which is the
                             ;; tidy-up the Rust's literal `0` invites. String
                             ;; surgery rather than a regex template, because
                             ;; `\\10` in a cl-ppcre replacement reads as
                             ;; register 10 and throws (measured twice).
                             (setf (getf file :path)
                                   (concatenate 'string
                                                (subseq path 0 (+ at 8))
                                                "0"
                                                (subseq path (+ at 8)))))))
                       result))))))
   (list "text: `10-source.js` written even when beautified"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-text-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-text-asset)
                   (lambda (asset opts)
                     (let ((result (funcall original asset opts)))
                       (when (getf (vovas.engine.pipeline:asset-result-entry result) :beautified)
                         (setf (vovas.engine.pipeline:asset-result-files result)
                               (append (vovas.engine.pipeline:asset-result-files result)
                                       (list (vovas.engine.pipeline:make-file
                                              "x/10-source.js" "")))))
                       result))))))
   ;; --- the binary pass -------------------------------------------------
   (list "binary: stage detail from the function count, not the named count"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-binary-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-binary-asset)
                   (lambda (url bytes opts)
                     (let ((result (funcall original url bytes opts)))
                       (dolist (stage (getf (vovas.engine.pipeline:asset-result-entry result)
                                            :stages))
                         (let ((detail (getf stage :detail)))
                           (when (and detail (search "named functions" detail))
                             (setf (getf stage :detail)
                                   (cl-ppcre:regex-replace
                                    " \\d+ named functions" detail
                                    " 0 named functions")))))
                       result))))))
   (list "binary: budget guard uses >= instead of >"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-binary-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-binary-asset)
                   (lambda (url bytes opts)
                     (if (>= (length bytes) vovas.engine.util:*limits-max-asset-bytes*)
                         (let ((entry (vovas.engine.pipeline:make-entry
                                       :url url :kind "binary" :bytes (length bytes))))
                           (setf (getf entry :notes) (list "asset exceeds unpack budget"))
                           (vovas.engine.pipeline:make-asset-result entry '()))
                         (funcall original url bytes opts)))))))
   (list "binary: strings.json written for an empty string list"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::unpack-binary-asset)))
             (setf (symbol-function 'vovas.engine.pipeline::unpack-binary-asset)
                   (lambda (url bytes opts)
                     (let ((result (funcall original url bytes opts)))
                       (setf (vovas.engine.pipeline:asset-result-files result)
                             (append (vovas.engine.pipeline:asset-result-files result)
                                     (list (vovas.engine.pipeline:make-file
                                            "x/strings.json" "[]"))))
                       result))))))
   ;; --- the batch -------------------------------------------------------
   (list "batch: `unpacked` counts every asset"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline:unpack-assets)))
             (setf (symbol-function 'vovas.engine.pipeline:unpack-assets)
                   (lambda (assets opts)
                     (let ((batch (funcall original assets opts)))
                       (setf (getf (vovas.engine.pipeline:report-totals
                                    (vovas.engine.pipeline:batch-result-report batch))
                                   :unpacked)
                             (length assets))
                       batch))))))
   (list "batch: shared JSC table never discovered"
         (lambda ()
           (setf (symbol-function 'vovas.engine.pipeline::discover-shared-table)
                 (lambda (assets) (declare (ignore assets)) (values nil nil)))))
   (list "batch: table discovered but NOT threaded to each asset"
         (lambda ()
           ;; The discovery happens INSIDE `unpack-assets`, so a mutation that
           ;; rebuilds the caller's options changes nothing (measured: it was
           ;; the one MISSED probe of the first battery, and the probe was
           ;; vacuous, not the gate). The reachable wrong implementation is
           ;; dropping the table on the way to the per-asset options.
           (let ((original (symbol-function 'vovas.engine.pipeline:unpack-asset)))
             (setf (symbol-function 'vovas.engine.pipeline:unpack-asset)
                   (lambda (asset opts)
                     (funcall original
                              asset
                              (let ((stripped '()))
                                (loop for (k v) on opts by #'cddr
                                      unless (member k '(:shared-jsc-strings
                                                         :shared-jsc-source))
                                        do (setf stripped (append stripped (list k v))))
                                stripped)))))))
   ;; --- the JSON writer --------------------------------------------------
   (list "json: `false` written as `null` (the Lisp-nil collapse)"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline::emit-json)))
             (setf (symbol-function 'vovas.engine.pipeline::emit-json)
                   (lambda (value stream level)
                     (funcall original (if (eq value :false) nil value) stream level))))))
   (list "json: empty map written as `null`, not `{}`"
         (lambda ()
           (setf vovas.engine.pipeline::*wire-object-keys* '())))
   (list "json: four-space indent instead of two"
         (lambda ()
           (setf (symbol-function 'vovas.engine.pipeline::write-indent)
                 (lambda (stream level) (dotimes (i (* 4 level)) (write-char #\Space stream))))))
   (list "json: a trailing newline after the report"
         (lambda ()
           (let ((original (symbol-function 'vovas.engine.pipeline:pretty-json)))
             (setf (symbol-function 'vovas.engine.pipeline:pretty-json)
                   (lambda (value) (concatenate 'string (funcall original value)
                                                (string #\Newline)))))))))

(defun reload-port ()
  "Reload the module source, which restores every `defun`, `defparameter` and
`symbol-function` the previous mutation touched. ASDF's cache is outside the
tree, so this is also the sanctioned way to rebuild a file in the shared
checkout."
  (asdf:load-system :vovas-engine.pipeline :force t))

(let ((baseline (vovas.engine.gate::run-pipeline-gate :verbose nil))
      (caught 0)
      (total 0)
      (missed '()))
  (format t "~&BASELINE: ~a~%" (if baseline "PASS" "FAIL - a baseline failure makes this test meaningless"))
  (unless baseline (sb-ext:exit :code 1))
  (dolist (mutation *pipeline-mutations*)
    (incf total)
    (let ((ok nil) (threw nil))
      (handler-case (funcall (second mutation))
        (error (e) (setf threw (format nil "~a" e))))
      (handler-case (setf ok (vovas.engine.gate::run-pipeline-gate :verbose nil))
        (error (e) (setf ok nil threw (format nil "gate threw: ~a" e))))
      (cond
        ((null ok) (incf caught))
        (t (push (first mutation) missed)))
      (format t "~&  ~a  ~a~@[  (~a)~]~%"
              (if ok "MISSED" "caught") (first mutation) threw))
    (reload-port))
  (format t "~&~%mutation test: ~a/~a mutations caught~%" caught total)
  (when missed
    (format t "  missed:~%~{    ~a~%~}" (reverse missed)))
  ;; the port must still be intact after the final reload
  (format t "~&  port after reload: ~a~%"
          (if (vovas.engine.gate::run-pipeline-gate :verbose nil) "PASS" "FAIL"))
  (sb-ext:exit :code (if (= caught total) 0 1)))
