;;;; gate-policy.lisp — the capture policy gate.
;;;;
;;;; The oracle is `tests/fixtures/panel/capture-policy.json`, which was captured
;;;; from the Rust but has only ever been read by `tests/capture_policy_test.rs`
;;;; for a few keys. It carries 41 redactKey cases and 23 textMime cases that
;;;; nothing had ever exercised - so this gate is the first use of most of it.
;;;;
;;;; Every pattern case is compiled HERE, from the shipped STRING, rather than
;;;; reusing a scanner the port might keep. That is deliberate: the engine ships
;;;; the pattern as text (the page world compiles it as a RegExp), so a port that
;;;; "helpfully" compiled it once would have two definitions to keep in step, and
;;;; this gate would be checking the wrong one.

(in-package :vovas.engine.gate)

(defun policy-scanner (pattern)
  "(?i) compile of a shipped pattern string.

Case-insensitivity is not assumed: the oracle records `flags: \"i\"` for both
patterns, and the page world's RegExp uses it, so matching without it would fail
the uppercase cases while the lowercase ones still passed."
  (cl-ppcre:create-scanner pattern :case-insensitive-mode t))

(defun wire-to-kebab (name)
  "`runtimeItems` -> `:RUNTIME-ITEMS`, the inverse of the port's wire naming.

Written out rather than derived from `policy-wire-name` because that function is
the thing under test: using it to build the expectation would let a broken
converter agree with itself."
  (let ((out (make-string-output-stream)))
    (loop for c across name
          do (if (upper-case-p c)
                 (progn (write-char #\- out) (write-char c out))
                 (write-char (char-upcase c) out)))
    (intern (get-output-stream-string out) :keyword)))

(defun run-policy-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "panel/capture-policy.json")))
         (result (make-gate-result))
         (count 0))

    ;; --- 1. the patterns, matched against the oracle's own case tables -----
    (dolist (pair '(("redactKey" . "redact-key")
                    ("textMime" . "text-mime")))
      (let* ((key (car pair))
             (section (gethash key oracle))
             (pattern (gethash "pattern" section))
             (scanner (policy-scanner pattern))
             (cases (gethash "cases" section)))
        ;; the STRING must be the shipped one, not just compile to something
        (incf count)
        (check result (format nil "~a/pattern" key) key
               pattern
               (if (string= key "redactKey")
                   vovas.engine.panel.policy:*redact-key-pattern*
                   vovas.engine.panel.policy:*text-mime-pattern*))
        (loop for text being the hash-keys of cases using (hash-value want)
              do (incf count)
                 (check result (format nil "~a/match" key) text
                        (and (cl-ppcre:scan scanner text) t)
                        (if (eq want t) t nil)))))

    ;; --- 2. the GraphQL URL marker ----------------------------------------
    (incf count)
    (check result "graphql-url" "marker"
           vovas.engine.panel.policy:*graphql-url-marker*
           (gethash "graphqlUrlMarker" oracle))

    ;; --- 3. every limit ---------------------------------------------------
    ;; Named individually so a wrong value names the budget, not the object.
    (let ((want (gethash "limits" oracle))
          (got vovas.engine.panel.policy:*limits*))
      (loop for key being the hash-keys of want using (hash-value value)
            do (incf count)
               (check result "limits" key (getf got (wire-to-kebab key))
                      (if (integerp value) value (truncate value)))))

    ;; --- 4. the wire object's SHAPE and key names -------------------------
    ;; The page world reads these by literal name, so a kebab-cased key would
    ;; silently stop a rule being applied rather than fail loudly.
    (let ((wire (vovas.engine.panel.policy:capture-policy)))
      (dolist (key '(:redact-key :text-mime :graphql-url :graphql-body
                     :graphql-body-keys :default-strategy :limits))
        (incf count)
        (check result "capture-policy/key" key
               (not (null (getf wire key))) t))
      ;; the nested objects must be wire-cased, not kebab
      (let ((limits (getf wire :limits))
            (strategy (getf wire :default-strategy)))
        ;; The wire keys are CAMELCASE with literal (pipe-interned) names -
        ;; `:|runtimeItems|`, not `:runtime-items`. Asserting the kebab spelling
        ;; here was wrong and cost a round: the port was correct and the
        ;; expectation was not. These are the names the page world reads by
        ;; literal string, so they are the boundary contract.
        (dolist (key '(:|runtimeItems| :|runtimeText| :|resourceUrls| :|scriptUrls|
                       :|responseText| :|socketMessage| :|mutationText|
                       :|elementText| :|elementLabel| :|classNames| :|queryItems|))
          (incf count)
          (check result "capture-policy/limits-wire-key" key
                 (not (null (getf limits key))) t))
        ;; PRESENCE, not truthiness. `:|preferHydratedDom|` is legitimately NIL and
        ;; the page world still needs the KEY to exist; a truthiness test reports a
        ;; correctly-shipped false as missing, which is exactly what it did here
        ;; once - in a section whose own comment already warned about it. The only
        ;; honest test is whether the key is IN the plist.
        (dolist (key '(:|bootDelayMs| :|networkQuietMs| :|maxCaptureMs|
                       :|preferHydratedDom| :|reasons|))
          (incf count)
          (check result "capture-policy/strategy-wire-key" key
                 (loop for (k v) on strategy by #'cddr thereis (eq k key))
                 t))))

    ;; --- 5. default-strategy, structurally (no oracle key) ----------------
    (let ((s (vovas.engine.panel.policy:default-strategy)))
      (incf count)
      (check result "default-strategy/profile" "profile"
             (getf s :profile) "generic-app")
      (incf count)
      (check result "default-strategy/count" "keys"
             (loop for rest on s by #'cddr count t)
             13)
      ;; all four opt-ins are false; a port defaulting any of them true would
      ;; change what the page world captures
      (incf count)
      (check result "default-strategy/opt-ins-all-false" "four booleans"
             (list (getf s :prefer-hydrated-dom)
                   (getf s :capture-framework-state)
                   (getf s :capture-graphql-ops)
                   (getf s :prioritize-source-maps))
             (list nil nil nil nil)))

    (when verbose
      (format t "~&policy gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
