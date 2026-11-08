#!/usr/bin/env bash
# Writes tests/<db>-<run>.ini: the integration tests' config for one of several runs side
# by side (shards, trace workers), with its own data directories, free ports, database,
# PostgreSQL role, and REPO_TEST_DIR (logs, the internal socket) when the caller exports one.
#
#   helpers/shard-config.sh <sqlite|pgsql|mysql> <index> [run]
#
# The run names the files, database and role: `shard<index>` unless given. Suites that run beside
# the integration shards (the migrations) name theirs apart.
set -euo pipefail

# Declarative fixtures return JSON; standalone helpers request shell assignments instead.
if [[ "${1:-}" == acquire || "${1:-}" == release ]]; then
    exec bash "$(dirname "$0")/shard-fixture.sh" "$@"
fi


# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

db="$1"
index="$2"
run="${3:-shard${index}}"
shard="-${run}"
config="${SHARD_DIR:+${SHARD_DIR}/${db}.ini}"
config="${config:-tests/${db}${shard}.ini}"

export TEST_MYSQL_DBNAME="testgitea_${run}?multiStatements=true"
export TEST_PGSQL_DBNAME="testgitea_${run}"
# Render tests/<db>.ini.tmpl directly into the shard's own ini (with data directories
# tests/integration/*-integration-<db>-<run>/ apart per run) without mutating
# tests/<db>.ini or contending on the ini-<db> lock.
sed \
    -e "s|{{TEST_MYSQL_HOST}}|${TEST_MYSQL_HOST:-mysql:3306}|g" \
    -e "s|{{TEST_MYSQL_DBNAME}}|${TEST_MYSQL_DBNAME}|g" \
    -e "s|{{TEST_MYSQL_USERNAME}}|${TEST_MYSQL_USERNAME:-root}|g" \
    -e "s|{{TEST_MYSQL_PASSWORD}}|${TEST_MYSQL_PASSWORD:-}|g" \
    -e "s|{{TEST_PGSQL_HOST}}|${TEST_PGSQL_HOST:-pgsql:5432}|g" \
    -e "s|{{TEST_PGSQL_DBNAME}}|${TEST_PGSQL_DBNAME}|g" \
    -e "s|{{TEST_PGSQL_USERNAME}}|${TEST_PGSQL_USERNAME:-postgres}|g" \
    -e "s|{{TEST_PGSQL_PASSWORD}}|${TEST_PGSQL_PASSWORD:-postgres}|g" \
    -e "s|{{TEST_PGSQL_SCHEMA}}|${TEST_PGSQL_SCHEMA:-gtestschema}|g" \
    -e "s|{{REPO_TEST_DIR}}|${REPO_TEST_DIR:-${PWD}/}|g" \
    -e "s|{{PROJECT_ROOT}}|${PWD}|g" \
    -e "s|{{TEST_LOGGER}}|${TEST_LOGGER:-test,file}|g" \
    -e "s|{{TEST_TYPE}}|${TEST_TYPE:-integration}|g" \
    -e "s|{{TEST_STORAGE_TYPE}}|${TEST_STORAGE_TYPE:-minio}|g" \
    -e "s|{{TEST_S3_HOST}}|${TEST_S3_HOST:-minio:9000}|g" \
    -e "s|-integration-${db}/|-integration-${db}${shard}/|g" \
    "tests/${db}.ini.tmpl" > "${config}"
# The ports are the caller's (integration.sh, go-migrations.sh) for its life.
PORTS_OWNER="${PORTS_OWNER:-${PPID}}" helpers/free-ports.sh "${config}"

# PostgreSQL: a role of its own too. The migration harnesses run `ALTER USER <user> SET
# search_path` before each test, which updates one server-wide row per role
# (pg_db_role_setting): shards sharing a role failed with "tuple concurrently updated".
# Upstream CI runs one job per server. A superuser, as upstream's `postgres` is: the tests
# drop and create their database, which an earlier run's role may own.
if [[ "${db}" == pgsql ]]; then
    eval "$(awk -F ' *= *' '/^\[/ { section = $0 } section == "[database]" && $1 ~ /^(HOST|USER|PASSWD)$/ { print "pg_" $1 "=\"" $2 "\"" }' "${config}")"
    role="forgejo_${run}"
    PGPASSWORD="${pg_PASSWD}" psql -q -v ON_ERROR_STOP=1 -h "${pg_HOST%:*}" -p "${pg_HOST##*:}" \
        -U "${pg_USER}" -d postgres -c "DO \$\$ BEGIN CREATE ROLE \"${role}\" SUPERUSER LOGIN PASSWORD '${pg_PASSWD}';
            EXCEPTION WHEN duplicate_object OR unique_violation THEN NULL; END \$\$"
    # A connection that names no database lands on the role's name (the harnesses' reset
    # does): upstream's `postgres` has its database, so this role gets one too.
    pg=(psql -q -v ON_ERROR_STOP=1 -h "${pg_HOST%:*}" -p "${pg_HOST##*:}" -U "${pg_USER}" -d postgres)
    if [[ "$(PGPASSWORD="${pg_PASSWD}" "${pg[@]}" -tAc "SELECT 1 FROM pg_database WHERE datname = '${role}'")" != 1 ]]; then
        PGPASSWORD="${pg_PASSWD}" "${pg[@]}" -c "CREATE DATABASE \"${role}\" OWNER \"${role}\""
    fi
    awk -v role="${role}" '/^\[/ { section = $0 } section == "[database]" && $1 == "USER" { $0 = "USER     = " role } { print }' \
        "${config}" > "${config}.tmp" && mv "${config}.tmp" "${config}"
fi
