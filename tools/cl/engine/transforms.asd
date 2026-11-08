;;;; transforms.asd — the peel chain slice, loadable on its own.
;;;;
;;;; `:depends-on ("vovas-engine")` rather than a chain of sibling systems.
;;;; transforms.lisp reaches detectors, scanner, decoders, digest and packers
;;;; through run-time symbol resolution (`call-foreign`), NOT at read time, so
;;;; this slice loads and its gate runs even if one of those is absent - and it
;;;; picks the real implementation up automatically when present. Depending on
;;;; them here would make the file unbuildable on its own, which is exactly what
;;;; the load-order rule in wip/CONTRACT.md is protecting.
;;;;
;;;; The gate file is a component of the same system, after the module, so
;;;; loading `vovas-engine.transforms` gives you both the thing and the check.
;;;;
;;;; ASDF warns that `engine/transforms.asd` "should" define `transforms` rather
;;;; than `vovas-engine.transforms`. Every sibling .asd has the same warning and
;;;; the port's naming contract fixes these system names; the warning is accepted
;;;; rather than papered over.

(asdf:defsystem "vovas-engine.transforms"
  :description "The peel chain (transforms.rs) for the DevTools sources-downloader engine"
  :author "sashathelambo"
  :license "MIT"
  :depends-on ("vovas-engine")
  :serial t
  :components ((:file "gate-transforms")))
