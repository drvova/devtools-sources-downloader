;;;; cdp.lisp — Chrome DevTools Protocol client: launch/attach, targets,
;;;; evaluate, screenshots. The REPL-facing surface of the toolchain.

(in-package :vovas.cdp)

(defstruct (browser (:constructor %make-browser))
  "A running Chrome with remote debugging."
  process
  port
  user-data-dir
  conn)

(defstruct (cdp-conn (:constructor make-cdp-conn))
  "One WebSocket connection to one target."
  ws
  next-id)

(defvar *browser* nil
  "Default browser handle, set by LAUNCH/ATTACH and consumed by the REPL-facing functions.")

(defun check-browser (browser)
  (unless browser
    (error "no browser: call (vcdp:launch) or (vcdp:attach port) first")))

;;; ---------- lifecycle ----------

(defun launch (&key headless (wait-seconds 30) extra-args profile-name)
  "Launch Chrome for Testing with a fresh profile and --remote-debugging-port=0.
EXTRA-ARGS are appended before the initial URL (extension loading, window size).
PROFILE-NAME picks the profile directory under .cache/cdp-profile, so a caller
that needs a stable profile can name one. Returns the browser handle (also bound
to *browser*)."
  (let* ((chrome (ensure-chrome))
         (udd (uiop:merge-pathnames*
               (format nil "cdp-profile/~a/"
                       (or profile-name (format nil "~d" (get-universal-time))))
               (cache-dir)))
         (argv (append (list (namestring chrome)
                             "--remote-debugging-port=0"
                             (format nil "--user-data-dir=~a" (namestring udd))
                             "--no-first-run"
                             "--no-default-browser-check")
                       (when headless (list "--headless=new"))
                       extra-args
                       (list "about:blank"))))
    (log-line "launching ~a" chrome)
    (let ((proc (uiop:launch-program argv :output nil :error-output nil)))
      (let ((port (loop repeat (* wait-seconds 10)
                        for port = (read-port-file
                                    (uiop:merge-pathnames* "DevToolsActivePort" udd))
                        when port return port
                        do (sleep 0.1))))
        (unless port
          (ignore-errors (uiop:terminate-process proc :urgent t))
          (error "chrome did not report a debug port within ~as" wait-seconds))
        (log-line "chrome up on port ~a" port)
        (setf *browser* (%make-browser :process proc :port port :user-data-dir udd))))))

(defun attach (port)
  "Attach to an already-running Chrome with remote debugging on PORT."
  (multiple-value-bind (status body)
      (http-request "127.0.0.1" port "GET" "/json/version")
    (declare (ignore body))
    (unless (= status 200)
      (error "no chrome with remote debugging on port ~a (HTTP ~a)" port status)))
  (setf *browser* (%make-browser :process nil :port port)))

(defun terminate-tree (process)
  "Terminate PROCESS and every child it spawned.
Chrome forks renderer, GPU and utility processes; terminating only the parent
leaves them running and holding the profile directory, so a gate that launches a
browser on every run leaks a process tree per run."
  (let ((pid (ignore-errors (sb-ext:process-pid process))))
    (if (and pid (member :win32 *features*))
        (ignore-errors
         (vovas.tools.util:run-program
          (list (vovas.tools.util:powershell-exe) "-NoProfile" "-Command"
                (format nil "taskkill /PID ~d /T /F | Out-Null" pid))))
        (ignore-errors (uiop:terminate-process process :urgent t)))))

(defun kill (&optional (browser *browser*))
  "Terminate a launched browser, close connections, remove its profile.
No-op for attached browsers beyond closing the connection."
  (when browser
    (when (browser-conn browser)
      (ignore-errors (ws-close (cdp-conn-ws (browser-conn browser)))))
    (when (browser-process browser)
      (terminate-tree (browser-process browser)))
    (when (browser-user-data-dir browser)
      (sleep 0.3)
      (ignore-errors (uiop:delete-directory-tree
                      (browser-user-data-dir browser) :validate t)))
    (when (eq *browser* browser)
      (setf *browser* nil)))
  (values))


;;; ---------- targets ----------

(defun tabs (&optional (browser *browser*))
  "All targets (/json/list) as a list of plists."
  (check-browser browser)
  (multiple-value-bind (status body)
      (http-request "127.0.0.1" (browser-port browser) "GET" "/json/list")
    (unless (= status 200)
      (error "tabs: HTTP ~a" status))
    (vovas.tools.util:json-decode body)))

(defun parse-ws-url (url)
  "ws://host:port/path -> (values host port path)"
  (unless (uiop:string-prefix-p "ws://" url)
    (error "not a ws:// url: ~a" url))
  (let* ((rest (subseq url 5))
         (slash (position #\/ rest))
         (hostport (if slash (subseq rest 0 slash) rest))
         (path (if slash (subseq rest slash) "/"))
         (colon (position #\: hostport :from-end t)))
    (unless colon
      (error "no port in ws url: ~a" url))
    (values (subseq hostport 0 colon)
            (parse-integer (subseq hostport (1+ colon)))
            path)))

(defun connect-target (browser target)
  "Open (and remember) the websocket connection to TARGET, replacing any
previous connection."
  (let ((ws-url (getf target :web-socket-debugger-url)))
    (unless ws-url
      (error "target has no webSocketDebuggerUrl: ~a" (getf target :url)))
    (multiple-value-bind (host port path) (parse-ws-url ws-url)
      (when (browser-conn browser)
        (ignore-errors (ws-close (cdp-conn-ws (browser-conn browser)))))
      (setf (browser-conn browser)
            (make-cdp-conn :ws (ws-connect host port path) :next-id 0))))
  (values (getf target :url) (getf target :title)))

(defun use (selector &optional (browser *browser*))
  "Connect to the target whose id/url/title contains SELECTOR, or to the
first page target when SELECTOR is NIL."
  (check-browser browser)
  (let* ((targets (tabs browser))
         (target (if selector
                     (find-if (lambda (tt)
                                (some (lambda (field)
                                        (and (getf tt field)
                                             (search selector (getf tt field)
                                                     :test #'char-equal)))
                                      (list :id :url :title)))
                              targets)
                     (find-if (lambda (tt) (string= (getf tt :type) "page")) targets))))
    (unless target
      (error "no target matching ~s" selector))
    (connect-target browser target)))

(defun new-tab (url &optional (browser *browser*))
  "Open a new tab and connect to it. Returns the target plist."
  (check-browser browser)
  (multiple-value-bind (status body)
      (http-request "127.0.0.1" (browser-port browser) "PUT"
                    (format nil "/json/new?~a" (url-encode url)))
    (unless (= status 200)
      (error "new-tab: HTTP ~a: ~a" status body))
    (let ((target (vovas.tools.util:json-decode body)))
      (connect-target browser target)
      target)))

(defun ensure-connection (browser)
  (check-browser browser)
  (or (browser-conn browser)
      (progn
        (use nil browser)
        (or (browser-conn browser)
            (error "could not attach to any page target")))))

;;; ---------- protocol ----------

(defun call (browser method &optional params)
  "One CDP command/response round trip. Returns the result object.
Transport errors drop the cached connection so the next call reconnects."
  (let ((conn (ensure-connection browser)))
    (handler-case
        (let ((id (incf (cdp-conn-next-id conn))))
          (ws-send-text (cdp-conn-ws conn)
                        (vovas.tools.util:json-encode
                         (if params
                             (list :id id :method method :params params)
                             (list :id id :method method))))
          (loop
            (let* ((resp (vovas.tools.util:json-decode
                          (ws-read-message (cdp-conn-ws conn))))
                   (rid (getf resp :id)))
              (when (and rid (eql rid id))
                (let ((err (getf resp :error)))
                  (when err
                    (error "CDP ~a failed: ~a" method (vovas.tools.util:json-encode err))))
                (return (getf resp :result))))))
      (error (e)
        (setf (browser-conn browser) nil)
        (error e)))))

(defun eval* (expr &key (browser *browser*))
  "Evaluate EXPR in the current target with returnByValue.
Returns (values value type); signals on JS exceptions."
  (let* ((result (call browser "Runtime.evaluate"
                       (list :expression expr :return-by-value t :await-promise t)))
         (details (getf result :exception-details)))
    (when details
      (let ((exc (getf details :exception)))
        (error "evaluate failed: ~a"
               (or (and exc (getf exc :description))
                   (getf details :text)
                   (vovas.tools.util:json-encode details)))))
    (let ((r (getf result :result)))
      (values (getf r :value) (getf r :type)))))

(defun nav (url &key (browser *browser*) (timeout-seconds 10))
  "Navigate the current target to URL and wait for document.readyState=complete."
  (call browser "Page.navigate" (list :url url))
  (loop repeat (* timeout-seconds 5)
        do (sleep 0.2)
           (multiple-value-bind (v ok)
               (ignore-errors (eval* "document.readyState" :browser browser))
             (when (and ok (stringp v) (string= v "complete"))
               (return t)))
        finally (error "navigation to ~a did not settle within ~as" url timeout-seconds)))

(defun shot (&key file (browser *browser*))
  "Capture a PNG of the current target. Returns (values path bytes-written)."
  (let* ((result (call browser "Page.captureScreenshot" (list :format "png")))
         (data (getf result :data)))
    (unless data
      (error "captureScreenshot returned no data"))
    (let* ((bytes (cl-base64:base64-string-to-usb8-array data))
           (path (or file
                     (uiop:merge-pathnames*
                      (format nil "cdp-shot-~d.png" (get-universal-time))
                      (cache-dir)))))
      (with-open-file (f path :direction :output :if-exists :supersede
                              :element-type '(unsigned-byte 8))
        (write-sequence bytes f))
      (values path (length bytes)))))

;;; ---------- selftest ----------

(defmacro try (form)
  "Evaluate FORM, returning (values first-value ok-p). An error yields
(values nil nil). Unlike IGNORE-ERRORS this reports success explicitly, so a
check can never mistake a returned value for an error flag."
  `(handler-case (values ,form t)
     (error () (values nil nil))))

(defun smoke-test ()
  "End-to-end selftest of the CDP client against a headless Chrome:
launch, list tabs, open a page with known content, evaluate JS (including a
1MB payload), screenshot. Prints one line per check and a final verdict."
  (let ((checks 0)
        (ok t)
        (browser (launch :headless t)))
    (flet ((check (name condition &optional detail)
             (if condition
                 (progn (incf checks)
                        (format t "[vovas] smoke ~a: OK~@[ (~a)~]~%" name detail))
                 (progn (setf ok nil)
                        (format t "[vovas] smoke ~a: FAIL~@[ (~a)~]~%" name detail)))
             ;; a harness that buffers its verdicts cannot name a hang
             (force-output)))
      (unwind-protect
           (progn
             (multiple-value-bind (ts tabs-ok) (try (tabs browser))
               (check "tabs" (and tabs-ok ts (plusp (length ts)))
                      (and tabs-ok (length ts))))
             (multiple-value-bind (target tab-ok)
                 (try (new-tab "data:text/html,<title>vovas cdp smoke</title><h1>hi</h1>"
                               browser))
               (check "new-tab" (and tab-ok target (getf target :id))
                      (and tab-ok (getf target :id)))
               (when target
                 (let ((ready nil))
                   (loop repeat 25
                         do (multiple-value-bind (v okp)
                                (try (eval* "document.readyState" :browser browser))
                              (when (and okp (stringp v) (string= v "complete"))
                                (setf ready t)
                                (return)))
                            (sleep 0.2))
                   (check "page ready" ready))
                 (multiple-value-bind (v okp) (try (eval* "2+2" :browser browser))
                   (check "evaluate 2+2" (and okp (eql v 4)) v))
                 (multiple-value-bind (v okp) (try (eval* "document.title" :browser browser))
                   (check "evaluate title" (and okp (stringp v)
                                                (search "vovas cdp smoke" v))
                          v))
                 (multiple-value-bind (v okp)
                     (try (eval* "(new Array(1000000)).fill('x').join('')"
                                 :browser browser))
                   (check "1MB payload" (and okp (stringp v) (= (length v) 1000000))
                          (and (stringp v) (length v))))
                 (multiple-value-bind (path okp) (try (shot :browser browser))
                   (let ((size (and okp path (ignore-errors
                                               (vovas.tools.util:file-size path)))))
                     (check "screenshot" (and okp path (> (or size 0) 1000))
                            (and path size)))))))
        (kill browser)))
    (format t "[vovas] smoke: ~a (~d checks)~%" (if ok "OK" "FAILED") checks)
    (force-output)
    ok))
