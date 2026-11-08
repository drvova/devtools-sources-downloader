;;;; bundler.lisp — webpack module splitting, ported from bundler.rs.
;;;;
;;;; Find the module map (the `__webpack_modules__` object, or the push-array
;;;; form), then slice every `id: function(params){...}` member into its own
;;;; module. This is what turns one bundled file into N archive entries.
;;;;
;;;; Two quirks inherited from the original and preserved rather than fixed:
;;;;   - Arrow-expression bodies (`(a) => ({...})`) are SKIPPED, not extracted.
;;;;   - A module whose region never closes is skipped, and the cursor stays
;;;;     where it was, so the scan continues rather than aborting.

(in-package :vovas.engine.bundler)

;;; ---------------------------------------------------------------------------
;;; The character classes the patterns interpolate
;;;
;;; Rust builds its regexes with format!, interpolating JS_S and JS_W into a
;;; character class. Interpolating into a class means the class body must be a
;;; literal fragment, so the same strings are used here - spelled once, in
;;; vovas.engine.util, so the two ports cannot disagree about what whitespace is.
;;; ---------------------------------------------------------------------------

(defparameter +js-s+ " \\t\\n\\x0B\\f\\r"
  "ECMAScript's ASCII whitespace as a regex class body, matching util.rs's JS_S.")

(defparameter +js-w+ "A-Za-z0-9_"
  "JS `\\w` as a regex class body, matching util.rs's JS_W.")

;;; ---------------------------------------------------------------------------
;;; Patterns, compiled once
;;;
;;; Rust holds these in LazyLock so each is compiled on first use and reused.
;;; load-time-value gives the same one-compilation-per-load here; a plain
;;; defparameter would compile at definition time, which is close enough but
;;; happens even when the module is never called.
;;; ---------------------------------------------------------------------------

(defparameter *push-array*
  (cl-ppcre:create-scanner "\\[\\s*\\[[^\\]]*\\]\\s*,\\s*\\{")
  "The push-array form's opening: `[[...],{`. Compiled once, matching the
LazyLock intent in the Rust.")

(defparameter *header-full*
  (cl-ppcre:create-scanner
   (format nil "(?:^|[~a,])(\\d{1,7})[~a]*:[~a]*(?:function[~a]*\\(([^)]*)\\)|(?:\\(([^)]*)\\)|([~a$]+))[~a]*=>)"
           +js-s+ +js-s+ +js-s+ +js-s+ +js-w+ +js-s+))
  "The first-search pattern: `^` or a separator, then the module id.")

(defparameter *header-continuation*
  (cl-ppcre:create-scanner
   (format nil "[~a,](\\d{1,7})[~a]*:[~a]*(?:function[~a]*\\(([^)]*)\\)|(?:\\(([^)]*)\\)|([~a$]+))[~a]*=>)"
           +js-s+ +js-s+ +js-s+ +js-s+ +js-w+ +js-s+))
  "The resume pattern: no `^`, because a search that resumes mid-body can never
match at position 0.")

(defparameter *source-url*
  (cl-ppcre:create-scanner "//[#@]\\s*sourceURL\\s*=\\s*(\\S+)")
  "transforms.rs's SOURCE_URL_COMMENT. The constant lands in transforms.lisp
eventually; it is spelled here so this module has no forward dependency on a
file that does not exist yet, and the two must be kept equal - a test in the
gate asserts they agree when transforms arrives.")

(defparameter *webpack-prefix* (cl-ppcre:create-scanner "^webpack(-internal)?://"))
(defparameter *dot-slash* (cl-ppcre:create-scanner "^\\./"))
(defparameter *leading-slashes* (cl-ppcre:create-scanner "^/+"))
(defparameter *dot-segments* (cl-ppcre:create-scanner "^\\.+$"))

;;; ---------------------------------------------------------------------------
;;; extractBundleModules
;;; ---------------------------------------------------------------------------

(defstruct (bundle-module (:constructor make-bundle-module (id params code)))
  (id "" :type string)
  (params "" :type string)
  (code "" :type string))

(defun bundle-map-open-index (text)
  "The index of the brace that opens the module map, or NIL.

Two forms: the named `__webpack_modules__` object, and the push-array form
`[[...],{`. Factored out because the nesting made the parent function hard to
read - and a function that is hard to read is a function whose parens get
miscounted, which is exactly what happened three times."
  (let ((map-start (search "__webpack_modules__" text)))
    (if map-start
        (position #\{ text :start map-start)
        (let ((start (cl-ppcre:scan *push-array* text)))
          (and start (position #\{ text :start start))))))

(defun module-header-match (body cursor)
  "The next module header at or after CURSOR, as (values whole groups-vector).

The FIRST search uses the anchored pattern and every later one the
continuation pattern: `^` can only match at position 0, so a resumed search
would never match with it.

`cl-ppcre:scan-to-strings` answers (values whole-match groups) where GROUPS is a
simple-vector of the capture strings - NOT a list - so this must be captured with
multiple-value-bind. Wrapping it in multiple-value-list and indexing with SECOND
yields the groups VECTOR where a string is expected, which reads as a type error
about characters."
  (let ((pattern (if (zerop cursor) *header-full* *header-continuation*)))
    (multiple-value-bind (whole groups)
        (cl-ppcre:scan-to-strings pattern body :start cursor)
      (values whole groups))))

(defun expression-body-p (body whole-end brace-index)
  "Whether the arrow between the header and the body makes this an
arrow-EXPRESSION module, which the original SKIPS rather than extracting.
Preserved quirk, never silently fixed."
  (let ((arrowless (subseq body whole-end brace-index)))
    (and (search "=>" arrowless)
         (plusp (length (string-trim '(#\Space #\Tab #\Newline) arrowless)))
         (find #\) arrowless)
         (plusp brace-index)
         (char= (char body (1- brace-index)) #\)))))

(defun extract-bundle-modules (text &optional max-modules)
  "`extractBundleModules(text, maxModules)`: every module in the bundle's map,
as `bundle-module` structs. MAX-MODULES NIL means the default cap (400)."
  (let ((cap (if (or (null max-modules) (zerop max-modules))
                 *limits-max-modules*
                 max-modules))
        (open-index (bundle-map-open-index text)))
    (when (null open-index)
      (return-from extract-bundle-modules '()))
    (let ((end (find-balanced text open-index)))
      (when (null end)
        (return-from extract-bundle-modules '()))
      (let ((body (subseq text (1+ open-index) (1- end)))
            (modules '())
            (cursor 0))
        (loop while (< (length modules) cap)
              do (multiple-value-bind (whole groups) (module-header-match body cursor)
                   (unless whole (return))
                   (let* ((whole-start (or (search whole body :start2 cursor) cursor))
                          (key (aref groups 0))
                          (params (or (aref groups 1) (aref groups 2) (aref groups 3) ""))
                          (whole-end (+ whole-start (length whole)))
                          (key-index (or (search key body :start2 whole-start) whole-start))
                          (brace-index (position #\{ body :start whole-end)))
                     (unless brace-index (return))
                     (unless (expression-body-p body whole-end brace-index)
                       (let ((region-end (find-balanced body brace-index)))
                         (when region-end
                           (push (make-bundle-module key params
                                                     (subseq body key-index region-end))
                                 modules)
                           (setf cursor region-end)))))))
        (nreverse modules)))))

;;; ---------------------------------------------------------------------------
;;; Naming
;;; ---------------------------------------------------------------------------

(defun module-file-name (module)
  "`moduleFileName(module)`: the module's sourceURL path, cleaned, or
`module-<id>.js` when it carries none."
  (let ((url (cl-ppcre:scan-to-strings *source-url* (bundle-module-code module))))
    (if (null url)
        (format nil "module-~a.js" (bundle-module-id module))
        (let ((cleaned (aref url 0)))
          (setf cleaned (cl-ppcre:regex-replace *webpack-prefix* cleaned ""))
          (setf cleaned (cl-ppcre:regex-replace *dot-slash* cleaned ""))
          (setf cleaned (cl-ppcre:regex-replace-all
                         "[\\\\:*?\"<>|]" cleaned "_"))
          (cl-ppcre:regex-replace *leading-slashes* cleaned "")))))

(defun safe-path (path)
  "JS `safePath`: one sanitising pass per path segment, with a segment that is
nothing but dots replaced entirely (so `./..` cannot escape the archive root)."
  (format nil "~{~a~^/~}"
          (loop for segment in (split-on-slash path)
                collect (cl-ppcre:regex-replace
                         *dot-segments*
                         (cl-ppcre:regex-replace-all "[\\\\:*?\"<>|]" segment "_")
                         "_"))))

(defun split-on-slash (text)
  (let ((out '())
        (start 0))
    (loop for i from 0 below (length text)
          do (when (char= (char text i) #\/)
               (push (subseq text start i) out)
               (setf start (1+ i))))
    (push (subseq text start) out)
    (nreverse out)))
