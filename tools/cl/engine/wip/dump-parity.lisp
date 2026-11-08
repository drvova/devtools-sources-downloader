(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(asdf:load-asd (merge-pathnames "tools/cl/vovas-engine.asd" (uiop:getcwd)))
(asdf:load-system :vovas-engine :force :all)

;; Write the port's fifty-three artifacts and the engine's alongside them, so a
;; plain text diff can say what actually differs. The gate's first-difference
;; report truncates at the newline, which is useless for JSON where the meaning
;; is a few characters earlier than the symptom.
(in-package :vovas.engine.gate)

(defun write-text (path text)
  (ensure-directories-exist path)
  (with-open-file (s path :direction :output :if-exists :supersede
                          :element-type 'character :external-format :utf-8)
    (write-string text s)))

(let* ((fx (read-json-file (fixture-path "panel/finalize-oracle.json")))
       (inp (gethash "inputs" fx))
       (exp (gethash "expected" fx))
       (opt (gethash "options" inp))
       (assets (coerce (gethash "jsAssets" inp) 'list))
       (recon (gethash "reconData" inp))
       (payloads (gethash "runtimePayloads" inp))
       (opts (vovas.engine.pipeline:make-unpack-options
              :path-prefix (or (and opt (vovas.engine.panel.assets:field-str opt "pathPrefix")) "_unpack")))
       (root #p"tools/cl/engine/wip/parity-out/")
       (files '()))
  ;; Clean the previous run so a stale artifact cannot masquerade as a match.
  (ignore-errors (uiop:delete-directory-tree (merge-pathnames "got/" root) :validate t))
  (ignore-errors (uiop:delete-directory-tree (merge-pathnames "want/" root) :validate t))

  (vovas.engine.panel.export:finalize-zip-with-recon
   (lambda (path content) (push (cons path content) files))
   assets recon nil payloads opts)
  (setf files (nreverse files))
  (format t "port wrote ~a files~%" (length files))

  (dolist (f files)
    (let ((path (merge-pathnames (format nil "got/~a" (car f)) root)))
      (if (stringp (cdr f))
          (write-text path (cdr f))
          (with-open-file (s path :direction :output :if-exists :supersede
                                  :element-type '(unsigned-byte 8))
            (write-sequence (cdr f) s)))))

  (dolist (w (coerce (gethash "files" exp) 'list))
    (let* ((p (coerce (vovas.engine.panel.assets:field-str w "path") 'string))
           (text (vovas.engine.panel.assets:field w "content"))
           (b64 (vovas.engine.panel.assets:field w "base64")))
      (cond
        (b64 (with-open-file (s (merge-pathnames (format nil "want/~a" p) root)
                                :direction :output :if-exists :supersede
                                :element-type '(unsigned-byte 8))
               (write-sequence (vovas.engine.decoders:decode-base64-to-bytes
                                (coerce b64 'string)) s)))
        (text (write-text (merge-pathnames (format nil "want/~a" p) root)
                          (coerce text 'string))))))
  (format t "oracle wrote ~a files~%" (length (coerce (gethash "files" exp) 'list))))
