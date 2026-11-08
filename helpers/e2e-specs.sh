#!/bin/sh
# Prints the Playwright specs a change runs, as upstream's tests/e2e/changes.go picks them:
#
#   helpers/e2e-specs.sh [changed file...]
#
# - A changed file matching one of changes.go's global patterns runs every spec.
# - Otherwise a spec runs when its own file changed (changes.go: the spec's path ends with
#   the changed file), when a glob of its `// @watch start` ... `// @watch end` block
#   matches a changed file, or when it has no watch block.
# - With no file, prints every spec (changes.go without CHANGED_FILES).
#
# The globs are gobwas globs with `.` and `/` as separators: `*` and `?` match within a
# name part (`*` never crosses a `.` or a `/`), `**` matches anything, `{a,b}` either.
# The watch block starts at the first `// @watch` line and ends at the next: each line in
# between, less a leading `// `, is a glob (the start line itself too, matching nothing).
#
# enact runs it to select targets, on the host and in CI's detect job, where there is no Go
# or Node: POSIX sh and an awk that runs as BSD awk too.
set -eu

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

specs=$(ls tests/e2e/*.test.e2e.ts)
if [ $# -eq 0 ]; then
    printf '%s\n' "${specs}"
    exit 0
fi

# The changed files on stdin (one per line), then the specs, each read for its watch block.
# shellcheck disable=SC2086
printf '%s\n' "$@" | awk '
    # A gobwas glob (separators `.` and `/`) as an anchored extended regular expression.
    function ere(glob,    out, i, n, c, depth, rest, close_at, class) {
        out = ""; depth = 0; n = length(glob)
        for (i = 1; i <= n; i++) {
            c = substr(glob, i, 1)
            if (c == "*") {
                if (substr(glob, i + 1, 1) == "*") {
                    out = out ".*"
                    while (substr(glob, i + 1, 1) == "*") i++
                } else {
                    out = out "[^./]*"
                }
            } else if (c == "?") {
                out = out "[^./]"
            } else if (c == "{") {
                out = out "("; depth++
            } else if (c == "}" && depth > 0) {
                out = out ")"; depth--
            } else if (c == "," && depth > 0) {
                out = out "|"
            } else if (c == "[") {
                rest = substr(glob, i + 1)
                close_at = index(rest, "]")
                if (close_at == 0) { out = out "\\["; continue }
                class = substr(rest, 1, close_at - 1)
                if (substr(class, 1, 1) == "!") class = "^" substr(class, 2)
                out = out "[" class "]"
                i += close_at
            } else if (c == "\\" && i < n) {
                i++; out = out literal(substr(glob, i, 1))
            } else {
                out = out literal(c)
            }
        }
        return "^" out "$"
    }
    function literal(c) {
        return (index(".+()|^$[]{}*?\\/", c) > 0 && c != "/") ? "\\" c : c
    }
    function ends_with(s, suffix) {
        return length(suffix) <= length(s) && substr(s, length(s) - length(suffix) + 1) == suffix
    }
    BEGIN {
        n_global = split("Makefile playwright.config.ts .forgejo/workflows/testing.yml tests/e2e/*.go tests/e2e/shared/* web_src/js/{index,utils}.* web_src/css/{base,index}.css templates/base/** modules/templates/**", global, " ")
        for (g = 1; g <= n_global; g++) global[g] = ere(global[g])
    }
    # stdin: the changed files.
    FILENAME == "" || FILENAME == "-" {
        if ($0 == "") next
        changed[++n_changed] = $0
        for (g = 1; g <= n_global; g++) if ($0 ~ global[g]) full = 1
        next
    }
    FNR == 1 { finish(); spec = FILENAME; in_block = 0; watched = 0; selected = full }
    # The first `// @watch` line opens the block, the next closes it; later ones are prose.
    !selected && /^\/\/ @watch/ {
        if (in_block) in_block = 0
        else if (!watched) { in_block = 1; watched = 1 }
    }
    !selected && in_block {
        pattern = $0
        if (substr(pattern, 1, 3) == "// ") pattern = substr(pattern, 4)
        if (pattern != "") {
            re = ere(pattern)
            for (c = 1; c <= n_changed; c++) if (changed[c] ~ re) { selected = 1; break }
        }
    }
    function finish(    c) {
        if (spec == "") return
        if (!selected && !watched) selected = 1
        for (c = 1; !selected && c <= n_changed; c++) if (ends_with(spec, changed[c])) selected = 1
        if (selected) print spec
        spec = ""
    }
    END { finish() }
' - ${specs}
