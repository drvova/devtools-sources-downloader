;;;; util.lisp — the JavaScript string semantics the panel's path writers depend on.
;;;;
;;;; Every function here exists because Common Lisp's default answer is not
;;;; JavaScript's:
;;;;   - `string-trim` uses CL whitespace, which misses U+FEFF and includes
;;;;     nothing JavaScript considers a line terminator it does not.
;;;;   - `length` counts characters; JavaScript counts UTF-16 code units, so an
;;;;     astral character is 1 in CL and 2 in JS. Archive paths are truncated by
;;;;     the JS number, so the two would disagree on every emoji.
;;;; The UTF-16 view is therefore explicit and named, never implied.

(in-package :vovas.engine.util)

;;; ---------------------------------------------------------------------------
;;; Whitespace
;;; ---------------------------------------------------------------------------

(declaim (inline js-whitespace-p))
(defun js-whitespace-p (c)
  "ECMAScript WhiteSpace + LineTerminator, the set String.prototype.trim
removes: tab, LF, VT, FF, CR, space, and the Unicode spaces JavaScript's `\\s`
also matches. NBSP and BOM are in this set; CL's `whitespace` omits the BOM."
  (or (case c
        ((#\Tab #\Newline #\Page #\Return) t)
        (#\Space t)
        (t nil))
      (let ((code (char-code c)))
        (or (= code #x0B)                 ; VT
            (= code #x00A0)               ; NBSP
            (= code #x1680)               ; OGHAM SPACE MARK
            (<= #x2000 code #x200A)       ; EN QUAD .. HAIR SPACE
            (= code #x2028)               ; LINE SEPARATOR
            (= code #x2029)               ; PARAGRAPH SEPARATOR
            (= code #x202F)               ; NARROW NO-BREAK SPACE
            (= code #x205F)               ; MEDIUM MATHEMATICAL SPACE
            (= code #x3000)               ; IDEOGRAPHIC SPACE
            (= code #xFEFF)))))           ; ZERO WIDTH NO-BREAK SPACE (BOM)

(defun js-trim (text)
  "String.prototype.trim. Returns a fresh string (never a displaced one) so a
caller cannot accidentally share storage with the input."
  (let* ((n (length text))
         (start (loop for i from 0 below n
                      while (js-whitespace-p (char text i))
                      finally (return i)))
         (end (loop for i from n downto (1+ start)
                    while (js-whitespace-p (char text (1- i)))
                    finally (return i))))
    (subseq text start end)))

;;; ---------------------------------------------------------------------------
;;; UTF-16 code units: JavaScript's unit of string length and index
;;; ---------------------------------------------------------------------------

(defun utf16-units (text)
  "The UTF-16 code units of TEXT as a vector of integers. Characters outside the
BMP (above U+FFFF) become a surrogate pair, which is why a length computed on
this vector differs from (length text) whenever TEXT holds one."
  (let ((out (make-array 0 :element-type 'fixnum :adjustable t :fill-pointer 0)))
    (loop for c across text
          for code = (char-code c)
          do (if (> code #xFFFF)
                 (let ((v (- code #x10000)))
                   (vector-push-extend (+ #xD800 (ash v -10)) out)
                   (vector-push-extend (+ #xDC00 (logand v #x3FF)) out))
                 (vector-push-extend code out)))
    out))

(defun utf16-length (text)
  "JS `text.length`."
  (loop for c across text
        sum (if (> (char-code c) #xFFFF) 2 1)))

(defun utf16-prefix (text n)
  "JS `text.slice(0, n)`: the first N UTF-16 units. A surrogate pair is never
split, so a truncated astral character is dropped rather than half-written."
  (let ((units 0)
        (end 0))
    (loop for c across text
          for width = (if (> (char-code c) #xFFFF) 2 1)
          while (<= (+ units width) n)
          do (incf units width)
             (incf end))
    (subseq text 0 end)))

(defun utf16-suffix (text n)
  "JS `text.slice(-n)`: the last N UTF-16 units."
  (let ((total (utf16-length text)))
    (if (<= total n)
        (copy-seq text)
        (utf16-substring text (- total n) total))))

(defun utf16-substring (text start &optional end)
  "JS `text.slice(start, end)` on UTF-16 boundaries."
  (let* ((total (utf16-length text))
         (to (min (or end total) total))
         (from (min start to)))
    (if (= from to)
        ""
        (let ((units 0)
              (begin-byte nil)
              (end-byte (length text))
              (index 0))
          (loop for c across text
                for width = (if (> (char-code c) #xFFFF) 2 1)
                do (when (and (null begin-byte) (>= units from))
                     (setf begin-byte index))
                   (when (and (>= units to)
                              (= end-byte (length text)))
                     (setf end-byte index))
                   (incf units width)
                   (incf index))
          (when (null begin-byte)
            (setf begin-byte (length text)))
          (subseq text (or begin-byte 0) end-byte)))))

;;; ---------------------------------------------------------------------------
;;; Path-hostile characters: one definition, shared by every producer
;;; ---------------------------------------------------------------------------

(defun bad-path-chars-p (c)
  "Characters a single path segment may not contain. `/` is deliberately
absent: it is the separator this set is applied *between*."
  (case c
    ((#\\ #\: #\* #\? #\") t)
    ((#\< #\> #\|) t)
    (t nil)))

(defun bad-path-chars-with-slash-p (c)
  "The same set plus `/`, for sanitising a whole path in one pass."
  (or (bad-path-chars-p c) (char= c #\/)))

;;; ---------------------------------------------------------------------------
;;; Regex metacharacter escaping (the JS `s.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')`
;;; idiom, used to build cl-ppcre patterns from literal text)
;;; ---------------------------------------------------------------------------

(defun regex-escape (text)
  (with-output-to-string (s)
    (loop for c across text
          do (when (member c '(#\. #\* #\+ #\? #\^ #\$ #\{ #\} #\( #\) #\| #\[ #\] #\\))
               (write-char #\\ s))
             (write-char c s))))
