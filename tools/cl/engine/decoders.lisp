;;;; decoders.lisp — escape decoding, ported from decoders.rs.
;;;;
;;;; `decode-escapes` is the one function `scanner.lisp` needs to give a string
;;;; literal its VALUE (the raw text between the quotes still contains JS
;;;; escapes). `decode-base64-to-bytes` and `bytes-to-text` were appended at the
;;;; end for `sourcemaps.lisp`: an inline source map arrives as a `data:` URI
;;;; whose payload is base64 for a UTF-8 JSON document. The inflate half of
;;;; decoders.rs still lands with the binary tier, where it is actually called.
;;;;
;;;; Everything about this function is a preserved quirk rather than a design:
;;;; the original ran in JavaScript, so its odd cases are the specification.

(in-package :vovas.engine.decoders)

;;; ---------------------------------------------------------------------------
;;; decodeEscapes
;;; ---------------------------------------------------------------------------

(defun parse-hex-prefix (text)
  "JS `parseInt(s, 16)`: the longest valid hex prefix, 0 when there is none.
Truncation rather than failure is what makes `\\x4` (one digit) decode to #\\EOT
instead of throwing, and the oracle pins that shape."
  (let ((value 0)
        (digits 0))
    (loop for c across text
          for d = (digit-value-of-hex c)
          while d
          do (setf value (+ (* value 16) d))
             (incf digits))
    (if (zerop digits) 0 value)))

(defun digit-value-of-hex (c)
  (let ((pos (position (char-downcase c) "0123456789abcdef")))
    pos))

(defun code-unit-to-char (code)
  "A JS `String.fromCharCode` argument: masked to 16 bits. A lone surrogate
cannot exist in a Lisp string, so it degrades to U+FFFD - the documented
divergence the Rust records as well."
  (let* ((unit (logand code #xFFFF))
         (ch (and (not (<= #xD800 unit #xDFFF)) (code-char unit))))
    (or ch (code-char #xFFFD))))

(defun code-point-to-char (code)
  "A JS `String.fromCodePoint` argument: a full code point, U+FFFD when out of
range (the JS throws instead; the Rust degrades, and so does this)."
  (or (and (<= 0 code #x10FFFF) (code-char code))
      (code-char #xFFFD)))

(defun decode-escapes (raw)
  "JS `decodeEscapes(raw)`.

Two documented divergences from the original JavaScript, both inherited from
the Rust port rather than invented here:

  - `\\u{` with no closing brace terminates the scan after emitting one
    replacement, because the JS rewinds its cursor to -1 and loops forever
    re-emitting NUL.
  - A code point above #x10FFFF degrades to U+FFFD, where `fromCodePoint`
    throws.

The trailing-backslash quirk is NOT a divergence and is oracle-pinned: a lone
backslash at the end appends the literal text \"undefined\", because the JS
string-concatenates the result of reading past the end."
  (let* ((n (length raw))
         (out (make-string-output-stream)))
    (labels ((at (i) (and (< i n) (char raw i)))
             (range (from to)
               "The substring RAW[FROM..TO) clamped to the string."
               (subseq raw from (min to n))))
      (loop with i = 0
            while (< i n)
            do (let ((ch (char raw i)))
                 (if (char/= ch #\\)
                     (progn (write-char ch out) (incf i))
                     (progn
                       (incf i)
                       (let ((next (at i)))
                         (cond
                           ;; past the end: the documented "undefined" quirk
                           ((null next)
                            (write-string "undefined" out)
                            (return))
                           ((char= next #\n) (write-char #\Newline out))
                           ((char= next #\r) (write-char #\Return out))
                           ((char= next #\t) (write-char #\Tab out))
                           ((char= next #\b) (write-char (code-char 8) out))
                           ((char= next #\f) (write-char (code-char 12) out))
                           ((char= next #\v) (write-char (code-char 11) out))
                           ((char= next #\0) (write-char (code-char 0) out))
                           ((char= next #\x)
                            (write-char (code-unit-to-char
                                         (parse-hex-prefix (range (1+ i) (+ i 3))))
                                        out)
                            (incf i 2))
                           ((char= next #\u)
                            (if (eql (at (1+ i)) #\{)
                                ;; \u{...}: variable length, braced
                                (let ((close (position #\} raw :start (+ i 2))))
                                  (if close
                                      (progn
                                        (write-char (code-point-to-char
                                                     (parse-hex-prefix
                                                      (range (+ i 2) close)))
                                                    out)
                                        (setf i close))
                                      (progn
                                        ;; divergence: terminate instead of looping
                                        (write-char (code-point-to-char
                                                     (parse-hex-prefix
                                                      (range (+ i 2) (max (+ i 2) (1- n)))))
                                                    out)
                                        (return))))
                                ;; \uXXXX: exactly four digits
                                (progn
                                  (write-char (code-unit-to-char
                                               (parse-hex-prefix
                                                (range (1+ i) (+ i 5))))
                                              out)
                                  (incf i 4))))
                           ;; a backslash before a real newline is a line
                           ;; continuation and contributes nothing
                           ((char= next #\Newline))
                           ((digit-char-p next 8)
                            (let ((octal (list next))
                                  (digits 1))
                              (loop while (and (< digits 3)
                                               (let ((d (at (1+ i))))
                                                 (and d (digit-char-p d 8))))
                                    do (incf i)
                                       (push (char raw i) octal)
                                       (incf digits))
                              (write-char (code-unit-to-char
                                           (parse-integer (coerce (nreverse octal)
                                                                  'string)
                                                          :radix 8))
                                          out)))
                           (t (write-char next out))))
                       (incf i)))))
      (get-output-stream-string out))))

;;; ---------------------------------------------------------------------------
;;; decodeBase64ToBytes — the byte-level half of decoders.rs
;;;
;;; Appended for sourcemaps.lisp: an inline source map arrives as a `data:` URI
;;; whose payload is base64 around a UTF-8 JSON document, so the map reader
;;; needs exactly these two functions and nothing else from the binary tier.
;;;
;;; The decoder is hand-written rather than `cl-base64`, for two reasons that are
;;; both about matching the shipped engine rather than about taste:
;;;
;;;   1. `cl-base64` is not a dependency of `vovas-engine.asd`, and that file
;;;      belongs to the integrator. A hand-written decoder adds no dependency.
;;;   2. The Rust uses `base64 0.22`'s STANDARD engine, whose padding mode is
;;;      RequireCanonical: it REJECTS non-zero trailing bits ("YR==" is an
;;;      InvalidLastSymbol error, not the byte #x61). `cl-base64` accepts them,
;;;      so calling it would silently answer bytes where the engine answers
;;;      null - a difference no oracle case in this module would catch.
;;; ---------------------------------------------------------------------------

(defun ascii-js-space-p (c)
  "util.rs `is_ascii_js_space`: the ASCII whitespace JavaScript's `String
.trim` and base64 normalisation drop. Deliberately NOT `js-whitespace-p`: the
Rust strips only these six here, so U+00A0 or U+FEFF inside a base64 payload
stays and makes the decode fail, and the engine's answer follows the Rust."
  (case c
    ((#\Space #\Tab #\Newline #\Page #\Return) t)
    (t (= (char-code c) 11))))          ; VT; Page above is FF (12)

(defparameter *base64-alphabet*
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  "The STANDARD alphabet. URL-safe input is folded onto it before decoding
rather than being decoded by a second engine, which is what the Rust does.")

(defun base64-digit (c)
  "The 6-bit value of C, or NIL when C is not in the alphabet."
  (position c *base64-alphabet*))

(defun decode-canonical-base64 (text)
  "Decode TEXT, which is already free of whitespace, folded onto the standard
alphabet, and padded to a multiple of four. Answers a `(unsigned-byte 8)`
vector or NIL.

Three rejections, each of them something `base64 0.22` does and a permissive
decoder does not:

  - more than two `=` (the Rust pads an already-padded string, so \"YQ===\"
    becomes \"YQ======\" and fails rather than being repaired),
  - an `=` anywhere before the final padding run,
  - non-zero bits left over after the last whole byte. \"YR==\" carries four
    spare bits set, which the crate reports as InvalidLastSymbol."
  (let* ((n (length text))
         (pad 0))
    (loop while (and (> (- n pad) 0) (char= (char text (- n pad 1)) #\=))
          do (incf pad))
    (when (> pad 2)
      (return-from decode-canonical-base64 nil))
    (let ((out (make-array 0 :element-type '(unsigned-byte 8)
                             :adjustable t :fill-pointer 0))
          (acc 0)
          (bits 0))
      (loop for i from 0 below (- n pad)
            for digit = (base64-digit (char text i))
            do (unless digit
                 ;; includes any '=' that survived the padding run above
                 (return-from decode-canonical-base64 nil))
               (setf acc (logior (ash acc 6) digit))
               (incf bits 6)
               (when (>= bits 8)
                 (decf bits 8)
                 (vector-push-extend (logand #xFF (ash acc (- bits))) out)))
      (when (plusp bits)
        (unless (zerop (logand acc (1- (ash 1 bits))))
          (return-from decode-canonical-base64 nil)))
      out)))

(defun decode-base64-to-bytes (base64)
  "JS `decodeBase64ToBytes`, answering NIL where the JS answers null.

The normalisation is the interesting part and is done here rather than by a
library: whitespace is stripped, the URL-safe characters `-` and `_` are folded
to `+` and `/`, and the string is padded with `=` until its length is a multiple
of four. Padding first is what makes an unpadded payload like \"YQ\" decode at
all; padding unconditionally is what makes an over-padded payload fail."
  (let ((normalized
          (coerce (loop for c across base64
                        unless (ascii-js-space-p c)
                          collect (case c
                                    (#\- #\+)
                                    (#\_ #\/)
                                    (t c)))
                  'string)))
    ;; The Rust counts BYTES here and this counts characters. The two only
    ;; disagree for a non-ASCII character in the payload, and every such
    ;; character is outside the alphabet, so both paths answer NIL regardless
    ;; of how many `=` the padding loop adds.
    (loop while (/= 0 (mod (length normalized) 4))
          do (setf normalized (concatenate 'string normalized "=")))
    (decode-canonical-base64 normalized)))

;;; ---------------------------------------------------------------------------
;;; bytesToText — UTF-8 with replacement characters
;;; ---------------------------------------------------------------------------

(defun bytes-to-text (bytes)
  "JS `bytesToText`: `new TextDecoder('utf-8', { fatal: false })`, i.e. Rust's
`String::from_utf8_lossy`.

The unit of failure is the MAXIMAL INVALID SUBPART, not the byte, and that is
the whole difficulty: #(#xE2 #x9C) is one U+FFFD (a truncated three-byte
sequence), while #(#xE2 #x28 #xA1) is two (a bad second byte ends the subpart
after the lead byte, then #xA1 is its own bad lead). Rust encodes this in
`Utf8Error::error_len()`: one byte for a bad lead or bad second byte, two when
the third byte is bad, three when the fourth is, and \"consume the rest\" when
the tail is merely truncated. Replacement-per-byte decoders get the length of
the output wrong, which then shifts every index a caller computes from it."
  (let ((n (length bytes))
        (out (make-string-output-stream)))
    (labels ((at (i) (aref bytes i))
             (continuation-p (i) (<= #x80 (at i) #xBF))
             (replacement () (write-char (code-char #xFFFD) out)))
      (loop with i = 0
            while (< i n)
            do (let ((lead (at i)))
                 (cond
                   ((<= lead #x7F)
                    (write-char (code-char lead) out)
                    (incf i))
                   ;; two-byte lead. #xC0 and #xC1 are absent on purpose: they
                   ;; can only start an overlong form, which UTF-8 forbids and
                   ;; Rust's width table reports as zero.
                   ((<= #xC2 lead #xDF)
                    (if (and (< (1+ i) n) (continuation-p (1+ i)))
                        (progn
                          (write-char (code-char (logior (ash (logand lead #x1F) 6)
                                                         (logand (at (1+ i)) #x3F)))
                                      out)
                          (incf i 2))
                        (progn (replacement) (incf i))))
                   ((<= #xE0 lead #xEF)
                    ;; The second byte's allowed range is narrower at both
                    ;; ends: #xE0 may not be followed by #x80..#x9F (overlong)
                    ;; and #xED may not be followed by #xA0..#xBF (a surrogate).
                    (let ((low (if (= lead #xE0) #xA0 #x80))
                          (high (if (= lead #xED) #x9F #xBF)))
                      (cond
                        ((or (>= (1+ i) n) (not (<= low (at (1+ i)) high)))
                         (replacement) (incf i))
                        ((or (>= (+ i 2) n) (not (continuation-p (+ i 2))))
                         (replacement) (incf i 2))
                        (t
                         (write-char (code-char (logior (ash (logand lead #x0F) 12)
                                                        (ash (logand (at (1+ i)) #x3F) 6)
                                                        (logand (at (+ i 2)) #x3F)))
                                     out)
                         (incf i 3)))))
                   ((<= #xF0 lead #xF4)
                    (let ((low (if (= lead #xF0) #x90 #x80))
                          (high (if (= lead #xF4) #x8F #xBF)))
                      (cond
                        ((or (>= (1+ i) n) (not (<= low (at (1+ i)) high)))
                         (replacement) (incf i))
                        ((or (>= (+ i 2) n) (not (continuation-p (+ i 2))))
                         (replacement) (incf i 2))
                        ((or (>= (+ i 3) n) (not (continuation-p (+ i 3))))
                         (replacement) (incf i 3))
                        (t
                         (write-char (code-char (logior (ash (logand lead #x07) 18)
                                                        (ash (logand (at (1+ i)) #x3F) 12)
                                                        (ash (logand (at (+ i 2)) #x3F) 6)
                                                        (logand (at (+ i 3)) #x3F)))
                                     out)
                         (incf i 4)))))
                   ;; #x80..#xC1 and #xF5..#xFF: a continuation byte with no lead
                   ;; in front of it, or a lead no UTF-8 sequence can use.
                   (t (replacement) (incf i)))))
      (get-output-stream-string out))))

;;; ---------------------------------------------------------------------------
;;; Exports
;;;
;;; `defpackage :vovas.engine.decoders` lives in package.lisp, which this module
;;; must not edit (it is the integrator's file). Exporting at load time is the
;;; equivalent that stays inside this file: it runs after the package exists and
;;; is idempotent, so a later move of these names into the defpackage is a
;;; no-op here rather than a conflict.
;;; ---------------------------------------------------------------------------

;; NOT `#:` - an uninterned-symbol reader prefix. `(export '(#:foo))` exports
;; nothing, because #:foo is a FRESH symbol that is not the interned FOO the
;; functions were defined under; the call signals "these symbols are not
;; accessible" instead. Quote the interned names, or use strings.
(eval-when (:load-toplevel :execute)
  (export (list (find-symbol "DECODE-BASE64-TO-BYTES" :vovas.engine.decoders)
                (find-symbol "BYTES-TO-TEXT" :vovas.engine.decoders))
          :vovas.engine.decoders))
