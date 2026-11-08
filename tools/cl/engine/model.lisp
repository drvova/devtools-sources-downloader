;;;; model.lisp — the panel's resource model, from panel/model.rs.
;;;;
;;;; Normalisation from raw `chrome.devtools` resource objects, filter matching,
;;;; and the four sort orders, all with the JavaScript semantics of the pre-port
;;;; `page.js`. Most of this file exists because JS coercion is not Lisp's:
;;;;
;;;;   `String(null)` is "null" but a null ARRAY ELEMENT joins as ""
;;;;   `String([1,2])` joins with "," and `String({})` is "[object Object]"
;;;;   `Number(null)` is 0, `Number([])` is 0, `Number([5])` is 5, `Number([1,2])` is NaN
;;;;   `sort()` compares UTF-16 CODE UNITS, so an astral character sorts by its
;;;;   surrogate half rather than by code point
;;;;
;;;; Each of those is a place a plausible Lisp translation would quietly differ.

(in-package :vovas.engine.panel.model)

;;; ---------------------------------------------------------------------------
;;; Counts: a counter that keeps FIRST-SEEN key order
;;;
;;; A plain hash table will not do: these counts are serialized straight into the
;;; exported analysis, and JavaScript objects keep insertion order. An alist whose
;;; append preserves position is the smallest structure that does.
;;; ---------------------------------------------------------------------------

(defstruct (counts (:constructor make-counts (&optional (pairs '()))))
  (pairs '() :type list))

(defun counts-add (counts key)
  "Increment KEY, appending on first sight so the order is insertion order."
  (let ((cell (assoc key (counts-pairs counts) :test #'string=)))
    (if cell
        (setf (cdr cell) (1+ (cdr cell)))
        (setf (counts-pairs counts)
              (append (counts-pairs counts) (list (cons key 1))))))
  counts)

(defun counts-alist (counts)
  "The pairs as (key . value) in insertion order."
  (copy-tree (counts-pairs counts)))

(defun counts-json (counts)
  "COUNTS as a wire OBJECT - an empty counter is `{}`, never `false`.

`counts-alist` answers NIL for an empty counter, and NIL reaching the serializer
is BOOLEAN FALSE, so nine artifacts in a fifty-three file export carried
`\"runtimeLabels\": false` where the engine had `{}`. The value was correct as a
count and wrong as a document.

This is the whole reason `json-marker` exists: NIL cannot express \"empty
collection\" because JSON has four states - absent, null, empty, false - and
a CL symbol has one. A caller that wants the alist (for a gate comparison, say)
keeps using `counts-alist`; a caller building a document uses this."
  (let ((pairs (counts-alist counts)))
    (if pairs
        (let ((out (make-hash-table :test #'equal)))
          (dolist (pair pairs)
            (setf (gethash (princ-to-string (car pair)) out) (cdr pair)))
          out)
        (empty-object))))

;;; ---------------------------------------------------------------------------
;;; The empty-container marker
;;;
;;; Defined HERE rather than in a module that uses it, because this is the leaf
;;; every consumer loads after: the serializer in `artifacts.lisp`, the wire
;;; conversion in `analysis.lisp`, and the producers in `assets.lisp` and
;;; `boundary.lisp` all name one type. While this lived in `stackprofile.lisp`
;;; only that module's own gate could decode it, and in the real export path a
;;; marker was an opaque struct the serializer rendered as `null` - a mechanism
;;; that existed and was invisible.
;;; ---------------------------------------------------------------------------

(defstruct (json-marker (:constructor %json-marker (kind)))
  "A tagged stand-in for an empty JSON container.

`nil` cannot serve: the same value would be an empty array, a false, or a missing
key depending on where it appears, and JSON distinguishes all four. The serializer
reads this marker's TYPE, so the producer states its intent once and the serializer
never guesses from a key's name - which is what went wrong when `traits` was an
array at the top level and an object inside `evidence`."
  (kind :object :type keyword :read-only t))

(defun empty-object () "A marker for an empty JSON OBJECT." (%json-marker :object))
(defun empty-array () "A marker for an empty JSON ARRAY." (%json-marker :array))

(defun resolve-json-markers (value)
  "VALUE with every `json-marker` replaced by the container it stands for.

Two writers exist in this tree - `json-serialize-compact` (hand-rolled, knows the
marker) and JZON `stringify` (cannot, and renders a struct as
`{\"kind\": \"OBJECT\"}`). `report-pretty-json` was the second kind, which is how
five analysis artifacts ended up carrying `{\"kind\": \"ARRAY\"}` where the engine
had `[]`: the marker was doing its job and neither writer had been told.

Walking here rather than teaching JZON means ONE definition of the conversion, so
a third writer added later inherits it instead of re-deriving it. The shapes are
the natural ones - an empty hash table and an empty vector - because those are
what a JSON object and array already are to this port."
  (cond
    ((json-marker-p value)
     (if (eq :array (json-marker-kind value)) #() (make-hash-table :test #'equal)))
    ;; A STRING IS A VECTOR. This test must precede the `vectorp` branch below or
    ;; every string decomposes into a vector of characters - the same mistake the
    ;; ledger already records three times for `analysis-wire`, `gate-value=` and
    ;; `value-as-text`. Fourth occurrence; the ordering is not stylistic.
    ((stringp value) value)
    ((hash-table-p value)
     (let ((out (make-hash-table :test #'equal)))
       (maphash (lambda (k v) (setf (gethash k out) (resolve-json-markers v))) value)
       out))
    ;; NIL is NOT converted wholesale. It is tempting - a `loop ... collect` that
    ;; found nothing answers NIL and the engine writes `[]` - but NIL in this port
    ;; ALSO spells boolean false and an absent plist value, and a blanket rule here
    ;; would turn every `:truncated nil` into `[]`. Producers that build a
    ;; collection state the empty case themselves; this function only rewrites the
    ;; markers, which are unambiguous by construction.
    ((consp value)
     (if (proper-list-p value)
         (mapcar #'resolve-json-markers value)
         (cons (resolve-json-markers (car value))
               (resolve-json-markers (cdr value)))))
    ((vectorp value)
     (let ((out (make-array (length value))))
       (dotimes (i (length value))
         (setf (aref out i) (resolve-json-markers (aref value i))))
       out))
    (t value)))

;;; ---------------------------------------------------------------------------
;;; js-string and js-number over JZON values
;;;
;;; The input is whatever JZON parsed, so dispatch covers the same cases the
;;; Rust's `Value` enum does. JZON represents null as its own SYMBOL and objects
;;; as hash-tables, so both are handled explicitly rather than left to fall
;;; through a cond.
;;; ---------------------------------------------------------------------------

(defun json-null-p (value)
  "Whether VALUE is JZON's null. Not `(null value)`, which is also true of NIL."
  (and (symbolp value) (string= (symbol-name value) "NULL")))

(defun json-null-symbol ()
  "JZON's null, for code that must WRITE a null rather than test for one.

A CL NIL serialises as `false` or as an absent key depending on the writer, so a
field the engine emits as `null` needs this symbol. Interning by name rather than
depending on `com.inuoe.jzon` keeps this usable from modules that never parse
JSON themselves."
  (intern "NULL" :com.inuoe.jzon))

(defun js-string (value)
  "`String(value)` for a JSON value."
  (cond
    ((json-null-p value) "null")
    ((eq value t) "true")
    ((null value) "false")              ; a parsed JSON false
    ((numberp value) (vovas.engine.number:to-string (coerce value 'double-float)))
    ((stringp value) value)
    ((vectorp value)
     ;; `String([a,b])` joins with "," and a null ELEMENT joins as "", not "null"
     (format nil "~{~a~^,~}"
             (loop for item across value
                   collect (if (json-null-p item) "" (js-string item)))))
    ((hash-table-p value) "[object Object]")
    (t (princ-to-string value))))

(defun js-number (value)
  "`Number(value)` for a JSON value; NaN where JS produces NaN.

The array cases are the ones worth knowing: `Number([])` is 0, `Number([5])` is 5
because a single element coerces recursively, and `Number([1,2])` is NaN because
the joined string \"1,2\" is not numeric."
  (cond
    ((json-null-p value) 0d0)
    ((eq value t) 1d0)
    ((null value) 0d0)
    ((numberp value) (coerce value 'double-float))
    ((stringp value) (vovas.engine.number:to-number value))
    ((vectorp value)
     (cond ((zerop (length value)) 0d0)
           ((= 1 (length value)) (js-number (aref value 0)))
           (t (vovas.engine.number:nan))))
    ((hash-table-p value) (vovas.engine.number:nan))
    (t (vovas.engine.number:nan))))

(defun js-truthy (value)
  "`Boolean(value)` for a JSON value. Arrays and objects are ALWAYS true, even
empty ones - the opposite of `length`-based intuition."
  (cond
    ((json-null-p value) nil)
    ((eq value t) t)
    ((null value) nil)
    ((numberp value) (let ((f (coerce value 'double-float)))
                       ;; finite check FIRST: comparing a NaN with `/=` signals on
                       ;; SBCL instead of answering, so the order is load-bearing.
                       (and (finite-p f) (/= f 0d0))))
    ((stringp value) (plusp (length value)))
    ((or (vectorp value) (hash-table-p value)) t)
    (t t)))

;;; ---------------------------------------------------------------------------
;;; Resource rows
;;; ---------------------------------------------------------------------------

(defstruct (resource (:constructor make-resource
                        (&key (status "") (kind "?") (source "?") (url "?")
                              (size 0d0) (time 0d0) (order 0))))
  (status "" :type string)
  (kind "?" :type string)
  (source "?" :type string)
  (url "?" :type string)
  (size 0d0 :type double-float)
  (time 0d0 :type double-float)
  (order 0 :type integer))

(defun finite-p (f)
  (and (not (sb-ext:float-nan-p f)) (not (sb-ext:float-infinity-p f))))

(defun get-resource-time (resource)
  "`getResourceTime`: the FIRST truthy timestamp field, coerced, required finite.
The key ORDER is the contract - `time` wins over `timestamp` even when the latter
is larger."
  (loop for key in '("time" "timestamp" "seenAt" "startTime")
        do (let ((raw (and (hash-table-p resource) (gethash key resource))))
             (when (js-truthy raw)
               (let ((v (js-number raw)))
                 (return-from get-resource-time (if (finite-p v) v 0d0)))))
        finally (return 0d0)))

(defun normalize-resource (resource status index)
  "`normalizeResource`: a raw resource object to a row.

Every text field falls back to \"?\" when the value is FALSY - so a resource with
`url: \"\"` and one with no url both become \"?\", which is the shipped behaviour
and why an empty string is not distinguishable downstream."
  (flet ((text (key)
           (let ((raw (and (hash-table-p resource) (gethash key resource))))
             (if (js-truthy raw) (js-string raw) "?"))))
    (let* ((raw-size (and (hash-table-p resource) (gethash "size" resource)))
           (size (if (null raw-size) 0d0 (js-number raw-size)))
           ;; ORDER MATTERS. `finite-p` must run BEFORE any comparison:
           ;; `(/= nan 0d0)` and `(= nan 0d0)` both SIGNAL
           ;; FLOATING-POINT-INVALID-OPERATION on SBCL rather than answering
           ;; true/false, so `(and (/= size 0d0) (finite-p size))` traps on a NaN
           ;; size the moment a resource carries an unparseable one.
           (size (if (and (finite-p size) (/= size 0d0)) size 0d0)))
      (make-resource :status status
                     :kind (text "type")
                     :source (text "source")
                     :url (text "url")
                     :size size
                     :time (get-resource-time resource)
                     :order index))))

;;; ---------------------------------------------------------------------------
;;; Filters and ordering
;;; ---------------------------------------------------------------------------

(defstruct (resource-filters (:constructor make-resource-filters
                                 (&key (status "") (kind "") (search "") (sort "newest"))))
  (status "" :type string)
  (kind "" :type string)
  (search "" :type string)
  (sort "newest" :type string))

(defun matches-resource-filters (item filters)
  "`matchesResourceFilters`. An empty or \"all\" status/kind is unconstrained; the
search is a case-insensitive substring over the four fields joined by a space, so
it can match ACROSS the join."
  (let ((status (resource-filters-status filters))
        (kind (resource-filters-kind filters)))
    (when (and (plusp (length status))
               (not (string= status "all"))
               (not (string= (resource-status item) status)))
      (return-from matches-resource-filters nil))
    (when (and (plusp (length kind))
               (not (string= kind "all"))
               (not (string= (resource-kind item) kind)))
      (return-from matches-resource-filters nil))
    (let ((search (string-downcase (vovas.engine.util:js-trim
                                    (resource-filters-search filters)))))
      (when (zerop (length search))
        (return-from matches-resource-filters t))
      (let ((haystack (string-downcase
                       (format nil "~a ~a ~a ~a"
                               (resource-status item) (resource-kind item)
                               (resource-source item) (resource-url item)))))
        (and (search search haystack) t)))))

(defun compare-resources (left right mode)
  "`compareResources` for one of the four modes, answering :LESS :EQUAL :GREATER.

`largest` and the default both break ties on a SECOND key rather than stopping at
the first, which is what makes the order deterministic for equal sizes or times.
The default's tie-break runs ASCENDING by order while the primary key descends -
a single reverse of the list would get that wrong."
  (flet ((cmp (a b) (cond ((< a b) :less) ((> a b) :greater) (t :equal))))
    (cond
      ((string= mode "largest")
       (let ((c (cmp (resource-size right) (resource-size left))))
         (if (eq c :equal)
             (cmp (resource-time right) (resource-time left))
             c)))
      ((string= mode "type")
       (let ((c (vovas.engine.text:locale-compare (resource-kind left)
                                                  (resource-kind right))))
         (if (eq c :equal)
             (vovas.engine.text:locale-compare (resource-url left)
                                               (resource-url right))
             c)))
      ((string= mode "url")
       (vovas.engine.text:locale-compare (resource-url left) (resource-url right)))
      (t
       (let ((c (cmp (resource-time right) (resource-time left))))
         (if (eq c :equal)
             (cmp (resource-order left) (resource-order right))
             c))))))

;;; ---------------------------------------------------------------------------
;;; Types
;;; ---------------------------------------------------------------------------

(defun resource-kind-or-question (item)
  (if (zerop (length (resource-kind item))) "?" (resource-kind item)))

(defun collect-types (items)
  "`collectTypes`: distinct kinds in first-seen order, then sorted the way
`Array.prototype.sort()` sorts - by UTF-16 CODE UNIT, not code point.

The distinction is real outside the BMP: an astral character's surrogate pair
starts at #xD800, so it sorts BELOW a BMP character it would sort after by code
point. `vovas.engine.util::utf16-units` exists so this cannot be got wrong
quietly."
  (let ((seen '()))
    (dolist (item items)
      (let ((kind (resource-kind-or-question item)))
        (unless (member kind seen :test #'string=)
          (push kind seen))))
    (sort seen
          #'utf16-less-p)))

(defun utf16-less-p (a b)
  "Whether A sorts before B by UTF-16 code units, the way `Array.prototype.sort`
compares strings. Split out as its own function because the comparator inside
`sort` cannot `return-from` a block that does not exist."
  (let ((ua (vovas.engine.util::utf16-units a))
        (ub (vovas.engine.util::utf16-units b)))
    (dotimes (i (min (length ua) (length ub)))
      (cond ((< (aref ua i) (aref ub i)) (return-from utf16-less-p t))
            ((> (aref ua i) (aref ub i)) (return-from utf16-less-p nil))))
    (< (length ua) (length ub))))

(defun resolve-type-selection (current types)
  "`resolveTypeSelection`: keep CURRENT when still present or \"all\", else \"all\"."
  (if (or (member current types :test #'string=) (string= current "all"))
      current
      "all"))

;;; ---------------------------------------------------------------------------
;;; Numeric output coercion
;;;
;;; These live here, beside `js-number`/`js-truthy`, because they are JS
;;; NUMBER semantics rather than anything about artifacts. They were in
;;; `artifacts.lisp` and `boundary` needed them - but `artifacts` loads AFTER
;;; `boundary`, so importing them from there is a package-order dependency on
;;; a file that has not been read yet. `model` is the leaf every panel module
;;; already imports, which is where a shared coercion belongs.
;;; ---------------------------------------------------------------------------

(defconstant +max-safe-integer+ 9007199254740992d0)

(defun finite-float-p (value)
  "Whether VALUE is finite. An INTEGER is always finite, so it answers T rather
than calling `float-nan-p` on it - SBCL's float predicates require a FLOAT
argument and signal a TYPE-ERROR on 0, which is how this surfaced.

`(= nan 0d0)` and `(/= nan 0d0)` both SIGNAL on SBCL, so finiteness has to be
asked before any comparison of a value that might be NaN."
  (cond
    ((integerp value) t)
    ((rationalp value) t)
    ((floatp value) (and (not (sb-ext:float-nan-p value))
                         (not (sb-ext:float-infinity-p value))))
    (t nil)))

(defun js-number-value (value)
  "`js_number_value`: VALUE as the JSON number it should print as.

A non-finite value becomes NIL, which the writer renders as `null`; an integral
value inside the safe range becomes an integer; anything else stays a double.

The order of the tests matters: the finiteness check must come FIRST, because
`(= nan 0d0)` and `(/= nan 0d0)` both SIGNAL on SBCL rather than answering, so a
NaN reaching `zerop` would raise instead of falling through to `null`."
  (cond
    ((not (realp value)) nil)
    ((and (floatp value) (not (finite-float-p value))) nil)
    ((integerp value) value)
    ((and (zerop (nth-value 1 (truncate value)))
          (< (abs value) +max-safe-integer+))
     (truncate value))
    (t value)))

