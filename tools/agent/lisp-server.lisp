;;;; lisp-server.lisp --- persistent SBCL service for the agent CLI.
;;;;
;;;; Lives in the project, started by tools/agent/lisp.mjs. Protocol: one
;;;; request line and one reply line per connection, payloads hex-encoded
;;;; UTF-8 so no framing character can appear inside them.
;;;;
;;;;   PING            -> PONG
;;;;   QUIT            -> BYE, then the process exits
;;;;   EVAL <hex-form> -> OK <hex-text> | ERR <hex-text>
;;;;
;;;; The OK/ERR text is exactly what the CLI prints: the form's captured
;;;; output followed by "=> printed values", or the condition text.
;;;; A condition is caught with *debugger-hook* and returned as data, so a
;;;; headless caller never waits on a debugger.
;;;;
;;;; The project's systems are registered from LISP_PROJECT_ROOT (set by the
;;;; CLI) so QL:QUICKLOAD works without a global Quicklisp local-projects
;;;; entry.

(require :sb-bsd-sockets)

(defpackage :agent.server
  (:use :cl)
  (:export #:main))

(in-package :agent.server)

(defparameter *port*
  (or (ignore-errors
        (parse-integer (or (sb-ext:posix-getenv "LISP_SERVER_PORT") "")
                       :junk-allowed t))
      47311))

;;; --- project registration -------------------------------------------------

(defun project-root ()
  "The checkout root: LISP_PROJECT_ROOT, else the server's working directory."
  (or (sb-ext:posix-getenv "LISP_PROJECT_ROOT")
      (namestring (uiop:getcwd))))

(defun register-project ()
  "Register the project's ASDF systems so QL:QUICKLOAD finds them."
  (let ((cl-dir (merge-pathnames "tools/cl/"
                                 (uiop:ensure-directory-pathname (project-root)))))
    (dolist (name '("vovas-engine.asd" "vovas-tools.asd"))
      (let ((asd (merge-pathnames name cl-dir)))
        (when (probe-file asd)
          (asdf:load-asd asd))))))

;;; --- hex -----------------------------------------------------------------

(defun hex-digit (c)
  (cond ((<= (char-code #\0) (char-code c) (char-code #\9))
         (- (char-code c) (char-code #\0)))
        ((<= (char-code #\a) (char-code c) (char-code #\f))
         (+ 10 (- (char-code c) (char-code #\a))))
        ((<= (char-code #\A) (char-code c) (char-code #\F))
         (+ 10 (- (char-code c) (char-code #\A))))
        (t (error "bad hex digit ~s" c))))

(defun hex-decode (string)
  (let* ((n (floor (length string) 2))
         (out (make-array n :element-type '(unsigned-byte 8))))
    (dotimes (i n out)
      (setf (aref out i)
            (logior (ash (hex-digit (char string (* 2 i))) 4)
                    (hex-digit (char string (1+ (* 2 i)))))))))

(defun hex-encode (octets)
  (with-output-to-string (s)
    (loop for b across octets do (format s "~2,'0x" b))))

(defun octets->text (octets)
  (sb-ext:octets-to-string octets :external-format :utf-8))

(defun text->octets (text)
  (sb-ext:string-to-octets text :external-format :utf-8))

;;; --- evaluation ----------------------------------------------------------

(defun agent-eval (string)
  "Evaluate the single form in STRING in CL-USER.
Return (\"ok\" OUTPUT VALUES) or (\"error\" OUTPUT CONDITION)."
  (let ((out (make-string-output-stream)))
    (catch 'agent-abort
      (let ((*debugger-hook*
              (lambda (condition previous-hook)
                (declare (ignore previous-hook))
                (throw 'agent-abort
                       (list "error" (get-output-stream-string out)
                             (format nil "~a" condition)))))
            (*standard-output* out)
            (*error-output* out)
            (*trace-output* out)
            (*package* (find-package :cl-user)))
        (let ((values (multiple-value-list (eval (read-from-string string)))))
          (list "ok" (get-output-stream-string out)
                (format nil "~{~S~^~%~}" values)))))))

;;; --- protocol ------------------------------------------------------------

(defun reply (stream status text)
  (format stream "~a ~a~%" status (hex-encode (text->octets text)))
  (finish-output stream))

(defun handle-line (line stream)
  (cond
    ((string= line "PING")
     (format stream "PONG~%")
     (finish-output stream)
     nil)
    ((string= line "QUIT")
     (format stream "BYE~%")
     (finish-output stream)
     :quit)
    ((and (>= (length line) 5) (string= (subseq line 0 5) "EVAL "))
     (let* ((result (agent-eval (octets->text (hex-decode (subseq line 5)))))
            (status (first result))
            (out (second result))
            (value (third result)))
       (if (string= status "ok")
           (reply stream "OK" (concatenate 'string out "=> " value (string #\Newline)))
           (reply stream "ERR" (concatenate 'string out value (string #\Newline)))))
     nil)
    (t (reply stream "ERR" (format nil "unknown request: ~a" line)) nil)))

(defun serve-connection (conn)
  (unwind-protect
       (with-open-stream
           (stream (sb-bsd-sockets:socket-make-stream
                    conn :input t :output t :buffering :line
                    :external-format :utf-8))
         (loop for line = (read-line stream nil :eof)
               while (not (eq line :eof))
               do (when (eq (handle-line line stream) :quit)
                    (sb-ext:exit :code 0))))
    (ignore-errors (sb-bsd-sockets:socket-close conn))))

(defun main ()
  (register-project)
  (let ((listener (make-instance 'sb-bsd-sockets:inet-socket
                                 :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind listener #(127 0 0 1) *port*)
    (sb-bsd-sockets:socket-listen listener 8)
    (format t "READY ~a~%" *port*)
    (finish-output)
    (loop (serve-connection (sb-bsd-sockets:socket-accept listener)))))
