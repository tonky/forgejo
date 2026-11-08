#!/usr/bin/env bash
# Acquire/release the config, ports, data and database owned by one Forgejo shard.
set -euo pipefail
cd "$(dirname "$0")/.."

release() {
    [[ -n "${FORGEJO_SHARD_CONFIG:-}" && -f "${FORGEJO_SHARD_CONFIG}" ]] || return 0
    local config="${FORGEJO_SHARD_CONFIG}" first db_HOST db_NAME db_USER db_PASSWD status=0
    first="$(awk -F ' *= *' '$1 == "HTTP_PORT" {print $2; exit}' "${config}")"
    if [[ -n "${first}" ]]; then
        "${ENACT_EXE:-${ENACT_BIN:-enact}}" helper free-ports --owner "${ENACT_FIXTURE_OWNER_PID:-${PPID}}" --release "${first}" 2 || status=$?
    fi
    if [[ "${FORGEJO_SHARD_DB}" != sqlite ]]; then
        eval "$(awk -F ' *= *' '/^\[/ { section = $0 } section == "[database]" && $1 ~ /^(HOST|NAME|USER|PASSWD)$/ { print "db_" $1 "=\"" $2 "\"" }' "${config}")"
        if [[ "${FORGEJO_SHARD_DB}" == pgsql ]]; then
            # Setup may fail before replacing USER in the ini; never drop the admin role.
            db_USER="forgejo_${FORGEJO_SHARD_RUN}"
            local pg=(psql -q -v ON_ERROR_STOP=1 -h "${db_HOST%:*}" -p "${db_HOST##*:}" -U "${TEST_PGSQL_USERNAME:-postgres}" -d postgres)
            PGPASSWORD="${db_PASSWD}" "${pg[@]}" -c "DROP DATABASE IF EXISTS \"${db_NAME}\" WITH (FORCE)" || status=$?
            PGPASSWORD="${db_PASSWD}" "${pg[@]}" -c "DROP DATABASE IF EXISTS \"${db_USER}\" WITH (FORCE)" || status=$?
            PGPASSWORD="${db_PASSWD}" "${pg[@]}" -c "DROP ROLE IF EXISTS \"${db_USER}\"" || status=$?
        else
            MYSQL_PWD="${db_PASSWD}" mysql -h "${db_HOST%:*}" -P "${db_HOST##*:}" -u "${db_USER}" -e "DROP DATABASE IF EXISTS \`${db_NAME%%\?*}\`" || status=$?
        fi
    fi
    rm -rf -- "tests/integration/forgejo-integration-${FORGEJO_SHARD_DB}-${FORGEJO_SHARD_RUN}" \
        "tests/integration/gitea-integration-${FORGEJO_SHARD_DB}-${FORGEJO_SHARD_RUN}" "${REPO_TEST_DIR}"
    rm -f -- "${config}"
    return "${status}"
}

if [[ "$1" == release ]]; then release; exit; fi
[[ "$1" == acquire && $# -ge 4 ]] || { echo 'usage: shard-config.sh acquire <db> <index> <integration|migrations> [--shell] | release' >&2; exit 2; }
db="$2" index="$3" suite="$4"
[[ "${suite}" == integration || "${suite}" == migrations ]] || exit 2
if [[ "${db}" == mariadb_* ]]; then
    port_var="ENVE_SERVICE_$(echo "${db}" | tr '[:lower:]' '[:upper:]')_PORT"
    export TEST_MYSQL_HOST="127.0.0.1:${!port_var:?MariaDB is not running}"
    db=mysql
fi
[[ "${db}" == sqlite || "${db}" == mysql || "${db}" == pgsql ]] || exit 2
unset SHARD_DIR
# Keep Unix socket paths below the platform limit, even with macOS's long TMPDIR.
export REPO_TEST_DIR="$(mktemp -d /tmp/fj.XXXXXX)/"
export FORGEJO_SHARD_RUN="${suite}${index}_$(basename "${REPO_TEST_DIR%/}" | tr . _)"
export FORGEJO_SHARD_DB="${db}"
export FORGEJO_SHARD_CONFIG="tests/${db}-${FORGEJO_SHARD_RUN}.ini"
trap 'status=$?; if (( status != 0 )); then release >&2 || true; rm -rf -- "${REPO_TEST_DIR}"; fi' EXIT
if [[ "${db}" == pgsql && "${suite}" == integration ]]; then
    export TEST_S3_HOST="${TEST_S3_HOST:-127.0.0.1:${ENVE_SERVICE_SEAWEEDFS_PORT:?SeaweedFS is not running}}"
fi
PORTS_OWNER="${ENACT_FIXTURE_OWNER_PID:-${PPID}}" helpers/shard-config.sh "${db}" "${index}" "${FORGEJO_SHARD_RUN}" >&2
if [[ "${5:-}" == --shell ]]; then
    for key in FORGEJO_SHARD_CONFIG FORGEJO_SHARD_RUN FORGEJO_SHARD_DB REPO_TEST_DIR; do printf 'export %s=%q\n' "${key}" "${!key}"; done
else
    # All values consist of fixed prefixes and mktemp's alphanumeric suffix.
    context="$(printf '{"env":{"FORGEJO_SHARD_CONFIG":"%s","FORGEJO_SHARD_RUN":"%s","FORGEJO_SHARD_DB":"%s","REPO_TEST_DIR":"%s"},"files":["%s"]}' "${FORGEJO_SHARD_CONFIG}" "${FORGEJO_SHARD_RUN}" "${db}" "${REPO_TEST_DIR}" "${FORGEJO_SHARD_CONFIG}")"
    if [[ -n "${ENACT_FIXTURE_CONTEXT_FILE:-}" ]]; then printf '%s\n' "${context}" > "${ENACT_FIXTURE_CONTEXT_FILE}"; else printf '%s\n' "${context}"; fi
fi
