package enve

import (
	"github.com/tonky/enve/schema/v1:schema"
	"github.com/tonky/enve/pkgs:pkgs"
)

// Forgejo toolchain: Go 1.27.3, Node 24, git+LFS, gpg, and rootless service daemons.
profiles: dev: schema.#Profile & {
	name: "forgejo-dev"
	tools: [
		schema.#ArchiveBuildSpec & {
			pname:   "go"
			version: "1.27.3"
			src: {
				"aarch64-darwin": "https://dl.google.com/go/go1.27.3.darwin-arm64.tar.gz"
				"aarch64-linux":  "https://dl.google.com/go/go1.27.3.linux-arm64.tar.gz"
				"x86_64-linux":   "https://dl.google.com/go/go1.27.3.linux-amd64.tar.gz"
			}
			sha256: {
				"aarch64-darwin": "dd3908cf20959d798c1e06ebe5b72213f0505ce01373b40ce3110975a6cd99c2"
				"aarch64-linux":  "a06e99309dbcbdca1a8ccd2282c3ee146e55930886e26b4f1193269587165f49"
				"x86_64-linux":   "65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40"
			}
			installPhase: "mkdir -p \"$out\" && cp -R ./. \"$out/\" && \"$out/bin/go\" version"
		},
		pkgs.nodejs & {version: "24"},
		pkgs.gcc,
		pkgs.git,
		"git-lfs", "gnupg", "bash", "openssh", "coreutils", "findutils",
		"gnugrep", "gnumake", "gnused", "gawk", "diffutils", "flock",
		"govulncheck", "curl", "unzip", "jq", "semgrep",
		pkgs.postgresql_16,
		pkgs.mysql & {version: "8.4"},
		pkgs.redis,
		pkgs.valkey,
		"renovate",
		pkgs.#PlaywrightBrowsers & {version: "1.62.1", features: ["firefox", "chromium-headless-shell"]},
	]
	services: {
		postgres: {
			port: 5437
			lifecycle: init: "initdb -D \"$DATA_DIR\" -U postgres --auth-local=trust --auth-host=trust --encoding=UTF8 --locale=C --locale-provider=icu --icu-locale=en-US-u-ka-shifted"
			command: "postgres -D \"$DATA_DIR\" -k \"$SOCKET_DIR\" -p $PORT -c fsync=off -c full_page_writes=off -c synchronous_commit=off"
			lifecycle: postStart: "psql -h 127.0.0.1 -p $PORT -U postgres -c \"ALTER USER postgres PASSWORD 'postgres'\""
		}
		mysql: {
			port:    3326
			command: "mysqld --no-defaults --datadir=\"$DATA_DIR\" --port=$PORT --socket=\"$SOCKET_DIR/mysql.sock\" --pid-file=\"$DATA_DIR/mysqld.pid\" --mysqlx=OFF --bind-address=127.0.0.1 --innodb-adaptive-flushing=OFF --innodb-flush-log-at-trx-commit=0 --innodb-flush-log-at-timeout=30 --innodb-flush-method=nosync --innodb-fsync-threshold=1000000000 --disable-log-bin"
		}
		let mariadbd = "mariadbd --no-defaults --datadir=\"$DATA_DIR\" --port=$PORT --socket=\"$SOCKET_DIR/mysql.sock\" --pid-file=\"$DATA_DIR/mariadbd.pid\" --bind-address=127.0.0.1 --table-definition-cache=16384 --table-open-cache=16384 --debug-no-sync --innodb-flush-log-at-trx-commit=0 --innodb-flush-method=nosync"
		mariadb_106: pkgs.#MariaDBService & {
			package: "mariadb_106"
			port:    3327
			command: mariadbd
		}
		mariadb_118: pkgs.#MariaDBService & {
			package: "mariadb_118"
			port:    3328
			command: mariadbd
		}
		redis: port:  6387
		valkey: port: 6388
		garnet: {package: "garnet", port: 6389, command: "GarnetServer --bind 127.0.0.1 --port $PORT"}
		opensearch: {
			package: "opensearch", port: 19200, ports: transport: 19300
			command: "helpers/opensearch.sh", timeout: "120s"
			readinessProbe: command: "curl -sf http://127.0.0.1:$PORT/"
		}
		openldap: {
			package: "openldap", port: 10389, command: "helpers/openldap.sh start"
			lifecycle: postStart: "helpers/openldap.sh seed"
		}
		seaweedfs: {
			port: 19010
			ports: {master: 19011, volume: 19012, filer: 19013, s3_grpc: 29010, master_grpc: 29011, volume_grpc: 29012, filer_grpc: 29013}
			command: "weed server -ip=127.0.0.1 -master.raftHashicorp -s3 -s3.port=$PORT -s3.port.grpc=$PORT_S3_GRPC -s3.config=\"$DATA_DIR/s3.json\" -s3.domainName=localhost -master.port=$PORT_MASTER -master.port.grpc=$PORT_MASTER_GRPC -volume.port=$PORT_VOLUME -volume.port.grpc=$PORT_VOLUME_GRPC -filer.port=$PORT_FILER -filer.port.grpc=$PORT_FILER_GRPC -s3.port.iceberg=0 -s3.port.lance=0 -volume.max=1000 -master.volumeSizeLimitMB=64 -dir=\"$DATA_DIR\""
			files: "s3.json": """
				{"identities": [{"name": "forgejo", "credentials": [{"accessKey": "123456", "secretKey": "12345678"}], "actions": ["Admin", "Read", "List", "Tagging", "Write"]}]}
				"""
			environment: WEED_MASTER_VOLUME_GROWTH_COPY_1: "1"
		}
	}
	environment: {
		GOTOOLCHAIN:     "local"
		CGO_ENABLED:     "1"
		CC:  "gcc"
		CXX: "g++"
		TZ:              "UTC"
		TEST_TAGS:   "sqlite sqlite_unlock_notify"
		TEST_PGSQL_HOST: "127.0.0.1:${ENVE_SERVICE_POSTGRES_PORT}"
		TEST_MYSQL_HOST: "127.0.0.1:${ENVE_SERVICE_MYSQL_PORT}"
	}
}
