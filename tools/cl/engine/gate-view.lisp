;;;; gate-view.lisp — the panel view gate.
;;;;
;;;; Driven by `view-oracle.json`, captured from the SHIPPED ENGINE's
;;;; `panelTrackerView` - not from the Rust module's unit tests. That matters: the
;;;; binary is what ships, so this gate would catch a divergence between view.rs and
;;;; the binary that built it.
;;;;
;;;; Ten cases, chosen so each show/hide boolean is reachable independently:
;;;;   mixed            -> showList, escaping in both cell text and title
;;;;   filteredToNothing-> showEmpty with rowsHtml still EMPTY (not a placeholder)
;;;;   emptyTracker     -> NEITHER showList nor showEmpty
;;;;   selectionDropped -> typeSelection falls back to "all"
;;;;
;;;; rows-html and types-html are compared as TEXT, so attribute order, inline
;;;; styles and every escape are pinned byte for byte - these strings are what the
;;;; e2e selectors and the CSS target.

(in-package :vovas.engine.gate)

(defun view-json (text)
  (let ((*read-default-float-format* 'double-float))
    (com.inuoe.jzon:parse text)))

(defun view-plist (obj)
  "A JZON filters object as the filter struct. Absent keys take the defaults."
  (let ((get (lambda (key fallback)
               (let ((v (and (hash-table-p obj) (gethash key obj))))
                 (if (and (stringp v) (plusp (length v))) v fallback)))))
    (vovas.engine.panel.model:make-resource-filters
     :status (funcall get "status" "")
     :kind (funcall get "kind" "")
     :search (funcall get "search" "")
     :sort (funcall get "sort" "newest"))))

(defun run-view-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "panel/view-oracle.json")))
         (cases (gethash "cases" oracle))
         (result (make-gate-result))
         (count 0))

    (loop for name being the hash-keys of cases using (hash-value case)
          do (let* ((tracker (gethash "tracker" case))
                    (filters (view-plist (gethash "filters" case)))
                    (want (gethash "view" case))
                    (got (vovas.engine.panel.view:tracker-view tracker filters)))
               ;; each field its own assertion, so a failure names the field
               (dolist (pair (list (cons :loaded "loaded")
                                   (cons :unloaded "unloaded")
                                   (cons :visible "visible")
                                   (cons :total "total")))
                 (incf count)
                 (check result (format nil "~a" (car pair)) name
                        (getf got (car pair))
                        (truncate (gethash (cdr pair) want))))
               ;; the booleans: presence, and a JSON false is not a missing key
               (dolist (pair (list (cons :show-status-bar "showStatusBar")
                                   (cons :show-list "showList")
                                   (cons :show-empty "showEmpty")))
                 (incf count)
                 (check result (format nil "~a" (car pair)) name
                        (and (getf got (car pair)) t)
                        (and (gethash (cdr pair) want) t)))
               (incf count)
               (check result "typeSelection" name
                      (getf got :type-selection)
                      (let ((v (gethash "typeSelection" want)))
                        (if (stringp v) v "all")))
               ;; the HTML, byte for byte
               (incf count)
               (check result "rowsHtml" name
                      (getf got :rows-html)
                      (let ((v (gethash "rowsHtml" want)))
                        (if (stringp v) v "")))
               (incf count)
               (check result "typesHtml" name
                      (getf got :types-html)
                      (let ((v (gethash "typesHtml" want)))
                        (if (stringp v) v "")))))

    (when verbose
      (format t "~&view gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
