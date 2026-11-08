#!/usr/bin/env bash
# The search server upstream CI's unit tests index issues into (TEST_ELASTICSEARCH_URL):
# bitnami/elasticsearch:7 there, single node, 512 MB of heap. Elasticsearch is unfree in
# nixpkgs, so no binary cache has it; OpenSearch, its Apache-licensed fork, answers the
# same REST API and passes the same tests, as the enve service `opensearch`.
#
#   helpers/opensearch.sh   the server, in the foreground on 127.0.0.1:$PORT (transport
#                           on $PORT_TRANSPORT), its data and config under $DATA_DIR
#
# nixpkgs' package reads its configuration from the store, read-only: the service copies
# it into its data directory and sets what the container's environment set there.
set -euo pipefail

home="$(cd "$(dirname "$(command -v opensearch)")/.." && pwd -P)"
conf="${DATA_DIR}/config"
rm -rf "${conf}"
mkdir -p "${DATA_DIR}/data" "${DATA_DIR}/logs" "${DATA_DIR}/tmp"
cp -R "${home}/config" "${conf}"
chmod -R u+w "${conf}"

# The JVM options name logs/ and data/ relative to the store's install, read-only here;
# GC logging goes nowhere a test reads.
sed -e '/-Xlog:gc/d' \
    -e "s#HeapDumpPath=data#HeapDumpPath=${DATA_DIR}/data#" \
    -e "s#ErrorFile=logs/#ErrorFile=${DATA_DIR}/logs/#" \
    "${home}/config/jvm.options" > "${conf}/jvm.options"
# ES_JAVA_OPTS upstream sets: -Xms512m -Xmx512m.
printf -- '-Xms512m\n-Xmx512m\n' > "${conf}/jvm.options.d/heap.options"

# discovery.type upstream sets; loopback keeps the production bootstrap checks off. The
# security plugin (TLS and users by default) stays off: bitnami's Elasticsearch 7 has none.
# The disk watermarks judge the host's whole filesystem, not what the tests write: past 90%
# used OpenSearch blocks index creation (403 create-index blocked), past 95% it makes the
# index read-only (429 flood-stage), and the indexer tests fail on a full developer disk.
cat > "${conf}/opensearch.yml" <<EOF
cluster.name: forgejo-test
discovery.type: single-node
network.host: 127.0.0.1
http.port: ${PORT}
transport.port: ${PORT_TRANSPORT}
path.data: ${DATA_DIR}/data
path.logs: ${DATA_DIR}/logs
plugins.security.disabled: true
cluster.routing.allocation.disk.threshold_enabled: false
EOF

export OPENSEARCH_PATH_CONF="${conf}"
export OPENSEARCH_TMPDIR="${DATA_DIR}/tmp"
exec opensearch
