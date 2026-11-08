;;;; number.lisp — ECMAScript number semantics.
;;;;
;;;; The panel writes archive paths and report text from numbers, so the
;;;; formatting rules are load-bearing: `1e-7` must print as "1e-7"
;;;; (JavaScript) not "0.0000001" (SBCL). The algorithm is ECMA-262 7.1.12.1
;;;; Number::toString applied to shortest-round-trip digits.
;;;;
;;;; Shortest digits are computed by search, not taken from the host printer:
;;;; SBCL prints a denormal as "4.9406564584124654e-324" where JavaScript
;;;; prints "5e-324", so trusting the host would be wrong on exactly the
;;;; magnitudes the exponent branches exist for. Trying precisions 1..17 and
;;;; requiring the text to read back as the same double is the specification's
;;;; own definition of "the smallest k such that the number reads back".

(in-package :vovas.engine.number)

;; A string, so DEFPARAMETER, not DEFCONSTANT: `defconstant` on a string mints a
;; fresh object per compile and reloading then signals DEFCONSTANT-UNEQL even for
;; identical text. The toolchain's own README records this exact trap.
(defparameter +digit-chars+ "0123456789abcdefghijklmnopqrstuvwxyz")

(defun nan ()
  "A fresh NaN. SBCL has no read-time NaN literal that survives a fasl, so it is
computed: 0/0 is a quiet NaN, and `float` keeps it a double."
  (/ 0d0 0d0))

(defun float-nan-p (value)
  "Whether VALUE is NaN.

NOT `(/= value value)`: on SBCL that SIGNALS floating-point-invalid-operation
rather than answering T, so the idiom silently turns every NaN check into a
crash the moment a NaN actually reaches it."
  (sb-ext:float-nan-p value))

(defun float-infinite-p (value)
  (sb-ext:float-infinity-p value))

;;; ---------------------------------------------------------------------------
;;; Shortest round-trip digits
;;; ---------------------------------------------------------------------------

(defun shortest-digits (abs-value)
  "The shortest digit string that reads back as ABS-VALUE, and N such that the
value is 0.DIGITS x 10^N. ABS-VALUE must be positive, finite and non-zero.

The search must tolerate a precision whose rounding OVERFLOWS: the shortest
candidate for the largest double is 2e308, which does not read back at all
(reading it signals floating-point-overflow, since it exceeds MAX-DOUBLE). A
naive `read-from-string` therefore crashes on the one value that most needs the
search, rather than moving to precision 2. A read that cannot be built is simply
not a candidate."
  (declare (type double-float abs-value))
  (loop for significant from 1 to 17
        do (let* ((directive (format nil "~~,~ae" (1- significant)))
                  (printed (let ((*read-default-float-format* 'double-float))
                             (format nil directive abs-value)))
                  (back (handler-case
                            (let ((*read-default-float-format* 'double-float))
                              (read-from-string printed))
                          (error () nil))))
             (when (and back (= back abs-value))
               (return (split-digits printed))))
        finally (error "no round-trip digits for ~s" abs-value)))

(defun split-digits (printed)
  "Split SBCL's `d.dddde+N` into (values digits n) with DIGITS free of trailing
zeros and N the position of the decimal point after the first significant digit
(ECMA-262's `n`).

The mantissa is NOT always `d.dddd`: at the edge of the exponent range SBCL
prints `10.` - 1e-320 comes out as `10.d-321`. So the point can sit one place
further right than the normal form, and n must account for where the point
actually is: n = exponent + (digits before the point). `10.d-321` and the
equivalent `1.0d-320` then agree, which they must, being the same number."
  (let* ((e-at (or (position #\e printed :test #'char-equal)
                   (error "no exponent in ~s" printed)))
         (mantissa (subseq printed 0 e-at))
         (exponent (parse-integer printed :start (1+ e-at)))
         (point (or (position #\. mantissa) (length mantissa)))
         (digits-before-point (if (plusp point) point 1))
         (flat (remove #\. mantissa))
         (trimmed (string-right-trim "0" flat)))
    (if (string= trimmed "")
        (values "0" 1)
        (values trimmed (+ exponent digits-before-point)))))

;;; ---------------------------------------------------------------------------
;;; Number::toString
;;; ---------------------------------------------------------------------------

(defun to-string (value)
  "JS `String(number)` / `Number.prototype.toString()` (ECMA-262 7.1.12.1).
The five shapes below are the specification's branches."
  (cond
    ((float-nan-p value) "NaN")
    ((zerop value) "0")                     ; -0 prints "0", as JS does
    ((float-infinite-p value)
     (if (plusp value) "Infinity" "-Infinity"))
    ((plusp value) (positive-to-string value))
    (t (concatenate 'string "-" (positive-to-string (- value))))))

(defun positive-to-string (value)
  "The positive, finite, non-zero branch of `to-string`."
  (declare (type double-float value))
  (multiple-value-bind (digits n) (shortest-digits value)
    (let ((k (length digits)))
      (cond
        ;; k <= n <= 21: digits then n-k zeros, no point
        ((<= k n 21)
         (concatenate 'string digits (make-string (- n k) :initial-element #\0)))
        ;; 0 < n <= 21: point after the first n digits
        ((<= 1 n 21)
         (concatenate 'string (subseq digits 0 n) "." (subseq digits n)))
        ;; -6 < n <= 0: "0." then -n zeros then the digits. The bound is STRICT:
        ;; n = -6 is 1e-7, which JavaScript prints in exponent form. Writing
        ;; (<= -6 n 0) includes it and prints "0.0000001" - an off-by-one the
        ;; oracle's cases never reach, caught by the mutation probe instead.
        ((<= -5 n 0)
         (concatenate 'string "0." (make-string (- n) :initial-element #\0) digits))
        (t
         ;; exponent forms; the exponent is n-1 because JS counts from the
         ;; first significant digit
         (let* ((exp (1- n))
                (sign (if (minusp exp) #\- #\+))
                (magnitude (abs exp)))
           (if (= k 1)
               (format nil "~ae~c~a" digits sign magnitude)
               (format nil "~a.~ae~c~a"
                       (subseq digits 0 1) (subseq digits 1) sign magnitude))))))))

;;; ---------------------------------------------------------------------------
;;; Radix and parsing
;;; ---------------------------------------------------------------------------

(defun to-radix-string (value radix)
  "JS `Number.prototype.toString(radix)`, truncated to the integer part, which
is the range the decoder recipes use."
  (assert (<= 2 radix 36) (radix) "radix ~a out of range" radix)
  (cond
    ((float-nan-p value) "NaN")
    ((float-infinite-p value)
     (if (plusp value) "Infinity" "-Infinity"))
    ((zerop value) "0")
    (t
     (let* ((negative (minusp value))
            (int (truncate (abs value)))
            (digits
              (if (zerop int)
                  "0"
                  (with-output-to-string (s)
                    (let ((rev '()))
                      (loop while (plusp int)
                            do (push (char +digit-chars+ (mod int radix)) rev)
                               (setf int (floor int radix)))
                      (dolist (c rev) (write-char c s)))))))
       (if negative (concatenate 'string "-" digits) digits)))))

(defun to-number (text)
  "JS `Number(string)` for the grammar the engine exercises. Answers a
double-float; NAN for the shapes JavaScript answers NaN."
  (let ((s (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) text)))
    (cond
      ((string= s "") 0d0)
      ((string= s "Infinity") sb-ext:double-float-positive-infinity)
      ((string= s "+Infinity") sb-ext:double-float-positive-infinity)
      ((string= s "-Infinity") sb-ext:double-float-negative-infinity)
      ((and (>= (length s) 3)
            (char= (char s 0) #\0)
            (member (char s 1) '(#\x #\X)))
       (let ((v (ignore-errors (parse-integer s :start 2 :radix 16))))
         (if v (coerce v 'double-float) 0d0)))
      (t
       (handler-case
           (let ((*read-default-float-format* 'double-float))
             (let ((v (read-from-string s)))
               ;; `read` accepts symbols and ratios; only a real number counts,
               ;; and a ratio has to be converted rather than rejected
               (if (numberp v) (coerce v 'double-float) (coerce 0 'double-float))))
         (error () 0d0))))))

(defun parse-int (text &optional (radix 10))
  "JS `parseInt`: leading whitespace, optional sign, optional 0x for radix 16,
then the longest valid digit run. A non-numeric prefix answers NAN, which the
decoder recipe treats as a failed count."
  (let* ((s (string-left-trim '(#\Space #\Tab #\Newline #\Return #\Page) text))
         (n (length s))
         (i 0)
         (negative nil))
    (when (zerop n) (return-from parse-int (nan)))
    (when (member (char s i) '(#\- #\+))
      (setf negative (char= (char s i) #\-))
      (incf i))
    (let ((radix* radix))
      (when (and (<= (+ i 2) n)
                 (char= (char s i) #\0)
                 (member (char s (1+ i)) '(#\x #\X)))
        (setf radix* 16)
        (incf i 2))
      (let ((start i)
            (value 0))
        (loop while (< i n)
              do (let ((d (digit-value (char s i) radix*)))
                   (unless d (return))
                   (setf value (+ (* value radix*) d))
                   (incf i)))
        (if (= i start)
            (nan)
            (let ((d (coerce value 'double-float)))
              (if negative (- d) d)))))))

(defun digit-value (c radix)
  "The numeric value of C as a digit in RADIX, or NIL. Zero is a legitimate
digit here, and CL treats 0 as true, so callers must test with NULL."
  (let ((pos (position (char-downcase c) +digit-chars+)))
    (when (and pos (< pos radix)) pos)))

;;; ---------------------------------------------------------------------------
;;; Rounding and fixed notation
;;; ---------------------------------------------------------------------------

(defun js-round (value)
  "JS `Math.round`: halves go toward positive infinity. CL's ROUND rounds half
to even, so it is not usable here."
  (if (or (float-nan-p value) (float-infinite-p value))
      value
      (floor (+ value 0.5d0))))

(defun exact-decimal-expansion (abs-value digits)
  "The exact decimal expansion of ABS-VALUE to DIGITS fractional places
(truncated, not rounded), as an unsigned decimal string.

`(format nil \"~,Nf\" value)` does NOT answer this: SBCL prints the shortest
DECIMAL that round-trips, so 1.45 prints as \"1.4500000...\" even though the
stored double is 1.4499999999999999556... JavaScript's toFixed decides on the
stored value, so rounding a printed decimal disagrees with it precisely on the
ties: 0.15 at one decimal is `0.1` in JS and `0.2` from the decimal text, and
1.005 at two decimals is `1.00` in JS and `1.01` from the decimal text.

The exact value comes from `rational`, which converts a float to the exact
rational it represents, so the expansion is exact by construction."
  (let* ((exact (abs (rational abs-value)))
         (scale (expt 10 digits)))
    (let* ((scaled (numerator exact))
           (den (denominator exact))
           (whole (floor (* scaled scale) den)))
      (let ((text (format nil "~d" whole)))
        (if (zerop digits)
            text
            ;; `whole` already carries `digits` implicit decimals at its end
            (let ((padded (concatenate 'string
                                       (make-string (max 0 (- (1+ digits) (length text)))
                                                    :initial-element #\0)
                                       text)))
              (concatenate 'string
                           (subseq padded 0 (- (length padded) digits))
                           "."
                           (subseq padded (- (length padded) digits)))))))))

(defun to-fixed (value digits)
  "JS `Number.prototype.toFixed`: round to DIGITS decimals, ties away from zero,
decided on the exact binary value.

The expansion needs one extra digit beyond DIGITS, because that digit is what
decides the rounding. It is computed exactly, then rounded half-away-from-zero."
  (cond
    ((or (float-nan-p value) (float-infinite-p value) (>= (abs value) 1d21))
     (to-string value))
    (t
     (let* ((negative (minusp value))
            (abs-value (abs value))
            (expanded (exact-decimal-expansion abs-value (1+ digits)))
            (rounded (round-decimal-half-away expanded digits)))
       ;; JS keeps the sign of a value that rounds to zero: (-0.05).toFixed(0)
       ;; is "-0", not "0"
       (if negative
           (concatenate 'string "-" rounded)
           rounded)))))

(defun round-decimal-half-away (decimal digits)
  "Round the unsigned decimal string DECIMAL (no exponent, no sign) to DIGITS
fractional places, ties away from zero."
  (let* ((point (position #\. decimal))
         (int-part (if point (subseq decimal 0 point) decimal))
         (frac-part (if point (subseq decimal (1+ point)) ""))
         (padded (concatenate 'string frac-part
                              (make-string digits :initial-element #\0)))
         (kept (subseq padded 0 digits))
         (next (if (> (length frac-part) digits) (char frac-part digits) #\0))
         (round-up (char>= next #\5))
         (int-digits (coerce int-part 'list))
         (kept-digits (coerce kept 'list)))
    (when round-up
      (multiple-value-bind (new-kept carry)
          (increment-digits kept-digits)
        (setf kept-digits new-kept)
        (when carry
          (multiple-value-bind (new-int carry2)
              (increment-digits int-digits)
            (setf int-digits new-int)
            (when carry2
              (push #\1 int-digits))))))
    (let ((int-text (coerce int-digits 'string))
          (frac-text (coerce kept-digits 'string)))
      (if (zerop digits)
          int-text
          (concatenate 'string int-text "." frac-text)))))

(defun increment-digits (digits)
  "Add one to the rightmost digit of DIGITS with carry leftward. Answers
(values new-digits carried-out-of-the-most-significant-digit-p)."
  (let ((result (reverse digits))
        (carry t))
    (setf result
          (loop for d in result
                collect (if carry
                            (if (char= d #\9)
                                #\0
                                (progn (setf carry nil)
                                       (code-char (1+ (char-code d)))))
                            d)))
    (values (reverse result) carry)))
