#!/usr/bin/env bash
# Prints the Go packages of one test suite that a change reaches:
#
#   helpers/go-packages.sh <base|backend|migrations|remote-cacher> [changed file...]
#
# Delegates to `enact helper go-packages`.
set -euo pipefail

cd "$(dirname "$0")/.."
scope="$1"
shift

module="$(awk '$1 == "module" {print $2; exit}' go.mod)"
migrations="models/(gitea_migrations|forgejo_migrations_legacy|forgejo_migrations)(/|$)|tests/integration/migration-test$"
case "${scope}" in
    base) keep="^${module}/(models|modules)(/|$)"; drop="^${module}/(${migrations})" ;;
    backend) keep="."; drop="^${module}/(models|modules|${migrations}|tests$|tests/integration(/|$)|tests/e2e$)" ;;
    migrations) keep="^${module}/(${migrations})"; drop="^$" ;;
    remote-cacher)
        cachers="$(awk '$1 == "REMOTE_CACHER_MODULES" {sub(/^[^=]*=[ \t]*/, ""); gsub(/[ \t]+/, "|"); print; exit}' Makefile)"
        [[ -n "${cachers}" ]] || { echo "no REMOTE_CACHER_MODULES in Makefile" >&2; exit 2; }
        keep="^${module}/modules/(${cachers})$"; drop="^$" ;;
    *) echo "unknown suite: ${scope}" >&2; exit 2 ;;
esac

enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
exec "${enact}" helper go-packages --keep "${keep}" --drop "${drop}" "$@"
