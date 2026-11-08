;;;; gate-export.lisp - exportSemanticAnalysis.
;;;;
;;;; No oracle exists for this function - the Rust has no assertion for
;;;; `export_semantic_analysis` either, because it is a COMPOSITION of parts that
;;;; each carry their own oracle. So this gate verifies the contract instead:
;;;;
;;;;   - every artifact declared in *analysis-artifacts* is actually written
;;;;   - the readable reconstructions come FIRST (the engine's stated order, so
;;;;     an interrupted export still has the human-readable files)
;;;;   - exactly one index.html
;;;;   - nine workspaces and four journeys, each named by a non-empty id
;;;;   - every .json artifact parses, so nothing is written malformed
;;;;
;;;; A structural gate cannot prove the CONTENT is right. It can prove the
;;;; composition happened, which is the failure mode this function actually had.

(in-package :vovas.engine.gate)

(defun gate-export-inputs ()
  "The fixture's own pipeline inputs, assembled the way the Rust test does."
  (let* ((fx (read-json-file (fixture-path "panel/boundary-oracle.json")))
         (input (gethash "input" fx))
         (rf (gethash "reconFixture" input))
         (recon (let ((c (make-hash-table :test #'equal)))
                  (maphash (lambda (k v) (setf (gethash k c) v)) rf)
                  (setf (gethash "recon" c) (gethash "recon" input))
                  (setf (gethash "frameworkState" c) (gethash "frameworkState" input))
                  c)))
    (values (coerce (gethash "scriptFixture" input) 'list)
            recon
            (coerce (gethash "runtimeEntries" input) 'list)
            (coerce (gethash "runtimeManifest" input) 'list))))

(defun run-export-semantic-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (written '()))
    (multiple-value-bind (scripts recon entries manifest) (gate-export-inputs)
      (vovas.engine.panel.report:export-semantic-analysis
       (lambda (path content) (push (cons path content) written))
       scripts recon entries manifest))
    (setf written (nreverse written))
    ;; The prefix LENGTHS are taken from the literals rather than typed:
    ;; "_analysis/workspaces/" is 21 characters, not 22, and a hardcoded 22
    ;; compared a 22-character slice against a 21-character string - never
    ;; equal, so both counts read 0 while the files were plainly on disk.
    (let* ((paths (mapcar #'car written))
           (ws-prefix "_analysis/workspaces/")
           (jn-prefix "_analysis/journeys/"))

      ;; ---- every declared analysis artifact is present -------------------
      (dolist (pair vovas.engine.panel.paths:*analysis-artifacts*)
        (incf count)
        (check result (format nil "export/artifact/~a" (cdr pair)) "present"
               (and (member (car pair) paths :test #'string=) t)
               t))

      ;; ---- the readable reconstructions come first -----------------------
      (incf count)
      (check result "export/order/readable-first" "prefix"
             (and (search "_analysis/readable/" (first paths)) t)
             t)

      ;; ---- the console page is written exactly once ----------------------
      (incf count)
      (check result "export/index-once" "count"
             (count vovas.engine.panel.paths:*analysis-index-html* paths
                    :test #'string=)
             1)

      ;; ---- one file per workspace, and no id may be empty ---------------
      (let ((ws (remove-if-not
                  (lambda (p)
                    (and (>= (length p) (length ws-prefix))
                         (string= ws-prefix (subseq p 0 (length ws-prefix)))))
                  paths)))
        (incf count)
        (check result "export/workspaces/count" "files" (length ws) 9)
        (incf count)
        (check result "export/workspaces/no-empty-id" "ids"
               (and (every (lambda (p)
                             (> (length p)
                                (length "_analysis/workspaces/.json")))
                           ws)
                    t)
               t))

      ;; ---- one file per journey -----------------------------------------
      (incf count)
      (check result "export/journeys/count" "files"
             (length (remove-if-not
                      (lambda (p)
                        (and (>= (length p) (length jn-prefix))
                             (string= jn-prefix (subseq p 0 (length jn-prefix)))))
                      paths))
             4)

      ;; ---- nothing written is malformed JSON -----------------------------
      (dolist (pair written)
        (when (search ".json" (car pair))
          (incf count)
          (check result (format nil "export/parses/~a" (car pair)) "json"
                 (handler-case (progn (com.inuoe.jzon:parse (cdr pair)) t)
                   (error () nil))
                 t))))

    (when verbose
      (format t "~&export semantic gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; finalizeZipWithRecon
;;;
;;; The whole export in one call. No oracle exists for it either - it is the
;;; composition of writeReconArtifacts, exportRuntimeArtifacts,
;;; exportSemanticAnalysis and two unpack passes. What CAN be pinned without one:
;;;
;;;   - the file census, by prefix: how many _recon/, _runtime/, _analysis/ and
;;;     _unpack*/ entries appear
;;;   - the ORDER contract (recon before runtime before analysis before unpack)
;;;   - the runtime pass uses the HARDCODED _unpack-runtime prefix while the
;;;     script pass uses the caller's
;;;   - the merged report carries both passes' totals
;;;   - every text artifact is non-empty
;;;
;;; The caller's prefix is deliberately something other than the default, so a
;;; port that ignored the option or hardcoded its own would show up.
;;; ---------------------------------------------------------------------------

(defun gate-prefix-count (paths prefix)
  (length (remove-if-not
           (lambda (p)
             (and (>= (length p) (length prefix))
                  (string= prefix (subseq p 0 (length prefix)))))
           paths)))

(defun gate-full-recon ()
  "The Rust test's own `full_recon()`: a payload with EVERY guarded field present.

The fixture's reconFixture is sparse - only timings, stackProfile, captureStatus
and page - so asserting localStorage/sessionStorage/cookies against it fails for
the right reason but the wrong cause. This is the input the export test uses."
  (let ((h (make-hash-table :test #'equal)))
    (flet ((put (k v) (setf (gethash k h) v))
           (table (&rest pairs)
             (let ((t2 (make-hash-table :test #'equal)))
               (loop for (k v) on pairs by #'cddr do (setf (gethash k t2) v))
               t2)))
      (put "ls" (table "token" "a"))
      (put "ss" (table "step" "1"))
      (put "cookies" "a=1; b=2")
      (put "page" (table "title" "Demo" "url" "https://demo.test/"))
      (put "stackProfile"
           (table "framework" "react"
                  "evidence" (vector "data-reactroot")
                  "strategy" (table "profile" "balanced" "captureGraphQLOps" t)))
      (put "captureStatus" (table "ready" t))
      (put "frameworkState" (table "summary" (table "roots" 1)
                                   "router" (table "path" "/")))
      (put "timings" (vector (table "name" "https://demo.test/a.js"
                                    "startTime" 0 "duration" 5)))
      (put "recon"
           (table "xhr" (vector (table "url" "https://demo.test/api"))
                  "fetch" (vector (table "url" "https://demo.test/api2"))
                  "websockets" (vector (table "url" "wss://demo.test/ws"))
                  "sse" (vector (table "url" "https://demo.test/sse"))
                  "mutations" (vector (table "type" "childList"))
                  "runtime" (vector (table "id" "r1" "kind" "eval"
                                           "text" "var a = 1")))))
    h))

(defun run-finalize-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (files '()))
    (multiple-value-bind (scripts recon entries manifest) (gate-export-inputs)
      (declare (ignore manifest))
      (let* ((recon (gate-full-recon))
             (options (vovas.engine.pipeline:make-unpack-options
                       :path-prefix "_gate-script"))
             (merged
               (vovas.engine.panel.export:finalize-zip-with-recon
                (lambda (path content) (push (cons path content) files))
                scripts recon nil entries options)))
        (setf files (nreverse files))
        (let* ((written (mapcar #'car files))
               (recon-prefix "_recon/")
               (runtime-prefix "_runtime/")
               (analysis-prefix "_analysis/"))

          ;; ---- every phase produced files -----------------------------
          (dolist (pair (list (cons "recon" recon-prefix)
                              (cons "runtime" runtime-prefix)
                              (cons "analysis" analysis-prefix)))
            (incf count)
            (check result (format nil "finalize/~a-files" (car pair)) "count>0"
                   (and (plusp (gate-prefix-count written (cdr pair))) t)
                   t))

          ;; ---- the recon census ---------------------------------------
          ;;
          ;; The fixture's recon payload has ls, ss, cookies, page,
          ;; stackProfile, captureStatus and recon{xhr,fetch} non-empty, so these
          ;; are the files that must appear.
          (dolist (path '("_recon/localStorage.json"
                          "_recon/sessionStorage.json"
                          "_recon/cookies.json"
                          "_recon/page.json"
                          "_recon/stack-profile.json"
                          "_recon/capture-status.json"))
            (incf count)
            (check result (format nil "finalize/recon/~a" path) "present"
                   (and (member path written :test #'string=) t)
                   t))

          ;; ---- the ORDER contract --------------------------------------
          ;;
          ;; Recon is written first and analysis last among the three text
          ;; phases; a port that reordered them would still produce the same
          ;; census, so the sequence itself is asserted.
          (let ((first-recon (position-if
                              (lambda (p) (search recon-prefix p)) written))
                (first-runtime (position-if
                                (lambda (p) (search runtime-prefix p)) written))
                (first-analysis (position-if
                                 (lambda (p) (search analysis-prefix p)) written)))
            (incf count)
            (check result "finalize/order" "recon<runtime<analysis"
                   (and first-recon first-runtime first-analysis
                        (< first-recon first-runtime)
                        (< first-runtime first-analysis)
                        t)
                   t))

          ;; ---- the two unpack passes use DIFFERENT prefixes ------------
          ;;
          ;; The caller asked for `_gate-script`; the runtime pass ignores it and
          ;; uses `_unpack-runtime`, exactly as the JavaScript hardcodes.
          (incf count)
          (check result "finalize/unpack/script-prefix" "files>0"
                 (and (plusp (gate-prefix-count written "_gate-script")) t)
                 t)
          (incf count)
          (check result "finalize/unpack/runtime-prefix" "files>0"
                 (and (plusp (gate-prefix-count written "_unpack-runtime")) t)
                 t)
          (incf count)
          (check result "finalize/unpack/caller-prefix-not-on-runtime" "none"
                 (gate-prefix-count written "_gate-script/_unpack-runtime")
                 0)

          ;; ---- the merged report ---------------------------------------
          ;;
          ;; Both passes contribute totals, so `assets` is the SCRIPT count plus
          ;; the RUNTIME count - strictly greater than either alone.
          (let ((totals (vovas.engine.panel.assets:field merged "totals")))
            (incf count)
            (check result "finalize/merged/totals-present" "table"
                   (and (hash-table-p totals) t)
                   t)
            (incf count)
            (check result "finalize/merged/assets-positive" "count>0"
                   (and (hash-table-p totals)
                        (plusp (or (vovas.engine.panel.assets:field-number
                                    totals "assets") 0d0))
                        t)
                   t))

          ;; ---- the summary line renders from it ------------------------
          (incf count)
          (check result "finalize/summary" "sentence"
                 (let ((s (vovas.engine.panel.export:export-summary merged)))
                   (and (stringp s)
                        (plusp (length s))
                        (search "Export ready." s)
                        t))
                 t)

          ;; ---- nothing written is empty -------------------------------
          (let ((empties (remove-if-not (lambda (pair)
                                          (zerop (length (cdr pair))))
                                        files)))
            (incf count)
            (check result "finalize/no-empty-artifacts" "count"
                   (length empties) 0)))))

    (when verbose
      (format t "~&finalize gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))

;;; ---------------------------------------------------------------------------
;;; Parity: finalize against the SHIPPED wasm engine
;;;
;;; `finalize-oracle.json` was captured from the real engine through
;;; `panelFinalizeZipWithRecon` (see unpack-rs/scripts/finalize-oracle.mjs). It
;;; carries the inputs AND the engine's own file list, so this compares CONTENT
;;; rather than census - the one gap the structural gate above cannot close.
;;;
;;; `generatedAt` appears inside several artifacts as a clock, so both sides are
;;; normalised before comparison.
;;; ---------------------------------------------------------------------------

(defun gate-strip-clock-text (text)
  "TEXT with every ISO-8601 UTC instant replaced by a placeholder.

The artifacts carry the clock in four different syntactic positions - a pretty
JSON `\"generatedAt\": \"...\"`, a compact one inside the HTML's embedded
`application/json` blob, an `\"unpackedAt\": \"...\"` closing a manifest, and
bare prose in the waterfall's subtitle. Keying the pattern to the `generatedAt`
key therefore missed three of the four; keying it to the SHAPE OF THE INSTANT
catches all of them without having to enumerate the sites.

Only the instant is normalised, not the surrounding text, so a real clock bug
still shows up as the wrong NUMBER of substitutions or as a differing offset in
`gate-first-difference`."
  (cl-ppcre:regex-replace-all
   "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z"
   text
   "<clock>"))

(defun gate-count-clocks (text)
  "How many ISO-8601 instants TEXT carries."
  (length (cl-ppcre:all-matches
           "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z"
           text)))

(defun run-finalize-parity-gate (&key (verbose t))
  (let* ((result (make-gate-result))
         (count 0)
         (fx (read-json-file (fixture-path "panel/finalize-oracle.json")))
         (inp (gethash "inputs" fx))
         (exp (gethash "expected" fx))
         (opt (gethash "options" inp))
         (files '()))
    (let* ((assets (coerce (gethash "jsAssets" inp) 'list))
           (recon (gethash "reconData" inp))
           (payloads (gethash "runtimePayloads" inp))
           (opts (vovas.engine.pipeline:make-unpack-options
                  :path-prefix (or (and opt
                                        (vovas.engine.panel.assets:field-str
                                         opt "pathPrefix"))
                                   "_unpack")))
           (merged (vovas.engine.panel.export:finalize-zip-with-recon
                    (lambda (path content) (push (cons path content) files))
                    assets recon nil payloads opts)))
      (setf files (nreverse files))

      ;; ---- the summary line, compared exactly ------------------------
      (incf count)
      (check result "parity/summary" "sentence"
             (vovas.engine.panel.export:export-summary merged)
             (coerce (gethash "summary" exp) 'string))

      ;; ---- the census -------------------------------------------------
      (incf count)
      (check result "parity/file-count" "files"
             (length files) (gethash "fileCount" exp))

      ;; ---- the paths, as a set ---------------------------------------
      ;;
      ;; Sorted on both sides and compared as lists, so a missing file and an
      ;; extra file are both visible rather than masking each other.
      ;; `let*`, not `let`: `want-paths` reads `want-files`, so the bindings are
      ;; SEQUENTIAL. Under `let` they bind in parallel and `want-files` is
      ;; unbound inside the `want-paths` initialiser.
      (let* ((want-files (coerce (gethash "files" exp) 'list))
             (got-paths (sort (mapcar #'car files) #'string<))
             (want-paths (sort (mapcar (lambda (f)
                                        (coerce (vovas.engine.panel.assets:field-str
                                                 f "path") 'string))
                                      want-files)
                              #'string<)))
        (incf count)
        (check result "parity/paths" "sorted paths" got-paths want-paths)

        ;; ---- per-file CONTENT ----------------------------------------
        ;;
        ;; This is the substantive comparison: every text artifact must match
        ;; the engine's bytes after clock normalisation, and every binary one
        ;; must match its base64.
        (let ((mismatches '())
              (checked 0))
          (dolist (want want-files)
            (let* ((path (coerce (vovas.engine.panel.assets:field-str want "path") 'string))
                   (got (cdr (assoc path files :test #'string=)))
                   (want-text (vovas.engine.panel.assets:field want "content"))
                   (want-b64 (vovas.engine.panel.assets:field want "base64")))
              (cond
                ((null got)
                 (push (format nil "~a: missing from port" path) mismatches))
                (want-b64
                 (incf checked)
                 ;; The port wrote raw BYTES while the oracle carries base64, and
                 ;; there is no encoder in this tree. Decode the oracle's base64
                 ;; and compare the byte sequences instead of encoding the port's
                 ;; - same information, one fewer function to get wrong.
                 (let ((want-bytes (vovas.engine.decoders:decode-base64-to-bytes
                                    (coerce want-b64 'string))))
                   (unless (and (not (stringp got))
                                (equalp got want-bytes))
                     (push (format nil "~a: bytes differ (~a vs ~a)"
                                   path
                                   (if (stringp got) :text (length got))
                                   (if want-bytes (length want-bytes) :undecodable))
                           mismatches))))
                (want-text
                 (incf checked)
                 (let ((want-str (coerce want-text 'string)))
                   (unless (stringp got)
                     (push (format nil "~a: port wrote bytes, engine wrote text" path)
                           mismatches))
                   (when (and (stringp got)
                              (not (string= (gate-strip-clock-text got)
                                            (gate-strip-clock-text want-str))))
                     (let ((d (gate-first-difference
                               (gate-strip-clock-text got)
                               (gate-strip-clock-text want-str))))
                       (push (format nil "~a: ~a" path d) mismatches))))))))
          (incf count)
          (check result "parity/contents" "all artifacts equal"
                 (if mismatches
                     (format nil "~a mismatched: ~{~a~^; ~}"
                             (length mismatches)
                             (subseq mismatches 0 (min 3 (length mismatches))))
                     (format nil "~a compared" checked))
                 (format nil "~a compared" checked)))))

    (when verbose
      (format t "~&finalize parity gate: ~a/~a cases match~%"
              (gate-result-passed result) (gate-result-total result))
      (report-failures result))

    (and (= (gate-result-passed result) (gate-result-total result))
         (plusp count))))
