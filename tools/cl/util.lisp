;;;; util.lisp — paths, subprocesses, logging, IO and JSON plumbing shared by everything.

(in-package :vovas.tools.util)

(defvar *repo-root* nil
  "Repository root, resolved once. The directory containing tools/cl/.")

(defun repo-root ()
  "Locate the repository root: the directory containing tools/cl/run.lisp.
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
                      when (probe-file (uiop:merge-pathnames* "tools/cl/run.lisp" dir))
                        return dir)
                (error "cannot locate the repository root (no tools/cl/run.lisp above the cwd)")))))

(defun cache-dir ()
  "Toolchain scratch: Chrome for Testing, CDP profiles, screenshots."
  (uiop:merge-pathnames* ".cache/" (repo-root)))

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

(defun find-on-path (name)
  "Find NAME on the PATH environment variable. Returns the full path or NIL."
  (loop for dir in (split-on #\; (uiop:getenv "PATH"))
        for candidate = (and (plusp (length dir))
                             (uiop:merge-pathnames*
                              name (uiop:ensure-directory-pathname dir)))
        for probe = (and candidate (ignore-errors (uiop:truename* candidate)))
        when (and probe (probe-file probe))
          return (namestring probe)))
(defun powershell-exe ()
  (or (find-on-path "powershell.exe")
      "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"))

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

;;; ---------- json: the wire boundary ----------
;; JSON exists in exactly one place, and it is Chrome's: the DevTools Protocol.
;; Everything above this boundary is Lisp data —
;; objects are plists keyed by keywords, arrays are lists — so call sites read
;; like the data they carry instead of building hash-tables by hand.

(defun json-key->keyword (name)
  "camelCase JSON key -> lisp-case keyword: exceptionDetails -> :EXCEPTION-DETAILS."
  (let ((out (make-string-output-stream)))
    (loop for ch across name
          for i from 0
          do (cond ((upper-case-p ch)
                    (when (plusp i) (write-char #\- out))
                    (write-char (char-downcase ch) out))
                   (t (write-char ch out))))
    (intern (string-upcase (get-output-stream-string out)) :keyword)))

(defun keyword->json-key (keyword)
  ":EXCEPTION-DETAILS -> exceptionDetails. The inverse of JSON-KEY->KEYWORD."
  (let ((out (make-string-output-stream))
        (upcase-next nil))
    (loop for ch across (string-downcase (symbol-name keyword))
          do (cond ((char= ch #\-) (setf upcase-next t))
                   (upcase-next (write-char (char-upcase ch) out)
                                (setf upcase-next nil))
                   (t (write-char ch out))))
    (get-output-stream-string out)))

(defun json->lisp (value)
  "Parsed JSON -> Lisp data. Objects become plists, arrays become lists.
JSON null and false both become NIL: every consumer here asks 'is it there',
and neither answer is a value."
  (cond ((eq value 'null) nil)
        ((hash-table-p value)
         (loop for k being the hash-keys of value using (hash-value v)
               collect (json-key->keyword k)
               collect (json->lisp v)))
        ((and (vectorp value) (not (stringp value)))
         (loop for v across value collect (json->lisp v)))
        (t value)))

(defun lisp->json (value)
  "Lisp data -> what jzon serializes. A plist becomes an object, any other list
an array, a keyword its name as a string, T true, NIL false. CL:NULL (jzon's own
null marker) passes through untouched."
  (cond ((eq value 'null) value)
        ((null value) nil)
        ((eq value t) t)
        ((keywordp value) (string-downcase (symbol-name value)))
        ((stringp value) value)
        ((numberp value) value)
        ((and (consp value) (keywordp (first value)))
         (let ((h (make-hash-table :test 'equal)))
           (loop for (k v) on value by #'cddr
                 do (setf (gethash (keyword->json-key k) h) (lisp->json v)))
           h))
        ((listp value) (coerce (mapcar #'lisp->json value) 'vector))
        ((vectorp value) (coerce (mapcar #'lisp->json value) 'vector))
        (t value)))

(defun json-decode (string)
  "Parse JSON into Lisp data: plists for objects, lists for arrays."
  (json->lisp (com.inuoe.jzon:parse string)))

(defun json-encode (value)
  "Serialize Lisp data to JSON: plists become objects, lists become arrays."
  (com.inuoe.jzon:stringify (lisp->json value)))
