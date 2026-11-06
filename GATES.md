# Gates: bridge export surface

OWNS: unpack-rs/tests/bridge_surface.rs, GATES.md

Scope: settle whether `unpack-bridge.js` exports anything no consumer reads, and whether the panel's imports are a subset of that surface — the premise behind the audit's "split the bridge into a product API and a test adapter" finding.

- [x] G1: no `unpack-bridge.js` export is unreferenced by any consumer
  CHECK: cargo test --test bridge_surface
  EXPECT: test result: ok
  CWD: unpack-rs
  EVIDENCE: automatic-evidence=v1; definition-sha256=5702777a41b121d60557233d278fd0aa7e30289df076dba3e5449264f2e1422f; exit=0; EXPECT=matched; output-sha256=176b805b79332e25345b8d7978ee1d441a4e86e73ac59e1db74877bd1623676b; output-bytes=468; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Users\bigmo\Downloads\vovas-devtools-soruce-downloader\unpack-rs; path=4f9c735ab59c/60 entries

- [x] G2: the repository gate still passes with the new test in it
  CHECK: "C:/Program Files/Steel Bank Common Lisp/sbcl.exe" --noinform --script tools/cl/run.lisp check
  EXPECT: check: PASS
  EVIDENCE: automatic-evidence=v1; definition-sha256=8051ddabcc6527ba43c80cb007cd2e940bf53219315c23462cc52001245372ac; exit=0; EXPECT=matched; output-sha256=5602d699b6fefb4f1f7750f837c8462b803e7a67bb573f0146c10feb5289cfcb; output-bytes=2102; shell=C:\WINDOWS\system32\cmd.exe; cwd=C:\Users\bigmo\Downloads\vovas-devtools-soruce-downloader; path=4f9c735ab59c/60 entries

<!--
G1 is the measurement that decides the finding. It asserts three things in one
binary: every export is referenced somewhere, the panel's imports are a strict
subset, and the panel plus the node baseline together cover the whole surface.
It is runnable and success-only: `test result: ok` cannot appear on a failing
run, and the test itself refuses to pass if its own export scan stops matching
the file (it requires more than 40 names).

G2 is the control: the new test must not disturb the existing gate.

Both commands were authored in this turn and run previously in this session.
-->
