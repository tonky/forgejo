#!/usr/bin/env bash
# `make lockfile-check` for a checkout other jobs run in: upstream's target rewrites
# package-lock.json in place (`npm install --package-lock-only`) and diffs it against git's
# index. Here npm rewrites a copy of the manifest, the lock and .npmrc, and the copy is
# compared with the checkout's lock, so the check sees uncommitted changes and leaves the
# checkout as it was: a rewritten lock, even an identical one, is newer than node_modules,
# and `make node_modules` would reinstall under the frontend jobs beside it.
set -euo pipefail

cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
for f in package.json package-lock.json .npmrc; do
    [[ -f "${f}" ]] && cp "${f}" "${work}/"
done
(cd "${work}" && npm install --package-lock-only)
if ! diff -u package-lock.json "${work}/package-lock.json"; then
    echo "Please run 'npm install --package-lock-only' and commit the result"
    exit 1
fi
