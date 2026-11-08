#!/usr/bin/env bash
# Runs Forgejo's unit tests as upstream CI's test-unit job does (`make test-backend` with
# RACE_ENABLED=true), for one part of them: `base` (models/ and modules/) or `backend` (the
# rest), as go-packages.sh splits them; or as its test-remote-cacher job does
# (`make test-remote-cacher`): `remote-cacher-<service>`, the packages with a Redis-protocol
# backend, against that enve service (redis, valkey, garnet).
#
#   helpers/go-unit.sh <base|backend|remote-cacher-<service>> <shard index> <shard total> [package...]
#
# enact passes the packages a change reaches (go-packages.sh selects them) and the changed
# _test.go files, already split across shards. With none - a full run - this shard takes
# its share of every package of the suite.
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

suite="$1"
server=""
if [[ "${suite}" == remote-cacher-* ]]; then
    server="${suite#remote-cacher-}"
    suite=remote-cacher
fi
shard_index="$2"
shard_total="$3"
shift 3

# A test file stands for its package.
package_of() {
    local dir
    case "$1" in
        *.go)
            dir="$(dirname "$1")"
            if [[ "${dir}" == "." ]]; then echo "${module}"; else echo "${module}/${dir}"; fi
            ;;
        *) echo "$1" ;;
    esac
}

if [[ $# -gt 0 ]]; then
    module="$(awk '$1 == "module" {print $2; exit}' go.mod)"
    # A changed migration test stands for a package of the migration suites.
    # shellcheck disable=SC2207
    packages=($(for target in "$@"; do package_of "${target}"; done | sort -u \
        | grep -Ev "^${module}/(models/(gitea_migrations|forgejo_migrations_legacy|forgejo_migrations)(/|$)|tests/integration(/|$))" || true))
else
    # Package paths hold no spaces: word splitting is safe, and works on bash 3.
    # shellcheck disable=SC2207
    packages=($(helpers/go-packages.sh "${suite}" \
        | awk -v shard="${shard_index}" -v total="${shard_total}" '(NR - 1) % total == shard - 1'))
fi
[[ ${#packages[@]} -gt 0 ]] || { echo "No ${suite} package for shard ${shard_index}/${shard_total}"; exit 0; }

echo "🧪 ${#packages[@]} ${suite} package(s), shard ${shard_index}/${shard_total}"
export PROJECT_ROOT="${PWD}"
# macOS's per-user temp dir is too long for the unix sockets the hook tests bind
# (sun_path holds 104 bytes).
[[ "$(uname -s)" != Darwin ]] || export TMPDIR=/tmp
# The storage package's S3 tests skip without an endpoint: enact exports the port of
# the SeaweedFS it starts. `localhost`, as the virtual-host test asks `gitea.localhost`.
[[ -z "${ENVE_SERVICE_SEAWEEDFS_PORT:-}" ]] || export TEST_MINIO_ENDPOINT="${TEST_MINIO_ENDPOINT:-localhost:${ENVE_SERVICE_SEAWEEDFS_PORT}}"
# The issue indexer's Elasticsearch tests skip without a URL: base's OpenSearch. Upstream
# leaves TEST_INDEXER_CODE_ES_URL (the code indexer's) unset, and so does this.
[[ -z "${ENVE_SERVICE_OPENSEARCH_PORT:-}" ]] || export TEST_ELASTICSEARCH_URL="${TEST_ELASTICSEARCH_URL:-http://127.0.0.1:${ENVE_SERVICE_OPENSEARCH_PORT}}"
count=()
if [[ -n "${server}" ]]; then
    # The tests read host:port from TEST_REDIS_SERVER and skip without it. The port is the
    # service's own variable: REDIS_PORT is ambiguous, as the Valkey preset exports it too.
    port_var="ENVE_SERVICE_$(echo "${server}" | tr '[:lower:]' '[:upper:]' | tr - _)_PORT"
    [[ -n "${!port_var:-}" ]] || { echo "remote-cacher: ${port_var} is unset: is ${server} running?" >&2; exit 2; }
    export TEST_REDIS_SERVER="localhost:${!port_var}"
    echo "🗄️  TEST_REDIS_SERVER=${TEST_REDIS_SERVER} (${server})"
    # A result Go cached against another server (or another run's) proves nothing about this one.
    count=(-count=1)
else
    # The Makefile's test-backend runs them in UTC (test-remote-cacher in the host's zone).
    export TZ=UTC
fi
# Upstream CI runs every unit test under the race detector (RACE_ENABLED=true). Tests that
# run the test binary as a git hook don't wait the detector's default second at exit
# (GORACE, as the Makefile sets it).
export GORACE="${GORACE:-atexit_sleep_ms=0}"

# Upstream's test-check (after test-backend and test-remote-cacher): the tests leave the
# checkout as they found it. Upstream's tree is clean, so it fails on any `git status`; a fork
# checkout carries the overlay and patches, so this compares the status before and after,
# untracked files one by one. enact's and enve's run state are not the tests'. The swagger
# checks rewrite the spec while they run: the status is taken between them (`swagger` lock).
tree_state() {
    helpers/exclusive.sh swagger git --no-optional-locks status --porcelain=v1 -uall \
        -- . ':(exclude).enact/state' ':(exclude).enve'
}
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    || { echo "test-check: not a git checkout" >&2; exit 2; }
before="$(tree_state)"
# ENACT_TEST_VERBOSE: the recall harness reads each test's own outcome (`--- PASS: TestX`).
go test -race ${ENACT_TEST_VERBOSE:+-v} ${count[@]+"${count[@]}"} -tags "${TEST_TAGS:-}" "${packages[@]}"
left="$(comm -13 <(printf '%s\n' "${before}" | sort) <(tree_state | sort) | sed '/^$/d')"
if [[ -n "${left}" ]]; then
    echo "make test-check: the tests changed files in the source tree:"
    echo "${left}"
    echo "You should change the tests to create these files in a temporary directory."
    echo "Do not simply add these files to .gitignore"
    exit 1
fi
