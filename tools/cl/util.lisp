;;;; util.lisp — paths, subprocesses, logging, IO and JSON plumbing shared by everything.

(in-package :vovas.tools.util)

(defvar *repo-root* nil
  "Repository root, resolved once. The directory containing unpack-rs/.")

(defun repo-root ()
  "Locate the repository root: the directory containing unpack-rs/package.json.
Tries the ASDF system location first (dev runs), then walks up from argv0 or
the cwd (standalone-image runs)."
  (or *repo-root*
      (setf *repo-root*
            (or (ignore-errors
                  (let ((sys (ignore-errors (asdf:find-system "vovas-tools" nil))))
                    (when sys
                      ;; system lives at <root>/tools/cl/ — two levels up
                      (uiop:pathname-parent-directory-pathname
                       (uiop:pathname-parent-directory-pathname
                        (asdf:system-source-directory sys))))))
                (loop with start = (or (ignore-errors
                                         (uiop:pathname-directory-pathname
                                          (uiop:truename* (uiop:argv0))))
                                       (uiop:getcwd))
                      for dir = start then (uiop:pathname-parent-directory-pathname dir)
                      while dir
                      when (probe-file (uiop:merge-pathnames* "unpack-rs/package.json" dir))
                        return dir)
                (error "cannot locate the repository root (no unpack-rs/package.json above the cwd)")))))

(defun log-line (format-control &rest args)
  (format t "[vovas] ~?~%" format-control args)
  (force-output))

;;; ---------- text helpers ----------

(defun split-on (char s)
  "Split S on CHAR; empty pieces are kept."
  (loop for start = 0 then (1+ end)
        for end = (position char s :start start)
        collect (subseq s start (or end (length s)))
        until (null end)))

(defun split-lines (s)
  "Split S on newlines, trimming trailing carriage returns."
  (mapcar (lambda (l) (string-trim '(#\Return) l))
          (split-on #\Newline s)))

(defun crlf-join (lines)
  "Join LINES with explicit CRLF terminators (HTTP needs exact CRLF; ~% is
implementation-dependent on Windows)."
  (with-output-to-string (s)
    (dolist (l lines)
      (write-string l s)
      (write-char (code-char 13) s)
      (write-char (code-char 10) s))))

(defun url-encode (s)
  "Percent-encode everything except unreserved characters (RFC 3986)."
  (with-output-to-string (out)
    (loop for b across (babel:string-to-octets s :encoding :utf-8)
          do (let ((c (code-char b)))
               (if (or (alpha-char-p c) (digit-char-p c)
                       (find c "-_.~" :test #'char=))
                   (write-char c out)
                   (format out "%~2,'0x" b))))))

;;; ---------- binary stream helpers ----------

(defun read-exactly (stream n)
  "Read exactly N bytes from a binary stream; a true EOF signals."
  (let ((buf (make-array n :element-type '(unsigned-byte 8))))
    (loop with got = 0
          while (< got n)
          for n-read = (read-sequence buf stream :start got :end n)
          when (= n-read got)
            do (error 'end-of-file :stream stream)
          do (setf got n-read))
    buf))

(defun read-until-eof (stream)
  "Read every byte until the peer closes. Returns an octet vector."
  (let ((buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (chunk (make-array 4096 :element-type '(unsigned-byte 8))))
    (loop for n = (read-sequence chunk stream)
          do (loop for i below n
                   do (vector-push-extend (aref chunk i) buf))
          until (< n 4096))
    buf))

(defun read-until-double-crlf (stream)
  "Read bytes through the first CRLFCRLF (end of HTTP headers). Returns octets."
  (let ((buf (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop with window = 0
          for b = (read-byte stream)
          do (vector-push-extend b buf)
             ;; keep the last 4 bytes as a big-endian 32-bit window
             (setf window (logior (ash (logand window #xFFFFFF) 8) b))
          until (= window #x0D0A0D0A)
          finally (return buf))))

(defun parse-headers (text)
  "Split an HTTP header block into (values status-line header-alist)."
  (let ((lines (split-lines text)))
    (values (first lines)
            (loop for line in (rest lines)
                  for colon = (position #\: line)
                  when (and colon (plusp colon))
                    collect (cons (string-downcase (string-trim " " (subseq line 0 colon)))
                                  (string-trim " " (subseq line (1+ colon))))))))

(defun read-headers (stream)
  "Read a response head off a binary stream. Returns (values status-line header-alist)."
  (parse-headers (babel:octets-to-string (read-until-double-crlf stream) :encoding :utf-8)))

;;; ---------- filesystem ----------

(defun file-size (path)
  (with-open-file (f path :element-type '(unsigned-byte 8))
    (file-length f)))

;;; ---------- processes ----------

(defun split-on-char (char s)
  (split-on char s))

(defun find-on-path (name)
  "Find NAME on the PATH environment variable. Returns the full path or NIL."
  (loop for dir in (split-on-char #\; (uiop:getenv "PATH"))
        for candidate = (and (plusp (length dir))
                             (uiop:merge-pathnames*
                              name (uiop:ensure-directory-pathname dir)))
        for probe = (and candidate (ignore-errors (uiop:truename* candidate)))
        when (and probe (probe-file probe))
          return (namestring probe)))
(defun node-exe ()
  (or (find-on-path "node.exe") (error "node.exe not found on PATH")))

(defun cargo-exe ()
  (or (find-on-path "cargo.exe") (error "cargo.exe not found on PATH")))

(defun powershell-exe ()
  (or (find-on-path "powershell.exe")
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"))

(defun npm-argv (args)
  "Run npm through node directly: npm.cmd is a batch wrapper that only adds
cmd.exe quoting problems. The real entry point is npm-cli.js beside node."
  (let* ((node (node-exe))
         (npm-cli (uiop:merge-pathnames*
                   "node_modules/npm/bin/npm-cli.js"
                   (uiop:pathname-directory-pathname node))))
    (unless (probe-file npm-cli)
      (error "npm-cli.js not found at ~a (is npm installed beside node?)" npm-cli))
    (list* node (namestring npm-cli) args)))

(defun cargo-argv (args)
  (cons (cargo-exe) args))

(defun directory-string (path)
  "Native namestring of directory PATH with no trailing separator.
SBCL's run-program :directory reads a trailing separator as \"PATH is a file,
use its parent\", so a directory pathname passed verbatim silently runs the
child one level up. Strip it at the single place that hands paths to children."
  (string-right-trim '(#\/ #\\) (uiop:native-namestring path)))
(defun run-program (argv &key cwd)
  "Run ARGV (list of strings) capturing stdout/stderr.
Returns (values exit-code stdout stderr); never signals on nonzero exit.
UIOP's :cwd is silently ignored by this SBCL, so the directory goes straight to
SB-EXT:RUN-PROGRAM, which honours it. Capturing through string streams keeps
stdout and stderr separate without temp files."
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream)))
    (let ((proc (sb-ext:run-program (first argv) (rest argv)
                                    :output out
                                    :error err
                                    :search t
                                    :wait nil
                                    :directory (and cwd (directory-string cwd)))))
      (sb-ext:process-wait proc)
      (values (or (sb-ext:process-exit-code proc) 1)
              (get-output-stream-string out)
              (get-output-stream-string err)))))

(defun print-tail (text n)
  "Print the last N non-empty lines of TEXT."
  (let* ((lines (remove-if (lambda (l) (zerop (length (string-trim " " l))))
                           (split-lines text)))
         (tail (last lines (min n (length lines)))))
    (dolist (l tail)
      (write-line l))))

(defun run-step (label argv &key cwd)
  "Run one pipeline step with timing, a verdict line and failure output.
Returns the exit code."
  (log-line "~a: ~{~a~^ ~}" label argv)
  (let ((start (get-internal-real-time)))
    (multiple-value-bind (code out err) (run-program argv :cwd cwd)
      (let ((secs (/ (- (get-internal-real-time) start)
                     internal-time-units-per-second)))
        (format t "[vovas] ~a -> ~a (~,1fs)~%" label (if (zerop code) "OK" "FAIL") secs)
        (force-output)
        (if (zerop code)
            (print-tail out 3)
            (progn
              (format t "--- stdout ---~%~a" out)
              (format t "--- stderr ---~%~a---~%" err)))
        code))))

;;; ---------- json ----------

(defun json-parse (s)
  (com.inuoe.jzon:parse s))

(defun json-stringify (v)
  (com.inuoe.jzon:stringify v))

(defun json-obj (&rest pairs)
  "Build a JSON object (hash-table keyed by lowercase strings) from
alternating keyword keys and values."
  (let ((h (make-hash-table :test 'equal)))
    (loop for (k v) on pairs by #'cddr
          do (setf (gethash (string-downcase (string k)) h) v))
    h))
