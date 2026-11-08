#!/usr/bin/env bash
# The frontend's unit tests as upstream's frontend-checks job runs them: `make
# test-frontend-coverage` (vitest with coverage of web_src) once per time zone. dayjs
# follows the local zone and its DST rules, so upstream runs them in two zones with
# different DST rules; the env's TZ (UTC) has none. Every zone runs, and the check fails
# naming each zone whose run failed. Run it after node_modules is installed
# (helpers/with-node-modules.sh).
#
#   helpers/vitest.sh [vitest args...]
set -euo pipefail

cd "$(dirname "$0")/.."

zones=(Europe/Berlin America/Edmonton)
failed=()
for zone in "${zones[@]}"; do
    echo "vitest: TZ=${zone}"
    TZ="${zone}" npx vitest --coverage --coverage.include 'web_src/**' "$@" || failed+=("${zone}")
done
if [[ ${#failed[@]} -gt 0 ]]; then
    echo "vitest: failed in TZ=${failed[*]}"
    exit 1
fi
