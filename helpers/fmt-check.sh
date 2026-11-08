#!/usr/bin/env bash
# `make fmt-check` for a checkout with uncommitted changes: upstream's target fails on any
# difference from HEAD, so this compares the working tree before and after `make fmt`.
set -euo pipefail

cd "$(dirname "$0")/.."

before=$(mktemp)
after=$(mktemp)
trap 'rm -f "${before}" "${after}"' EXIT
git diff --binary > "${before}"
make --no-print-directory fmt
git diff --binary > "${after}"
if ! cmp -s "${before}" "${after}"; then
    git diff --color=always --stat
    diff "${before}" "${after}" || true
    echo "Please run 'make fmt' and commit the result"
    exit 1
fi
