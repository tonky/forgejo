#!/usr/bin/env bash
# Builds a Go test binary and its toolchain/flags stamp (`<stem>.stamp.test`).
# Declarative `integration*:build` `#Job.outputs` producers call this with `ENACT_JOB=build*`
# under enact's output-key cache and lock; standalone callers materialize declared producers via
# `enact helper ensure-outputs`, and non-producer binaries serialize via `exclusive.sh`.
#
#   helpers/go-test-binary.sh <package> <binary> [go test -c flag...]
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

package="$1"
binary="$2"
shift 2

if [[ "${ENACT_JOB:-}" != build* && -d .enact ]]; then
    enact="${ENACT_EXE:-${ENACT_BIN:-$(command -v enact || true)}}"
    if [[ -n "${enact}" ]]; then
        case "${binary}" in
            integrations.sqlite.test)      exec "${enact}" helper ensure-outputs integration:build ;;
            integrations.sqlite.race.test) exec "${enact}" helper ensure-outputs integration:build_race ;;
            integrations.mysql.test)       exec "${enact}" helper ensure-outputs integration-mysql:build ;;
            integrations.pgsql.race.test)  exec "${enact}" helper ensure-outputs integration-pgsql:build ;;
        esac
    fi
fi

build() {
    # What the binary was built with; named `*.test`, as the binary is, for upstream's .gitignore.
    local stamp_file="${binary%.test}.stamp.test" stamp
    # The C compiler by its resolved path: cgo links it into the sqlite driver.
    stamp="$(go version) $(command -v "$(go env CC)") $*"
    if [[ "${ENACT_JOB:-}" != build* && -x "${binary}" && "$(cat "${stamp_file}" 2>/dev/null)" == "${stamp}" ]]; then
        echo "🔨 ${binary} is up to date"
        return
    fi
    echo "🔨 Building ${binary}..."
    go test -c "${package}" -o "${binary}.tmp" "$@"
    mv "${binary}.tmp" "${binary}"
    echo "${stamp}" > "${stamp_file}"
}

if [[ "${ENACT_JOB:-}" == build* || "${GO_TEST_BINARY_LOCKED:-}" == "${binary}" ]]; then
    build "$@"
else
    GO_TEST_BINARY_LOCKED="${binary}" exec helpers/exclusive.sh "build-${binary}" helpers/go-test-binary.sh "${package}" "${binary}" "$@"
fi
