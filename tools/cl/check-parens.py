# check-parens.py — report where a Lisp file's parens stop balancing.
#
# Hand-counting parens across a 300-line file has cost several rounds this
# session, and every miss produced a misleading message ("end of file" or
# "undefined variable") rather than a location. This walks the file with the
# reader's own rules - comments, strings, character literals - and prints the
# depth at the START of each top-level form, so the first form whose depth does
# not return to zero is named by line.
#
#   python tools/cl/check-parens.py tools/cl/engine/bundler.lisp

import sys


def scan(path):
    src = open(path, encoding='utf-8').read()
    i, n, depth, line = 0, len(src), 0, 1
    form_start = None
    problems = []
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            i += 1
            continue
        if c == ';':
            while i < n and src[i] != '\n':
                i += 1
            continue
        if c == '"':
            start_line = line
            i += 1
            while i < n:
                if src[i] == '\\':
                    i += 2
                    continue
                if src[i] == '"':
                    i += 1
                    break
                if src[i] == '\n':
                    line += 1
                i += 1
            else:
                problems.append((start_line, 'unterminated string'))
            continue
        if c == '#' and i + 1 < n and src[i + 1] == '\\':
            # Character literal. The name after #\ is either a single character
            # of ANY kind (so #\( #\/ #\" are all one char, and #\" must not
            # start a string) or a letter/digit run naming a character
            # (#\Space, #\Newline, #\u00e9). Deciding between the two is what a
            # naive alnum scan gets wrong.
            i += 2
            if i < n:
                first = src[i]
                if first.isalnum():
                    while i < n and (src[i].isalnum() or src[i] in '-_+'):
                        i += 1
                else:
                    i += 1          # one literal character, whatever it is
            continue
        if c == '#' and i + 1 < n and src[i + 1] == '|':
            # block comment #| ... |#
            i += 2
            nesting = 1
            while i < n and nesting:
                if src[i] == '\n':
                    line += 1
                if src.startswith('#|', i):
                    nesting += 1
                    i += 2
                elif src.startswith('|#', i):
                    nesting -= 1
                    i += 2
                else:
                    i += 1
            continue
        if c == '(':
            if depth == 0:
                form_start = line
            depth += 1
            i += 1
            continue
        if c == ')':
            depth -= 1
            if depth == 0:
                form_start = None
            elif depth < 0:
                problems.append((line, 'extra close paren (depth %d)' % depth))
                depth = 0
            i += 1
            continue
        i += 1
    if depth > 0:
        problems.append((form_start or 0, 'unclosed form, %d paren(s) still open' % depth))
    return problems


def main():
    if len(sys.argv) < 2:
        print('usage: check-parens.py FILE...')
        return 2
    bad = 0
    for path in sys.argv[1:]:
        problems = scan(path)
        if problems:
            bad = 1
            print('%s: UNBALANCED' % path)
            for line, what in problems:
                print('  line %s: %s' % (line, what))
        else:
            print('%s: balanced' % path)
    return bad


if __name__ == '__main__':
    sys.exit(main())
