#!/usr/bin/env bash
# Runs Forgejo's migration tests against one database, as the Makefile's
# test-<db>-migration does: each migration package's tests one package at a time, and
# the migration test that upgrades old database dumps.
#
#   helpers/go-migrations.sh <sqlite|pgsql|mysql|mariadb_<version>> <shard index> <shard total> [package...]
#
# enact passes the migration packages a change reaches (go-packages.sh selects them) and
# the changed _test.go files, already split across shards. With none - a full run - the
# last of several shards upgrades the old dumps, the longest part, and the others share
# the migration packages.
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

db="$1"
shard_index="$2"
shard_total="$3"
shift 3

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

module="$(awk '$1 == "module" {print $2; exit}' go.mod)"
migration_test="${module}/tests/integration/migration-test"

# A test file stands for its package.
package_of() {
    case "$1" in
        *.go) echo "${module}/$(dirname "$1")" ;;
        *) echo "$1" ;;
    esac
}

if [[ $# -gt 0 ]]; then
    # shellcheck disable=SC2207
    packages=($(for target in "$@"; do package_of "${target}"; done | sort -u))
else
    # shellcheck disable=SC2207
    packages=($(helpers/go-packages.sh migrations | awk -v upgrade="${migration_test}" \
        -v shard="${shard_index}" -v total="${shard_total}" '
            total == 1 { print; next }
            $0 == upgrade { if (shard == total) print; next }
            shard < total && (n++ % (total - 1)) == shard - 1'))
fi
[[ ${#packages[@]} -gt 0 ]] || { echo "No migration package for shard ${shard_index}/${shard_total}"; exit 0; }

if [[ -z "${FORGEJO_SHARD_CONFIG:-}" ]]; then
    export ENACT_FIXTURE_OWNER_PID="${ENACT_FIXTURE_OWNER_PID:-$$}"
    fixture_env="$(helpers/shard-config.sh acquire "${server:-${db}}" "${shard_index}" migrations --shell)"
    eval "${fixture_env}"
    trap 'status=$?; helpers/shard-config.sh release || { cleanup=$?; if (( status == 0 )); then status=$cleanup; fi; }; exit "${status}"' EXIT
fi
config="${FORGEJO_SHARD_CONFIG}"
run="${FORGEJO_SHARD_RUN}"
export PROJECT_ROOT="${PWD}" PROJECT_CONF="${config}"

# RACE_ENABLED=true, as upstream's Makefile reads it: every package and the dump upgrade
# under -race, which doesn't wait a second at each exit (GORACE, as the Makefile sets it).
flags=(-tags "${TEST_TAGS:-}")
race=""
if [[ "${RACE_ENABLED:-}" == true ]]; then
    flags+=(-race)
    race=".race"
    export GORACE="${GORACE:-atexit_sleep_ms=0}"
fi

individual=()
upgrade=false
for package in "${packages[@]}"; do
    if [[ "${package}" == "${migration_test}" ]]; then upgrade=true; else individual+=("${package}"); fi
done

if [[ ${#individual[@]} -gt 0 ]]; then
    echo "🧪 ${#individual[@]} migration package(s)${race:+ under -race}, shard ${shard_index}/${shard_total}"
    # The Makefile runs them one by one: their tests share the test database. Never Go's
    # cached result: the packages' TestMain reads PROJECT_CONF before m.Run, where Go's test
    # log doesn't see it, so a result cached on one database was replayed for the others.
    go test -p 1 -count=1 "${flags[@]}" "${individual[@]}"
fi
if [[ "${upgrade}" == true ]]; then
    echo "🧪 Upgrading old database dumps${race:+ under -race}"
    go test -c "${migration_test}" -o "migrations.${db}${run}${race}.test" "${flags[@]}"
    "./migrations.${db}${run}${race}.test"
fi
