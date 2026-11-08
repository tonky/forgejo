#!/usr/bin/env bash
# Runs Forgejo's integration tests against one database, as the Makefile's test-<db> does.
#
#   helpers/integration.sh <sqlite|pgsql|mysql|mariadb_<version>> <shard index> <shard total> [target...]
#
# Targets are what enact's trace reach map selects, already split across shards. With
# none - a full run - this shard takes its block of the package (helpers/integration-tests.sh).
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
here="${PWD}"
cd "$(dirname "$0")/.."

db="$1"
shard_index="$2"
shard_total="$3"
shift 3

# enact rewrites a repository path in a command to the component's directory, so a test
# file target comes as `../../tests/integration/a_test.go`: name it from the repository root.
# One that isn't there is taken as given (from the repository root).
root_dir="$(pwd -P)"
targets=()
for target in "$@"; do
    if [[ "${target}" == *_test.go && "${target}" != /* && -f "${here}/${target}" ]]; then
        target="$(cd "$(dirname "${here}/${target}")" && pwd -P)/$(basename "${target}")"
        target="${target#"${root_dir}"/}"
    fi
    targets+=("${target}")
done
set -- ${targets[@]+"${targets[@]}"}

# Upstream's push-only testing-integration runs the MySQL suites against MariaDB 10.6 and
# 11.8 too: `mariadb_<version>` is that enve service, reached as TEST_MYSQL_HOST, and its
# runs (ini, data, database) are named apart from MySQL's, which may run beside them.
server=""
if [[ "${db}" == mariadb_* ]]; then
    server="${db}"
    db=mysql
    port_var="ENVE_SERVICE_$(echo "${server}" | tr '[:lower:]' '[:upper:]')_PORT"
    [[ -n "${!port_var:-}" ]] || { echo "${server}: ${port_var} is unset: is ${server} running?" >&2; exit 2; }
    export TEST_MYSQL_HOST="127.0.0.1:${!port_var}"
    # The server must be the MariaDB its name spells (mariadb_106: 10.6.x): MySQL's client asks.
    version="$(mysql --host=127.0.0.1 --port="${!port_var}" --user=root --skip-password \
        --batch --skip-column-names --execute='SELECT VERSION()')"
    want="${server#mariadb_}"
    want="${want:0:${#want}-1}.${want: -1}"
    [[ "${version}" == "${want}."*MariaDB* ]] \
        || { echo "${server}: the server is ${version}, not MariaDB ${want}" >&2; exit 2; }
    echo "${server}: MariaDB ${version}"
fi

package_dir="tests/integration"

# Tests and subtests to run, and subtests to skip (`-Test/Sub`): `go test -run` and `-skip`
# patterns, a `^name$` per level, alternatives joined by `|`.
# Listed first: a target naming no test fails the shard (a process substitution would lose
# the lister's exit status).
entries="$(helpers/integration-tests.sh "${shard_index}" "${shard_total}" "$@")"

# Recording while it runs (`enact run`): enact asks for footprints with
# ENACT_FOOTPRINT_DIR, and lists the tests it wants traced in ENACT_FOOTPRINT_TARGETS (a
# `tests/integration::Test[/Sub]` or a `_test.go` file per line; no list: every test). The
# map is recorded on sqlite, on Linux (eBPF), as helpers/trace-integration.sh records it:
# the shard's wanted tests are traced one by one, the rest run as below. A test the map
# holds by its subtests (helpers/integration-split-tests) runs untraced when whole.
splits="$(sed 's/#.*//; s/[[:space:]]//g; /^$/d' helpers/integration-split-tests)"
# RACE_ENABLED=true, as upstream's Makefile reads it (test-pgsql on every pull request,
# testing-integration's test-sqlite on pushes): the binary built with -race. Traces come
# from a run without it.
race=""
[[ "${RACE_ENABLED:-}" != true ]] || race=1
recording=""
[[ -z "${ENACT_FOOTPRINT_DIR:-}" || "${db}" != sqlite || "$(uname -s)" != Linux || -n "${race}" ]] || recording=1
declaring=""
if [[ -n "${recording}" && -n "${ENACT_FOOTPRINT_TARGETS:-}" ]] && grep -q '_test\.go$' "${ENACT_FOOTPRINT_TARGETS}"; then
    # `TestName file` per declared test: a listed file wants each of its tests.
    declaring="$(awk 'match($0, /^func Test[A-Za-z0-9_]+\(t \*testing\.T\)/) {
        name = substr($0, 6, RLENGTH - 5); sub(/\(.*/, "", name); print name, FILENAME
    }' "${package_dir}"/*_test.go)"
fi
wanted() {
    [[ -n "${recording}" ]] || return 1
    ! grep -qxF "$1" <<< "${splits}" || return 1
    [[ -n "${ENACT_FOOTPRINT_TARGETS:-}" ]] || return 0
    grep -qxF "${package_dir}::$1" "${ENACT_FOOTPRINT_TARGETS}" && return 0
    local file
    file="$(awk -v test="${1%%/*}" '$1 == test { print $2; exit }' <<< "${declaring}")"
    [[ -n "${file}" ]] && grep -qxF "${file}" "${ENACT_FOOTPRINT_TARGETS}"
}

run="" skip="" count=0 traced=()
while read -r entry; do
    [[ -n "${entry}" ]] || continue
    pattern="$(printf '%s' "${entry#-}" | sed 's/[][\.+*?(){}|^$]/\\&/g; s|/|$/^|g')"
    pattern="^${pattern}\$"
    if [[ "${entry}" == -* ]]; then
        skip="${skip:+${skip}|}${pattern}"
    elif wanted "${entry}"; then
        # Traced instead: the untraced run skips it.
        traced+=("${entry}"); skip="${skip:+${skip}|}${pattern}"; count=$((count + 1))
    else
        run="${run:+${run}|}${pattern}"; count=$((count + 1))
    fi
done <<< "${entries}"
# A full run's shard can be empty; selected targets that run no test are a failure.
if [[ ${count} -eq 0 ]]; then
    echo "No integration test for shard ${shard_index}/${shard_total}${*:+ in: $*}"
    [[ $# -eq 0 ]]
    exit
fi

tmpdir="${TMPDIR:-}"
if [[ "$(uname -s)" == Darwin || "${#tmpdir}" -gt 16 ]]; then
    export TMPDIR=/tmp
fi

# Upstream CI stores pgsql's files in MinIO: here in the SeaweedFS enact starts.
[[ "${db}" != pgsql ]] || export TEST_S3_HOST="${TEST_S3_HOST:-127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT:?SeaweedFS is not running}}"
# And runs the LDAP tests (TEST_LDAP=1) against OpenLDAP: here the one enact starts, with
# the image's entries (helpers/openldap.sh). The other databases' jobs skip them, as upstream's.
if [[ "${db}" == pgsql ]]; then
    export TEST_LDAP=1
    export TEST_LDAP_HOST="${TEST_LDAP_HOST:-127.0.0.1}"
    export TEST_LDAP_PORT="${TEST_LDAP_PORT:-${ENVE_SERVICE_OPENLDAP_PORT:?OpenLDAP is not running}}"
fi

status=0
if [[ ${#traced[@]} -gt 0 ]]; then
    TRACE_SHARD="${shard_index}" helpers/trace-integration.sh "${traced[@]}" || status=$?
fi
if [[ -z "${run}" ]]; then
    exit "${status}"
fi

# Materialized before the shards by the component's `build` / `build_race` `#Job.outputs`
# producer in `enact run` and `enact reach record`; built here only for standalone callers.
binary="integrations.${db}${race:+.race}.test"
flags=()
[[ "${db}" == sqlite ]] && flags=(-tags "${TEST_TAGS:-}")
if [[ -n "${race}" ]]; then
    flags+=(-race)
    # The test binary runs itself for every git hook: don't wait a second at each exit
    # (GOTESTCOMPILEDRUNPREFIX, as the Makefile sets it).
    export GORACE="${GORACE:-atexit_sleep_ms=0}"
fi
if [[ ! -x "${binary}" ]]; then
    helpers/go-test-binary.sh "forgejo.org/${package_dir}" "${binary}" ${flags[@]+"${flags[@]}"}
fi

if [[ -z "${FORGEJO_SHARD_CONFIG:-}" ]]; then
    export ENACT_FIXTURE_OWNER_PID="${ENACT_FIXTURE_OWNER_PID:-$$}"
    fixture_env="$(helpers/shard-config.sh acquire "${server:-${db}}" "${shard_index}" integration --shell)"
    eval "${fixture_env}"
    trap 'status=$?; helpers/shard-config.sh release || { cleanup=$?; if (( status == 0 )); then status=$cleanup; fi; }; exit "${status}"' EXIT
fi
config="${FORGEJO_SHARD_CONFIG}"

# Upstream CI's database server is new for every job: a shard starts from an empty database,
# not from what an earlier run, or a killed one, left in the instance's server.
# TestDatabaseCollation found a killed run's test_tbl, in a collation of its own, on MySQL.
if [[ "${db}" != sqlite ]]; then
    eval "$(awk -F ' *= *' '/^\[/ { section = $0 } section == "[database]" && $1 ~ /^(HOST|NAME|USER|PASSWD)$/ { print "db_" $1 "=\"" $2 "\"" }' "${config}")"
fi
if [[ "${db}" == mysql ]]; then
    MYSQL_PWD="${db_PASSWD}" mysql -h "${db_HOST%:*}" -P "${db_HOST##*:}" -u "${db_USER}" \
        -e "DROP DATABASE IF EXISTS \`${db_NAME%%\?*}\`"
fi
if [[ "${db}" == pgsql ]]; then
    # The tests create their database, but connect to it first to ask whether it exists:
    # on a fresh server (CI, a new shard) that fails. Create it from the ini's settings.
    pg=(psql -q -v ON_ERROR_STOP=1 -h "${db_HOST%:*}" -p "${db_HOST##*:}" -U "${db_USER}" -d postgres)
    PGPASSWORD="${db_PASSWD}" "${pg[@]}" -c "DROP DATABASE IF EXISTS \"${db_NAME}\" WITH (FORCE)"
    PGPASSWORD="${db_PASSWD}" "${pg[@]}" -c "CREATE DATABASE \"${db_NAME}\""
    # The ini's bucket is `gitea`, which the unit tests' S3 tests fill and list beside
    # these, and which every shard would share: each run takes its own.
    bucket="$(printf 'integration-%s' "${FORGEJO_SHARD_RUN//_/-}" | tr '[:upper:]' '[:lower:]')"
    awk -v bucket="${bucket}" '/^MINIO_BUCKET *=/ { $NF = bucket } { print }' \
        "${config}" > "${config}.tmp" && mv "${config}.tmp" "${config}"
fi

echo "🧪 $((count - ${#traced[@]})) test(s) on ${db}${race:+ under -race}, shard ${shard_index}/${shard_total}"
# GOTESTCOMPILEDRUNSUFFIX as upstream's Makefile takes it: `-test.v` prints the times
# helpers/integration-durations.sh records.
# shellcheck disable=SC2086
args=(-test.run "${run}")
# The recall harness reads each test's own outcome (`--- PASS: TestX`).
[[ -z "${ENACT_TEST_VERBOSE:-}" || "${GOTESTCOMPILEDRUNSUFFIX:-}" == *-test.v* ]] || args+=(-test.v)
[[ -z "${skip}" ]] || args+=(-test.skip "${skip}")
PROJECT_ROOT="${PWD}" PROJECT_CONF="${config}" "./${binary}" ${GOTESTCOMPILEDRUNSUFFIX:-} "${args[@]}" || status=$?
exit "${status}"
