;;;; tasks.lisp — the build/check/pack pipeline, mirroring npm run verify
;;;; exactly (rs check, cargo test, clippy, npm test, build, both e2e suites)
;;;; but with per-step verdicts, timings and fail-fast control.

(in-package :vovas.tools)

(defun unpack-rs-dir ()
  (uiop:merge-pathnames* "unpack-rs/" (repo-root)))

(defun dist-dir ()
  (uiop:merge-pathnames* "dist/" (unpack-rs-dir)))

;;; ---------- build ----------

(defun verify-dist ()
  "Structural checks on the built artifact. Returns T when everything holds."
  (let ((all-ok t))
    (flet ((check (name ok &optional detail)
             (format t "[vovas] dist ~a: ~a~@[ (~a)~]~%" name (if ok "OK" "FAIL") detail)
             (unless ok (setf all-ok nil))))
      (let ((manifest-path (uiop:merge-pathnames* "manifest.json" (dist-dir))))
        (check "manifest.json exists" (probe-file manifest-path))
        (when (probe-file manifest-path)
          (let ((m (vovas.tools.util:json-parse
                    (uiop:read-file-string manifest-path))))
            (check "manifest name" (gethash "name" m) (gethash "name" m))
            (check "manifest version" (gethash "version" m) (gethash "version" m))
            (check "manifest_version 3" (eql (gethash "manifest_version" m) 3))
            (let ((csp (gethash "content_security_policy" m)))
              ;; MV3's default CSP already allows wasm; an explicit policy must
              ;; carry wasm-unsafe-eval or the engine will not instantiate.
              (if csp
                  (check "csp allows wasm"
                         (search "wasm-unsafe-eval"
                                 (or (gethash "extension_pages" csp) ""))
                         (gethash "extension_pages" csp))
                  (check "csp allows wasm" t "default MV3 policy")))
            (let ((icons (gethash "icons" m)))
              (when icons
                (maphash (lambda (size path)
                           (declare (ignore size))
                           (check (format nil "icon ~a" path)
                                  (probe-file (uiop:merge-pathnames* path (dist-dir)))))
                         icons)))))
        (let ((wasm (uiop:merge-pathnames* "js/engine.wasm" (dist-dir))))
          (check "engine.wasm exists" (probe-file wasm))
          (when (probe-file wasm)
            (let ((size (vovas.tools.util:file-size wasm)))
              (check "engine.wasm size" (> size 500000) (format nil "~d bytes" size)))))
        (check "page.html exists"
               (probe-file (uiop:merge-pathnames* "html/page.html" (dist-dir))))))
    all-ok))

(defun build ()
  "Full build: wasm engine + bundle, then verify the dist artifact.
Returns 0 on success, 1 on failure."
  (let ((code (vovas.tools.util:run-step
               "build (engine + bundle)" (npm-argv '("run" "build"))
               :cwd (unpack-rs-dir))))
    (if (zerop code)
        (if (verify-dist) 0 1)
        1)))

;;; ---------- check ----------

(defun gate-file ()
  "The gate definition: tools/cl/vovas.sexp."
  (uiop:merge-pathnames* "tools/cl/vovas.sexp" (repo-root)))

(defun gate-report-file ()
  "Where a gate run records its own result, as a sexp file."
  (uiop:merge-pathnames* "unpack-rs/.cache/gate.sexp" (repo-root)))

(defun gate-step-argv (label opts)
  "Resolve one step's runner and argv. A step names exactly one of npm or cargo."
  (let ((npm (getf opts :npm))
        (cargo (getf opts :cargo)))
    (cond ((and npm cargo)
           (error "gate step ~s names both npm and cargo" label))
          (npm (vovas.tools.util:npm-argv npm))
          (cargo (vovas.tools.util:cargo-argv cargo))
          (t (error "gate step ~s names neither npm nor cargo" label)))))

(defun gate-steps (&key fast)
  "The gate as data, read from tools/cl/vovas.sexp.
Each step is (step \"label\" npm (args) [fast t]) or with cargo.
Returns an alist of (label . argv), in file order, filtered by FAST."
  (let* ((path (gate-file))
         (form (vovas.tools.util:read-sexp-file path)))
    (unless (and (consp form) (eq (first form) :gate))
      (error "~a must be a (gate ...) form" path))
    (loop for spec in (rest form)
          do (unless (and (consp spec) (eq (first spec) :step))
               (error "~a: expected (step ...), got ~s" path spec))
          ;; every step is validated even when FAST filters it out, so a broken
          ;; entry can never hide behind the filter
          append (let* ((label (second spec))
                        (opts (cddr spec))
                        (argv (gate-step-argv label opts)))
                   (when (or (not fast) (getf opts :fast))
                     (list (cons label argv)))))))

(defun check (&key fast)
  "The gate, decomposed from npm run verify: per-step verdicts, fail-fast.
The steps live in tools/cl/vovas.sexp; FAST keeps only those marked (fast t).
Writes the run to unpack-rs/.cache/gate.sexp. Returns 0/1."
  ;; a data format that is never round-tripped is a format waiting to break
  (vovas.tools.util:sexp-selftest)
  (let ((steps (gate-steps :fast fast))
        (results nil)
        (failed nil))
    (dolist (step steps)
      (let ((code (vovas.tools.util:run-step (car step) (cdr step) :cwd (unpack-rs-dir))))
        (push (list :step (car step) :exit code) results)
        (unless (zerop code)
          (setf failed t)
          (return))))
    (vovas.tools.util:write-sexp-file
     (gate-report-file)
     (list :gate-run
           (list :at (get-universal-time))
           (list :fast (and fast t))
           (cons :steps (nreverse results))))
    (format t "[vovas] check: ~a~%" (if failed "FAIL" "PASS"))
    (force-output)
    (if failed 1 0)))

;;; ---------- pack ----------

(defun pack ()
  "Zip dist/ into dist-<version>.zip next to unpack-rs/. Returns 0/1."
  (let* ((manifest-path (uiop:merge-pathnames* "manifest.json" (dist-dir))))
    (unless (probe-file manifest-path)
      (error "no manifest.json in ~a - run vovas build first" (dist-dir)))
    (let* ((version (gethash "version"
                            (vovas.tools.util:json-parse
                             (uiop:read-file-string manifest-path))))
           (zip (uiop:merge-pathnames* (format nil "dist-~a.zip" version)
                                       (unpack-rs-dir))))
      (multiple-value-bind (code out err)
          (vovas.tools.util:run-program
           (list (vovas.tools.util:powershell-exe)
                 "-NoProfile" "-NonInteractive" "-Command"
                 (format nil "Compress-Archive -Path '~a*' -DestinationPath '~a' -Force"
                         (uiop:native-namestring (dist-dir))
                         (uiop:native-namestring zip))))
        (if (zerop code)
            (progn
              (log-line "packed ~a" zip)
              0)
            (progn
              (format t "~a~a" out err)
              1))))))
