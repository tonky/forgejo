#!/usr/bin/env bash
# Pick two unused loopback ports (HTTP_PORT, SSH_PORT) and patch Forgejo's app.ini in place.
# Delegates to `enact helper free-ports` (`F-shell-loop-free-ports-timeout`).
set -euo pipefail

[ $# -eq 1 ] && [ -f "$1" ] || { echo "usage: $0 <path/to/app.ini>" >&2; exit 2; }

enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact)}}"
exec "${enact}" helper free-ports --count 2 --owner "${PORTS_OWNER:-${PPID}}" ${FREE_PORTS_RANGE:+--range "${FREE_PORTS_RANGE}"} --rewrite-ini "$1" >/dev/null
