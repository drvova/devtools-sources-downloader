;;;; gate-model.lisp — the resource model gate.
;;;;
;;;; The oracle here is the Rust module's OWN unit tests, which were captured from
;;;; node running the pre-port page.js functions. They are ported case for case,
;;;; plus the JS-coercion edges the tests do not reach: `Number([1,2])` is NaN,
;;;; `String([1,null])` is "1,", and a UTF-16 sort of an astral character against
;;;; a BMP one (the case where `string<` and `Array.prototype.sort` disagree).
;;;;
;;;; There is no JSON fixture for this module, so it is important to say plainly
;;;; what is pinned where:
;;;;   - normalize-resource: the six Rust test rows, byte for byte
;;;;   - compare-resources:   the four modes over the Rust test's sample items
;;;;   - collect-types:       first-seen order, then UTF-16 order
;;;;   - js-string/js-number/js-truthy: structural, from the spec's own table
;;;; This is an oracle-pinned gate for the rows and a structural one for the
;;;; coercions, and the counts below do not conflate them.

(in-package :vovas.engine.gate)

(defun model-json (text)
  "Parse a JSON literal for a case row."
  (let ((*read-default-float-format* 'double-float))
    (com.inuoe.jzon:parse text)))

(defun resource-wire (r)
  "A resource as the plist its JSON serialization would produce, so a row can be
compared against the Rust test's expected object directly."
  (list :status (vovas.engine.panel.model:resource-status r)
        :type (vovas.engine.panel.model:resource-kind r)
        :source (vovas.engine.panel.model:resource-source r)
        :url (vovas.engine.panel.model:resource-url r)
        :size (vovas.engine.panel.model:resource-size r)
        :time (vovas.engine.panel.model:resource-time r)
        :order (vovas.engine.panel.model:resource-order r)))

(defun run-model-gate (&key (verbose t))
  (let ((result (make-gate-result))
        (count 0))

    ;; --- 1. normalize-resource: the Rust test's six rows, exactly -----------
    ;;
    ;; Row 2 is a bare `{}` and row 3 is `{"size":"2048","timestamp":12}` - so the
    ;; "?" fallbacks, the string-to-number size coercion and the timestamp
    ;; precedence are all in here. Row 4 has size "abc" and an INFINITE
    ;; startTime, both of which must collapse to 0 rather than leaking NaN/inf.
    (dolist (case (list (list "{\"type\":\"script\",\"source\":\"network\",\"url\":\"https://x/a.js\",\"size\":100,\"time\":5}" "loaded" 0
                             (list :status "loaded" :type "script" :source "network" :url "https://x/a.js" :size 100d0 :time 5d0 :order 0))
                       (list "{}" "unloaded" 3
                             (list :status "unloaded" :type "?" :source "?" :url "?" :size 0d0 :time 0d0 :order 3))
                       (list "{\"size\":\"2048\",\"timestamp\":12}" "loaded" 1
                             (list :status "loaded" :type "?" :source "?" :url "?" :size 2048d0 :time 12d0 :order 1))
                       ;; The Rust test uses `f64::INFINITY` for startTime, which
                       ;; JSON cannot express and JZON cannot parse (1e999 signals
                       ;; FLOATING-POINT-OVERFLOW). The PROPERTY under test is that
                       ;; a non-finite time collapses to 0, so the case is built
                       ;; directly rather than through JSON.
                       (list :infinite-time "loaded" 2
                             (list :status "loaded" :type "?" :source "?" :url "?"
                                   :size 0d0 :time 0d0 :order 2))
                       (list "null" "unloaded" 4
                             (list :status "unloaded" :type "?" :source "?" :url "?" :size 0d0 :time 0d0 :order 4))
                       (list "{\"seenAt\":7}" "loaded" 5
                             (list :status "loaded" :type "?" :source "?" :url "?" :size 0d0 :time 7d0 :order 5))))
      (incf count)
      (check result "normalize-resource" (second case)
             (resource-wire (if (eq (first case) :infinite-time)
                                ;; built by hand: the point is a NON-FINITE time
                                (vovas.engine.panel.model:normalize-resource
                                 (let ((h (make-hash-table :test #'equal)))
                                   (setf (gethash "size" h) "abc"
                                         (gethash "startTime" h)
                                         sb-ext:double-float-positive-infinity)
                                   h)
                                 (second case) (third case))
                                (vovas.engine.panel.model:normalize-resource
                                 (model-json (first case)) (second case) (third case))))
             (fourth case)))

    ;; --- 2. js-string / js-number / js-truthy: the coercion table ----------
    ;;
    ;; These are the cases a Lisp translation gets wrong by being reasonable:
    ;; `String(null)` is the four characters "null", an array's null ELEMENT joins
    ;; as empty rather than "null", `Number([1,2])` is NaN while `Number([5])` is 5,
    ;; and an EMPTY array is truthy.
    (dolist (case (list
                   ;; (json . (string-value number-value truthy))
                   (list "null" "null" 0d0 nil)
                   (list "true" "true" 1d0 t)
                   (list "false" "false" 0d0 nil)
                   (list "5" "5" 5d0 t)
                   (list "\"x\"" "x" :nan t)
                   (list "\"\"" "" 0d0 nil)
                   (list "[]" "" 0d0 t)              ; EMPTY ARRAY IS TRUTHY
                   (list "[1,2]" "1,2" :nan t)       ; two elements -> NaN
                   (list "[5]" "5" 5d0 t)            ; one element -> recursive
                   (list "[1,null]" "1," :nan t)     ; null element joins EMPTY
                   (list "{}" "[object Object]" :nan t)))
      (let* ((v (model-json (first case)))
             (want-string (second case))
             (want-number (third case))
             (want-truthy (fourth case)))
        (incf count)
        (check result "js-string" (first case)
               (vovas.engine.panel.model:js-string v) want-string)
        (incf count)
        (let ((got (vovas.engine.panel.model:js-number v)))
          (check result "js-number" (first case)
                 (if (sb-ext:float-nan-p got) :nan (coerce got 'double-float))
                 want-number))
        (incf count)
        (check result "js-truthy" (first case)
               (and (vovas.engine.panel.model:js-truthy v) t)
               want-truthy)))

    ;; --- 3. compare-resources over a fixed sample -------------------------
    ;;
    ;; The sample mirrors the Rust test's: two equal-size rows with different
    ;; times, and two rows whose kind differs only in CASE, so a case-sensitive
    ;; comparison shows up in the `type` order.
    (let* ((mk (lambda (status kind source url size time order)
                 (vovas.engine.panel.model:make-resource
                  :status status :kind kind :source source :url url
                  :size (coerce size 'double-float)
                  :time (coerce time 'double-float)
                  :order order)))
           (a (funcall mk "loaded" "script" "network" "https://x/a.js" 300 5 0))
           (b (funcall mk "unloaded" "image" "memory" "https://x/b.png" 100 9 1))
           (c (funcall mk "loaded" "script" "network" "https://x/c.js" 100 9 2)))
      (flet ((order (mode)
               (mapcar #'vovas.engine.panel.model:resource-url
                       (sort (list a b c)
                             (lambda (l r)
                               (eq :less (vovas.engine.panel.model:compare-resources
                                          l r mode)))))))
        (incf count)
        ;; largest: a (300), then the 100s broken by time DESC (both 9), then order
        (check result "compare-resources/largest" "sample"
               (order "largest")
               '("https://x/a.js" "https://x/b.png" "https://x/c.js"))
        (incf count)
        ;; newest: descending time, so the two 9s first, tied rows by ASCENDING order
        (check result "compare-resources/newest" "sample"
               (order "newest")
               '("https://x/b.png" "https://x/c.js" "https://x/a.js"))
        (incf count)
        ;; url: plain locale order
        (check result "compare-resources/url" "sample"
               (order "url")
               '("https://x/a.js" "https://x/b.png" "https://x/c.js"))))

    ;; --- 4. collect-types: first-seen, then UTF-16 order -------------------
    (let* ((mk (lambda (kind)
                 (vovas.engine.panel.model:make-resource :kind kind)))
           (items (list (funcall mk "script") (funcall mk "image")
                        (funcall mk "script") (funcall mk "Script")
                        (funcall mk ""))))
      (incf count)
      ;; "" becomes "?", and "Script" and "script" are DISTINCT because the sort
      ;; is case-sensitive; UTF-16 order puts uppercase before lowercase
      (check result "collect-types" "distinct-and-sorted"
             (vovas.engine.panel.model:collect-types items)
             '("?" "Script" "image" "script")))

    ;; the astral case: an emoji (surrogate D83D...) sorts BELOW a BMP char it
    ;; would sort after by code point. This is the one `string<` gets wrong.
    (incf count)
    (check result "collect-types/utf16-order" "astral vs BMP"
           (vovas.engine.panel.model:collect-types
            (list (vovas.engine.panel.model:make-resource :kind "\u{1F600}")
                  (vovas.engine.panel.model:make-resource :kind "\u{FFFD}")))
           ;; D83D < FFFD, so the emoji comes FIRST by UTF-16
           (list "\u{1F600}" "\u{FFFD}"))

    ;; --- 5. resolve-type-selection ----------------------------------------
    (incf count)
    (check result "resolve-type-selection" "present"
           (vovas.engine.panel.model:resolve-type-selection "script" '("script" "image"))
           "script")
    (incf count)
    (check result "resolve-type-selection" "absent"
           (vovas.engine.panel.model:resolve-type-selection "gone" '("script"))
           "all")
    (incf count)
    (check result "resolve-type-selection" "all"
           (vovas.engine.panel.model:resolve-type-selection "all" '("script"))
           "all")

    ;; --- 6. filters -------------------------------------------------------
    (let ((row (vovas.engine.panel.model:make-resource
                :status "loaded" :kind "script" :source "network"
                :url "https://x/app.js")))
      (flet ((passes (status kind search)
               (and (vovas.engine.panel.model:matches-resource-filters
                     row (vovas.engine.panel.model:make-resource-filters
                          :status status :kind kind :search search))
                    t)))
        (incf count)
        (check result "matches-filters" "empty" (passes "" "" "") t)
        (incf count)
        (check result "matches-filters" "all" (passes "all" "all" "") t)
        (incf count)
        (check result "matches-filters" "status miss" (passes "error" "" "") nil)
        (incf count)
        ;; the search haystack is the four fields joined by a SPACE, so a term
        ;; spanning the join matches - "network https" is not in any one field
        (check result "matches-filters" "across join"
               (passes "" "" "network https") t)
        (incf count)
        (check result "matches-filters" "case-insensitive"
               (passes "" "" "APP.JS") t)
        (incf count)
        (check result "matches-filters" "trimmed"
               (passes "" "" "  app  ") t)))

    ;; --- 7. Counts keep insertion order -----------------------------------
    (incf count)
    (let ((c (vovas.engine.panel.model:make-counts)))
      (dolist (k '("b" "a" "b" "c" "a"))
        (vovas.engine.panel.model:counts-add c k))
      (check result "counts" "insertion order"
             (vovas.engine.panel.model:counts-alist c)
             '(("b" . 2) ("a" . 2) ("c" . 1))))

    (when verbose
      (format t "~&model gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
