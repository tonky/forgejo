package forgejo

import (
	"enact.dev/schema"
	"forgejo.org/enact:enve"
)

let J = pipeline.#jobs

let checks = {
	name:      "checks"
	select:    [J.lint, J.fmt, J.checks, J.typecheck, J.audit]
	fail_fast: false
}
let tests = {
	name:      "test"
	matrix:    true
	fail_fast: false
	services:  "on_demand"
}

forgejo: services: enve.profiles.dev.services & {
	postgres: enact: kind: "postgres"
	mysql: enact: kind:    "mysql"
	mariadb_106: enact: {
		kind: "mysql"
		export_env: TEST_MARIADB106_HOST: "{host}:{port}"
	}
	mariadb_118: enact: {
		kind: "mysql"
		export_env: TEST_MARIADB118_HOST: "{host}:{port}"
	}
	seaweedfs: enact: {
		kind:    "object_storage"
		buckets: ["gitea"]
		export_env: TEST_MINIO_ENDPOINT: "{host}:{port}/"
	}
	opensearch: enact: {
		kind: "elasticsearch"
		export_env: TEST_ELASTICSEARCH_URL: "http://{host}:{port}"
	}
	redis: enact: kind:  "redis"
	valkey: enact: kind: "redis"
	garnet: enact: kind: "redis"
}

pipeline: schema.#Pipeline & {
	services: forgejo.services
	toolchain: node: {
		package_manager: "npm"
		install:         "helpers/exclusive.sh node_modules make --no-print-directory node_modules"
		outputs:         ["node_modules/.package-lock.json", "node_modules/.bin/vitest", "node_modules/@primer/octicons"]
	}
	ci: {
		rerun: {
			labels:          ["rerun", "showcase"]
			branch_prefixes: ["showcase/"]
		}
		concurrency: max_parallel_jobs: 16
		remote_cache: {
			secrets: {bucket: "R2_BUCKET", access_key_id: "R2_ACCESS_KEY_ID", secret_access_key: "R2_SECRET_ACCESS_KEY"}
			public_url: "https://pub-30fd937eb7634039b8c49d49bfec91a9.r2.dev"
			public_key: "enve-r2-1:ckHPTeWVef6mba+1AwWHjKYCsUWKPfP9IXPm5YXNoHg="
			repo:       "tonky/forgejo"
			branch:     "perf/ci-showcase"
		}
		// Runner sizes within ibp8/mac1/l7 shared host budget (agentic/KNOWLEDGE.md tonky-ci).
		workers: {
			standard: {
				labels:          ["self-hosted", "Linux", "X64", "tonky-ci", "ibp8"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				timeout_minutes: 120
				pool: {
					cpus:      14
					memory_mb: 28672
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			arm64: {
				labels:          ["self-hosted", "Linux", "ARM64", "tonky-ci", "mac1"]
				tier:            "dedicated"
				available:       1
				cost_per_min:    0.010
				timeout_minutes: 120
				pool: {
					cpus:      16
					memory_mb: 36864
					floor: {cpus: 4, memory_mb: 8192} // mac1 under its lane clamp (KNOWLEDGE `tonky-ci` load clamp)
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
						"tonky-ci-l": {cpus: 6, memory_mb: 13312}
					}
				}
			}
			l7: {
				// A second X64 host (8c/14G): s and m only; a gate lane holding l7 drains it to zero.
				// A size costs the rate times its share of the largest size: 0.006 prices its m as
				// the 13 GB pools price theirs.
				labels: ["self-hosted", "Linux", "X64", "tonky-ci", "l7"], tier: "dedicated", available: 1, cost_per_min: 0.006, timeout_minutes: 120
				pool: {
					cpus: 8, memory_mb: 12288
					sizes: {
						"tonky-ci-s": {cpus: 2, memory_mb: 4096}
						"tonky-ci-m": {cpus: 4, memory_mb: 8192}
					}
				}
			}
		}
	}
	workflows: {
		ci: {
			layout: "staged", services: "on_demand"
			concurrency: {scope: "branch", cancel_in_progress: true}
			triggers: {
				push: branches:         ["main", "perf/ci-showcase"]
				pull_request: branches: ["main", "perf/ci-showcase", "enact-showcase"]
			}
			stages: [
				checks,
				tests & {select: [J.test, J.build]},
			]
		}
		local: {
			services: "on_demand"
			stages: [
				{name: "checks", select: [J.lint, J.fmt, J.checks, J.typecheck, J.audit]},
				{name: "test", select: [J.test, J.build]},
			]
		}
	}
}
