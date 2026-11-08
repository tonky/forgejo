#!/usr/bin/env bash
# `make security-check` as upstream's security-check job runs it: govulncheck over the
# module (`go run golang.org/x/vuln/cmd/govulncheck@v1 -show color ./...`; the env locks
# the release `@v1` resolves to). It reads a copy of the Go vulnerability database
# instead of querying vuln.go.dev: the copy (vulndb.zip) lives in GOVULNDB_MIRROR, which
# CI restores from the `govulndb` cache, and every run first refreshes it when vuln.go.dev
# publishes a newer one (a conditional GET, so an unchanged database downloads nothing).
#
#   helpers/security-check.sh [package patterns...]   (default ./...)
#
#   GOVULNDB_MIRROR  the copy's directory (default ~/.cache/govulndb)
#   GOVULNDB_URL     where the copy comes from (default https://vuln.go.dev/vulndb.zip);
#                    `none` checks against the copy as it is
#
# A refresh that fails (no network) checks against the copy it has, and says how old it
# is; without a copy the check fails.
set -euo pipefail

cd "$(dirname "$0")/.."

mirror="${GOVULNDB_MIRROR:-${HOME}/.cache/govulndb}"
url="${GOVULNDB_URL:-https://vuln.go.dev/vulndb.zip}"
zip="${mirror}/vulndb.zip"
mkdir -p "${mirror}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

if [[ "${url}" != none ]]; then
    # `-R` dates the file as the server does, `-z` asks only for a newer one (a 304 writes
    # nothing). The rename is atomic: a run beside this one unzips the old or the new copy.
    since=()
    [[ -f "${zip}" ]] && since=(-z "${zip}")
    fetched="$(mktemp "${mirror}/.vulndb.zip.XXXXXX")"
    if curl -fsSL --retry 2 -R "${since[@]}" -o "${fetched}" "${url}"; then
        if [[ -s "${fetched}" ]]; then
            mv -f "${fetched}" "${zip}"
        else
            rm -f "${fetched}"
        fi
    else
        rm -f "${fetched}"
        [[ -f "${zip}" ]] || { echo "security-check: ${url} unreachable and no copy in ${mirror}" >&2; exit 1; }
        echo "security-check: couldn't refresh the database from ${url}: checking against the copy saved $(date -r "${zip}" '+%Y-%m-%d %H:%M')" >&2
    fi
fi
[[ -f "${zip}" ]] || { echo "security-check: no vulnerability database in ${mirror}" >&2; exit 1; }

# Each run reads its own unpacked copy: a refresh beside it replaces only the zip.
unzip -q "${zip}" -d "${work}/db"
echo "security-check: Go vulnerability database of $(cat "${work}/db/index/db.json")"

[[ $# -gt 0 ]] || set -- ./...
govulncheck -db "file://${work}/db" -show color "$@"
