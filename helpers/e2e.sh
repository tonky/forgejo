#!/usr/bin/env bash
# Runs Forgejo's Playwright end-to-end tests on sqlite, as the Makefile's test-e2e-sqlite
# does, in Firefox as upstream CI runs them (coverage-run-e2e).
#
#   helpers/e2e.sh <shard index> <shard total> [spec...]
#
# Specs are what helpers/e2e-specs.sh selects (`tests/e2e/<name>.test.e2e.ts`, or the bare
# file name), already split across shards. With none - a full run - this shard takes its
# share of every spec.
#
# The test binary serves Forgejo in process on the ini's ROOT_URL and runs
# `npx playwright test <spec>` per spec (tests/e2e/e2e_test.go). Shards side by side in one
# checkout each get their own ini, data, ports and E2E_OUTPUT_DIR (session cookies, test
# artifacts; patch 0006), as integration.sh's do. The browser is the env's
# (pkgs.#PlaywrightBrowsers): nothing is installed at run time.
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd -P "$(dirname "$0")/.."

shard_index="$1"
shard_total="$2"
shift 2

specs=()
if [[ $# -gt 0 ]]; then
    for spec in "$@"; do
        case "${spec}" in
            tests/e2e/*) file="${spec}" ;;
            *) file="tests/e2e/${spec}" ;;
        esac
        # A target naming no spec fails the shard: it would otherwise pass having run nothing.
        [[ "${file}" == *.test.e2e.ts && -f "${file}" ]] || { echo "No e2e spec ${spec}" >&2; exit 1; }
        specs+=("${file}")
    done
else
    # Paths hold no spaces: word splitting is safe, and works on bash 3.
    # shellcheck disable=SC2207
    specs=($(ls tests/e2e/*.test.e2e.ts \
        | awk -v shard="${shard_index}" -v total="${shard_total}" '(NR - 1) % total == shard - 1'))
fi
[[ ${#specs[@]} -gt 0 ]] || { echo "No e2e spec for shard ${shard_index}/${shard_total}"; exit 0; }

# TestE2e runs a subtest per spec, named after its file: `<name>.test.e2e`.
run=""
for file in "${specs[@]}"; do
    name="$(basename "${file}" .ts)"
    run="${run:+${run}|}${name//./\\.}"
done
run="^TestE2e\$/^(${run})\$"

# Shards side by side, and a second run of the checkout (another enve instance), each get
# their own ini, data and output directory; a single shard outside an instance keeps
# upstream's directories. Ports are free ones (helpers/free-ports.sh).
shard=""
if (( shard_total > 1 )); then shard="-shard${shard_index}"; fi
shard="${shard}${ENVE_INSTANCE:+_${ENVE_INSTANCE//[^A-Za-z0-9]/_}}"
if [[ "$(uname -s)" == Darwin ]]; then
    # Unix sockets (INTERNAL_LISTENER_PATH, under REPO_TEST_DIR) are capped at 104 bytes
    # on macOS: keep the repositories and the socket under a short directory.
    export TMPDIR=/tmp
fi
if [[ "$(uname -s)" == Darwin || -n "${shard}" ]]; then
    work="$(mktemp -d /tmp/fje.XXXXXX)"
    export REPO_TEST_DIR="${work}/"
    # Session cookies, login states and Playwright's output (which each run empties first).
    [[ -z "${shard}" ]] || export E2E_OUTPUT_DIR="${work}/output"
    # A failed run keeps its data and logs, and the last spec's screenshots: Playwright
    # empties its output directory for each spec (upstream sets one per spec only when
    # updating screenshots).
    trap 'status=$?; if (( status == 0 )); then rm -rf "${work}"; else echo "e2e: kept ${work}" >&2; fi' EXIT
fi

# The pages load the built frontend (public/assets): `frontend:build` stages it via
# `#Job.outputs` in CI, and standalone `e2e:test` runs build it under the same lock.
if [[ ! -f public/assets/js/index.js || ! -f public/assets/css/index.css ]]; then
    helpers/with-node-modules.sh helpers/exclusive.sh webpack make --no-print-directory webpack
fi

# Playwright's own Firefox build at the revision the locked @playwright/test looks up: the
# env's store object (enve.cue), never `playwright install`.
[[ -d "${PLAYWRIGHT_BROWSERS_PATH:-}" ]] || {
    echo "e2e: PLAYWRIGHT_BROWSERS_PATH is not the env's browsers (run under enve)" >&2
    exit 1
}
browser="${PLAYWRIGHT_PROJECT-firefox}"

helpers/go-test-binary.sh forgejo.org/tests/e2e e2e.sqlite.test -tags "${TEST_TAGS:-}"

# An ini of its own: the harness rewrites it while it runs, and the sqlite integration and
# migration jobs generate tests/sqlite.ini beside it.
config="tests/sqlite-e2e${shard}.ini"
helpers/exclusive.sh "ini-sqlite" sh -c \
    "make --no-print-directory generate-ini-sqlite TEST_TYPE=e2e && cp tests/sqlite.ini ${config}.tmp"
awk -v shard="${shard}" '
    { gsub("-e2e-sqlite/", "-e2e-sqlite" shard "/") }
    { print }' "${config}.tmp" > "${config}"
rm "${config}.tmp"
helpers/free-ports.sh "${config}"

echo "🎭 ${#specs[@]} spec(s) in ${browser:-every browser}, shard ${shard_index}/${shard_total}"
# Every spec given runs: changes.go would skip some by CHANGED_FILES, which enact's
# selection (helpers/e2e-specs.sh) already applied.
unset CHANGED_FILES RUN_ALL
# Playwright's settings as upstream CI has them (playwright.config.ts reads CI, which the
# runner sets): a failed test retries once, and a spec stops at its first failure.
export CI=true
PROJECT_ROOT="${PWD}" PROJECT_CONF="${config}" PLAYWRIGHT_PROJECT="${browser}" \
    ./e2e.sqlite.test ${GOTESTCOMPILEDRUNSUFFIX:-} -test.run "${run}"
