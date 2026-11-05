;;;; chrome.lisp — Chrome for Testing: cache discovery, download, launch.
;;;; Cache layout matches @puppeteer/browsers so both producers share one cache:
;;;;   .cache/browser/chrome/win64-<version>/chrome-win64/chrome.exe

(in-package :vovas.cdp)

(defparameter +cft-manifest-url+
  "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json")

(defun cft-cache-dir ()
  (uiop:merge-pathnames* "unpack-rs/.cache/browser/" (repo-root)))

(defun version-key (name)
  "win64-141.0.7390.65 -> (141 0 7390 65), or NIL when the name does not fit."
  (let ((s (string name)))
    (when (uiop:string-prefix-p "win64-" s)
      (mapcar (lambda (p) (parse-integer p :junk-allowed t))
              (vovas.tools.util:split-on #\. (subseq s 6))))))

(defun version-older-p (a b)
  "Lexicographic version comparison; NIL sorts as oldest."
  (cond ((null a) t)
        ((null b) nil)
        ((/= (car a) (car b)) (< (car a) (car b)))
        (t (version-older-p (cdr a) (cdr b)))))

(defun find-chrome-exe ()
  "Newest chrome.exe in the CFT cache, or NIL."
  (let ((versions (ignore-errors (uiop:subdirectories
                                  (uiop:merge-pathnames* "chrome/" (cft-cache-dir))))))
    (when versions
      (let* ((sorted (sort versions
                           (lambda (a b) (version-older-p (version-key a) (version-key b)))
                           :key (lambda (d) (car (last (pathname-directory d))))))
             (exe (uiop:merge-pathnames* "chrome-win64/chrome.exe" (first (last sorted)))))
        (and (probe-file exe) exe)))))

(defun ps-run (script &key (cwd nil))
  "Run a PowerShell one-liner. Returns (values exit-code stdout)."
  (vovas.tools.util:run-program
   (list (vovas.tools.util:powershell-exe)
         "-NoProfile" "-NonInteractive" "-Command" script)
   :cwd cwd))

(defun download-chrome ()
  "Fetch the latest stable Chrome for Testing (win64) via powershell, which
owns TLS and the system trust store. Returns (values url version)."
  (multiple-value-bind (code out) (ps-run (format nil "(Invoke-WebRequest -Uri '~a' -UseBasicParsing).Content" +cft-manifest-url+))
    (unless (zerop code)
      (error "could not fetch the Chrome for Testing manifest (powershell exit ~a)" code))
    (let* ((data (vovas.tools.util:json-parse out))
           (stable (gethash "Stable" (gethash "channels" data)))
           (version (gethash "version" stable))
           (entries (gethash "chrome" (gethash "downloads" stable)))
           (entry (find-if (lambda (e) (string= (gethash "platform" e) "win64")) entries))
           (url (and entry (gethash "url" entry))))
      (unless url
        (error "no win64 chrome download in the Chrome for Testing manifest"))
      (let* ((cache (cft-cache-dir))
             (zip (uiop:merge-pathnames* "chrome.zip" cache))
             (dest (uiop:merge-pathnames* (format nil "chrome/win64-~a/" version) cache)))
        (ensure-directories-exist dest)
        (log-line "downloading chrome ~a" version)
        (multiple-value-bind (dl-code) (ps-run (format nil "Invoke-WebRequest -Uri '~a' -OutFile '~a'" url (namestring zip)))
          (unless (zerop dl-code)
            (error "chrome download failed (powershell exit ~a)" dl-code)))
        (log-line "extracting")
        (multiple-value-bind (x-code) (ps-run (format nil "Expand-Archive -Path '~a' -DestinationPath '~a' -Force" (namestring zip) (namestring dest)))
          (unless (zerop x-code)
            (error "chrome extraction failed (powershell exit ~a)" x-code)))
        (values url version)))))

(defun ensure-chrome ()
  (or (find-chrome-exe)
      (progn
        (log-line "no Chrome for Testing in the cache - downloading")
        (download-chrome)
        (or (find-chrome-exe)
            (error "chrome download did not produce a chrome.exe")))))

(defun read-port-file (path)
  "DevToolsActivePort: line 1 is the port, line 2 the browser ws path."
  (when (probe-file path)
    (ignore-errors
      (with-open-file (f path)
        (let ((port (parse-integer (read-line f) :junk-allowed t)))
          (when (and port (> port 0))
            port))))))
