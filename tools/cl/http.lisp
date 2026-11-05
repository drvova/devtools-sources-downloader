;;;; http.lisp — minimal HTTP/1.1 client for Chrome's /json endpoints.
;;;; Loopback only, no TLS: anything needing TLS (downloads) goes through
;;;; powershell, which owns the system trust store.

(in-package :vovas.cdp.http)

(defun http-request (host port method path)
  "One HTTP/1.1 request with Connection: close. Returns (values status body-string).
Reads the body by Content-Length when present, else to EOF."
  (let ((socket (usocket:socket-connect host port :element-type '(unsigned-byte 8))))
    (unwind-protect
         (let ((stream (usocket:socket-stream socket)))
           (write-sequence
            (babel:string-to-octets
             (vovas.tools.util:crlf-join
              (list (format nil "~a ~a HTTP/1.1" method path)
                    (format nil "Host: ~a:~a" host port)
                    "Connection: close"
                    "")))
            stream)
           (force-output stream)
           (multiple-value-bind (status headers) (vovas.tools.util:read-headers stream)
             (let* ((cl (cdr (assoc "content-length" headers :test #'string=)))
                    (body-bytes (if cl
                                    (vovas.tools.util:read-exactly
                                     stream (parse-integer cl :junk-allowed t))
                                    (vovas.tools.util:read-until-eof stream))))
               (values (progn
                         (unless (and status (>= (length status) 12))
                           (error "malformed HTTP status line: ~a" status))
                         (parse-integer (subseq status 9 12)))
                       (babel:octets-to-string body-bytes :encoding :utf-8)))))
      (ignore-errors (usocket:socket-close socket)))))
