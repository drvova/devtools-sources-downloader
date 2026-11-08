;;;; v8codecache.lisp — the V8 code-cache reader, ported from v8codecache.rs.
;;;;
;;;; WHAT A CODE CACHE IS. `vm.Script#createCachedData`, node's compile cache,
;;;; and a JSCeal-sealed .jsc after inflation all carry the same opening word:
;;;; 0xC0DE0000 | N, where N is the external-reference-table size of the V8
;;;; build that wrote the blob. Behind that header sits a serialized V11/V12
;;;; payload — bytecode with one-byte string frames embedded in it. This module
;;;; answers three questions and nothing else: is this blob that shape, what
;;;; does its header say, and which strings are framed inside the payload.
;;;;
;;;; WHY THIS IS ITS OWN MODULE AND NOT A `detect_layers` STAGE. The JSC-bytecode
;;;; reader accepts files that begin with a length-and-magic header; a code
;;;; cache begins with 0xC0DE. The two formats are disjoint, and the routing in
;;;; pipeline.rs depends on exactly one of these detectors claiming a blob;
;;;; conflating them sends a cached-data blob into the bytecode decoder, which
;;;; then reports garbage strings instead of refusing. Detection is therefore
;;;; strict on purpose: a whole 16-bit tag plus a bounded nonzero ext-ref count,
;;;; and a minimum length of one full V12 header.
;;;;
;;;; TWO HEADER LAYOUTS, ONE RULE. The layout changed at node22: V11 keeps
;;;; `payload_length` at +16, V12 inserts the read-only snapshot checksum there
;;;; and moves `payload_length` to +20. There is no version byte to read, so the
;;;; only reliable discriminator is arithmetic: the payload always ends exactly
;;;; at the blob end, so the layout whose declared length closes the gap wins.
;;;; V12 is tested FIRST because a V11 blob whose +20 word happened to equal
;;;; (len - 32) is far less likely than the reverse (junk at +16 would be
;;;; length-shaped only by coincidence) — and because the writer that produced
;;;; the new layout is the one that ships today.
;;;;
;;;; THE BROTLI SEAM. In the original JavaScript the inflator was injected
;;;; because the browser route is DecompressionStream('br') while node's undici
;;;; rejects 'br'. Rust has no platform variance, so `inflate_brotli_default`
;;;; uses the brotli crate and the injected form exists for parity and failure
;;;; injection — the tests exercise BOTH. This port keeps that seam exactly
;;;; (`inflate-brotli-with` takes an optional injected function) and supplies a
;;;; real default by calling into libbrotlidec through SBCL's alien interface.
;;;; There is no brotli implementation in this toolchain's Lisp, and writing one
;;;; from the RFC would be a second, unverified decoder in the one place a wrong
;;;; decoder is silent — inflating to plausible-looking garbage. A real CFFI-free
;;;; call into the shipped library is the honest option; when the library is
;;;; absent the default answers NIL and the sealed route degrades to a refusal,
;;;; never to invented bytes. `brotli-available-p` reports which world we are in.

(defpackage :vovas.engine.v8codecache
  (:use :cl)
  (:export
   ;; the reader
   #:detect-v8-code-cache
   #:parse-v8-code-cache
   #:extract-v8-strings
   #:v8-code-cache
   #:v8-code-cache-magic
   #:v8-code-cache-magic-hex
   #:v8-code-cache-runtime
   #:v8-code-cache-format
   #:v8-code-cache-version-hash
   #:v8-code-cache-source-hash
   #:v8-code-cache-flag-hash
   #:v8-code-cache-payload-offset
   #:v8-code-cache-payload-length
   #:v8-code-cache-strings
   ;; the sealed route
   #:parse-sealed-v8
   #:sealed-v8
   #:sealed-v8-inflated-bytes
   #:sealed-v8-cache
   #:inflate-brotli-with
   #:inflate-brotli-default
   #:brotli-available-p
   #:*brotli-directory-patterns*
   #:brotli-candidate-directories))

(in-package :vovas.engine.v8codecache)

;;; ---------------------------------------------------------------------------
;;; Constants (v8codecache.rs, top of file)
;;;
;;; `defparameter` rather than `defconstant`: these are numbers, but a reload
;;; that changes one would signal DEFCONSTANT-UNEQL and take the whole system
;;; down over a tuning value. The Rust uses `const`, which has no such trap.
;;; ---------------------------------------------------------------------------

(defparameter *v8-magic-family* #xC0DE0000
  "The high half every code-cache magic shares. Written as the full word rather
than the 0xC0DE literal the Rust shifts, so the comparison below mirrors the
Rust line for line.")

(defparameter *v8-min-ext-refs* 1
  "Zero external references is never a real build: an empty table would mean a
V8 with no builtins. Treating 0 as valid made the all-zero test blob detect.")

(defparameter *v8-max-ext-refs* #x4000
  "16384 references is already absurd for a real V8 (node24 is 1673). The bound
exists so a random 0xC0DE-prefixed word cannot claim the format.")

(defparameter *v11-header-size* 24)
(defparameter *v12-header-size* 32
  "Also the minimum length of any acceptable blob: detection needs the V12
header's full size even for a V11 blob, because the +20 word must be readable
before the layout can be chosen.")

(defparameter *v8-max-payload* (* 256 1024 1024))
(defparameter *v8-string-min* 2)
(defparameter *v8-string-max* (ash 1 24)
  "2 is the minimum because a one-character frame is indistinguishable from the
map byte run of a longer frame; 16MiB is far past any real string interned into
a code cache, and the bound stops a corrupt length from allocating the blob.")

(defparameter *brotli-window-max-bytes* (* 64 1024 1024)
  "The sealed route refuses anything larger before inflating, because a brotli
bomb is a small file that becomes gigabytes. The reader's own input limit is
8MiB (util:*limits-max-asset-bytes*), so this is the outer wall.")

(defparameter *v8-runtime-table*
  '((#xC0DE0563 . "node18")
    (#xC0DE05CC . "node20")
    (#xC0DE0628 . "node22")
    (#xC0DE0688 . "node24"))
  "The four magics a shipped node produces, from `v8_known_runtime`. The value is
the runtime NAME, and the field is named `runtime` in the wire JSON — the panel
prints it directly, so the spelling is contract, not cosmetics.")

;;; ---------------------------------------------------------------------------
;;; Little-endian reads
;;; ---------------------------------------------------------------------------

(declaim (inline u32-le))
(defun u32-le (bytes at)
  "The little-endian 32-bit word at AT in BYTES.

The Rust helper indexes the slice directly and would panic past the end. Every
call site here is guarded by a length test, so the bounds assertion is not
defensive padding: it turns a future mis-guarded caller into a named error
instead of a silently shifted read that looks like a corrupt blob."
  (let ((n (length bytes)))
    (unless (<= 0 at (- n 4))
      (error "u32-le: ~a + 4 is outside a ~a-byte buffer" at n))
    (logior (aref bytes at)
            (ash (aref bytes (+ at 1)) 8)
            (ash (aref bytes (+ at 2)) 16)
            (ash (aref bytes (+ at 3)) 24))))

;;; ---------------------------------------------------------------------------
;;; Detection
;;; ---------------------------------------------------------------------------

(defun detect-v8-code-cache (bytes)
  "True when BYTES opens like a V8 code cache.

Three conditions, all of them load-bearing:

  1. At least one V12 header. A 20-byte blob cannot hold the +20 word the
     parser reads, so accepting it would only move the failure.
  2. The HIGH HALF of the magic is the 0xC0DE family tag. Comparing the whole
     word against four known magics would reject every future node build; the
     Rust compares `magic >> 16`, and so does this.
  3. The low half (the external-reference count) is in [1, 0x4000]. This is what
     keeps the format from being 'any file whose first two bytes are C0 DE'."
  (let ((n (length bytes)))
    (when (< n *v12-header-size*)
      (return-from detect-v8-code-cache nil))
    (let* ((magic (u32-le bytes 0))
           (ext-refs (logand magic #xFFFF)))
      (and (= (ash magic -16) (ash *v8-magic-family* -16))
           (<= *v8-min-ext-refs* ext-refs *v8-max-ext-refs*)))))

(defun v8-runtime-name (magic)
  "The `runtime` field: a known runtime name, or a diagnostic string naming the
family and the reference count.

The unknown form is not a placeholder — the panel renders it verbatim, and it is
what tells a reader that the blob came from a node build this port has never
seen. `~(~x~)` is the Rust `{:x}`: lowercase, no leading zeros, no `0x`."
  (or (cdr (assoc magic *v8-runtime-table*))
      (format nil "unknown build (~(~x~) family, ~d external refs)"
              *v8-magic-family* (logand magic #xFFFF))))

;;; ---------------------------------------------------------------------------
;;; The parsed header
;;; ---------------------------------------------------------------------------

(defstruct (v8-code-cache (:constructor %make-v8-code-cache))
  "`V8CodeCache` from v8codecache.rs, field for field. The slot names are the
serde camelCase wire names lowercased, because the report JSON is assembled from
these readers by name."
  (magic 0)
  (magic-hex "")
  (runtime "")
  (format "")
  (version-hash 0)
  (source-hash 0)
  (flag-hash 0)
  (payload-offset 0)
  (payload-length 0)
  (strings '()))

(defun parse-v8-code-cache (bytes)
  "Parse a plain (un-inflated) code cache, or NIL when BYTES is not one.

Order matters and mirrors the Rust exactly: detect, read both candidate payload
lengths, pick the layout that closes the blob, then the (in practice
unreachable) size guards, then the string scan over exactly the payload.

The two size guards are dead code under the layout test — a length that closes
the blob is by definition <= the blob — and they are ported anyway, because a
future layout rule that does not compare equality would make them live and
dropping them would then be silent."
  (unless (detect-v8-code-cache bytes)
    (return-from parse-v8-code-cache nil))
  (let* ((magic (u32-le bytes 0))
         (n (length bytes))
         (v11-payload (u32-le bytes 16))
         (v12-payload (u32-le bytes 20)))
    (multiple-value-bind (fmt payload-length payload-offset)
        (cond
          ((= (+ v12-payload *v12-header-size*) n)
           (values "v12" v12-payload *v12-header-size*))
          ((= (+ v11-payload *v11-header-size*) n)
           (values "v11" v11-payload *v11-header-size*))
          (t (values nil nil nil)))
      (when (null fmt)
        ;; Neither layout's declared length reaches the end: a truncated or
        ;; hand-edited blob. Detection said yes, parsing says no, and that is
        ;; the intended split — the pipeline reports "unrecognised" rather than
        ;; a half-filled header.
        (return-from parse-v8-code-cache nil))
      (when (or (> payload-length *v8-max-payload*)
                (> (+ payload-offset payload-length) n))
        (return-from parse-v8-code-cache nil))
      (%make-v8-code-cache
       :magic magic
       :magic-hex (format nil "0x~(~x~)" magic)
       :runtime (v8-runtime-name magic)
       :format fmt
       :version-hash (u32-le bytes 4)
       :source-hash (u32-le bytes 8)
       :flag-hash (u32-le bytes 12)
       :payload-offset payload-offset
       :payload-length payload-length
       :strings (extract-v8-strings bytes payload-offset
                                    (+ payload-offset payload-length))))))

;;; ---------------------------------------------------------------------------
;;; Framed strings
;;;
;;; A frame is: 0x52, a map byte (0x61/0x62/0x63 — the three pointer-map
;;; classes a string can sit under), four bytes of something, the StringImpl
;;; hash, the length as a little-endian u32 at +6, then the bytes at +10.
;;; Every field test exists because the payload is BYTECODE: 0x52 appears in it
;;; constantly as an opcode operand, and the only thing separating a frame from
;;; noise is that five consecutive fields happen to agree.
;;; ---------------------------------------------------------------------------

(declaim (inline v8-map-byte-p))
(defun v8-map-byte-p (byte)
  (or (= byte #x61) (= byte #x62) (= byte #x63)))

(defun v8-printable-run-p (bytes at length)
  "True when LENGTH bytes at AT are all printable ASCII.

The Rust range is `(0x20..0x7f)`, i.e. 0x20 INCLUSIVE and 0x7f EXCLUSIVE, so DEL
is rejected. Writing the Lisp bound as `(<= #x20 b #x7f)` admits DEL and also
admits every byte above it, turning the test into 'not a C0 control' — a
one-character mistake that lets binary noise through as a string."
  (loop for k from at below (+ at length)
        always (and (<= #x20 (aref bytes k)) (< (aref bytes k) #x7f))))

(defun v8-octets-to-ascii (bytes at length)
  "The ASCII text of LENGTH bytes at AT. Only called after `v8-printable-run-p`,
so every byte is a code point below 0x80 and one octet is one character — no
UTF-8 decode, which is what the Rust does with `b as char`."
  (let ((out (make-string length)))
    (loop for k from 0 below length
          do (setf (char out k) (code-char (aref bytes (+ at k)))))
    out))

(defun extract-v8-strings (bytes from &optional to)
  "Every distinct framed string in BYTES between FROM and TO (exclusive, TO
defaulting to the end).

Answers a LIST of strings, first-seen order. The Rust collects into a Vec with a
HashSet for de-duplication; a list plus an `equal` hash table is the same thing
without the index bookkeeping, and these lists are a handful of entries.

THE ADVANCE IS THE SUBTLE PART. On a match the cursor moves to the frame's last
character, `char-at + length - 1`, and the loop's own step carries it past. A
port that advances to `char-at + length` skips a byte after every frame; a port
that advances by one re-reads the frame's characters and finds nested garbage.
Neither shows up on a two-string fixture, so the gate pins both with synthetic
frames whose neighbours are deliberately one byte apart."
  (let* ((n (length bytes))
         (end (if to (min to n) n))
         (seen (make-hash-table :test #'equal))
         (out '())
         (i from))
    (loop while (<= (+ i 10) end)
          do (cond
               ;; not the frame tag
               ((/= (aref bytes i) #x52)
                (incf i))
               ;; tag but an unknown pointer-map class
               ((not (v8-map-byte-p (aref bytes (1+ i))))
                (incf i))
               (t
                (let ((length (u32-le bytes (+ i 6))))
                  (cond
                    ;; 2 <= length < 2^24
                    ((not (<= *v8-string-min* length (1- *v8-string-max*)))
                     (incf i))
                    ;; the characters must fit inside the window, not just
                    ;; inside the buffer: a frame running past TO belongs to a
                    ;; region the caller excluded
                    ((> (+ i 10 length) end)
                     (incf i))
                    ((not (v8-printable-run-p bytes (+ i 10) length))
                     (incf i))
                    (t
                     (let ((text (v8-octets-to-ascii bytes (+ i 10) length)))
                       (unless (gethash text seen)
                         (setf (gethash text seen) t)
                         (push text out))
                       ;; last character of the frame; the loop's own step
                       ;; lands the cursor one past it
                       (setf i (+ i 10 length -1)))))))))
    (nreverse out)))

;;; ---------------------------------------------------------------------------
;;; The brotli seam
;;;
;;; There is no brotli decoder in this toolchain's Lisp, and a second
;;; hand-written decoder is the worst possible place for an unverified
;;; implementation: a wrong inflate yields plausible bytes, not an error. So the
;;; default calls the real library, loaded lazily, and answers NIL when no
;;; library can be found. `parse-sealed-v8` then refuses, which is a visible
;;; behaviour, not a silent zero.
;;;
;;; The candidate directories are searched because the DLL is not a system
;;; component on Windows — it ships inside Git for Windows, msys2, or nowhere.
;;; The bare-name entry resolves through the loader's own PATH search, so a
;;; deployment that puts the DLL next to sbcl.exe works without editing this.
;;; ---------------------------------------------------------------------------

(defparameter *brotli-directory-patterns*
  (list "C:/Program Files/Git/*/bin/"
        "C:/Program Files/Git/mingw64/bin/"
        "C:/Program Files/Git/usr/bin/"
        "C:/msys64/usr/bin/"
        "C:/msys64/mingw64/bin/"
        "C:/msys64/clang64/bin/"
        "C:/Users/*/AppData/Local/ms-playwright/webkit-*/")
  "Directory PATTERNS to search for libbrotlidec, expanded with CL's wildcard
`directory` (verified: `C:/Program Files/Git/*/bin/` answers ucrt64/bin and
usr/bin; the ms-playwright pattern answers each installed webkit revision).

Patterns rather than a fixed list because every one of these paths moves:
Git's toolchain directory is `ucrt64` on current installs and `mingw64` on
older ones, and playwright's WebKit directory carries a build NUMBER
(`webkit-2336`, `webkit-2370`, …) that changes with every browser update.
Hardcoding either produces a probe that silently stops finding a library that
is still on the machine — which is indistinguishable, from the sealed route's
side, from 'this machine has no brotli'.

A bare filename is tried BEFORE any of these, through the OS loader's own PATH
search, so a deployment that ships the DLL beside sbcl.exe needs no entry here.")

(defparameter *brotli-decoder-library-names*
  '("libbrotlidec.dll" "brotlidec.dll")
  "Both spellings: the mingw/ucrt64 prefix and the bare form. Playwright's WebKit
bundle uses the BARE spelling (`brotlidec.dll`), which is why it is in the list
and not merely a defensive alternative.")

(defparameter *brotli-common-library-names*
  '("libbrotlicommon.dll" "brotlicommon.dll")
  "libbrotlidec links against libbrotlicommon, and Windows does not search the
decoder's own directory for its dependency, so the common library is loaded
FIRST. Loading only the decoder answers 'the specified module could not be
found' — which reads like a missing decoder.")

(defparameter *brotli-chunk-bytes* 4096
  "The output chunk size, mirroring `brotli::Decompressor::new(bytes, 4096)`.
The decoder's output length is not known in advance, so the loop grows an
adjustable vector one chunk at a time.")

(defvar *brotli-probe* :unprobed
  "T once a decoder library has been loaded, :UNAVAILABLE once every candidate
failed. Memoised because a failed dlopen is slow and the answer cannot change
within a run.")

;; The three entry points used. Declared as alien routines so a missing symbol
;; signals at CALL time, inside the handler that turns it into NIL, rather than
;; at load time, which would make this module unloadable on a machine without
;; the library.
(sb-alien:define-alien-routine ("BrotliDecoderCreateInstance" %brotli-create)
    sb-sys:system-area-pointer
  (alloc-func sb-sys:system-area-pointer)
  (free-func sb-sys:system-area-pointer)
  (opaque sb-sys:system-area-pointer))

(sb-alien:define-alien-routine ("BrotliDecoderDestroyInstance" %brotli-destroy)
    sb-alien:void
  (state sb-sys:system-area-pointer))

;; BrotliDecoderResult: 0=error 1=success 2=needs-more-input 3=needs-more-output.
;; `int` rather than an unsigned type because the C enum is signed and a decoder
;; that ever returned -1 would otherwise read as a huge positive result code.
(sb-alien:define-alien-routine ("BrotliDecoderDecompressStream" %brotli-decompress-stream)
    sb-alien:int
  (state sb-sys:system-area-pointer)
  (available-in sb-sys:system-area-pointer)
  (next-in sb-sys:system-area-pointer)
  (available-out sb-sys:system-area-pointer)
  (next-out sb-sys:system-area-pointer)
  (total-out sb-sys:system-area-pointer))

(defun try-load-shared-object (name)
  "Load NAME, answering T on success and NIL on any failure. The name is echoed
nowhere on failure on purpose: the probe walks a dozen candidates and the
interesting answer is 'none of them', which `brotli-available-p` reports."
  (handler-case (progn (sb-alien:load-shared-object name) t)
    (error () nil)))

(defun brotli-exports-decoder-p ()
  "T when the loaded libraries export `BrotliDecoderCreateInstance`.

A successfully loaded library is not enough: a DLL that happens to carry the
name but does not export the decoder API (an incompatible soname, a stub, a
32-bit build) must be rejected HERE rather than failing once per call.
`extern-alien` signals when the symbol is missing, which is the check."
  (handler-case
      (progn (sb-alien:extern-alien "BrotliDecoderCreateInstance"
                                    (function sb-sys:system-area-pointer))
             t)
    (error () nil)))

(defun try-brotli-directory (prefix)
  "Try to load the brotli pair from PREFIX (a string, possibly empty). Answers T
when the decoder is loaded AND exports its entry point.

The common library is loaded first and its failure is deliberately ignored: some
builds statically link it into the decoder, and treating a missing
libbrotlicommon as fatal would reject a decoder that works. The DECODER load is
the one that decides."
  (dolist (common *brotli-common-library-names*)
    (try-load-shared-object (concatenate 'string prefix common)))
  (some (lambda (decoder)
          (and (try-load-shared-object (concatenate 'string prefix decoder))
               (brotli-exports-decoder-p)))
        *brotli-decoder-library-names*))

(defun brotli-candidate-directories ()
  "Every directory to search, as strings with a trailing separator: the bare
prefix first (the OS loader's PATH search), then each expanded wildcard pattern.

Expansion goes through CL's `directory`, which accepts wildcards on Windows —
verified here: `C:/Program Files/Git/*/bin/` answers both `ucrt64/bin/` and
`usr/bin/`, and the ms-playwright pattern answers every installed webkit
revision. A pattern that matches nothing contributes nothing; it is not an
error, because a machine with neither Git-for-Windows nor Playwright is the
ordinary case on which this probe must simply answer :UNAVAILABLE.

Duplicates are removed: `Git/*/bin/` and the explicit `Git/usr/bin/` entry
both resolve to the same directory on this machine, and loading the same DLL
twice under two path spellings would be a pointless second dlopen."
  (remove-duplicates
   (append
    (list "")
    (loop for pattern in *brotli-directory-patterns*
          append (handler-case
                     (mapcar (lambda (dir)
                               (let ((name (namestring dir)))
                                 (if (and (plusp (length name))
                                          (member (char name (1- (length name)))
                                                  '(#\/ #\\)))
                                     name
                                     (concatenate 'string name "/"))))
                             (directory (pathname pattern)))
                   (error () nil))))
   :test #'string-equal))

(defun probe-brotli ()
  "Load a brotli decoder if one can be found. Answers T or :UNAVAILABLE.

Searches the bare prefix (PATH) first, then every directory the wildcard
patterns expand to, and stops at the first that both loads and exports the
decoder entry point."
  (if (some #'try-brotli-directory (brotli-candidate-directories))
      t
      :unavailable))

(defun brotli-known-p ()
  "T when a decoder library has been loaded and exports the streaming API."
  (when (eq *brotli-probe* :unprobed)
    (setf *brotli-probe* (probe-brotli)))
  (eq *brotli-probe* t))

(defun brotli-available-p ()
  "T when the default brotli path can inflate. NIL means the sealed route is
inoperative in this process and `parse-sealed-v8` will refuse every blob unless
the caller injects its own inflator — which is exactly the Rust seam, used the
way the Rust tests use it."
  (brotli-known-p))

(defun ensure-simple-octets (bytes)
  "BYTES as a `(simple-array (unsigned-byte 8) (*))`, which is what
`sb-sys:vector-sap` can hand to C. A fill-pointer or adjustable vector is
copied; an already-simple one is passed through, because copying an 8MiB asset
to satisfy a type declaration would be a real cost for no semantic gain."
  (if (typep bytes '(simple-array (unsigned-byte 8) (*)))
      bytes
      (coerce bytes '(simple-array (unsigned-byte 8) (*)))))

(defun %inflate-brotli-streaming (bytes)
  "Inflate BYTES with the loaded libbrotlidec, streaming, or answer NIL.

Streaming rather than `BrotliDecoderDecompress`: the one-shot entry point needs
an output buffer sized in advance, and its behaviour when that buffer is too
small differs across brotli versions (some report ERROR, later ones report
NEEDS_MORE_OUTPUT and the required size). Streaming is correct at every version
and is also what the Rust's `read_to_end` does.

The five size_t/pointer cells live in one 40-byte system-memory block indexed
`0,8,16,24,32`; `deallocate-system-memory` takes an explicit length, so a block
per cell would mean five matching frees to keep straight.

Answers NIL — never a partial buffer — on a decoder error, on a truncated stream
(the decoder wants input that will never come), or when `BrotliDecoderCreateInstance`
fails."
  (let* ((input (ensure-simple-octets bytes))
         (n (length input))
         (chunk (make-array *brotli-chunk-bytes* :element-type '(unsigned-byte 8)))
         (out (make-array 0 :element-type '(unsigned-byte 8)
                            :adjustable t :fill-pointer 0))
         (cells (sb-sys:allocate-system-memory 40))
         (state nil)
         (complete nil)
         (result nil))
    (unwind-protect
         (progn
           (setf state (%brotli-create (sb-sys:int-sap 0)
                                       (sb-sys:int-sap 0)
                                       (sb-sys:int-sap 0)))
           (unless (zerop (sb-sys:sap-int state))
             (sb-sys:with-pinned-objects (input chunk)
               (let ((next-in (sb-sys:vector-sap input))
                     (consumed 0))
                 (loop
                   (setf (sb-sys:sap-ref-64 cells 0) (- n consumed)
                         (sb-sys:sap-ref-sap cells 8) next-in
                         (sb-sys:sap-ref-64 cells 16) (length chunk)
                         (sb-sys:sap-ref-sap cells 24) (sb-sys:vector-sap chunk))
                   (let* ((rc (%brotli-decompress-stream
                               state
                               (sb-sys:sap+ cells 0)
                               (sb-sys:sap+ cells 8)
                               (sb-sys:sap+ cells 16)
                               (sb-sys:sap+ cells 24)
                               (sb-sys:sap+ cells 32)))
                          (produced (- (length chunk)
                                       (sb-sys:sap-ref-64 cells 16)))
                          (used (- (- n consumed)
                                   (sb-sys:sap-ref-64 cells 0))))
                     (incf consumed used)
                     (loop for k from 0 below produced
                           do (vector-push-extend (aref chunk k) out))
                     (case rc
                       ;; SUCCESS is the ONLY success. The other two exits —
                       ;; ERROR, and NEEDS_MORE_INPUT with nothing consumed —
                       ;; mean the stream ended without a complete frame, and
                       ;; `read_to_end` in the Rust reports that as an io error.
                       ;;
                       ;; Getting this wrong is not hypothetical: a decoder fed
                       ;; the PLAIN fixture (not brotli at all) happily emits 421
                       ;; bytes before running out of input, and a loop that
                       ;; treated "it stopped" as "it finished" would answer
                       ;; plausible garbage for a blob the Rust refuses. The gate
                       ;; pins `brotli/default-on-plain-bytes` precisely here.
                       (1 (setf complete t) (return))
                       (2 (when (zerop used) (return)))
                       (3 nil)
                       (t (return))))))))
           (when complete
             (setf result (coerce out '(simple-array (unsigned-byte 8) (*))))))
      (when state (%brotli-destroy state))
      (sb-sys:deallocate-system-memory cells 40))
    result))

(defun inflate-brotli-default (bytes)
  "`inflate_brotli_default`: brotli-inflate BYTES, or NIL.

Empty output is NIL here, and ONLY here — that is the Rust's explicit
`if out.is_empty() { None }`, and it is why an injected inflator answering zero
bytes yields `Some([])` while the default answering zero bytes yields `None`.
The gate pins both sides of that asymmetry because a port that unified them
would pass every fixture case and still diverge on the failure route."
  (unless (brotli-known-p)
    (return-from inflate-brotli-default nil))
  (handler-case
      (let ((out (%inflate-brotli-streaming bytes)))
        (if (or (null out) (zerop (length out))) nil out))
    (error () nil)))

(defun inflate-brotli-with (bytes &optional injected)
  "`inflate_brotli_with`: the injected inflator when given, else the default.

INJECTED is the `Option<&InflateImpl>` seam, as a function designator. The Rust
does `impl_fn(bytes).ok()`, so a signalling inflator degrades to NIL exactly like
an `Err`: the sealed route then reports 'not that shape' rather than propagating
a decompressor's complaint into the pipeline's error surface. An injected
function that RETURNS NIL is treated the same way, which is the natural Lisp
spelling of 'no bytes'."
  (if injected
      (handler-case (funcall injected bytes)
        (error () nil))
      (inflate-brotli-default bytes)))

;;; ---------------------------------------------------------------------------
;;; The sealed route: brotli around a code cache
;;; ---------------------------------------------------------------------------

(defstruct (sealed-v8 (:constructor %make-sealed-v8))
  "`SealedV8`: the inflated size (for the report's note) and the parsed cache."
  (inflated-bytes 0)
  (cache nil))

(defun parse-sealed-v8 (bytes &optional injected)
  "`parse_sealed_v8`: peel brotli off BYTES, then parse the code cache inside.

Answers a `sealed-v8` or NIL. The guards are ordered as in the Rust and each one
means something different:

  - an EMPTY blob is not brotli-wrapped anything;
  - a blob that already detects as a plain cache is not sealed, so returning NIL
    here is what lets the caller route it to the plain parser (and, for a .jsc,
    lets the JSC-bytecode detector have its turn);
  - a blob past the window ceiling is refused before any decompression, because
    that is the only defence against a bomb;
  - an inflator that answers NIL, or inflates to something that is still not a
    code cache, is a refusal — not a parse of garbage."
  (when (or (zerop (length bytes)) (detect-v8-code-cache bytes))
    (return-from parse-sealed-v8 nil))
  (when (> (length bytes) *brotli-window-max-bytes*)
    (return-from parse-sealed-v8 nil))
  (let ((inflated (inflate-brotli-with bytes injected)))
    (when (null inflated)
      (return-from parse-sealed-v8 nil))
    (unless (detect-v8-code-cache inflated)
      (return-from parse-sealed-v8 nil))
    (let ((parsed (parse-v8-code-cache inflated)))
      (when (null parsed)
        (return-from parse-sealed-v8 nil))
      (%make-sealed-v8 :inflated-bytes (length inflated) :cache parsed))))
