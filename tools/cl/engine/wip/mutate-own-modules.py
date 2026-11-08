#!/usr/bin/env python3
"""Do MY gates actually catch wrong implementations?

Eight modules in this port had the same person write the code and the gate:
util, number, text, scanner, decoders, digest, bundler, transforms. Every agent's
slice was mutation-tested by that agent; mine never were. This applies real
mutations to my own source and requires the suite to FAIL each time.

SAFETY: each mutation is (backup -> mutate -> run -> restore), and the restore is
verified by SHA-256. If a restore ever mismatches, the script stops dead rather
than continuing on a corrupted tree.

Deliberately NOT an in-repo test artefact: it edits source files, so it lives here
as a tool and runs only when asked.
"""

import hashlib
import pathlib
import shutil
import subprocess
import sys

def find_repo_root():
    """Walk up until the checkout root, by MARKER rather than by counting.

    `parents[3]` from this file is tools/, not the repo - a miscount that made the
    baseline report 'SUITE ALREADY FAILING' because it ran a nonexistent path. This
    is the second off-by-one of exactly this shape in the port (the other was
    fixture-path), so the fix is a marker search, not a corrected index.
    """
    for parent in pathlib.Path(__file__).resolve().parents:
        if (parent / "unpack-rs").is_dir() and (parent / "tools").is_dir():
            return parent
    raise SystemExit("no checkout root above this file")


ROOT = find_repo_root()
ENGINE = ROOT / "tools" / "cl" / "engine"
GATE = "tools/cl/run-engine.lisp"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


# (module, description, old_text, new_text)
# Each mutation is a plausible WRONG implementation - the kind a hurried port
# would produce - not a syntax break.
MUTATIONS = [
    ("digest", "hex uses uppercase (SBCL's ~x behaviour)",
     '"0123456789abcdef"', '"0123456789ABCDEF"'),

    ("digest", "padding dropped: one digit per byte",
     "(write-char (char digits (ash b -4)) s)\n             (write-char (char digits (logand b #x0F)) s)",
     "(write-char (char digits (logand b #x0F)) s)"),

    ("number", "toString exponent off by one (n instead of n-1)",
     "(let* ((exp (1- n))", "(let* ((exp n)"),

    ("number", "decimal branch includes n = -6 (the original bug)",
     "((<= -5 n 0)", "((<= -6 n 0)"),

    ("number", "to-fixed rounds half to even via round instead of away",
     "(round-up (char>= next #\\5))", "(round-up (char> next #\\5))"),

    ("text", "hash-string multiplies by 32 instead of 31",
     "(+ (* 31 hash) unit)", "(+ (* 32 hash) unit)"),

    ("text", "hash-string drops the signed reinterpretation",
     "(if (>= hash #x80000000) (- hash #x100000000) hash)", "hash"),

    ("text", "append-path-suffix uses the LAST slash instead of the last slash",
     "(> dot slash)", "(>= dot slash)"),

    ("scanner", "escape skip advances one character instead of two",
     "((char= ch #\\\\) (incf j 2))\n                 ((char= ch quote) (return-from skip-quoted (1+ j)))",
     "((char= ch #\\\\) (incf j))\n                 ((char= ch quote) (return-from skip-quoted (1+ j)))"),

    ("scanner", "regex-start ignores a preceding closing paren",
     "(char= c #\\))", "nil"),

    ("decoders", "trailing backslash emits nothing instead of \"undefined\"",
     '(write-string "undefined" out)', '(write-string "" out)'),

    ("decoders", "octal escape caps at two digits instead of three",
     "(and (< digits 3)", "(and (< digits 2)"),

    ("bundler", "arrow-expression bodies are extracted instead of skipped",
     "(unless expression-body", "(when t"),

    ("util", "utf16-length counts every char as one unit",
     "sum (if (> (char-code c) #xFFFF) 2 1)", "sum 1"),

    ("transforms", "URI decoder accepts a truncated escape",
     "(when (> (+ i 2) (1- n))\n                       (return-from decode-uri-component nil))",
     "(when (> (+ i 2) n)\n                       (return-from decode-uri-component nil))"),
]


def run_suite():
    r = subprocess.run(["sbcl", "--script", GATE], cwd=ROOT,
                       capture_output=True, text=True, timeout=400)
    passes = r.stdout.count("=> PASS")
    return r.returncode, passes, r.stdout


def main():
    print("baseline: ", end="", flush=True)
    code, passes, _ = run_suite()
    if code != 0:
        print(f"SUITE ALREADY FAILING (exit {code}) - fix it before mutating")
        return 1
    print(f"exit 0, {passes} gates PASS\n")

    caught = 0
    survived = []

    for i, (module, desc, old, new) in enumerate(MUTATIONS, 1):
        path = ENGINE / f"{module}.lisp"
        before = sha(path)
        original = path.read_text(encoding="utf-8", newline="")

        if old not in original:
            print(f"{i:2d}. SKIP  {module}: anchor not found")
            survived.append((module, desc, "ANCHOR MISS"))
            continue

        backup = path.with_suffix(".lisp.mutbak")
        shutil.copy2(path, backup)
        try:
            path.write_text(original.replace(old, new, 1),
                            encoding="utf-8", newline="")
            code, passes, out = run_suite()
            if code != 0:
                caught += 1
                failed = [l.strip() for l in out.splitlines() if "=> FAIL" in l]
                print(f"{i:2d}. CAUGHT {module}: {desc}")
                print(f"           (exit {code}, {len(failed)} gate verdict(s) FAIL)")
            else:
                survived.append((module, desc, f"exit 0, {passes} PASS"))
                print(f"{i:2d}. SURVIVED {module}: {desc}  <-- GATE IS BLIND HERE")
        finally:
            shutil.copy2(backup, path)
            backup.unlink()
            after = sha(path)
            if after != before:
                print(f"\nFATAL: restore mismatch on {module}.lisp")
                print(f"  before {before}")
                print(f"  after  {after}")
                return 1

    print(f"\n{caught}/{len(MUTATIONS)} mutations caught")
    if survived:
        print(f"\n{len(survived)} SURVIVED - each is a gate that cannot see its own bug:")
        for module, desc, why in survived:
            print(f"  {module}: {desc}  ({why})")
    else:
        print("every mutation was caught")

    print("\nverifying the tree is restored: ", end="", flush=True)
    code, passes, _ = run_suite()
    print(f"exit {code}, {passes} gates PASS")
    return 0 if code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
