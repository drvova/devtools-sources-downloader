;;;; gate-graph.lisp — the GraphQL tier of panel/graph.rs.
;;;;
;;;; The oracle is `graph-oracle.json`. Its inputs live as hardcoded JSON literals
;;;; in `graph.rs`'s own test block (same pattern as assets.rs), so they are
;;;; transcribed here in the same order the expected arrays are indexed by.
;;;;
;;;; SCOPE: five sections - looksLikeGraphQLBody, normalizeGraphQLPayload,
;;;; parseGraphQLOperation, collectGraphQLOperations, collectNetworkOperations.
;;;; `buildModuleGraph` and `buildStartupChain` are NOT asserted because they are
;;;; not ported; they need ScriptAsset/RuntimeOrigin records.

(in-package :vovas.engine.gate)

(defun graph-json (text)
  "Parse a JSON literal. Empty text is the empty string, not a parse error."
  (if (string= text "")
      ""
      (let ((*read-default-float-format* 'double-float))
        (com.inuoe.jzon:parse text))))

(defun graph-want (value)
  "Normalise an oracle value for comparison: JZON's null to NIL, and a
double-float stays a double-float."
  (json-null value))

(defun run-graph-gate (&key (verbose t))
  (let* ((oracle (read-json-file (fixture-path "panel/graph-oracle.json")))
         (exp (gethash "expected" oracle))
         (result (make-gate-result))
         (count 0))

    ;; --- 1. looksLikeGraphQLBody, compared by TRUTHINESS ------------------
    ;;
    ;; The Rust test compares against `js_truthy(want[index])`, not the raw value,
    ;; because the JS returns `undefined` and the caller only ever reads it as a
    ;; boolean. Comparing raw would fail on a null expectation.
    (let ((bodies '("\"{\\\"query\\\":\\\"query Foo { a }\\\"}\""
                    "\"query Foo { a }\""
                    "\"mutation Bar($x:Int){b}\""
                    "\"{\\\"operationName\\\":\\\"X\\\"}\""
                    "\"{\\\"a\\\":1}\""
                    "\"\""
                    "null"
                    "{\"query\":\"query A\"}"
                    "{\"operationName\":\"B\"}"
                    "{\"extensions\":{}}"
                    "{\"other\":1}"
                    "[\"query A\"]")))
      (loop for text in bodies
            for i from 0
            for want across (gethash "looksLikeGraphQLBody" exp)
            do (incf count)
               (let ((body (graph-json text)))
                 (check result "looksLikeGraphQLBody" text
                        (and (vovas.engine.panel.graph:looks-like-graphql-body-p body) t)
                        (and (vovas.engine.panel.model:js-truthy (graph-want want)) t)))))

    ;; --- 2. normalizeGraphQLPayload ---------------------------------------
    (let ((payloads '("\"{\\\"query\\\":\\\"query Foo($x:Int){a}\\\",\\\"operationName\\\":\\\"Explicit\\\"}\""
                      "\"{\\\"body\\\":\\\"mutation Baz { b }\\\"}\""
                      "\"not json at all\""
                      "{\"query\":\"subscription Sub { c }\"}"
                      "{\"query\":\"plain text\"}"
                      "null"
                      "\"{\\\"query\\\":\\\"\\\"}\"")))
      (loop for text in payloads
            for want across (gethash "normalizeGraphQLPayload" exp)
            do (incf count)
               (let ((got (vovas.engine.panel.graph:normalize-graphql-payload
                           (graph-json text))))
                 (check result "normalizeGraphQLPayload" text
                        (list (getf got :operation-name)
                              (getf got :operation-type)
                              (getf got :query-preview))
                        (list (or (json-null (gethash "operationName" want)) "")
                              (or (json-null (gethash "operationType" want)) "")
                              (or (json-null (gethash "queryPreview" want)) ""))))))

    ;; --- 3. parseGraphQLOperation -----------------------------------------
    ;;
    ;; An entry that is not a GraphQL operation answers NIL, which the oracle
    ;; records as null.
    (let ((entries (list
                    (graph-json "{\"url\":\"https://api.test/graphql\",\"method\":\"POST\",\"requestBody\":\"{\\\"query\\\":\\\"query Q{a}\\\"}\",\"timestamp\":5,\"status\":200}")
                    (graph-json "{\"url\":\"https://api.test/rest\",\"requestBody\":\"{\\\"query\\\":\\\"query R{a}\\\"}\",\"timestamp\":0}")
                    (graph-json "{\"url\":\"https://api.test/rest\",\"requestBody\":\"nope\",\"status\":500}")
                    (graph-json "{\"url\":\"https://api.test/graphql\",\"requestBody\":{\"query\":\"query S{a}\"}}")
                    (graph-json "null"))))
      (loop for entry in entries
            for want across (gethash "parseGraphQLOperation" exp)
            do (incf count)
               (let ((got (vovas.engine.panel.graph:parse-graphql-operation entry))
                     (want-null (json-null want)))
                 (if (null want-null)
                     (check result "parseGraphQLOperation" "not an operation" got nil)
                     (check result "parseGraphQLOperation"
                            (gethash "url" want)
                            (and got (list (getf got :url) (getf got :method)))
                            (list (gethash "url" want)
                                  (gethash "method" want)))))))

    ;; --- 4. collectGraphQLOperations over the recon fixture ---------------
    ;; BUG 2 was here: the operations come from `graphRecon`, not `reconFixture`.
    ;; `reconFixture` holds only timings and stackProfile, so every call returned
    ;; zero operations and the count assertion read 0 against an expected 3.
    (let* ((input (gethash "input" oracle))
           (recon (gethash "graphRecon" input))
           (want (gethash "collectGraphQLOperations" exp))
           (got (vovas.engine.panel.graph:collect-graphql-operations recon)))
      (incf count)
      (check result "collectGraphQLOperations" "count"
             (length got) (length want))
      (incf count)
      (check result "collectGraphQLOperations" "order and urls"
             (loop for op in got collect (getf op :url))
             (loop for op across want collect (gethash "url" op))))

    ;; --- 5. collectNetworkOperations --------------------------------------
    ;;
    ;; Every xhr and fetch entry, not only GraphQL ones, sorted by timestamp.
    (let* ((input (gethash "input" oracle))
           (recon (gethash "graphRecon" input))
           (want (gethash "collectNetworkOperations" exp))
           (got (vovas.engine.panel.graph:collect-network-operations recon)))
      (incf count)
      (check result "collectNetworkOperations" "count"
             (length got) (length want))
      (incf count)
      (check result "collectNetworkOperations" "type and url order"
             (loop for op in got collect (list (getf op :type) (getf op :url)))
             (loop for op across want
                   collect (list (gethash "type" op) (gethash "url" op))))
      (incf count)
      (check result "collectNetworkOperations" "timestamps ascending"
             (loop for op in got collect (getf op :timestamp))
             (loop for op across want
                   collect (coerce (gethash "timestamp" op) 'double-float))))

    (when verbose
      (format t "~&graph gate: ~a/~a cases match (GraphQL tier)~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))
    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
