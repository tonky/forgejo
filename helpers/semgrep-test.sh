#!/usr/bin/env bash
# Native semgrep test requires rules beside their test and autofix fixtures.
set -euo pipefail
work=$(mktemp -d "${TMPDIR:-/tmp}/forgejo-semgrep.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
for file in .semgrep/config/* .semgrep/tests/*; do
    if [ ! -f "$file" ] || [ -e "$work/${file##*/}" ]; then
        printf 'Cannot stage unique Semgrep test input: %s\n' "$file" >&2
        exit 1
    fi
    cp -- "$file" "$work/"
done
semgrep test "$work" "$@"
