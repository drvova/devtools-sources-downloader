;;;; ws.lisp — minimal RFC 6455 WebSocket client over usocket.
;;;; Scope: a localhost CDP client. Text frames both ways, server->client
;;;; fragmentation, ping/pong, close handshake. Client frames are always
;;;; masked as the RFC requires. No TLS (CDP is ws:// on loopback).

(in-package :vovas.cdp.ws)

(define-condition ws-error (error)
  ((message :initarg :message :reader ws-error-message))
  (:report (lambda (c s) (format s "websocket error: ~a" (ws-error-message c)))))

(defun ws-error (format-control &rest args)
  (error 'ws-error :message (apply #'format nil format-control args)))

;; a string DEFCONSTANT mints a fresh object per compile, so reloading the fasl
;; fires DEFCONSTANT-UNEQL even for identical text; defparameter is the honest form
(defparameter +guid+ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(defstruct (ws-conn (:constructor %make-ws-conn))
  "An open WebSocket connection."
  socket
  stream
  open-p)

(defun random-bytes (n)
  (let ((v (make-array n :element-type '(unsigned-byte 8))))
    (map-into v (lambda () (random 256 (make-random-state t))))
    v))

(defun write-bytes (stream bytes)
  (write-sequence bytes stream)
  (force-output stream))

(defun mask-payload (payload mask)
  (let ((out (make-array (length payload) :element-type '(unsigned-byte 8))))
    (loop for i below (length payload)
          do (setf (aref out i) (logxor (aref payload i) (aref mask (mod i 4))))
          finally (return out))))

(defun valid-accept-p (key accept)
  "Verify Sec-WebSocket-Accept = base64(sha1(key || GUID)) per RFC 6455 4.2.2."
  (and accept
       (string= (string-trim " " accept)
                (cl-base64:usb8-array-to-base64-string
                 (ironclad:digest-sequence
                  :sha1
                  (babel:string-to-octets (concatenate 'string key +guid+)
                                          :encoding :utf-8))))))

(defun ws-connect (host port path)
  "Connect to ws://host:port<PATH> and perform the RFC 6455 opening handshake."
  (let ((socket (usocket:socket-connect host port :element-type '(unsigned-byte 8))))
    (handler-case
        (let* ((stream (usocket:socket-stream socket))
               (key (cl-base64:usb8-array-to-base64-string (random-bytes 16)))
               (request (vovas.tools.util:crlf-join
                         (list (format nil "GET ~a HTTP/1.1" path)
                               (format nil "Host: ~a:~a" host port)
                               "Upgrade: websocket"
                               "Connection: Upgrade"
                               (format nil "Sec-WebSocket-Key: ~a" key)
                               "Sec-WebSocket-Version: 13"
                               ""))))
          (write-bytes stream (babel:string-to-octets request :encoding :utf-8))
          (multiple-value-bind (status headers)
              (vovas.tools.util:read-headers stream)
            (let ((accept (cdr (assoc "sec-websocket-accept" headers
                                      :test #'string=))))
              (unless (and (search " 101" status) (valid-accept-p key accept))
                (ws-error "handshake rejected: ~a" (string-trim " " status)))
              (%make-ws-conn :socket socket :stream stream :open-p t))))
      (error (e)
        (ignore-errors (usocket:socket-close socket))
        (error e)))))

(defun send-frame (conn opcode payload)
  "Send one masked frame. OPCODE: 1=text 2=binary 8=close 9=ping 10=pong."
  (unless (ws-conn-open-p conn)
    (ws-error "connection is closed"))
  (let* ((stream (ws-conn-stream conn))
         (len (length payload))
         (mask (random-bytes 4))
         (header (make-array 0 :element-type '(unsigned-byte 8)
                               :adjustable t :fill-pointer 0)))
    (vector-push-extend (logior #x80 opcode) header)
    (cond ((< len 126)
           (vector-push-extend (logior #x80 len) header))
          ((< len 65536)
           (vector-push-extend (logior #x80 126) header)
           (vector-push-extend (ldb (byte 8 8) len) header)
           (vector-push-extend (ldb (byte 8 0) len) header))
          (t
           (vector-push-extend (logior #x80 127) header)
           (loop for i from 7 downto 0
                 do (vector-push-extend (ldb (byte 8 (* 8 i)) len) header))))
    (loop for i below 4
          do (vector-push-extend (aref mask i) header))
    (write-bytes stream
                 (concatenate '(vector (unsigned-byte 8))
                              header
                              (mask-payload payload mask)))))

(defun read-frame (conn)
  "Read one frame. Returns (values opcode payload-bytes final-p)."
  (let* ((stream (ws-conn-stream conn))
         (b0 (read-byte stream))
         (b1 (read-byte stream))
         (opcode (logand b0 #x0F))
         (len7 (logand b1 #x7F))
         (len (cond ((= len7 126)
                     (+ (* 256 (read-byte stream)) (read-byte stream)))
                    ((= len7 127)
                     (loop with n = 0
                           repeat 8
                           do (setf n (+ (* n 256) (read-byte stream)))
                           finally (return n)))
                    (t len7))))
    (when (logbitp 7 b1)
      (ws-error "server sent a masked frame (protocol violation)"))
    (values opcode (read-exactly stream len) (logbitp 7 b0))))

(defun ws-read-message (conn)
  "Read one complete message: reassembles fragments, answers pings with
pongs, signals on close. Returns the payload decoded as UTF-8."
  (handler-case
      (let (acc)
        (loop
          (multiple-value-bind (opcode data fin) (read-frame conn)
            (case opcode
              ((1 2) (setf acc data))
              (0 (unless acc
                   (ws-error "continuation frame with no message in progress"))
                 (setf acc (concatenate '(vector (unsigned-byte 8)) acc data)))
              (8 (setf (ws-conn-open-p conn) nil)
                 (ignore-errors (send-frame conn 8 #()))
                 (ws-error "connection closed by peer"))
              (9 (send-frame conn 10 data))
              (10 nil)
              (t (ws-error "unexpected websocket opcode ~a" opcode)))
            (when (and fin (member opcode '(0 1 2)))
              (return (babel:octets-to-string acc :encoding :utf-8))))))
    (error (e)
      (setf (ws-conn-open-p conn) nil)
      (ignore-errors (usocket:socket-close (ws-conn-socket conn)))
      (error e))))

(defun ws-send-text (conn text)
  (send-frame conn 1 (babel:string-to-octets text :encoding :utf-8)))

(defun ws-close (conn)
  "Send a close frame and drop the socket. Idempotent."
  (when (and conn (ws-conn-open-p conn))
    (setf (ws-conn-open-p conn) nil)
    (ignore-errors (send-frame conn 8 #()))
    (ignore-errors (usocket:socket-close (ws-conn-socket conn))))
  (values))
