#!/usr/bin/env bash
# Records the sqlite integration tests' reach map: enact runs each test alone under eBPF
# with coverage of the whole module, several side by side, and keys it
# `tests/integration::TestName`, as the integration job takes its targets. Linux only
# (eBPF).
#
#   [TRACE_JOBS=n] [FULL=1] helpers/trace-integration.sh [test...]
#
# Standalone (no ENACT_FOOTPRINT_DIR): traces the tests `enact reach stale` lists (untraced,
# failed, or a file they read changed since), or the named ones, or every test (FULL=1), and
# lays their traces over the stored map at HEAD (`enact reach store where`), storing the
# result at HEAD: the rest keep theirs, and tests the package no longer declares are dropped.
# Nothing stale: nothing runs.
#
# Called from helpers/integration.sh during a shard run (ENACT_FOOTPRINT_DIR set, with
# TRACE_SHARD=<index>): traces the shard's wanted tests one by one inside the already-running
# enve environment and writes `${ENACT_FOOTPRINT_DIR}/integration-sqlite.json` with each test's
# outcome (`"outcomes": true`).
#
# Tests listed in helpers/integration-split-tests are traced by their subtests, keyed
# `tests/integration::TestName/Sub/Leaf`: the integration job runs and shards each alone.
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

package_dir="tests/integration"
# The enact running this (ENACT_EXE, set in enact tasks), else ENACT, else the one on PATH.
enact="${ENACT_EXE:-${ENACT:-enact}}"
tests=("$@")

if [ -z "${ENACT_FOOTPRINT_DIR:-}" ]; then
    map="$("${enact}" reach store where --path)"
    if [ ${#tests[@]} -eq 0 ] && [ -z "${FULL:-}" ]; then
        # Listed first: a process substitution would lose its exit status, and a failing
        # `reach stale` read as "nothing stale".
        if ! stale="$("${enact}" reach stale "${package_dir}" ${map:+--reach-file "${map}"})"; then
            echo "❌ enact reach stale failed: nothing traced" >&2
            exit 1
        fi
        mapfile -t tests < <(printf '%s' "${stale}" | sed "s|^${package_dir}::||")
        if [ ${#tests[@]} -eq 0 ]; then
            echo "Every integration test's trace is current: nothing to trace (FULL=1 traces all)."
            exit 0
        fi
        echo "Tracing ${#tests[@]} stale tests."
    fi
    jobs="${TRACE_JOBS:-$(( ($(nproc) + 1) / 2 ))}"
    prefix="trace"
    # The workers' ports stay reserved while this runs (helpers/free-ports.sh).
    export PORTS_OWNER=$$
    tags="$(enve run -- printenv TEST_TAGS)"
    shard_config=(enve run -- helpers/shard-config.sh)
else
    jobs=1
    prefix="record"
    tags="${TEST_TAGS:-}"
    shard_config=(helpers/shard-config.sh)
    echo "🎙️  tracing ${#tests[@]} test(s) for enact's reach map, with ${enact}"
fi

args=()
for test in ${tests[@]+"${tests[@]}"}; do args+=(--test "${test}"); done
while read -r split; do
    [ -z "${split}" ] || args+=(--subtests-of "${split}")
done < <(sed 's/#.*//; s/[[:space:]]//g; /^$/d' helpers/integration-split-tests)

# Each worker gets a config of its own, as shards get: data directories, ports and
# REPO_TEST_DIR. Config and data live outside the repository (under TMPDIR so enact counts a
# recording shard's tmpfs): a footprint holding what the tests themselves write (the database,
# keys, the listing of tests/integration) went stale as soon as it was recorded.
tmpdir="${TMPDIR:-}"
if [ "$(uname -s)" = Darwin ] || [ "${#tmpdir}" -gt 16 ]; then
    export TMPDIR=/tmp
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/fjtrace.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
for worker in $(seq 1 "${jobs}"); do
    mkdir "${work}/${worker}"
    slot="${TRACE_SHARD:-${worker}}"
    tag="${prefix}${slot}"
    SHARD_DIR="${work}/${worker}" REPO_TEST_DIR="${work}/${worker}/" "${shard_config[@]}" sqlite "${slot}" "${tag}"
    sed "s|${PWD}/tests/integration/forgejo-integration-sqlite-${tag}/|${work}/${worker}/data/|" \
        "${work}/${worker}/sqlite.ini" > "${work}/${worker}/sqlite.ini.tmp"
    mv "${work}/${worker}/sqlite.ini.tmp" "${work}/${worker}/sqlite.ini"
done
worker_dir="${work}/{worker}"
[ "${jobs}" -gt 1 ] || worker_dir="${work}/1"

# The tracer lists the tests by running the binary, whose TestMain sets up the database
# first: with worker 1's config, not the shared tests/sqlite.ini and its database, which
# other shards rewrite and set up meanwhile (2 of 12 shards' listers listed nothing:
# "declares no test"). Tests leave state in their data directory (queued work, a custom
# manifest) that changes what the next test runs: each starts on an empty one.
status=0
PROJECT_ROOT="${PWD}" PROJECT_CONF="${work}/1/sqlite.ini" \
    "${enact}" trace run --go --no-fingerprint --reach-file "${work}/traces.json" ${args[@]+"${args[@]}"} \
    --jobs "${jobs}" \
    --worker-env "PROJECT_CONF=${worker_dir}/sqlite.ini" \
    --worker-env "TRACE_DATA=${worker_dir}/data" \
    --before-each 'rm -rf "${TRACE_DATA}"' \
    -- "${package_dir}" -tags "${tags}" || status=$?

if [ -n "${ENACT_FOOTPRINT_DIR:-}" ]; then
    # The map says each test's outcome (a failed test's trace is incomplete): a failed
    # shard still lands its passing tests'. A test traced but not recorded (it crashed, or
    # ran no test) fails the shard, as it would fail the run.
    node - "${work}/traces.json" "${ENACT_FOOTPRINT_DIR}/integration-sqlite.json" "${package_dir}" ${tests[@]+"${tests[@]}"} <<'JS' || status=1
const fs = require('node:fs');
const [from, to, pkg, ...tests] = process.argv.slice(2);
const map = fs.existsSync(from) ? JSON.parse(fs.readFileSync(from, 'utf8')) : { version: 1, targets: {} };
map.outcomes = true;
fs.writeFileSync(to, JSON.stringify(map));
let failed = 0;
for (const test of tests) {
  const fp = (map.targets || {})[`${pkg}::${test}`];
  const outcome = !fp ? 'not recorded' : fp.outcome === undefined ? 'complete' : 'incomplete';
  console.log(`🎯 [footprints] recorded '${pkg}::${test}' (${outcome})`);
  if (outcome !== 'complete') failed++;
}
process.exit(failed ? 1 : 0);
JS
    exit "${status}"
fi

[ "${status}" -eq 0 ] || exit "${status}"
base=()
[ -n "${map}" ] && [ -z "${FULL:-}" ] && base=(--base "${map}")
"${enact}" reach pack --fingerprint ${base[@]+"${base[@]}"} -o "${work}/reach.bin" "${work}/traces.json"
"${enact}" reach store put "${work}/reach.bin"
