;; The gate, as data.
;;
;; `vovas check` reads this file; --fast keeps only the steps marked (fast t).
;; A step names its runner — :npm or :cargo — and the argv it receives. Every
;; symbol here is a keyword; only t and nil are bare.
;;
;; Order matters: the first failing step stops the run.

(:gate
 (:step "lint+format (rs check)"
       :npm ("run" "check")
       :fast t)
 (:step "rust tests (cargo test)"
       :cargo ("test")
       :fast t)
 (:step "clippy"
       :cargo ("clippy" "--all-targets" "--" "-D" "warnings")
       :fast t)
 (:step "js tests (npm test)"
       :npm ("test"))
 (:step "build (npm run build)"
       :npm ("run" "build"))
 (:step "e2e (npm run test:e2e)"
       :npm ("run" "test:e2e"))
 (:step "extension e2e"
       :npm ("run" "test:e2e:ext")))
