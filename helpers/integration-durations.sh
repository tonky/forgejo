#!/usr/bin/env bash
# Records how long each integration test took into .enact/integration-durations.json,
# from the output of runs with `GOTESTCOMPILEDRUNSUFFIX=-test.v` (enact logs included).
#
#   helpers/integration-durations.sh <log>...
#
# One run per log. Entries for tests not in the logs are kept; a test in several logs
# keeps the last time. Within a log, the times of a test split across shards add up:
# each shard that ran part of it reports it.
# Keys are enact's target ids for the suite (`tests/integration::TestName`), so enact
# balances selected targets by the same file the full run's blocks are cut by.
set -euo pipefail

durations="$(dirname "$0")/../.enact/integration-durations.json"
[[ $# -gt 0 ]] || { echo "usage: $0 <log>..." >&2; exit 2; }
[[ -f "${durations}" ]] || echo '{}' > "${durations}"

export LC_ALL=C
splits="$(dirname "$0")/integration-split-tests"
{
    # Existing entries first, so that the logs' times replace them.
    sed -n 's/^ *"\(tests\/integration::Test[^"]*\)": *\([0-9.]*\).*/\1 \2/p' "${durations}"
    # `--- PASS: TestName (1.23s)`, and `TestName/Sub` of the tests split across shards.
    for log in "$@"; do
        sed -En 's/^.*--- (PASS|FAIL|SKIP): (Test[^ ]*) \(([0-9.]+)s\)$/tests\/integration::\2 \3/p' "${log}" \
        | awk -v splits="${splits}" '
            BEGIN {
                while ((getline line < splits) > 0) {
                    sub(/#.*/, "", line); gsub(/[ \t]/, "", line)
                    if (line != "") split_node[line] = 1
                }
            }
            # JSON keys stay plain: a name with a quote or backslash is not recorded.
            /["\\]/ { next }
            {
                name = $1; sub(/^tests\/integration::/, "", name)
                parent = name
                if (!sub(/\/[^\/]*$/, "", parent) || (parent in split_node)) print
            }' \
        | awk '{ seconds[$1] += $2 } END { for (t in seconds) print t, seconds[t] }'
    done
} | awk '{ seconds[$1] = $2 } END { for (t in seconds) print t, seconds[t] }' \
    | sort \
    | awk 'BEGIN { print "{" }
        NR > 1 { print line "," }
        { line = sprintf("  \"%s\": %s", $1, $2) }
        END { if (NR) print line; print "}" }' > "${durations}.tmp"
mv "${durations}.tmp" "${durations}"
echo "$(grep -c '::' "${durations}") test durations in ${durations}"
