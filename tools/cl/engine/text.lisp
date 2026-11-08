;;;; text.lisp — the panel's path/text helpers, ported from panel/text.rs.
;;;;
;;;; Every function here was held to `tests/fixtures/text-helpers.json`, which
;;;; was captured from the shipped `page.js` before the Rust port. The gate reads
;;;; the same file, so the Lisp answers are compared against the same JavaScript
;;;; answers the Rust is.
;;;;
;;;; Two deliberate differences from the Rust, both forced by the language:
;;;;   - `sanitize-filename` does not delegate URL parsing to a library. Rust
;;;;     used the `url` crate (WHATWG URL); SBCL has no such thing in quicklisp,
;;;;     so the parser is written here against the WHATWG rules the oracle
;;;;     exercises. It is stricter about what it accepts and falls to the same
;;;;     manual-segment path the original JS used for unparseable input.
;;;;   - `string-replace-bad` takes a predicate, so the two character sets stay
;;;;     one definition each rather than being inlined as regex classes.

(in-package :vovas.engine.text)

;;; ---------------------------------------------------------------------------
;;; hashString: the Java-style 32-bit rolling hash, rendered as unsigned hex
;;; ---------------------------------------------------------------------------

(defun hash-string (text)
  "`hashString` from the panel: `h = (h * 31 + charCode) | 0` over UTF-16 code
units, then `Math.abs(h).toString(16)`.

The mask keeps the value in 32 bits and the signed reinterpretation is what
makes `(abs h)` match JS rather than saturating: the original's `h|0` is a
signed truncation, so a hash above #x7FFFFFFF is a NEGATIVE number whose
absolute value is the two's complement magnitude (2^32 - h), which is exactly
what `(- h #x100000000)` produces before abs."
  (let ((units (vovas.engine.util::utf16-units text)))
    (let ((hash 0))
      (declare (type (unsigned-byte 32) hash))
      (loop for unit across units
            do (setf hash (logand #xFFFFFFFF (+ (* 31 hash) unit))))
      (let ((signed (if (>= hash #x80000000) (- hash #x100000000) hash)))
        (format nil "~(~x~)" (abs signed))))))

(defun safe-decode-uri-component (value)
  "`safeDecodeURIComponent`: decode strictly, and hand back the input unchanged
when the JS engine would have thrown.

The strict decoder lives in vovas.engine.transforms, not here: it was written
twice during the port (once for the panel's paths, once for the engine), and two
implementations of a decoder is how an archive path and an engine peel end up
disagreeing about the same URL."
  (or (vovas.engine.transforms:decode-uri-component value) (copy-seq value)))

;;; ---------------------------------------------------------------------------
;;; Path segments
;;; ---------------------------------------------------------------------------

(defun replace-bad-chars (text predicate)
  "Replace every character satisfying PREDICATE with an underscore, in one pass.
This is the single place a character set is applied to text."
  (with-output-to-string (s)
    (loop for c across text
          do (write-char (if (funcall predicate c) #\_ c) s))))

(defun truncate-utf16 (text limit)
  "Slice to LIMIT UTF-16 units, JS-style (never splitting a surrogate pair)."
  (if (> (vovas.engine.util:utf16-length text) limit)
      (vovas.engine.util:utf16-prefix text limit)
      (copy-seq text)))

(defun sanitize-path-part (value &optional (fallback ""))
  "`sanitizePathPart`: strip path-hostile characters, fall back on empty, and
truncate to 100 UTF-16 units."
  (let* ((trimmed (js-trim value))
         (replaced (replace-bad-chars trimmed #'bad-path-chars-p))
         (resolved (if (string= replaced "")
                       (if (string= fallback "") "_" fallback)
                       replaced)))
    (truncate-utf16 resolved 100)))

(defun append-path-suffix (path suffix)
  "`appendPathSuffix`: insert before the final extension, where \"extension\"
means the last dot after the last slash. Indices are UTF-16, matching JS."
  (let ((dot -1) (slash -1) (utf16-at 0))
    (loop for c across path
          do (cond ((char= c #\.) (setf dot utf16-at))
                   ((char= c #\/) (setf slash utf16-at)))
             (incf utf16-at (if (> (char-code c) #xFFFF) 2 1)))
    (if (> dot slash)
        (concatenate 'string (vovas.engine.util:utf16-substring path 0 dot)
                     suffix
                     (vovas.engine.util:utf16-substring path dot))
        (concatenate 'string path suffix))))

;;; ---------------------------------------------------------------------------
;;; URL normalisation
;;; ---------------------------------------------------------------------------

(defun normalize-url-candidate (url)
  "`normalizeUrlCandidate`: trim, pass data: URLs through untouched, collapse
backslash runs to slashes, and repair a scheme followed by a single slash."
  (let ((value (js-trim url)))
    (cond
      ((string= value "") value)
      ((and (>= (length value) 5)
            (string-equal (subseq value 0 5) "data:"))
       value)
      (t (fix-single-slash (collapse-backslashes value))))))

(defun collapse-backslashes (value)
  "Replace every run of backslashes with one forward slash."
  (with-output-to-string (s)
    (loop with i = 0
          with n = (length value)
          while (< i n)
          do (if (char= (char value i) #\\)
                 (progn
                   (write-char #\/ s)
                   (loop while (and (< i n) (char= (char value i) #\\))
                         do (incf i)))
                 (progn
                   (write-char (char value i) s)
                   (incf i))))))

(defun scheme-prefix-length (value)
  "Length of a leading `scheme:` prefix in VALUE, or NIL. The scheme grammar is
`[A-Za-z][A-Za-z0-9+.-]*` followed by a colon."
  (let ((n (length value)))
    (when (and (plusp n) (alpha-char-p (char value 0)))
      (let ((i 1))
        (loop while (and (< i n)
                         (let ((c (char value i)))
                           (or (alphanumericp c)
                               (member c '(#\+ #\. #\-)))))
              do (incf i))
        (when (and (< i n) (char= (char value i) #\:))
          (1+ i))))))

(defun fix-single-slash (value)
  "`/^([a-z][a-z0-9+.-]*):\\/(?!\\/)/i` -> `\"$1://\"`. Written by hand: the
lookahead it needs does not exist in cl-ppcre without a loadable predicate, and
the grammar here is three lines."
  (let ((scheme-end (scheme-prefix-length value)))
    (when scheme-end
      (let ((n (length value)))
        (when (and (< scheme-end n) (char= (char value scheme-end) #\/))
          (unless (and (< (1+ scheme-end) n)
                       (char= (char value (1+ scheme-end)) #\/))
            (return-from fix-single-slash
              (concatenate 'string
                           (subseq value 0 scheme-end)
                           "//"
                           (subseq value (1+ scheme-end)))))))))
  (copy-seq value))

;;; ---------------------------------------------------------------------------
;;; A WHATWG-shaped URL parse, limited to the authority form the panel sees
;;; ---------------------------------------------------------------------------

(defstruct (parsed-url (:constructor %make-parsed-url))
  (scheme "" :type string)
  (host "" :type string)
  (port nil)
  (path "/" :type string)
  (query nil)
  (fragment nil)
  (opaque nil))

(defun parse-url-for-panel (value)
  "Parse VALUE as a URL with an authority, answering NIL when it does not have
one. This mirrors the subset of WHATWG URL the panel's inputs use: scheme,
userinfo (discarded), host with optional port, path, query and fragment.

Deliberately not a general parser. WHATWG would accept relative forms against a
base, and the panel never has a base - Rust used `url::Url::parse`, which also
requires absolute input, so requiring a scheme here matches it."
  (let ((scheme-end (scheme-prefix-length value)))
    (unless scheme-end (return-from parse-url-for-panel nil))
    (let ((scheme (string-downcase (subseq value 0 (1- scheme-end)))))
      ;; an authority needs the "//" separator
      (unless (and (<= (+ scheme-end 2) (length value))
                   (string= (subseq value scheme-end (+ scheme-end 2)) "//"))
        (return-from parse-url-for-panel nil))
      (let* ((rest (subseq value (+ scheme-end 2)))
             (authority-end (or (position-if (lambda (c) (member c '(#\/ #\? #\#))) rest)
                                (length rest)))
             (authority (subseq rest 0 authority-end))
             (tail (subseq rest authority-end)))
        ;; userinfo is discarded: the panel never writes credentials into a path
        (let ((at (position #\@ authority :from-end t)))
          (when at (setf authority (subseq authority (1+ at)))))
        (multiple-value-bind (host port) (split-host-port authority)
          (when (string= host "")
            (return-from parse-url-for-panel nil))
          ;; WHATWG lowercases the HOST but preserves the path's case, which the
          ;; oracle pins with "HTTPS://Demo.Test/A.JS" -> "demo.test/A.JS": the
          ;; scheme and host fold, the file name does not.
          (let ((path tail) (query nil) (fragment nil))
            (let ((hash (position #\# path)))
              (when hash
                (setf fragment (subseq path (1+ hash)))
                (setf path (subseq path 0 hash))))
            (let ((q (position #\? path)))
              (when q
                (setf query (subseq path (1+ q)))
                (setf path (subseq path 0 q))))
            (when (string= path "") (setf path "/"))
            (%make-parsed-url :scheme scheme :host (string-downcase host) :port port
                              :path path :query query :fragment fragment)))))))

(defun split-host-port (authority)
  "Split AUTHORITY into (values host port). Handles the bracketed IPv6 form,
where colons inside brackets are not port separators."
  (let ((n (length authority)))
    (if (and (plusp n) (char= (char authority 0) #\[))
        (let ((close (position #\] authority)))
          (cond
            ((null close) (values authority nil))
            ;; "]:" then digits
            ((and (< (+ close 2) n)
                  (char= (char authority (1+ close)) #\:))
             (let ((port (ignore-errors
                           (parse-integer authority :start (+ close 2) :junk-allowed t))))
               (values (subseq authority 0 (1+ close))
                       (if (and port (plusp port)) port nil))))
            (t (values (subseq authority 0 (1+ close)) nil))))
        (let ((colon (position #\: authority :from-end t)))
          (if (null colon)
              (values authority nil)
              (let ((port (ignore-errors
                            (parse-integer authority :start (1+ colon)
                                                :junk-allowed t))))
                (if (and port (<= 0 port 65535))
                    (values (subseq authority 0 colon)
                            (if (zerop port) nil port))
                    ;; not a numeric port: the whole thing is the host, which is
                    ;; what WHATWG does for an empty port
                    (values authority nil))))))))

(defun parsed-url-host-with-port (parsed)
  "JS `parsed.host`: the host, with `:port` appended when one is present."
  (if (parsed-url-port parsed)
      (format nil "~a:~a" (parsed-url-host parsed) (parsed-url-port parsed))
      (parsed-url-host parsed)))

;;; ---------------------------------------------------------------------------
;;; sanitizeFilename: the archive-path authority
;;; ---------------------------------------------------------------------------

(defun sanitize-filename (url)
  "`sanitizeFilename`: turn a resource URL into a stable archive path."
  (when (string= url "")
    (return-from sanitize-filename "unknown/resource"))
  (let ((url (normalize-url-candidate url)))
    ;; data: URLs are named by their MIME subtype plus a content hash
    (when (and (>= (length url) 5) (string-equal (subseq url 0 5) "data:"))
      (let* ((header-end (or (position-if (lambda (c) (member c '(#\, #\;))) url)
                             (length url)))
             (mime (if (> header-end 5) (subseq url 5 header-end) ""))
             (ext (let ((slash (position #\/ mime)))
                    (if slash (subseq mime (1+ slash)) "data"))))
        (return-from sanitize-filename
          (format nil "inline/~a.~a" (hash-string url) ext))))
    ;; blob: URLs are their inner resource, suffixed
    (when (and (>= (length url) 5) (string-equal (subseq url 0 5) "blob:"))
      (return-from sanitize-filename
        (append-path-suffix (sanitize-filename (subseq url 5)) "__blob")))
    (let ((parsed (parse-url-for-panel url)))
      (if parsed
          (sanitize-parsed-url parsed url)
          (sanitize-manual-segments url)))))

(defun sanitize-parsed-url (parsed url)
  "The parsed branch of `sanitizeFilename`, including the query/hash digest both
Rust and the original JS append."
  (declare (ignore url))
  (let ((segments '())
        (protocol (sanitize-path-part (parsed-url-scheme parsed) "scheme")))
    (unless (member protocol '("http" "https") :test #'string=)
      (push protocol segments))
    (let ((host (sanitize-path-part (parsed-url-host-with-port parsed) "host")))
      (unless (string= host "")
        (push host segments)))
    (let ((pathname (parsed-url-path parsed)))
      (when (string= pathname "") (setf pathname "/"))
      (when (char= (char pathname (1- (length pathname))) #\/)
        (setf pathname (concatenate 'string pathname "index.html")))
      (loop with start = 0
            for slash = (position #\/ pathname :start start)
            do (let ((part (subseq pathname start slash)))
                 (unless (string= part "")
                   (push (sanitize-path-part (safe-decode-uri-component part) "_")
                         segments)))
               (if slash (setf start (1+ slash)) (return))))
    (when (null segments) (push "unknown" segments))
    (let ((name (format nil "~{~a~^/~}" (nreverse segments))))
      ;; an EMPTY search or hash is falsy in `if (parsed.search || parsed.hash)`,
      ;; so a bare '?' or '#' must not produce a suffix
      (let* ((search (let ((q (parsed-url-query parsed)))
                       (if (and q (plusp (length q))) (concatenate 'string "?" q) "")))
             (hash (let ((f (parsed-url-fragment parsed)))
                     (if (and f (plusp (length f))) (concatenate 'string "#" f) ""))))
        (when (or (plusp (length search)) (plusp (length hash)))
          (let* ((digest (hash-string (concatenate 'string search hash)))
                 (short (subseq digest 0 (min 8 (length digest)))))
            (setf name (append-path-suffix name (format nil "__~a" short))))))
      name)))

(defun sanitize-manual-segments (url)
  "The unparseable branch: the original's manual segment walk, kept because a
loose scheme like `custom-scheme:/x` lands here and the oracle pins it."
  (let* ((cut (or (position-if (lambda (c) (member c '(#\? #\#))) url) (length url)))
         (raw-value (subseq url 0 cut))
         (parts (split-on-slash raw-value))
         (cleaned '())
         (offset 0))
    (when (and (> (length parts) 1)
               (loose-scheme-p (first parts)))
      (let ((loose (string-downcase (subseq (first parts) 0 (1- (length (first parts)))))))
        (unless (member loose '("http" "https") :test #'string=)
          (push (sanitize-path-part loose "scheme") cleaned))
        (push (sanitize-path-part (safe-decode-uri-component (second parts)) "host")
              cleaned)
        (setf offset 2)))
    (loop for part in (nthcdr offset parts)
          do (unless (string= part "")
               (push (sanitize-path-part (safe-decode-uri-component part) "_")
                     cleaned)))
    (let ((joined (format nil "~{~a~^/~}" (nreverse cleaned))))
      (if (string= joined "")
          "unknown/resource"
          joined))))

(defun split-on-slash (value)
  "Split VALUE on runs of `/`, keeping no empty leading/trailing entries beyond
what the walk skips anyway. Preserves an empty first element, which the scheme
check depends on."
  (let ((out '())
        (start 0))
    (loop for i from 0 below (length value)
          do (when (char= (char value i) #\/)
               (push (subseq value start i) out)
               ;; collapse the run
               (loop while (and (< (1+ i) (length value))
                                (char= (char value (1+ i)) #\/))
                     do (incf i))
               (setf start (1+ i))))
    (push (subseq value start) out)
    (nreverse out)))

(defun loose-scheme-p (part)
  "Whether PART is a scheme with a trailing colon and nothing else: `foo:`."
  (let ((n (length part)))
    (and (> n 1)
         (char= (char part (1- n)) #\:)
         (alpha-char-p (char part 0))
         (loop for i from 1 below (1- n)
               always (let ((c (char part i)))
                        (or (alphanumericp c) (member c '(#\+ #\. #\-))))))))

;;; ---------------------------------------------------------------------------
;;; Titles and formatting
;;; ---------------------------------------------------------------------------

(defun sanitize-page-title (title)
  "`sanitizePageTitle`: the same character set plus `/`, truncated to 100 UTF-16
units, falling back to \"page\"."
  (let ((replaced (replace-bad-chars title #'bad-path-chars-with-slash-p)))
    (let ((truncated (truncate-utf16 replaced 100)))
      (if (string= truncated "") "page" truncated))))

(defun format-size (bytes)
  "`formatSize`."
  (cond
    ((= bytes 0d0) "0 B")
    ((< bytes 1024d0) (format nil "~a B" (to-string bytes)))
    ((< bytes 1048576d0) (format nil "~a KB" (to-fixed (/ bytes 1024d0) 1)))
    (t (format nil "~a MB" (to-fixed (/ bytes 1048576d0) 2)))))

(defun format-ms (ms)
  "`formatMs`."
  (cond
    ((< ms 1d0) (format nil "~a us" (to-string (js-round (* ms 1000d0)))))
    ((< ms 1000d0) (format nil "~a ms" (to-fixed ms 1)))
    (t (format nil "~a s" (to-fixed (/ ms 1000d0) 2)))))

(defun locale-compare (left right)
  "`js_locale_compare`: case-folded compare, then a CASE KEY tie-break.

The tie-break is NOT a plain string compare. The Rust builds a per-character key
where UPPERCASE is 1 and lowercase is 0, then compares those vectors
lexicographically - so among strings that fold equal, LOWERCASE SORTS FIRST.
Comparing the raw strings instead puts `#\\A` before `#\\a` by code point and
inverts the order for every case-differing pair.

Answers :LESS, :EQUAL or :GREATER."
  (let ((lf (string-downcase left))
        (rf (string-downcase right)))
    (cond
      ((string< lf rf) :less)
      ((string> lf rf) :greater)
      ((string= left right) :equal)
      (t (let* ((n (min (length left) (length right)))
                (cmp 0))
           ;; element-wise over the case keys; the first difference decides
           (dotimes (i n)
             (when (zerop cmp)
               (let ((lk (if (and (char>= (char left i) #\A)
                                  (char<= (char left i) #\Z))
                             1 0))
                     (rk (if (and (char>= (char right i) #\A)
                                  (char<= (char right i) #\Z))
                             1 0)))
                 (cond ((< lk rk) (setf cmp -1))
                       ((> lk rk) (setf cmp 1))))))
           ;; all shared positions matched: the SHORTER key is less, matching
           ;; the lexicographic compare on unequal-length byte vectors
           (cond ((< cmp 0) :less)
                 ((> cmp 0) :greater)
                 ((< (length left) (length right)) :less)
                 ((> (length left) (length right)) :greater)
                 (t :equal)))))))
