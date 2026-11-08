#!/usr/bin/env bash
# Prints what one shard of the integration suite runs, one entry per line, in the order Go
# runs them: a test (`TestName`), a subtest (`TestName/Sub/Leaf`), or a subtest the shard
# skips (`-TestName/Sub/Leaf`).
#
#   helpers/integration-tests.sh <shard index> <shard total> [target...]
#
# Targets are what enact's trace reach map selects, already split across shards:
# `tests/integration::TestName`, or a `_test.go` file (all of its tests). With none - a
# full run - the shard takes a contiguous block of the whole package in Go's order: files
# by name, tests as declared. Some tests leave global settings for the next test in the
# file to restore (TestAPILFSNotStarted turns LFS off), so a shard must run an unbroken
# stretch of upstream's sequence, not every n-th test.
#
# Blocks are cut by the recorded time of each test (.enact/integration-durations.json,
# which enact also balances selected targets by): no block is longer than the least bound
# `total` contiguous blocks can keep to, and blocks stay near an even share of the time
# left. A test without a record weighs the median; with no record, all weigh the same.
#
# The longest tests would bound every block: those listed in helpers/integration-split-tests
# are spread out by their recorded subtests. One shard runs the whole test, skipping the
# subtests other shards run, so a subtest added since the record still runs.
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

# Go orders a package's files byte-wise; a locale's collation can ignore `_` and case.
export LC_ALL=C

shard_index="$1"
shard_total="$2"
shift 2

# The tests files declare, as `go test -list` would print them, without building.
declared_tests() {
    awk 'match($0, /^func Test[A-Za-z0-9_]+\(t \*testing\.T\)/) {
        name = substr($0, 6, RLENGTH - 5); sub(/\(.*/, "", name); print name
    }' "$@"
}

durations=".enact/integration-durations.json"

if [[ $# -eq 0 ]]; then
    declared_tests tests/integration/*_test.go \
        | awk -v shard="${shard_index}" -v total="${shard_total}" -v durations="${durations}" \
            -v splits="helpers/integration-split-tests" '
            BEGIN {
                # One `"tests/integration::TestName[/Sub...]": seconds` per line.
                while ((getline line < durations) > 0) {
                    if (match(line, /"tests\/integration::Test[^"]*": *[0-9.]+/)) {
                        entry = substr(line, RSTART + 20, RLENGTH - 20)
                        name = entry; sub(/": *[0-9.]+$/, "", name)
                        seconds = entry; sub(/.*": */, "", seconds)
                        if (index(name, "/")) subtest[name] = seconds + 0
                        else recorded[name] = seconds + 0
                    }
                }
                while ((getline line < splits) > 0) {
                    sub(/#.*/, "", line); gsub(/[ \t]/, "", line)
                    if (line != "") split_node[line] = 1
                }
            }
            { tests[++n] = $0 }
            END {
                known = 0
                for (i = 1; i <= n; i++) if (tests[i] in recorded) times[++known] = recorded[tests[i]]
                median = 1
                if (known > 0) {
                    # Insertion sort: BSD awk has no asort.
                    for (i = 2; i <= known; i++) {
                        v = times[i]
                        for (j = i - 1; j > 0 && times[j] > v; j--) times[j + 1] = times[j]
                        times[j + 1] = v
                    }
                    median = times[int((known + 1) / 2)]
                }
                # Units, in Go order: a test, or the recorded leaves of a split test.
                for (i = 1; i <= n; i++) {
                    t = tests[i]; leaves = 0
                    if (t in split_node) {
                        for (path in subtest) {
                            parent = path; sub(/\/[^\/]*$/, "", parent)
                            if (index(path, t "/") == 1 && (parent in split_node) && !(path in split_node))
                                leaf[++leaves] = path
                        }
                        for (a = 2; a <= leaves; a++) {
                            v = leaf[a]
                            for (b = a - 1; b > 0 && leaf[b] > v; b--) leaf[b + 1] = leaf[b]
                            leaf[b + 1] = v
                        }
                    }
                    if (leaves == 0) {
                        unit[++units] = t; root[units] = ""
                        weight[units] = (t in recorded) ? recorded[t] : median
                        continue
                    }
                    for (a = 1; a <= leaves; a++) {
                        unit[++units] = leaf[a]; root[units] = t; anchor[units] = (a == 1)
                        weight[units] = subtest[leaf[a]]
                    }
                }
                for (u = 1; u <= units; u++) {
                    # A shard runs its tests one after another: none is free.
                    if (weight[u] < 0.01) weight[u] = 0.01
                    sum[u] = sum[u - 1] + weight[u]
                    if (weight[u] > heaviest) heaviest = weight[u]
                }
                # The smallest bound on a block that `total` contiguous blocks can keep to.
                low = heaviest; high = sum[units]
                for (step = 0; step < 50; step++) {
                    bound = (low + high) / 2
                    if (blocks_under(bound) <= total) high = bound; else low = bound
                }
                bound = high
                # need[u]: the fewest blocks units u.. fit in under the bound.
                need[units + 1] = 0; j = units + 1
                for (u = units; u >= 1; u--) {
                    while (sum[j - 1] - sum[u - 1] > bound) j--
                    need[u] = 1 + need[j]
                }
                # Cut a block where the rest would exceed the bound, or where the next unit
                # is mostly past an even share of the time left; but only while the units
                # after it still fit in the shards after it.
                block = 1; current = 0
                for (u = 1; u <= units; u++) {
                    if (current > 0 && block < total) {
                        share = (sum[units] - sum[u - 1] + current) / (total - block + 1)
                        if ((current + weight[u] > bound || current + weight[u] / 2 > share) \
                            && need[u] <= total - block) { block++; current = 0 }
                    }
                    current += weight[u]
                    assigned[u] = block
                }
                for (u = 1; u <= units; u++) {
                    if (assigned[u] != shard) continue
                    if (root[u] == "") { print unit[u]; continue }
                    if (!anchor[u]) {
                        # The anchor shard runs the whole test.
                        for (a = 1; a <= units; a++) if (anchor[a] && root[a] == root[u]) break
                        if (assigned[a] != shard) print unit[u]
                        continue
                    }
                    print root[u]
                    for (a = 1; a <= units; a++)
                        if (root[a] == root[u] && assigned[a] != shard) print "-" unit[a]
                }
            }
            function blocks_under(bound,    count, current, u) {
                count = 1; current = 0
                for (u = 1; u <= units; u++) {
                    if (current > 0 && current + weight[u] > bound) { count++; current = 0 }
                    current += weight[u]
                }
                return count
            }'
    exit 0
fi
# A target naming nothing is an error, not an empty shard: a bare test name was dropped,
# and its shard passed without running a test.
declared=" $(declared_tests tests/integration/*_test.go | tr '\n' ' ')"
test_named() {
    local base="${1#-}"
    [[ "${declared}" == *" ${base%%/*} "* ]] || { echo "no integration test ${1%%/*}" >&2; exit 1; }
    echo "$1"
}
for target in "$@"; do
    case "${target}" in
        *::*) test_named "${target##*::}" ;;
        Test*|-Test*) test_named "${target}" ;;
        *_test.go) [[ -f "${target}" ]] || { echo "no such test file: ${target}" >&2; exit 1; }
            declared_tests "${target}" ;;
        *) echo "not an integration test target: ${target}" >&2; exit 1 ;;
    esac
done
