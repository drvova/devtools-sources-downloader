;;;; transforms.lisp — the peel chain's decoder helpers, ported from transforms.rs.
;;;;
;;;; This file currently holds only the URI-component codec, which is the piece
;;;; scanner/sourcemaps/panel all reach for. The peel chain itself (`peel_text`,
;;;; `collect_eval_payloads`, SOURCE_URL_COMMENT) lands with the pipeline slice,
;;;; because those consume detectors, packers and jsfuck and would be a forward
;;;; dependency until those exist.
;;;;
;;;; ONE DEFINITION. `vovas.engine.text` used to carry a private copy of the
;;;; strict decoder; it now calls this one. Two implementations of a decoder is
;;;; how the panel and the engine end up disagreeing about an archive path.

(in-package :vovas.engine.transforms)

;;; ---------------------------------------------------------------------------
;;; decodeURIComponent
;;; ---------------------------------------------------------------------------

(defun hex-digit-value (c)
  "The value of C as a hex digit, or NIL. Returning NIL rather than 0 for a
non-digit is what makes an invalid escape fail the decode instead of silently
producing a NUL byte."
  (position (char-downcase c) "0123456789abcdef"))

(defun decode-uri-component (text)
  "JS `decodeURIComponent`: strict %XX decoding, `+` is NOT a space, and an
invalid sequence or invalid UTF-8 answers NIL where the JS throws.

Two failure modes the strictness covers, both of which a lenient decoder would
silently accept:
  - a `%` with fewer than two characters after it
  - a `%XX` triple whose bytes are not valid UTF-8 (lone continuation bytes,
    overlong forms, surrogate encodings, truncated tails)
"
  (let* ((n (length text))
         (out (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 0)))
    (loop with i = 0
          while (< i n)
          do (let ((c (char text i)))
               (if (char= c #\%)
                   (progn
                     ;; needs TWO characters after the '%'
                     (when (> (+ i 2) (1- n))
                       (return-from decode-uri-component nil))
                     (let ((hi (hex-digit-value (char text (1+ i))))
                           (lo (hex-digit-value (char text (+ i 2)))))
                       (unless (and hi lo)
                         (return-from decode-uri-component nil))
                       (vector-push-extend (+ (* 16 hi) lo) out)
                       (incf i 3)))
                   (progn
                     ;; a literal non-ASCII character contributes its UTF-8 bytes;
                     ;; `loop ... across` not `dolist`, which needs a LIST and the
                     ;; octets come back as a vector
                     (loop for b across (sb-ext:string-to-octets (string c)
                                                                 :external-format :utf-8)
                           do (vector-push-extend b out))
                     (incf i)))))
    (utf8-strict-decode out)))

(defun utf8-strict-decode (octets)
  "Decode OCTETS as UTF-8, answering NIL for any malformed sequence.

JavaScript's decodeURIComponent REJECTS overlong forms, encoded surrogates and
truncated tails; it does not substitute U+FFFD. A permissive decoder here would
turn `%ZZ`-adjacent garbage into plausible-looking paths, which is worse than
failing."
  (let ((n (length octets))
        (out (make-string-output-stream)))
    (labels ((at (i) (aref octets i)))
      (loop with i = 0
            while (< i n)
            do (let ((b (at i)))
                 (cond
                   ((< b #x80)
                    (write-char (code-char b) out)
                    (incf i))
                   ((= (logand b #xE0) #xC0)
                    (when (> (+ i 2) n) (return-from utf8-strict-decode nil))
                    (let ((b2 (at (1+ i))))
                      (unless (= (logand b2 #xC0) #x80)
                        (return-from utf8-strict-decode nil))
                      (let ((code (logior (ash (logand b #x1F) 6) (logand b2 #x3F))))
                        (when (< code #x80)
                          (return-from utf8-strict-decode nil))     ; overlong
                        (write-char (code-char code) out))
                      (incf i 2)))
                   ((= (logand b #xF0) #xE0)
                    (when (> (+ i 3) n) (return-from utf8-strict-decode nil))
                    (let ((b2 (at (1+ i))) (b3 (at (+ i 2))))
                      (unless (and (= (logand b2 #xC0) #x80)
                                   (= (logand b3 #xC0) #x80))
                        (return-from utf8-strict-decode nil))
                      (let ((code (logior (ash (logand b #x0F) 12)
                                          (ash (logand b2 #x3F) 6)
                                          (logand b3 #x3F))))
                        (when (or (< code #x800) (<= #xD800 code #xDFFF))
                          (return-from utf8-strict-decode nil))     ; overlong / surrogate
                        (write-char (code-char code) out))
                      (incf i 3)))
                   ((= (logand b #xF8) #xF0)
                    (when (> (+ i 4) n) (return-from utf8-strict-decode nil))
                    (let ((b2 (at (1+ i))) (b3 (at (+ i 2))) (b4 (at (+ i 3))))
                      (unless (and (= (logand b2 #xC0) #x80)
                                   (= (logand b3 #xC0) #x80)
                                   (= (logand b4 #xC0) #x80))
                        (return-from utf8-strict-decode nil))
                      (let ((code (logior (ash (logand b #x07) 18)
                                          (ash (logand b2 #x3F) 12)
                                          (ash (logand b3 #x3F) 6)
                                          (logand b4 #x3F))))
                        (when (or (< code #x10000) (> code #x10FFFF))
                          (return-from utf8-strict-decode nil))
                        (write-char (code-char code) out))
                      (incf i 4)))
                   (t (return-from utf8-strict-decode nil)))))
      (get-output-stream-string out))))

;;; ---------------------------------------------------------------------------
;;; The sourceURL comment pattern
;;;
;;; transforms.rs owns this constant and bundler.rs imports it. It is spelled
;;; ONCE here; bundler.lisp must reference this rather than its own copy. The
;;; bundler gate asserts the two agree, so a divergence fails loudly instead of
;;; quietly changing which module names get written into the archive.
;;; ---------------------------------------------------------------------------

(defparameter *source-url-comment* "//[#@]\\s*sourceURL\\s*=\\s*(\\S+)"
  "The `//# sourceURL=` comment pattern, verbatim from transforms.rs's
SOURCE_URL_COMMENT.")
