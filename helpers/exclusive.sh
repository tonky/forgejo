#!/usr/bin/env bash
# Runs a command while no other command holding the same lock runs in this checkout:
#
#   helpers/exclusive.sh <lock name> <command...>
#
# Delegates to `enact helper lock` (lock lives outside the checkout, released on SIGKILL).
set -euo pipefail

cd "$(dirname "$0")/.."
name="${1:?usage: exclusive.sh <lock name> <command...>}"
shift
enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
exec "${enact}" helper lock "${name}" -- "$@"
