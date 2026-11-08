#!/usr/bin/env bash
# `make tidy-check` on every host: go.mod and go.sum tidy, and assets/go-licenses.json as
# upstream's Linux CI generates it. go-licenses lists the packages of the GOOS it runs
# for (prometheus/procfs is Linux-only), so it is built for the host and lists for
# linux/amd64; the Makefile's `go run` would build it for the target and not run. The rest
# of the license recipe (the modules it ignores and copies itself) is the Makefile's own.
set -euo pipefail

cd "$(dirname "$0")/.."

license_file=assets/go-licenses.json
go_licenses="$(awk '$1 == "GO_LICENSES_PACKAGE" {print $3; exit}' Makefile)"
[[ -n "${go_licenses}" ]] || { echo "tidy-check: no GO_LICENSES_PACKAGE in the Makefile" >&2; exit 1; }

go mod tidy -compat="$(awk '$1 == "go" {print $2; exit}' go.mod)"

bin="$(mktemp -d)"
trap 'rm -rf "${bin}" .go-licenses' EXIT
GOBIN="${bin}" go install "${go_licenses}"
recipe="$(make --no-print-directory -B -n GO=go "${license_file}")"
save="go run ${go_licenses} "
[[ "${recipe}" == *"${save}"* ]] || { echo "tidy-check: the ${license_file} recipe no longer runs \`${save}…\`:" >&2; echo "${recipe}" >&2; exit 1; }
# As the Makefile's `-$(GO) run … save`: go-licenses exits 1 on the modules it can't
# classify and still saves the others; the diff below judges the result.
recipe="$(printf '%s\n' "${recipe}" | awk -v save="${save}" -v run="GOOS=linux GOARCH=amd64 ${bin}/go-licenses " '
    index($0, save) == 1 { print run substr($0, length(save) + 1) " || true"; next } { print }')"
bash -euo pipefail -c "${recipe}"

git diff --exit-code --color=always go.mod go.sum "${license_file}" || {
    echo "Please run 'make tidy' and commit the result"
    exit 1
}
