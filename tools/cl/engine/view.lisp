;;;; view.lisp — the panel's view layer, from panel/view.rs.
;;;;
;;;; View models plus the HTML strings the platform shim applies to the DOM. The
;;;; pre-port renderers built elements with `createElement`/`textContent`; the
;;;; markup produced here is the same structure with the same classes, labels and
;;;; inline styles, so the CSS and the e2e selectors keep working.
;;;;
;;;; That "same structure" is the whole contract, and it makes the HTML a stable
;;;; artifact rather than an implementation detail: a changed attribute order or a
;;;; changed escape would be a changed e2e selector.

(in-package :vovas.engine.panel.view)

;;; ---------------------------------------------------------------------------
;;; Escaping
;;; ---------------------------------------------------------------------------

(defun escape-html (text)
  "`escapeHtml`: the five HTML-sensitive characters, entity-encoded.

Apostrophe becomes `&#39;` rather than `&apos;` because the pre-port code used
the numeric form and the attribute values this escapes end up inside
double-quoted attributes that a browser must parse identically."
  (with-output-to-string (s)
    (loop for c across text
          do (case c
               (#\& (write-string "&amp;" s))
               (#\< (write-string "&lt;" s))
               (#\> (write-string "&gt;" s))
               (#\" (write-string "&quot;" s))
               (#\' (write-string "&#39;" s))
               (t (write-char c s))))))

;;; ---------------------------------------------------------------------------
;;; Markup
;;; ---------------------------------------------------------------------------

(defun resource-rows-html (items)
  "`resourceRowsHtml`: one `<tr>` per item, mirroring `appendResourceRow`.

The status dot is INLINE style, not a class, and the colour is decided by an exact
`status == \"loaded\"` test - so any status other than the literal string \"loaded\"
gets the red dot. An empty kind/source/url renders \"?\" in the cell but the
ORIGINAL (empty) value would still be what the title attribute carries, which is
why the title and the cell share one computed value here rather than each
substituting independently."
  (with-output-to-string (out)
    (dolist (row items)
      (let* ((dot (if (string= (vovas.engine.panel.model:resource-status row) "loaded")
                      "#48c774"
                      "#f14668"))
             (kind (let ((v (vovas.engine.panel.model:resource-kind row)))
                     (if (zerop (length v)) "?" v)))
             (source (let ((v (vovas.engine.panel.model:resource-source row)))
                       (if (zerop (length v)) "?" v)))
             (url (let ((v (vovas.engine.panel.model:resource-url row)))
                    (if (zerop (length v)) "?" v))))
        (write-string "<tr>" out)
        (format out "<td data-label=\"Status\"><span style=\"display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:4px;background-color:~a\"></span>~a</td>"
                dot (escape-html (vovas.engine.panel.model:resource-status row)))
        (format out "<td data-label=\"Type\">~a</td>" (escape-html kind))
        (format out "<td data-label=\"Source\">~a</td>" (escape-html source))
        (format out "<td data-label=\"URL\" class=\"url-cell mono\" title=\"~a\">~a</td>"
                (escape-html url) (escape-html url))
        (format out "<td data-label=\"Size\">~a</td>"
                (escape-html (vovas.engine.text:format-size
                              (vovas.engine.panel.model:resource-size row))))
        (write-string "</tr>" out)))))

(defun type-options-html (types)
  "`typeOptionsHtml`: the \"All types\" option first, then one per distinct kind."
  (with-output-to-string (out)
    (write-string "<option value=\"all\">All types</option>" out)
    (dolist (kind types)
      (format out "<option value=\"~a\">~a</option>"
              (escape-html kind) (escape-html kind)))))

;;; ---------------------------------------------------------------------------
;;; The tracker view
;;; ---------------------------------------------------------------------------

(defun tracker-view (tracker filters)
  "`trackerView`: counters, filter state and the row markup.

Returns a plist with the camelCase wire keys the platform shim reads, because
this object crosses into JavaScript and the key names are the contract:

  :loaded :unloaded :visible :total :type-selection
  :show-status-bar :show-list :show-empty :rows-html :types-html

The SHOW booleans are the subtle part. `show-list` is \"there are items AND some
survived filtering\"; `show-empty` is \"there are items BUT none survived\". With no
items at all BOTH are false, so the caller shows neither the list nor the empty
state - which is what keeps a fresh panel from flashing \"no results\" before the
first capture."
  (flet ((arr (key)
           (let ((v (and (hash-table-p tracker) (gethash key tracker))))
             (if (vectorp v) v #()))))
    (let* ((loaded (arr "loaded"))
           (unloaded (arr "unloaded"))
           (items '()))
      ;; loaded rows first, then unloaded; the ORDER index continues across the
      ;; two lists so a stable sort can break ties on it
      (loop for raw across loaded
            for i from 0
            do (push (vovas.engine.panel.model:normalize-resource raw "loaded" i) items))
      (loop for raw across unloaded
            for i from 0
            do (push (vovas.engine.panel.model:normalize-resource
                      raw "unloaded" (+ (length loaded) i))
                     items))
      (setf items (nreverse items))
      (let* ((types (vovas.engine.panel.model:collect-types items))
             (type-selection (vovas.engine.panel.model:resolve-type-selection
                              (vovas.engine.panel.model:resource-filters-kind filters)
                              types))
             (filtered (remove-if-not
                        (lambda (item)
                          (vovas.engine.panel.model:matches-resource-filters
                           item filters))
                        items))
             (sorted (stable-sort (copy-list filtered)
                                  (lambda (a b)
                                    (eq :less
                                        (vovas.engine.panel.model:compare-resources
                                         a b
                                         (vovas.engine.panel.model:resource-filters-sort
                                          filters))))))
             (has-items (plusp (length items))))
        (list :loaded (length loaded)
              :unloaded (length unloaded)
              :visible (length sorted)
              :total (length items)
              :type-selection type-selection
              :show-status-bar t
              :show-list (and has-items (plusp (length sorted)))
              :show-empty (and has-items (zerop (length sorted)))
              :rows-html (if has-items (resource-rows-html sorted) "")
              :types-html (type-options-html types))))))
