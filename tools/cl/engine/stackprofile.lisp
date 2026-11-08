;;;; stackprofile.lisp — the page-profile analyzer, from panel/stackprofile.rs.
;;;;
;;;; Technology and trait detection over a captured page snapshot, plus the capture
;;;; strategy derived from it. The page world collects the snapshot - only it can
;;;; read a page's globals and DOM - and the analysis runs here, so the detector
;;;; vocabulary lives with the rest of the engine's scanning logic.
;;;;
;;;; ORDER IS THE CONTRACT in three places, each commented where it happens:
;;;;   - technology rules run in a FIXED sequence, and Vue is an `else if` under
;;;;     Nuxt, so a page carrying both markers reports Nuxt only
;;;;   - `tech` MERGES into an existing entry by name, raising confidence to the
;;;;     maximum seen and appending evidence, so two rules firing for React leave
;;;;     ONE React entry with both signals
;;;;   - the final sort is confidence DESC, then name ASC

(in-package :vovas.engine.panel.stackprofile)

(defparameter *version* "1.0.0"
  "Reported by the profile, mirroring the page-world module's VERSION.")

;;; ---------------------------------------------------------------------------
;;; The regexes
;;; ---------------------------------------------------------------------------

(defparameter *react-re*
  (cl-ppcre:create-scanner "/react(?:-dom)?(?:@|\\.|/)" :case-insensitive-mode t))
(defparameter *chunk-re*
  (cl-ppcre:create-scanner "\\.chunk\\.[^/?#]+$" :case-insensitive-mode t))
(defparameter *webpack-re*
  (cl-ppcre:create-scanner "webpack(?:-|\\.|/)" :case-insensitive-mode t))
(defparameter *hashed-assets-re*
  (cl-ppcre:create-scanner "/assets/.+\\.[a-f0-9]{6,}\\.(?:js|css)"
                           :case-insensitive-mode t))
(defparameter *parcel-re* (cl-ppcre:create-scanner "parcel" :case-insensitive-mode t))
(defparameter *apollo-re* (cl-ppcre:create-scanner "apollo" :case-insensitive-mode t))
(defparameter *relay-re* (cl-ppcre:create-scanner "relay" :case-insensitive-mode t))

;;; ---------------------------------------------------------------------------
;;; Snapshot reads
;;;
;;; Every one treats a MISSING parent as an empty object, because a snapshot from
;;; a page with no `network` block must behave exactly like one with an empty
;;; `network` block. That is why they take the parent and the key rather than a
;;; pre-resolved value.
;;; ---------------------------------------------------------------------------

(defun snap-field (parent key)
  "`parent[key]`, or NIL. A non-object parent reads as no field at all."
  (vovas.engine.panel.assets:field parent key))

(defun snap-flag (parent key)
  "`flag`: whether the field is JS-truthy."
  (let ((v (snap-field parent key)))
    (if (vovas.engine.panel.model:js-truthy v) t nil)))

(defun snap-num (parent key)
  "`num`: `x || 0` for the counter comparisons."
  (let ((v (snap-field parent key)))
    (if (numberp v) (coerce v 'double-float) 0d0)))

(defun snap-over (parent key n)
  "`over`: `(x || 0) > n`."
  (> (snap-num parent key) (coerce n 'double-float)))

(defun snap-lower (parent key)
  "`lower`: `String(value || '').toLowerCase()`."
  (let ((v (snap-field parent key)))
    (if (vovas.engine.panel.model:js-truthy v)
        (string-downcase (vovas.engine.panel.model:js-string v))
        "")))

(defun normalize-list (value)
  "`normalizeList`: an array filtered by truthiness then mapped to strings;
anything that is not an array reads as empty."
  (if (vectorp value)
      (loop for item across value
            when (vovas.engine.panel.model:js-truthy item)
              collect (vovas.engine.panel.model:js-string item))
      '()))

(defun add-unique (list value)
  "`addUnique`: trimmed, non-empty, first occurrence wins. Answers the new list."
  (let ((v (vovas.engine.util:js-trim (or value ""))))
    (if (or (zerop (length v)) (member v list :test #'string=))
        list
        (append list (list v)))))

;;; ---------------------------------------------------------------------------
;;; The registries
;;; ---------------------------------------------------------------------------

(defmacro tech (place name category confidence signal)
  "`tech()`: register NAME, or merge into an existing entry.

A MACRO, not a function, because the accumulator is a caller binding: a function
would `push` onto its own parameter and the caller would never see the entry, so
every technology would be silently dropped and the profile would report
`technologies: null` while looking healthy. The macro setfs the place, which needs
no changes at the ~20 call sites.

Merging raises confidence to the MAXIMUM seen and appends the signal, so two rules
firing for React leave ONE entry carrying both pieces of evidence. A confidence of
exactly 0 becomes 0.5 - the Rust's `if confidence == 0.0`."
  `(setf ,place (tech-1 ,place ,name ,category ,confidence ,signal)))

(defun tech-1 (techs name category confidence signal)
  (let* ((confidence (if (= (coerce confidence 'double-float) 0d0)
                         0.5d0
                         (coerce confidence 'double-float)))
         (cell (assoc name techs :test #'string=)))
    (if cell
        (progn
          (when (> confidence (getf (cdr cell) :confidence))
            (setf (getf (cdr cell) :confidence) confidence))
          (when signal
            (let ((ev (getf (cdr cell) :evidence)))
              (setf (getf (cdr cell) :evidence) (add-unique ev signal)))))
        ;; APPEND, for the same reason as traits: the evidence object iterates this
        ;; list in insertion order and `profileText` pins that order.
        (setf techs
              (append techs
                      (list (cons name (list :category category
                                             :confidence confidence
                                             :evidence (add-unique '() (or signal ""))))))))
    techs))

(defmacro trait-hit (place name signal)
  "`trait()`: register NAME or append a signal. A macro for the same reason as
`tech`: the accumulator is the caller's binding."
  `(setf ,place (trait-hit-1 ,place ,name ,signal)))

(defun trait-hit-1 (traits name signal)
  "`trait()`: register NAME or append a signal.

APPENDS rather than pushes. The evidence object is built by iterating this list in
INSERTION order, and `profileText` pins that order - so a `push` reverses it and
every multi-trait case differs on key order alone while every value is correct."
  (let ((cell (assoc name traits :test #'string=)))
    (if cell
        (when signal
          (let ((ev (getf (cdr cell) :evidence)))
            (setf (getf (cdr cell) :evidence) (add-unique ev signal))))
        (setf traits
              (append traits
                      (list (cons name (list :evidence (add-unique '() (or signal ""))))))))
    traits))

;;; ---------------------------------------------------------------------------
;;; Strategy
;;; ---------------------------------------------------------------------------

(defun default-strategy ()
  "`createDefaultStrategy`: the generic profile's timings.

The four booleans are all NIL - the generic profile does not opt into hydrated
DOM, framework state, GraphQL operations or source-map priority. They are present
rather than omitted because the page world reads them directly."
  (list :profile "generic-app"
        :boot-delay-ms 1200d0
        :network-quiet-ms 1000d0
        :mutation-quiet-ms 1200d0
        :runtime-quiet-ms 1000d0
        :socket-quiet-ms 2200d0
        :worker-grace-ms 1200d0
        :max-capture-ms 18000d0
        :prefer-hydrated-dom nil
        :capture-framework-state nil
        :capture-graphql-ops nil
        :prioritize-source-maps nil
        :reasons '("Generic adaptive profile")))

(defun build-strategy (tech-names traits)
  "`buildStrategy(profile)`: the capture timings derived from what was detected.

Each block OVERRIDES the previous where they overlap, and the ORDER is the Rust's:
hydration, GraphQL, socket, worker, CMS, bundler.

The CMS block is the one that goes the other way: it LOWERS networkQuietMs with
`min` where the others RAISE it with `max`. A WordPress site that also shows
GraphQL therefore ends at 1100, not 1600 - and a port that used max everywhere
would pass every single-detection case and fail only the combination."
  (let* ((s (default-strategy))
         (has-tech (lambda (name) (member name tech-names :test #'string=)))
         (has-trait (lambda (name) (member name traits :test #'string=)))
         (reasons '()))
    (flet ((set-num (key value) (setf (getf s key) (coerce value 'double-float)))
           (num (key) (getf s key))
           (reason (text)
             (unless (member text reasons :test #'string=)
               (push text reasons))))
      (when (or (funcall has-tech "Next.js") (funcall has-tech "Nuxt")
                (funcall has-tech "Remix") (funcall has-tech "Astro")
                (funcall has-tech "SvelteKit"))
        (setf (getf s :profile) "spa-hydration")
        (set-num :boot-delay-ms 1600)
        (set-num :network-quiet-ms 1500)
        (set-num :mutation-quiet-ms 1800)
        (set-num :runtime-quiet-ms 1400)
        (setf (getf s :prefer-hydrated-dom) t
              (getf s :capture-framework-state) t
              (getf s :prioritize-source-maps) t)
        (reason "Hydration-oriented framework markers detected"))

      (when (or (funcall has-trait "graphql-heavy") (funcall has-tech "Apollo")
                (funcall has-tech "Relay") (funcall has-tech "GraphQL"))
        (when (string= (getf s :profile) "generic-app")
          (setf (getf s :profile) "graphql-app"))
        (setf (getf s :capture-graphql-ops) t)
        (set-num :network-quiet-ms (max (num :network-quiet-ms) 1600d0))
        (reason "GraphQL traffic detected"))

      (when (funcall has-trait "socket-heavy")
        (setf (getf s :profile) "socket-streaming")
        (set-num :socket-quiet-ms 3600)
        (set-num :max-capture-ms (max (num :max-capture-ms) 22000d0))
        (reason "Socket or SSE activity detected"))

      (when (or (funcall has-trait "worker-heavy") (funcall has-trait "wasm-heavy"))
        (setf (getf s :profile) "worker-runtime-heavy")
        (set-num :worker-grace-ms 2200)
        (set-num :runtime-quiet-ms 1800)
        (set-num :max-capture-ms (max (num :max-capture-ms) 24000d0))
        (reason "Worker or WebAssembly activity detected"))

      (when (or (funcall has-tech "WordPress") (funcall has-tech "Shopify"))
        (when (string= (getf s :profile) "generic-app")
          (setf (getf s :profile) "static-site"))
        (set-num :network-quiet-ms (min (num :network-quiet-ms) 1100d0))
        (set-num :mutation-quiet-ms (min (num :mutation-quiet-ms) 1000d0))
        (reason "CMS or commerce platform markers detected"))

      (when (or (funcall has-tech "Webpack") (funcall has-tech "Vite")
                (funcall has-tech "Parcel"))
        (setf (getf s :prioritize-source-maps) t)
        (reason "Bundler markers detected"))

      (when reasons
        (setf (getf s :reasons) (nreverse reasons))))
    s))

;;; ---------------------------------------------------------------------------
;;; analyze
;;; ---------------------------------------------------------------------------

(defun has-url (urls needle)
  "`hasUrl`: a lowercased substring search over the URL list."
  (let ((needle (string-downcase needle)))
    (some (lambda (url) (search needle (string-downcase url))) urls)))

(defun any-regex (list scanner)
  "`anyRegex`: any item matching SCANNER."
  (some (lambda (item) (cl-ppcre:scan scanner item)) list))

(defun clamp (value min max)
  "`Math.max(min, Math.min(max, value))`."
  (max (coerce min 'double-float) (min (coerce max 'double-float) value)))

;; The empty-container marker USED to be defined here. It now lives in
;; `model.lisp`, because `artifacts.lisp` - which owns the serializer that has to
;; honour it - loads in a package that was declared before this one, and a struct
;; it cannot name is a struct it cannot read. See the note in `package.lisp`.

(defun analyze (snapshot)
  "`analyze(snapshot)`: the technology/trait profile plus its capture strategy.

`generated-at` is the clock seam; everything else is a pure function of SNAPSHOT,
which is what lets the 28-case oracle compare whole profiles."
  (let* ((urls (append (normalize-list (snap-field snapshot "resourceUrls"))
                       (normalize-list (snap-field snapshot "scriptUrls"))))
         (globals (snap-field snapshot "globals"))
         (dom (snap-field snapshot "dom"))
         (network (snap-field snapshot "network"))
         (runtime (snap-field snapshot "runtime"))
         (activity (snap-field snapshot "activity"))
         (endpoints (normalize-list (snap-field network "graphqlEndpoints")))
         (techs '())
         (traits '()))

    ;; --- frameworks, in the Rust's fixed order ---------------------------
    (when (or (snap-flag globals "nextData") (snap-flag dom "hasNextRoot")
              (has-url urls "/_next/"))
      (tech techs "Next.js" "framework" 0.97d0
            (if (snap-flag globals "nextData") "window.__NEXT_DATA__" "/_next/ assets")))
    (when (or (snap-flag globals "reactDevtoolsHook")
              (has-url urls "react-dom")
              (any-regex urls *react-re*))
      (tech techs "React" "library" 0.86d0
            (if (snap-flag globals "reactDevtoolsHook")
                "__REACT_DEVTOOLS_GLOBAL_HOOK__"
                "React bundle markers")))
    (if (or (snap-flag globals "nuxt") (snap-flag dom "hasNuxtRoot")
            (has-url urls "/_nuxt/"))
        (tech techs "Nuxt" "framework" 0.95d0
              (if (snap-flag dom "hasNuxtRoot") "#__nuxt" "/_nuxt/ assets"))
        ;; Vue is an ELSE IF under Nuxt: a page carrying both reports Nuxt only
        (when (or (snap-flag globals "vue") (snap-flag globals "vueDevtoolsHook")
                  (snap-flag dom "hasVueApp"))
          (tech techs "Vue" "framework" 0.84d0
                (if (snap-flag globals "vueDevtoolsHook")
                    "__VUE_DEVTOOLS_GLOBAL_HOOK__"
                    "Vue mount markers"))))
    (when (or (snap-flag globals "angular") (snap-flag dom "hasNgVersion"))
      (tech techs "Angular" "framework" 0.85d0
            (if (snap-flag dom "hasNgVersion") "[ng-version]" "Angular global markers")))
    (when (or (snap-flag globals "svelteKit") (snap-flag dom "hasSvelteData")
              (has-url urls "/_app/immutable/"))
      (tech techs "SvelteKit" "framework" 0.9d0
            (if (snap-flag globals "svelteKit")
                "__SVELTEKIT_APP_VERSION__"
                "SvelteKit asset markers")))
    (when (or (snap-flag dom "hasAstroIsland") (has-url urls "/_astro/"))
      (tech techs "Astro" "framework" 0.9d0
            (if (snap-flag dom "hasAstroIsland") "<astro-island>" "/_astro/ assets")))
    (when (or (snap-flag globals "remix") (snap-flag dom "hasRemixData"))
      (tech techs "Remix" "framework" 0.88d0
            (if (snap-flag globals "remix") "__remixContext" "Remix DOM markers")))

    ;; --- bundlers --------------------------------------------------------
    (when (or (snap-flag globals "webpackChunk") (snap-flag globals "webpackJsonp")
              (any-regex urls *chunk-re*) (any-regex urls *webpack-re*))
      (tech techs "Webpack" "bundler" 0.88d0
            (if (snap-flag globals "webpackChunk") "webpackChunk* global" "Chunk naming")))
    (if (or (snap-flag globals "vitePreamble") (has-url urls "/@vite/client"))
        (tech techs "Vite" "bundler" 0.95d0
              (if (snap-flag globals "vitePreamble")
                  "__vite_plugin_react_preamble_installed__"
                  "/@vite/client"))
        (when (any-regex urls *hashed-assets-re*)
          (tech techs "Vite" "bundler" 0.72d0 "Hashed /assets/ bundles")))
    (when (any-regex urls *parcel-re*)
      (tech techs "Parcel" "bundler" 0.67d0 "Parcel URL marker"))

    ;; --- platforms -------------------------------------------------------
    (let* ((generator (snap-lower dom "metaGenerator"))
           (wp (and (plusp (length generator)) (search "wordpress" generator))))
      (when (or wp (has-url urls "/wp-content/") (has-url urls "/wp-includes/"))
        (tech techs "WordPress" "platform" 0.94d0
              (if wp "generator meta tag" "wp-content assets"))))
    (when (or (snap-flag globals "shopify") (snap-flag dom "hasShopify")
              (has-url urls "cdn.shopify.com") (has-url urls "/shopifycloud/"))
      (tech techs "Shopify" "platform" 0.95d0
            (if (snap-flag globals "shopify") "window.Shopify" "Shopify asset markers")))

    ;; --- protocols and data ----------------------------------------------
    (when (snap-over network "graphqlCount" 0)
      (tech techs "GraphQL" "protocol" 0.9d0 "GraphQL requests observed"))
    (when (or (snap-flag globals "apolloClient") (snap-flag globals "apolloState")
              (any-regex endpoints *apollo-re*))
      (tech techs "Apollo" "data" 0.82d0
            (if (snap-flag globals "apolloClient")
                "__APOLLO_CLIENT__"
                "Apollo/GraphQL markers")))
    (when (or (snap-flag globals "relay") (any-regex endpoints *relay-re*))
      (tech techs "Relay" "data" 0.76d0
            (if (snap-flag globals "relay") "__RELAY_DEVTOOLS_HOOK__" "Relay markers")))

    ;; --- runtime ---------------------------------------------------------
    (when (snap-over runtime "wasmCount" 0)
      (tech techs "WebAssembly" "runtime" 0.88d0 "WASM bytes captured"))
    (when (or (snap-flag globals "serviceWorkerController")
              (snap-over runtime "serviceWorkerCount" 0))
      (tech techs "Service Worker" "runtime" 0.8d0 "serviceWorker activity"))

    ;; --- traits ----------------------------------------------------------
    (when (or (snap-flag globals "nextData") (snap-flag dom "hasNuxtRoot")
              (snap-flag dom "hasVueApp") (snap-flag dom "hasSvelteData")
              (snap-flag dom "hasRemixData") (snap-flag dom "hasAstroIsland"))
      (trait-hit traits "spa-hydration" "Framework hydration markers"))
    (when (snap-over dom "mutationCount" 20)
      (trait-hit traits "dynamic-dom" "Sustained DOM mutation activity"))
    (when (snap-over network "graphqlCount" 0)
      (trait-hit traits "graphql-heavy" "GraphQL endpoints observed"))
    (when (or (snap-over network "websocketCount" 0) (snap-over network "sseCount" 0)
              (snap-over activity "openSockets" 0))
      (trait-hit traits "socket-heavy" "WebSocket or SSE activity"))
    (when (snap-over runtime "workerCount" 0)
      (trait-hit traits "worker-heavy" "Worker runtime observed"))
    (when (snap-over runtime "wasmCount" 0)
      (trait-hit traits "wasm-heavy" "WebAssembly runtime observed"))
    (when (> (+ (snap-num network "fetchCount") (snap-num network "xhrCount")) 10)
      (trait-hit traits "api-heavy" "High XHR/fetch volume"))
    (when (snap-over runtime "runtimeCount" 6)
      (trait-hit traits "runtime-generated-code" "In-memory code generation observed"))
    (when (and (<= (snap-num dom "scriptCount") 6)
               (<= (snap-num network "fetchCount") 2)
               (<= (snap-num network "xhrCount") 1))
      (trait-hit traits "static-ish" "Low script and API activity"))

    ;; --- fallback --------------------------------------------------------
    (when (null techs)
      (tech techs "Generic Web App" "profile" 0.45d0 "Fallback profile"))

    ;; --- sort: confidence DESC, then name ASC ---------------------------
    (setf techs (stable-sort techs
                             (lambda (a b)
                               (let ((ca (getf (cdr a) :confidence))
                                     (cb (getf (cdr b) :confidence)))
                                 (if (= ca cb)
                                     (string< (car a) (car b))
                                     (> ca cb))))))
    (let* ((tech-names (mapcar #'car techs))
           (trait-names (sort (mapcar #'car traits) #'string<))
           (evidence-techs (loop for (name . props) in techs
                                 collect (cons name (getf props :evidence))))
           (evidence-traits (loop for (name . props) in traits
                                  collect (cons name (getf props :evidence))))
           (globals-detected (let ((v (snap-field snapshot "globalsDetected")))
                               (if (vovas.engine.panel.model:js-truthy v) v #())))
           (conf-base (if techs (* (getf (cdr (first techs)) :confidence) 100d0) 45d0))
           (confidence (round (clamp (+ conf-base
                                        (* (min (length techs) 4) 4d0)
                                        (* (min (length trait-names) 5) 3d0))
                                     35d0 99d0)))
           (technologies (loop for (name . props) in techs
                               collect (list :name name
                                             :category (getf props :category)
                                             :confidence (getf props :confidence)
                                             :evidence (getf props :evidence))))
           ;; `strategy` and `summary` are computed BEFORE the profile plist so the
           ;; plist can be assembled in the Rust's insertion order. Building the
           ;; profile first and then setf-ing onto the end would put both keys LAST,
           ;; and `profileText` comparison pins key ORDER as well as values.
           (strategy (build-strategy tech-names trait-names))
           (summary (format nil "~a | ~{~a~^, ~}"
                            (getf strategy :profile)
                            (subseq tech-names 0 (min 3 (length tech-names))))))
      (list :version *version*
            :generated-at (vovas.engine.util:now-unix-millis)
            :technologies (if technologies technologies (empty-array))
            :traits (if trait-names trait-names (empty-array))
            :confidence (coerce confidence 'double-float)
            ;; The `evidence` MAPS are objects and its `globals`/`endpoints` are
            ;; arrays. `traits` appears on BOTH sides of this profile in different
            ;; shapes - a list of names at the top level, a name-to-evidence map
            ;; inside `evidence` - so the empty case has to be tagged at the point
            ;; where the intent is still known.
            :evidence (list :technologies (if evidence-techs evidence-techs (empty-object))
                            :traits (if evidence-traits evidence-traits (empty-object))
                            :globals globals-detected
                            :endpoints (if (> (length endpoints) 20)
                                           (subseq endpoints 0 20)
                                           (coerce endpoints 'vector)))
            :strategy strategy
            :summary summary))))
