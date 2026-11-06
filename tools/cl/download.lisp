;;;; download.lisp — drive the real DevTools panel against a real page and
;;;; verify the archive it produces.
;;;;
;;;; The other two browser checks stop short of the product. `panel-check` proves
;;;; the panel registers in `UI.panels`; the extension e2e opens `html/page.html`
;;;; as a plain tab and asserts it refuses to run without the DevTools API. So
;;;; nothing collected from a real inspected page and produced a zip until this.
;;;;
;;;; Two obstacles, both solved here:
;;;;
;;;; DevTools loads a panel's iframe lazily, when its tab is selected, and on
;;;; Chrome for Testing 157 `UI.InspectorView` is undefined - the frontend exposes
;;;; only `UI.panels`, a registry rather than a selector. The way in is the panel
;;;; cycle keybind (Ctrl+]), which is what a user presses.
;;;;
;;;; The archive is read back through a `URL.createObjectURL` hook instead of from
;;;; Chrome's download directory, so the bytes land in `.cache/` rather than the
;;;; user's Downloads folder and the check does not depend on download-path policy.

(in-package :vovas.cdp)

(defparameter *download-panel-fragment* "/html/page.html"
  "The panel's page, as it appears in a target URL once DevTools loads it.")

(defparameter *download-panel-cycles* 18
  "Ctrl+] presses to spend looking for the panel. It was found at 9.")

;;; ---------------------------------------------------------------------------
;;; Reporting. The stages below are separate functions so each one stays flat;
;;; they share the tally through these rather than through a closure.

(defvar *checks* 0)
(defvar *checks-ok* t)

(defun check (name condition &optional detail)
  (if condition
      (progn (incf *checks*)
             (format t "[vovas] download ~a: OK~@[ (~a)~]~%" name detail))
      (progn (setf *checks-ok* nil)
             (format t "[vovas] download ~a: FAIL~@[ (~a)~]~%" name detail)))
  (force-output))

;;; ---------------------------------------------------------------------------
;;; Target discovery.

(defun targets-matching (browser predicate)
  (loop for target in (tabs browser) when (funcall predicate target) collect target))

(defun extension-frame (browser)
  "The extension's devtools page, which is how the extension id is discovered."
  (first (targets-matching
          browser
          (lambda (target)
            (and (string= (getf target :type) "iframe")
                 (search "/html/devtools.html" (or (getf target :url) "")))))))

(defun devtools-windows (browser)
  (targets-matching browser
                    (lambda (target)
                      (and (string= (getf target :type) "page")
                           (search "devtools_app.html" (or (getf target :url) ""))))))

(defun panel-frame (browser)
  "The extension panel's iframe, once DevTools has loaded it."
  (first (targets-matching
          browser
          (lambda (target)
            (search *download-panel-fragment* (or (getf target :url) ""))))))

(defun inspected-page-targets (browser)
  "Tabs a DevTools panel could inspect. The DevTools frontend is itself a `page`
target, so it has to be excluded or the startup tab is mistaken for the window."
  (targets-matching
   browser
   (lambda (target)
     (and (string= (getf target :type) "page")
          (let ((url (or (getf target :url) "")))
            (and (not (search "devtools://" url))
                 (not (search "chrome-extension://" url))))))))

(defun cycle-to-panel (browser)
  "Press Ctrl+] until DevTools loads the extension panel's iframe, or give up."
  (or (panel-frame browser)
      (loop repeat *download-panel-cycles*
            do (dolist (kind '("keyDown" "keyUp"))
                 (ignore-errors
                  (call browser "Input.dispatchKeyEvent"
                        (list :type kind
                              :modifiers 2
                              :key "]"
                              :code "BracketRight"
                              :windows-virtual-key-code 221))))
               (sleep 0.4)
               (let ((frame (panel-frame browser)))
                 (when frame (return frame))))))

;;; ---------------------------------------------------------------------------
;;; Reading the archive back.

(defun zip-entries (path)
  "Entry names inside the zip at PATH, read by PowerShell's ZipFile.
Returns NIL when the file is not a readable zip."
  (let ((script (format nil
                        "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[System.IO.Compression.ZipFile]::OpenRead('~a'); $z.Entries | ForEach-Object { $_.FullName }; $z.Dispose()"
                        (uiop:native-namestring path))))
    (multiple-value-bind (code out)
        (vovas.tools.util:run-program
         (list (vovas.tools.util:powershell-exe) "-NoProfile" "-Command" script))
      (when (zerop code)
        (remove-if (lambda (line) (zerop (length line)))
                   (vovas.tools.util:split-lines out))))))

(defun zip-entry-text (path entry)
  "Contents of ENTRY inside the zip at PATH, or NIL when it is absent."
  (let ((script (format nil
                        "Add-Type -AssemblyName System.IO.Compression.FileSystem; $z=[System.IO.Compression.ZipFile]::OpenRead('~a'); $e=$z.GetEntry('~a'); if ($e) { $r=New-Object System.IO.StreamReader($e.Open()); $r.ReadToEnd(); $r.Close() }; $z.Dispose()"
                        (uiop:native-namestring path) entry)))
    (multiple-value-bind (code out)
        (vovas.tools.util:run-program
         (list (vovas.tools.util:powershell-exe) "-NoProfile" "-Command" script))
      (when (zerop code) out))))

(defun zip-signature-p (path)
  "Whether PATH begins with the local-file header every zip starts with."
  (with-open-file (stream path :element-type '(unsigned-byte 8) :if-does-not-exist nil)
    (when stream
      (let ((head (make-array 4 :element-type '(unsigned-byte 8) :initial-element 0)))
        (when (= (read-sequence head stream) 4)
          (equalp head #(80 75 3 4)))))))

(defun data-url-bytes (data-url)
  "Decode `data:<type>;base64,<payload>` into octets."
  (let ((comma (position #\, data-url)))
    (unless comma
      (error "not a data URL: ~a" (subseq data-url 0 (min 40 (length data-url)))))
    (cl-base64:base64-string-to-usb8-array (subseq data-url (1+ comma)))))

(defun write-octets (path octets)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede :if-does-not-exist :create)
    (write-sequence octets out))
  path)

;;; ---------------------------------------------------------------------------
;;; A local page with real JavaScript, served for the check.
;;;
;;; `example.com` proves the pipeline but has no scripts, so it cannot exercise
;;; the runtime payload path at all. The fixture has an external script, an
;;; `eval`, a `Function` constructor and a worker - the three runtime payload
;;; kinds the capture records - which makes the check deterministic, offline, and
;;; stronger than a real site would be.

(defun fixture-dir ()
  (uiop:merge-pathnames* "fixtures/download-page/"
                         (uiop:pathname-directory-pathname
                          (uiop:truename* (or *load-truename* *compile-file-truename*
                                              #p"tools/cl/download.lisp")))))

(defparameter *fixture-server-js*
  "const http = require('http'), fs = require('fs'), path = require('path');
const root = process.argv[1], port = Number(process.argv[2]);
const types = { '.html': 'text/html', '.js': 'text/javascript',
                '.css': 'text/css', '.json': 'application/json' };
http.createServer((req, res) => {
  const name = decodeURIComponent(req.url.split('?')[0]);
  const file = path.join(root, name === '/' ? 'index.html' : name);
  fs.readFile(file, (err, body) => {
    if (err) { res.writeHead(404); res.end('not found'); return; }
    res.writeHead(200, { 'content-type': types[path.extname(file)] || 'application/octet-stream' });
    res.end(body);
  });
}).listen(port, '127.0.0.1');")

(defun free-port ()
  (let ((socket (usocket:socket-listen "127.0.0.1" 0)))
    (unwind-protect (usocket:get-local-port socket)
      (usocket:socket-close socket))))

(defun start-fixture-server ()
  "Serve the download fixture on a free port. Returns (values process url)."
  (let* ((port (free-port))
         (process (uiop:launch-program
                   (list (vovas.tools.util:node-exe)
                         "-e" *fixture-server-js*
                         (uiop:native-namestring (fixture-dir))
                         (write-to-string port))
                   :output nil :error-output nil))
         (url (format nil "http://127.0.0.1:~d/" port)))
    (unless (wait-until (lambda ()
                          (multiple-value-bind (status) (http-request "127.0.0.1" port "GET" "/")
                            (= status 200)))
                        :timeout-seconds 15)
      (ignore-errors (uiop:terminate-process process :urgent t))
      (error "the fixture server did not answer on ~a" url))
    (values process url)))

;;; ---------------------------------------------------------------------------
;;; The JS the check runs inside the panel.

(defparameter *hook-js*
  "(function () {
  window.__VOVAS__ = { b64: null, name: null, error: null };
  var create = URL.createObjectURL;
  URL.createObjectURL = function (blob) {
    try {
      if (blob && blob.type === 'application/zip') {
        var reader = new FileReader();
        reader.onload = function () { window.__VOVAS__.b64 = String(reader.result); };
        reader.readAsDataURL(blob);
      }
    } catch (e) { window.__VOVAS__.error = String(e); }
    return create.call(URL, blob);
  };
  var click = HTMLAnchorElement.prototype.click;
  HTMLAnchorElement.prototype.click = function () {
    if (this.download) {
      // Capture the name and stop there. The bytes are already in hand, and a
      // check that runs in CI must not write into the user's Downloads folder
      // every time; the real download was observed working by hand.
      window.__VOVAS__.name = this.download;
      return;
    }
    return click.call(this);
  };
  return 'hooked';
})()"
  "Installed in the panel before the click. `saveBytes` hands the archive to
`URL.createObjectURL`, so hooking it is how the bytes are recovered without
depending on where Chrome decides to write downloads.")

(defparameter *click-js*
  "(function () {
  var button = document.getElementById('downloadBtn');
  if (!button) return 'no download button';
  button.click();
  return 'clicked';
})()")

(defparameter *state-js*
  "(function () {
  var v = window.__VOVAS__;
  if (!v) return 'gone';
  if (v.b64) return 'ready';
  if (v.error) return 'error: ' + v.error;
  var activity = document.getElementById('activityText');
  var text = activity ? activity.textContent : '';
  return text || 'pending';
})()")

;;; ---------------------------------------------------------------------------
;;; Stages.

(defun download-stage-page (browser url)
  "Open URL in the startup tab, so there is exactly one DevTools window."
  (let ((tab (first (inspected-page-targets browser))))
    (connect-target browser tab)
    (nav url :browser browser)
    (let ((title (ignore-errors (eval* "document.title" :browser browser))))
      (check "real page loads" (and (stringp title) (plusp (length title)))
             (or title url))
      (and (stringp title) (plusp (length title))))))

(defun download-stage-panel (browser)
  "Cycle to the panel, hook the archive, and press Download All."
  (let ((devtools (wait-until (lambda () (first (devtools-windows browser)))
                              :timeout-seconds 25)))
    (unless devtools (check "panel iframe loads" nil "no DevTools window") (return-from download-stage-panel nil))
    (connect-target browser devtools)
    (let ((panel (cycle-to-panel browser)))
      (check "panel iframe loads" panel (and panel (getf panel :url)))
      (when panel
        (connect-target browser panel)
        (let ((hooked (ignore-errors (eval* *hook-js* :browser browser))))
          (check "panel hooks the archive" (equal hooked "hooked") hooked))
        (let ((clicked (ignore-errors (eval* *click-js* :browser browser))))
          (check "download clicked" (equal clicked "clicked") clicked)))
      panel)))

(defun download-stage-archive (browser timeout-seconds)
  "Wait for the panel to hand the archive to the browser, then decode it."
  (let ((state (wait-until
                (lambda ()
                  (let ((value (ignore-errors (eval* *state-js* :browser browser))))
                    (and (stringp value)
                         (or (string= value "ready")
                             (search "error" value)
                             (search "failed" value))
                         value)))
                :timeout-seconds timeout-seconds
                :interval 0.5)))
    (check "archive built" (equal state "ready") state)
    (unless (equal state "ready")
      (return-from download-stage-archive nil))
    (let ((name (ignore-errors (eval* "String(window.__VOVAS__.name)" :browser browser))))
      (check "archive is named sources.zip" (equal name "sources.zip") name))
    (let* ((data-url (ignore-errors (eval* "window.__VOVAS__.b64" :browser browser)))
           (octets (and (stringp data-url) (ignore-errors (data-url-bytes data-url)))))
      (check "archive decodes" octets (and octets (length octets)))
      octets)))

(defun download-stage-verify (octets archive expect-runtime)
  "Write OCTETS to ARCHIVE and prove it is the archive the product promises.
EXPECT-RUNTIME also requires the runtime payloads the fixture page generates."
  (unless octets
    (return-from download-stage-verify nil))
  (write-octets archive octets)
  (check "archive is a zip" (zip-signature-p archive) (file-namestring archive))
  (let ((entries (zip-entries archive)))
    (check "archive carries the capture"
           (and entries
                (find-if (lambda (e) (search "_recon/" e)) entries)
                (find-if (lambda (e) (search "_unpack/" e)) entries)
                (find-if (lambda (e) (search "_analysis/" e)) entries))
           (and entries (length entries)))
    (when expect-runtime
      ;; A worker records a url and a workerType rather than inline text, so its
      ;; script arrives as an unpacked asset; only eval and Function produce a
      ;; payload file. The manifest is what says which kinds were seen.
      (let* ((text (zip-entry-text archive "_runtime/runtime-manifest.json"))
             (manifest (and text (ignore-errors (vovas.tools.util:json-decode text))))
             (kinds (and (listp manifest)
                         (remove nil (mapcar (lambda (e) (getf e :kind)) manifest)))))
        (check "manifest records the runtime payloads"
               (and kinds
                    (member "eval" kinds :test #'string=)
                    (member "function" kinds :test #'string=)
                    (member "worker" kinds :test #'string=))
               (and kinds (format nil "~{~a~^,~}" kinds)))
        (dolist (kind '("eval" "function"))
          (check (format nil "runtime ~a payload is written" kind)
                 (find-if (lambda (e) (search (format nil "_runtime/~a/" kind) e)) entries)
                 (and entries (length entries)))))
      ;; The fixture's app.js carries an inline source map, so the unpack path has
      ;; to decode it and recover the original from sourcesContent.
      (check "archive resolves the inline source map"
             (find-if (lambda (e) (search "/source-map.json" e)) entries)
             (and entries (length entries)))
      (check "archive recovers the mapped source"
             (find-if (lambda (e) (search "/sources/app.ts" e)) entries)
             (and entries (length entries)))
      ;; The fixture fetches a real wasm module, so the detector and parser have
      ;; to run and name what the module exports.
      (let ((info-entry (find-if (lambda (e) (search "/wasm-info.json" e)) entries)))
        (check "archive parses the wasm module" info-entry (and entries (length entries)))
        (when info-entry
          (let ((info (zip-entry-text archive info-entry)))
            (check "wasm parse names the export"
                   (and (stringp info) (search "\"answer\"" info))
                   (and info (length info))))))
      (check "runtime wasm payload is written"
             (find-if (lambda (e) (search "_runtime/wasm/" e)) entries)
             (and entries (length entries)))
      ;; The fixture carries a Dean Edwards packed script, so the peel has to
      ;; detect the packer and recover what it unpacks to - the product's
      ;; headline claim, exercised rather than assumed.
      (let ((packer (find-if (lambda (e) (search "/layers/01-packer.js" e)) entries)))
        (check "archive peels the packer layer" packer (and entries (length entries)))
        (when packer
          (let ((text (zip-entry-text archive packer)))
            (check "packer layer unpacks to the payload"
                   (and (stringp text)
                        (search "console.log(\"packed ok\")" text))
                   (and text (length text)))))))))

;;; ---------------------------------------------------------------------------
;;; The check.

(defun download-check (&key headless url fixture (timeout-seconds 120))
  "Load the built extension, open URL, press Download All in the real panel, and
verify the archive it produces. Returns 0 when every check passes, 1 otherwise.

FIXTURE serves `fixtures/download-page` locally and asserts the runtime payloads
it generates, which is stronger than a real site and needs no network. URL
defaults to example.com when neither is given."
  (let ((*checks* 0)
        (*checks-ok* t)
        (dist (string-right-trim "/" (namestring (vovas.tools.util:dist-dir))))
        (archive (uiop:merge-pathnames* "download-check/sources.zip"
                                        (vovas.tools.util:cache-dir)))
        (server nil)
        (browser nil))
    (when fixture
      (multiple-value-setq (server url) (start-fixture-server))
      (check "fixture server answers" url url))
    (setf url (or url "https://example.com"))
    (unwind-protect
         (progn
           (unless (probe-file (uiop:merge-pathnames* "manifest.json"
                                                      (uiop:ensure-directory-pathname dist)))
             (error "no manifest.json in ~a - run `vovas build` first" dist))
           (ignore-errors (delete-file archive))
           (setf browser
                 (launch :headless headless
                         :extra-args (list (format nil "--load-extension=~a" dist)
                                           (format nil "--disable-extensions-except=~a" dist)
                                           "--auto-open-devtools-for-tabs"
                                           "--window-size=1600,1100")))
           (sleep 3)
           (let ((frame (wait-until (lambda () (extension-frame browser))
                                    :timeout-seconds 25)))
             (check "extension loads" frame (and frame (extension-id-of frame)))
             (when (and frame (download-stage-page browser url))
               (let ((panel (download-stage-panel browser)))
                 (when panel
                   (download-stage-verify (download-stage-archive browser timeout-seconds)
                                          archive fixture))))))
      (when browser (kill browser))
      (when server (ignore-errors (uiop:terminate-process server :urgent t))))
    (format t "[vovas] download: ~a (~d checks)~%"
            (if *checks-ok* "OK" "FAILED") *checks*)
    (force-output)
    (if *checks-ok* 0 1)))
