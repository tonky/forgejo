#!/usr/bin/env bash
# Runs a command once node_modules is installed. Toolchain prepare installs it once per
# run for Node-served suites; standalone callers and Go-only checks fall back to the lock.
#
#   helpers/with-node-modules.sh <command...>
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

if [[ ",${ENACT_PREPARED:-}," != *,node,* ]]; then
    helpers/exclusive.sh node_modules make --no-print-directory node_modules
fi
exec "$@"
