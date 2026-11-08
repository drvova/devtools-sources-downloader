;;;; decoders.lisp — escape decoding, ported from decoders.rs.
;;;;
;;;; Only `decode-escapes` is ported here: it is the one function `scanner.lisp`
;;;; needs to give a string literal its VALUE (the raw text between the quotes
;;;; still contains JS escapes). The base64 and inflate halves of decoders.rs
;;;; land with the binary tier, where they are actually called.
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
