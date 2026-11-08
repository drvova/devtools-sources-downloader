;;;; graph.lisp — GraphQL and network operation collection, from panel/graph.rs.
;;;;
;;;; SCOPE: the GraphQL tier only — `looks-like-graphql-body`,
;;;; `normalize-graphql-payload`, `parse-graphql-operation`,
;;;; `collect-graphql-operations`, `collect-network-operations`.
;;;;
;;;; NOT ported yet, stated plainly: `build-module-graph` and `build-startup-chain`.
;;;; Those need `ScriptAsset` and `RuntimeOrigin` records, which the assets pipeline
;;;; tier still owes. This file's gate asserts the five functions above and nothing
;;;; else, so a green run does not imply the graph or chain builders work.
;;;;
;;;; The GraphQL body rule is shared with the page world through
;;;; `policy:*graphql-body-pattern*` — the Rust builds its regex FROM that constant
;;;; with `unicode(false)`, and the page world compiles the same string as a
;;;; RegExp. Spelling it again here would be the same rule written two ways.

(in-package :vovas.engine.panel.graph)

;;; ---------------------------------------------------------------------------
;;; The two patterns, compiled from the shared constant
;;; ---------------------------------------------------------------------------

(defparameter *body-scanner*
  (cl-ppcre:create-scanner vovas.engine.panel.policy:*graphql-body-pattern*)
  "`looksLikeGraphQLBody`'s matcher, compiled from the policy constant.

cl-ppcre's `\\b` is ASCII-only already, which is what the Rust gets from
`unicode(false)` — so the shared string means the same thing on both sides without
a flag.")

(defparameter *operation-scanner*
  (cl-ppcre:create-scanner
   "(?:^|\\b)(query|mutation|subscription)[ \t\n\u{b}\u{c}\r]+([A-Za-z0-9_]+)")
  "`normalizeGraphQLPayload`'s operation capture. The whitespace run between the
keyword and the name is REQUIRED - `query` alone names no operation.")

;;; ---------------------------------------------------------------------------
;;; Coercion
;;; ---------------------------------------------------------------------------

(defun graphql-value-text (value)
  "`graphqlValueText`: a string for text and numbers, EMPTY for null, and
\"[object Object]\" for an array or object.

Deliberately NOT `assets::value-text`, which coerces a structure through
`Number(...)`. A GraphQL variable that is a structure must not silently become 0
in the report, so the two accessors differ on purpose."
  (cond
    ((null value) "")                    ; JSON null and absent both
    ((vovas.engine.panel.model:json-null-p value) "")
    ((stringp value) value)
    ((numberp value) (vovas.engine.number:to-string (coerce value 'double-float)))
    ((eq value t) "true")
    ((or (vectorp value) (hash-table-p value)) "[object Object]")
    (t "")))

;;; ---------------------------------------------------------------------------
;;; looksLikeGraphQLBody
;;; ---------------------------------------------------------------------------

(defun looks-like-graphql-body-p (body)
  "`looksLikeGraphQLBody`: whether BODY names a GraphQL operation.

A STRING is pattern-matched. An OBJECT is a GraphQL body if any of
`query` / `operationName` / `extensions` is present AND truthy - an empty string
for `query` does not count, which is what separates `{query:\"\"}` from a real
operation. Anything else, including an ARRAY, is not a GraphQL body."
  (cond
    ((stringp body) (and (cl-ppcre:scan *body-scanner* body) t))
    ((hash-table-p body)
     (loop for key in vovas.engine.panel.policy:*graphql-body-keys*
           thereis (vovas.engine.panel.model:js-truthy
                    (vovas.engine.panel.assets:field body key))))
    (t nil)))

;;; ---------------------------------------------------------------------------
;;; normalizeGraphQLPayload
;;; ---------------------------------------------------------------------------

(defun normalize-graphql-payload (body)
  "`normalizeGraphQLPayload`: `{operationName, operationType, queryPreview}`.

A STRING body is parsed as JSON when it is JSON, and otherwise treated as the
query itself (`{\"query\": <text>}`) - that fallback is what lets a raw GraphQL
document be recorded rather than rejected.

The name comes from `operationName` when it is truthy, else from the FIRST
`query|mutation|subscription NAME` in the query text, else empty. The preview is
truncated to 240 UTF-16 UNITS, not characters."
  (let* ((parsed
           (cond
             ((stringp body)
              ;; On a parse FAILURE the Rust falls back to {"query": <the text>},
              ;; so a raw GraphQL document is recorded rather than rejected. My
              ;; first version answered NIL here, which then read as "not a table"
              ;; and produced an empty payload - so the fallback existed in the
              ;; sentence and not in the code.
              (handler-case
                  (let ((*read-default-float-format* 'double-float))
                    (let ((v (com.inuoe.jzon:parse body)))
                      (if (hash-table-p v) v (list :query-text body))))
                (error () (list :query-text body))))
             (t body)))
         (payload (cond ((hash-table-p parsed) parsed)
                        ((and (listp parsed) (stringp (getf parsed :query-text)))
                         ;; the parse-failure fallback: the whole text IS the query
                         (let ((h (make-hash-table :test #'equal)))
                           (setf (gethash "query" h) (getf parsed :query-text))
                           h))
                        (t (make-hash-table :test #'equal))))
         (from-query (let ((v (vovas.engine.panel.assets:field payload "query")))
                       (and (vovas.engine.panel.model:js-truthy v)
                            (graphql-value-text v))))
         (from-body (let ((v (vovas.engine.panel.assets:field payload "body")))
                      (and (vovas.engine.panel.model:js-truthy v)
                           (graphql-value-text v))))
         (query (or from-query from-body ""))
         (capture (multiple-value-list (cl-ppcre:scan-to-strings *operation-scanner* query)))
         (captured (and (first capture) (second capture)))
         (explicit (let ((v (vovas.engine.panel.assets:field payload "operationName")))
                     (and (vovas.engine.panel.model:js-truthy v)
                          (graphql-value-text v))))
         (operation-name (or explicit
                             (and captured (aref captured 1))
                             ""))
         (operation-type (or (and captured (aref captured 0)) "")))
    (list :operation-name operation-name
          :operation-type operation-type
          :query-preview (vovas.engine.util:utf16-prefix query 240))))

;;; ---------------------------------------------------------------------------
;;; parseGraphQLOperation
;;; ---------------------------------------------------------------------------

(defun text-or (entry key fallback)
  "`textOr`: the field, or FALLBACK when it is EMPTY. An empty string is as good
as absent here, which is the JS `entry[key] || fallback` idiom."
  (let ((value (vovas.engine.panel.assets:field-str entry key)))
    (if (zerop (length value)) fallback value)))

(defun parse-graphql-operation (entry)
  "`parseGraphQLOperation`: a normalized operation, or NIL when ENTRY is not one.

The gate is: the URL contains \"graphql\" (case-insensitively) OR the body looks
like a GraphQL body. That OR matters - a documented endpoint need not carry a
recognisable body, and a REST-shaped URL can still carry one."
  (when (null entry)
    (return-from parse-graphql-operation nil))
  (when (vovas.engine.panel.model:json-null-p entry)
    (return-from parse-graphql-operation nil))
  (let* ((url (graphql-value-text (vovas.engine.panel.assets:field entry "url")))
         (body (vovas.engine.panel.assets:field entry "requestBody")))
    (unless (or (search "graphql" (string-downcase url))
                (looks-like-graphql-body-p body))
      (return-from parse-graphql-operation nil))
    (let ((payload (normalize-graphql-payload body)))
      (list :url url
            :method (text-or entry "method" "POST")
            :operation-name (getf payload :operation-name)
            :operation-type (getf payload :operation-type)
            :query-preview (getf payload :query-preview)
            :timestamp (vovas.engine.panel.assets:field-number entry "timestamp")
            :status (vovas.engine.panel.assets:field-number entry "status")))))

;;; ---------------------------------------------------------------------------
;;; collectGraphQLOperations
;;; ---------------------------------------------------------------------------

(defun recon-array (recon key)
  "The array at RECON[KEY], or an empty vector. Absent, null, and a non-array all
read as empty - the Rust's `as_array().cloned().unwrap_or_default()`."
  (let ((v (and (hash-table-p recon) (gethash key recon))))
    (if (vectorp v) v #())))

(defun collect-graphql-operations (recon)
  "`collectGraphQLOperations`: operations from `xhr` then `fetch`, in that order.

XHR before fetch, and NOT re-sorted - the order is part of the output."
  (let ((ops '()))
    (dolist (key '("xhr" "fetch"))
      (loop for item across (recon-array recon key)
            do (let ((parsed (parse-graphql-operation item)))
                 (when parsed (push parsed ops)))))
    (nreverse ops)))

;;; ---------------------------------------------------------------------------
;;; collectNetworkOperations
;;; ---------------------------------------------------------------------------

(defun collect-network-operations (recon)
  "`collectNetworkOperations`: EVERY xhr and fetch entry, sorted by timestamp
ascending.

The sort is stable and treats NaN as 0, so an entry with no timestamp sorts with
the zeros rather than to an undefined position. `responsePreview` is the first
truthy of three possible keys, in a fixed order."
  (let ((ops '()))
    (dolist (pair '(("xhr" . "xhr") ("fetch" . "fetch")))
      (loop for item across (recon-array recon (cdr pair))
            do (let* ((body (let ((v (vovas.engine.panel.assets:field item "requestBody")))
                              (if (vovas.engine.panel.model:js-truthy v) v "")))
                      (headers (let ((v (vovas.engine.panel.assets:field item "requestHeaders")))
                                 (if (vovas.engine.panel.model:js-truthy v)
                                     v
                                     (make-hash-table :test #'equal))))
                      (preview (or (loop for key in '("responseText" "responseBodyExcerpt"
                                                      "responsePreview")
                                         for v = (vovas.engine.panel.assets:field item key)
                                         when (vovas.engine.panel.model:js-truthy v)
                                           return v)
                                   "")))
                 (push (list :type (car pair)
                             :url (vovas.engine.panel.assets:field-str item "url")
                             :method (text-or item "method" "GET")
                             :status (vovas.engine.panel.assets:field-number item "status")
                             :timestamp (vovas.engine.panel.assets:field-number item "timestamp")
                             :request-body body
                             :request-headers headers
                             :response-headers (vovas.engine.panel.assets:field-str
                                                item "responseHeaders")
                             :response-preview preview)
                       ops))))
    (stable-sort (nreverse ops)
                 (lambda (a b)
                   (< (let ((v (getf a :timestamp)))
                        (if (sb-ext:float-nan-p v) 0d0 v))
                      (let ((v (getf b :timestamp)))
                        (if (sb-ext:float-nan-p v) 0d0 v)))))))
