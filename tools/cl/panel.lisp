;;;; panel.lisp — verify the extension's DevTools panel really registers.
;;;;
;;;; The extension e2e opens html/page.html directly and asserts the off-panel
;;;; guard; nothing checked that chrome.devtools.panels.create produces a tab in
;;;; a real DevTools window. Scraping the tab strip cannot answer that: the strip
;;;; overflows into a chevron on any laptop-width screen, and the UI lives behind
;;;; shadow roots. The frontend keeps its own registry on `UI.panels`, keyed by
;;;; "<extension id><title without spaces>", so the check asks the frontend
;;;; instead of guessing at pixels.

(in-package :vovas.cdp)

(defparameter *panel-key-suffix* "SourcesDownloader"
  "Panel title with its spaces removed; DevTools keys UI.panels by this.")

(defun panel-registry-js ()
  "JS that returns the DevTools frontend's registered panel keys, or a reason."
  (format nil "(function () {
  if (typeof UI === 'undefined') return 'no UI global';
  if (!UI.panels) return 'no UI.panels';
  return Object.keys(UI.panels).join(',');
})()"))

(defun extension-frame-targets (browser)
  "Targets for the extension's devtools page (the page Chrome loads per window)."
  (loop for tt in (tabs browser)
        when (and (string= (getf tt :type) "iframe")
                  (search "/html/devtools.html" (or (getf tt :url) "")))
          collect tt))

(defun devtools-window-targets (browser)
  "Targets for the DevTools frontend pages."
  (loop for tt in (tabs browser)
        when (and (string= (getf tt :type) "page")
                  (search "devtools_app.html" (or (getf tt :url) "")))
          collect tt))

(defun extension-id-of (target)
  "chrome-extension://<id>/html/devtools.html -> <id>."
  (let ((url (or (getf target :url) "")))
    (when (search "chrome-extension://" url)
      (let ((start (length "chrome-extension://"))
            (end (position #\/ url :start (length "chrome-extension://"))))
        (when (and end (> end start))
          (subseq url start end))))))

(defun wait-until (predicate &key (timeout-seconds 20) (interval 0.25))
  "Poll PREDICATE until it returns true or the timeout elapses. Returns the value."
  (loop repeat (round (/ timeout-seconds interval))
        for value = (funcall predicate)
        when value return value
        do (sleep interval)
        finally (return nil)))

(defun panel-check (&key headless (timeout-seconds 25))
  "Load the built extension into Chrome for Testing, let DevTools open for a page
opened after the extension settles, and assert the panel is in the frontend's
registry. Returns 0 when every check passes, 1 otherwise."
  (let ((checks 0)
        (ok t)
        (dist (string-right-trim "/" (namestring
                                      (uiop:merge-pathnames* "unpack-rs/dist/"
                                                             (repo-root)))))
        (browser nil))
    (flet ((check (name condition &optional detail)
             (if condition
                 (progn (incf checks)
                        (format t "[vovas] panel ~a: OK~@[ (~a)~]~%" name detail))
                 (progn (setf ok nil)
                        (format t "[vovas] panel ~a: FAIL~@[ (~a)~]~%" name detail)))
             (force-output)))
      (unwind-protect
           (progn
             (unless (probe-file (uiop:merge-pathnames* "manifest.json"
                                                        (uiop:ensure-directory-pathname dist)))
               (error "no manifest.json in ~a - run `vovas build` first" dist))
             (setf browser
                   (launch :headless headless
                           :extra-args (list (format nil "--load-extension=~a" dist)
                                             (format nil "--disable-extensions-except=~a" dist)
                                             "--auto-open-devtools-for-tabs"
                                             "--window-size=1600,1100")))
             ;; The startup tab's DevTools opens before the extension registers,
             ;; so open a page afterwards; that window is the one that gets the panel.
             (sleep 3)
             (new-tab "data:text/html,<title>vovas panel probe</title><h1>probe</h1>" browser)

             (let ((frame (wait-until (lambda () (first (extension-frame-targets browser)))
                                      :timeout-seconds timeout-seconds)))
               (check "extension devtools page loaded" frame
                      (and frame (extension-id-of frame)))
               (let ((ext-id (and frame (extension-id-of frame))))
                 (let ((window (wait-until (lambda () (first (devtools-window-targets browser)))
                                           :timeout-seconds timeout-seconds)))
                   (check "devtools window opened" window
                          (and window (length (devtools-window-targets browser))))
                   (when (and window ext-id)
                     ;; every DevTools window is checked; the panel must be in one
                     (let ((keys nil))
                       (dolist (w (devtools-window-targets browser))
                         (connect-target browser w)
                         (let ((raw (handler-case (eval* (panel-registry-js) :browser browser)
                                      (error (e) (format nil "ERR: ~a" e)))))
                           (when (stringp raw)
                             (setf keys (append keys (vovas.tools.util:split-on #\, raw))))))
                       ;; the registry keys by full origin: "chrome-extension://<id>" + title
                       (let ((wanted (format nil "chrome-extension://~a~a"
                                             ext-id *panel-key-suffix*)))
                         (check "panel registered in UI.panels"
                                (member wanted keys :test #'string=)
                                (or (find-if (lambda (k) (search *panel-key-suffix* k)) keys)
                                    (format nil "~{~a~^,~}" keys)))))
                     ;; the registered page must actually boot in the extension origin
                     (let ((page (handler-case
                                     (progn
                                       (connect-target browser
                                                       (or (find-if (lambda (tt)
                                                                      (string= (getf tt :type) "page"))
                                                                    (tabs browser))
                                                           (first (tabs browser))))
                                       (new-tab (format nil "chrome-extension://~a/html/page.html" ext-id)
                                                browser))
                                   (error (e) (format nil "ERR: ~a" e)))))
                       (if (stringp page)
                           (check "panel page boots" nil page)
                           (let ((href (wait-until
                                        (lambda ()
                                          (let ((v (handler-case (eval* "location.href" :browser browser)
                                                     (error () nil))))
                                            (and (stringp v) (search "/html/page.html" v) v)))
                                        :timeout-seconds 10)))
                             (check "panel page boots" href href)))))))
             ;; a screenshot of the DevTools window is the artifact a human checks
             (let ((window (first (devtools-window-targets browser))))
               (when window
                 (connect-target browser window)
                 (multiple-value-bind (path okp) (handler-case
                                                     (values (shot :browser browser) t)
                                                   (error () (values nil nil)))
                   (check "devtools screenshot" (and okp path) path)))))
        (when browser (kill browser))))
    (format t "[vovas] panel: ~a (~d checks)~%" (if ok "OK" "FAILED") checks)
    (force-output)
    (if ok 0 1))))
