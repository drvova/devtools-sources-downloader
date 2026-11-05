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

(defun check (&key fast)
  "The gate, decomposed from npm run verify: per-step verdicts, fail-fast.
FAST runs lint + rust tests + clippy only. Returns 0/1."
  (let* ((steps (list
                 (cons "lint+format (rs check)" (vovas.tools.util:npm-argv '("run" "check")))
                 (cons "rust tests (cargo test)" (vovas.tools.util:cargo-argv '("test")))
                 (cons "clippy" (vovas.tools.util:cargo-argv
                                 '("clippy" "--all-targets" "--" "-D" "warnings")))))
         (steps (if fast
                    steps
                    (append steps
                            (list (cons "js tests (npm test)" (vovas.tools.util:npm-argv '("test")))
                                  (cons "build (npm run build)" (vovas.tools.util:npm-argv '("run" "build")))
                                  (cons "e2e (npm run test:e2e)" (vovas.tools.util:npm-argv '("run" "test:e2e")))
                                  (cons "extension e2e" (vovas.tools.util:npm-argv '("run" "test:e2e:ext")))))))
         (failed nil))
    (dolist (step steps)
      (let ((code (vovas.tools.util:run-step (car step) (cdr step) :cwd (unpack-rs-dir))))
        (unless (zerop code)
          (setf failed t)
          (return))))
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
