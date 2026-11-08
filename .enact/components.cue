package forgejo

import (
	"list"

	"enact.dev/schema"
)

let goSources = ["build/**", "cmd/**", "contrib/environment-to-ini/**", "models/**", "modules/**", "routers/**", "services/**", "main.go"]
let goTrees = ["build", "cmd", "contrib/environment-to-ini", "models", "modules", "routers", "services"]
let fixtureSources = ["tests/testdata/**", "tests/gitea-repositories-meta/**", "tests/gitea-lfs-meta/**"]
let fixtureTrees = ["tests/testdata", "tests/gitea-repositories-meta", "tests/gitea-lfs-meta"]
let backendTestTrees = ["tests/forgery", "tests/fuzz", "tests/internaltest"]
let packageTestdata = "{build,cmd,models,modules,routers,services}/**/testdata/**"
let goLintConfigs = [".golangci.yml", ".deadcode-out", ".mockery.yml", ".spectral.yaml"]

let migrationSuites = {
	migrations: "sqlite", "migrations-mysql": "mysql", "migrations-pgsql": "pgsql"
	"migrations-mariadb106": "mariadb_106", "migrations-mariadb118": "mariadb_118"
}
let integrationSuites = {
	integration: "sqlite", "integration-mysql": "mysql", "integration-pgsql": "pgsql"
	"integration-mariadb106": "mariadb_106", "integration-mariadb118": "mariadb_118"
}
let databaseOf = {sqlite: "sqlite", mysql: "mysql", pgsql: "pgsql", mariadb_106: "mysql", mariadb_118: "mysql"}
let pushOnly = {sqlite: false, mysql: false, pgsql: false, mariadb_106: true, mariadb_118: true}
let cacherSuites = {"remote-cacher-redis": "redis", "remote-cacher-valkey": "valkey", "remote-cacher-garnet": "garnet"}

let fixtures = {for db in ["sqlite", "mysql", "pgsql", "mariadb_106", "mariadb_118"] {
	(db): {
		allow_env: ["FORGEJO_SHARD_*", "REPO_TEST_DIR"]
		owned_paths: ["tests"]
		inputs: ["tests/\(databaseOf[db]).ini.tmpl", "helpers/shard-config.sh", "helpers/shard-fixture.sh", "helpers/free-ports.sh"]
		timeout: "60s"
	}
}}

let migrationNames = [for name, _ in migrationSuites {name}]
let integrationNames = [for name, _ in integrationSuites {name}]
let cacherNames = [for name, _ in cacherSuites {name}]

let databaseServices = {
	sqlite:      {}
	mysql:       {mysql: forgejo.services.mysql}
	pgsql:       {postgres: forgejo.services.postgres}
	mariadb_106: {mariadb_106: forgejo.services.mariadb_106}
	mariadb_118: {mariadb_118: forgejo.services.mariadb_118}
}
let integrationServices = databaseServices & {pgsql: {
	seaweedfs: forgejo.services.seaweedfs
	openldap:  forgejo.services.openldap
}}
let integrationServiceHelpers = {
	sqlite: [], mysql: [], pgsql: ["helpers/openldap.sh", "helpers/openldap-seed.ldif"], mariadb_106: [], mariadb_118: []
}

let raceEnabled = {RACE_ENABLED: "true"}
let raceEnv = {sqlite: {}, mysql: {}, pgsql: raceEnabled, mariadb_106: {}, mariadb_118: {}}
let raceResources = {cpus: 0.75, memory_mb: 2560}
let plainResources = {cpus: 0.5, memory_mb: 1536}
let buildResources = {cpus: 2, memory_mb: 4096}
let recordResources = {cpus: 1, memory_mb: 3072}
let integrationResources = {sqlite: plainResources, mysql: plainResources, pgsql: raceResources, mariadb_106: plainResources, mariadb_118: plainResources}
let integrationBinary = {
	sqlite: "integrations.sqlite", mysql: "integrations.mysql", pgsql: "integrations.pgsql.race"
}
let integrationBuildFlags = {
	sqlite: " -tags \"sqlite sqlite_unlock_notify\"", mysql: "", pgsql: " -race"
}
let integrationBuildKey = list.Concat([goSources, [
	"go.mod", "go.sum", "tests/*.go", "tests/forgery/**", "tests/internaltest/**",
	"tests/integration/**", "helpers/go-test-binary.sh",
]])

let integrationSplitTargets = [
	"TestGit", "TestGit/HTTP", "TestGit/SSH",
	"TestInstanceSigning", "TestInstanceSigning/PGP", "TestInstanceSigning/SSH",
	"TestPullRequestCommentPlacement", "TestActionsRunsEvaluateIf",
	"TestActionsScheduleDetection_PullRequest", "TestAPIIssueTemplateList",
	"TestGitPush", "TestGitPush/sha1", "TestGitPush/sha256",
	"TestLinguistSupport", "TestOrgProfile",
	"TestPullAutoMergeAfterCommitStatusSucceed",
	"TestPullReviewApplySuggestion", "TestPullReviewApplySuggestionBatch",
	"TestPullReviewSuggestionRender", "TestUserProfile",
]

let integrationTargets = {
	fallback:         "none"
	tests:            ["tests/integration/*_test.go"]
	incidental_reads: ["options/**", "public/**", "templates/**", "tests/gitea-repositories-meta/**", "tests/gitea-lfs-meta/**"]
	shard_order:      "contiguous"
	split_targets:    integrationSplitTargets
	rules: [
		{match: [packageTestdata], action: "ignore"},
		{match: ["**/*.go"], engine: "reach"},
	]
}
let fromSqlite = integrationTargets & {footprints_from: "integration:test"}
let integrationScope = {sqlite: integrationTargets, mysql: fromSqlite, pgsql: fromSqlite, mariadb_106: fromSqlite, mariadb_118: fromSqlite}
let goUnitTags = ["race", "sqlite", "sqlite_unlock_notify"]
let goMigrationsPattern = "models/(gitea_migrations|forgejo_migrations_legacy|forgejo_migrations)(/|$)|tests/integration/migration-test$"

let migrationTargets = {
	fallback: "none"
	tests: ["models/{gitea_migrations,forgejo_migrations_legacy,forgejo_migrations}/**/*_test.go", "tests/integration/migration-test/*_test.go"]
	rules: [{match: ["**/*.go", packageTestdata, "tests/integration/migration-test/**"], engine: "go", keep: "^${module}/(\(goMigrationsPattern))"}]
}

pipeline: schema.#Pipeline & {
	name:        "forgejo"
	description: "Forgejo, a self-hosted lightweight software forge (enact + enve accelerated)"
	workspace_scope: include: [
		".enact", "cue.mod", "enve.cue", "enve.lock", "bin", "helpers",
		".github", ".forgejo", ".editorconfig", ".gitattributes", ".gitignore", "Makefile",
	]
	analysis: durations: [".enact/integration-durations.json"]

	caches: {
		go_build: {
			paths: ["~/.cache/go-build", "~/go/pkg/mod"], key: ["go.sum"], scope: "task"
			used_by: components: list.Concat([["templates", "base", "backend", "e2e"], migrationNames, integrationNames, cacherNames])
		}
		npm: {
			paths: ["~/.npm"], key: ["package-lock.json"], scope: "task"
			used_by: components: ["js-root", "templates", "frontend", "e2e"]
		}
		govulndb: {
			paths: ["~/.cache/govulndb"]
			used_by: {components: ["backend"], jobs: [pipeline.#jobs.audit]}
		}
	}

	components: {
		root: {
			title: "Makefile, toolchain and pipeline", root: "."
			watch_paths: [
				"Makefile", "BSDmakefile", "enve.cue", "enve.lock", ".enact/**", "cue.mod/**",
				"bin/**", "tools/*.sh", ".github/workflows/**", ".forgejo/workflows/**", ".editorconfig",
				"helpers/exclusive.sh", "helpers/fmt-check.sh", "helpers/with-node-modules.sh",
			]
		}
		"go-root": {
			title: "Go module and Go helpers", root: ".", depends_on: ["root"]
			watch_paths: [
				"go.mod", "go.sum", "helpers/go-packages.sh", "helpers/go-unit.sh",
				"helpers/go-test-binary.sh", "helpers/shard-config.sh", "helpers/shard-fixture.sh", "helpers/free-ports.sh",
			]
		}
		"js-root": {
			title: "npm package and Node version", technology: "typescript", root: ".", depends_on: ["root"]
			watch_paths: ["package.json", "package-lock.json", ".npmrc", ".node-version", "helpers/lockfile-check.sh"]
			workspace_scope: include: ["package.json", "package-lock.json", ".npmrc", ".node-version"]
			jobs: checks: tasks: [{name: "npm lockfile", command: "helpers/lockfile-check.sh"}]
		}
		templates: {
			title: "Templates, locales and static assets", kind: "library", domain: "frontend", technology: "typescript", root: ".", depends_on: ["root"]
			watch_paths: ["templates/**", "options/**", "public/**", "custom/**", "assets/**"]
			workspace_scope: include: ["templates", "options", "public", "custom", "assets", "package.json", "package-lock.json", ".npmrc", ".node-version"]
			lint: "make lint-css lint-editorconfig"
			fmt: {
				lock:            "fmt"
				expect_no_drift: true
				command:         "helpers/exclusive.sh fmt helpers/fmt-check.sh"
			}
			jobs: checks: tasks: [{name: "Locales", command: "make lint-locale lint-locale-usage"}]
		}
		base: {
			title: "Go models and modules", kind: "library", domain: "backend", technology: "go", root: "."
			watch_paths: list.Concat([["models/**", "modules/**", "tests/unittest.ini.tmpl", "helpers/opensearch.sh"], fixtureSources])
			workspace_scope: include: list.Concat([["models", "modules"], fixtureTrees])
			depends_on: ["go-root", "templates"]
			resources:  {cpus: 4, memory_mb: 8192}, shards: 2
			services:   {seaweedfs: forgejo.services.seaweedfs, opensearch: forgejo.services.opensearch}
			uses: [
				{protocol: schema.#Protocol.Http, target: "seaweedfs", title: "LFS & package object storage"},
				{protocol: schema.#Protocol.Http, target: "opensearch", title: "Code & issue search indexing"},
			]
			test:       {command: "helpers/go-unit.sh base {shard_index} {shard_total} {targets}", timeout: "60m", expect_no_drift: true}
			target_scope: {
				fallback: "none", tests: ["{models,modules}/**/*_test.go"], go_tags: goUnitTags
				rules: [{match: ["**/*.go", packageTestdata], engine: "go", keep: "^${module}/(models|modules)(/|$)", drop: "^${module}/(\(goMigrationsPattern))"}]
			}
		}
		backend: {
			title: "Go backend", kind: "service", domain: "backend", technology: "go", root: ".", depends_on: ["base"]
			uses: [{protocol: schema.#Protocol.Ipc, target: "base", title: "Calls models & modules"}]
			watch_paths: list.Concat([goSources, goLintConfigs, [
				"tests/*.go", "tests/install.ini.tmpl", "tests/forgery/**", "tests/fuzz/**",
				"tests/internaltest/**", "helpers/tidy-check.sh", "helpers/security-check.sh",
			]])
			workspace_scope: include: list.Concat([goTrees, backendTestTrees])
			resources: {cpus: 4, memory_mb: 8192}, shards: 2
			lint: {command: "make lint-go", timeout: "20m"}
			fmt: {
				lock:            "fmt"
				expect_no_drift: true
				command:         "helpers/exclusive.sh fmt helpers/fmt-check.sh"
			}
			jobs: checks: {
				resources: {cpus: 4, memory_mb: 6144}
				tasks: [
					{name: "go vet", command: "make lint-go-vet"},
					{name: "go.mod tidy", command: "helpers/tidy-check.sh"},
					{name: "Swagger spec", lock: "swagger", command: "helpers/exclusive.sh swagger make swagger-check swagger-validate"},
					{name: "Swagger lint", lock: "swagger", command: "helpers/with-node-modules.sh helpers/exclusive.sh swagger make --no-print-directory lint-swagger"},
					{name: "Repository lints", command: "make lint-editorconfig lint-locale lint-locale-usage lint-disposable-emails lint-single-response"},
				]
			}
			jobs: audit: {
				direct: true, resources: {cpus: 2, memory_mb: 4096}
				tasks: [{name: "govulncheck", command: "helpers/security-check.sh", timeout: "20m"}]
			}
			test: {command: "helpers/go-unit.sh backend {shard_index} {shard_total} {targets}", timeout: "60m", expect_no_drift: true}
			target_scope: {
				fallback: "none"
				tests:    ["{build,cmd,contrib,routers,services}/**/*_test.go", "tests/{forgery,fuzz,internaltest}/**/*_test.go"]
				go_tags:  goUnitTags
				rules: [
					{match: ["**/*.go", packageTestdata], engine: "go", drop: "^${module}/(models|modules|\(goMigrationsPattern)|tests$|tests/integration(/|$)|tests/e2e$)"},
					{match: goLintConfigs, action: "ignore"},
				]
			}
		}

		for name, db in migrationSuites {
			(name): {
				title: "Database migrations (\(db))", kind: "verification", domain: "verification", technology: "go", root: ".", depends_on: ["go-root"]
				watch_paths: list.Concat([goSources, ["tests/integration/migration-test/**", "tests/\(databaseOf[db]).ini.tmpl", "helpers/go-migrations.sh"]])
				workspace_scope: include: list.Concat([goTrees, fixtureTrees, backendTestTrees, ["tests/integration/migration-test"]])
				resources: {cpus: 2, memory_mb: 4096}, services: databaseServices[db]
				let migrate = {
					command: "helpers/go-migrations.sh \(db) {shard_index} {shard_total} {targets}"
					timeout: "30m", env: raceEnv[db]
				}
				if !pushOnly[db] {
					jobs: test: {
						shards: 3, target_scope: migrationTargets
						fixture: fixtures[db] & {release: "helpers/shard-config.sh release", setup: "helpers/shard-config.sh acquire \(db) {shard_index} migrations"}
						tasks: [migrate]
					}
				}
				if pushOnly[db] {
					jobs: mariadb: {
						shards: 3, resources: {cpus: 2, memory_mb: 4096}, target_scope: migrationTargets
						fixture: fixtures[db] & {release: "helpers/shard-config.sh release", setup: "helpers/shard-config.sh acquire \(db) {shard_index} migrations"}
						tasks: [migrate & {name: "migrations on \(db)"}]
					}
				}
			}
		}

		migrations: jobs: race: {
			fixture: fixtures.sqlite & {release: "helpers/shard-config.sh release", setup: "helpers/shard-config.sh acquire sqlite {shard_index} migrations"}
			shards: 3, resources: {cpus: 2, memory_mb: 4096}, target_scope: migrationTargets
			tasks: [{
				name: "migrations under -race", timeout: "30m", env: raceEnabled
				command: "helpers/go-migrations.sh sqlite {shard_index} {shard_total} {targets}"
			}]
		}

		for name, server in cacherSuites {
			(name): {
				title: "Remote cache tests (\(server))", kind: "verification", domain: "verification", technology: "go", root: ".", depends_on: ["go-root"]
				watch_paths: goSources
				workspace_scope: include: list.Concat([goTrees, fixtureTrees])
				resources: {cpus: 2, memory_mb: 3072}, shards: 1
				services: (server): forgejo.services[server] & {enact: primary: true}
				test: {command: "helpers/go-unit.sh \(name) {shard_index} {shard_total} {targets}", timeout: "30m", expect_no_drift: true}
				target_scope: {
					fallback: "none", tests: ["modules/{cache,nosql,session,queue}/*_test.go"], go_tags: goUnitTags
					rules: [{match: ["**/*.go", packageTestdata], engine: "go", keep: "^${module}/modules/(cache|nosql|session|queue)$"}]
				}
			}
		}

		for name, db in integrationSuites {
			(name): {
				title: "Integration tests (\(db))", kind: "verification", domain: "verification", technology: "go", root: "tests/integration"
				if !pushOnly[db] {
					depends_on: ["base"]
				}
				if pushOnly[db] {
					depends_on: ["base", "integration-mysql"]
				}
				watch_paths: list.Concat([goSources, fixtureSources, [
					"tests/\(databaseOf[db]).ini.tmpl", "tests/*.go", "tests/forgery/**",
					"tests/internaltest/**", "tests/integration/**", "helpers/integration.sh",
					"helpers/integration-tests.sh", "helpers/integration-split-tests",
					"helpers/integration-durations.sh", "helpers/trace-integration.sh",
				], integrationServiceHelpers[db]])
				workspace_scope: include: list.Concat([goTrees, fixtureTrees, ["tests/forgery", "tests/internaltest", "tests/integration"]])
				resources: integrationResources[db], services: integrationServices[db]
				let integrate = {
					command: "../../helpers/integration.sh \(db) {shard_index} {shard_total} {targets}"
					timeout: "120m", env: raceEnv[db]
				}
				if !pushOnly[db] {
					let bin = integrationBinary[db]
					jobs: {
						build: {
							services: false, resources: buildResources
							outputs: {
								paths: ["\(bin).test", "\(bin).stamp.test"]
								key:   integrationBuildKey
							}
							tasks: [{
								name:    "build \(bin).test", timeout: "30m"
								command: "../../helpers/go-test-binary.sh forgejo.org/tests/integration \(bin).test\(integrationBuildFlags[db])"
							}]
						}
						test: {
							fixture: fixtures[db] & {setup: "../../helpers/shard-config.sh acquire \(db) {shard_index} integration", release: "../../helpers/shard-config.sh release"}
							shards: "auto", needs: ["build"]
							tasks: [integrate & {name: "integration tests on \(db)"}]
						}
					}
					target_scope: integrationScope[db]
				}
				if db == "sqlite" {
					recorder: "own_linux", record_resources: recordResources
				}
				if pushOnly[db] {
					jobs: mariadb: {
						fixture: fixtures[db] & {setup: "../../helpers/shard-config.sh acquire \(db) {shard_index} integration", release: "../../helpers/shard-config.sh release"}
						shards: "auto", max_shards: 6, needs: ["integration-mysql:build"]
						resources: integrationResources[db], target_scope: integrationScope[db]
						tasks: [integrate & {name: "integration tests on \(db)"}]
					}
				}
			}
		}

		integration: jobs: {
			build_race: {
				services: false, resources: buildResources
				outputs: {
					paths: ["integrations.sqlite.race.test", "integrations.sqlite.race.stamp.test"]
					key:   integrationBuildKey
				}
				tasks: [{
					name:    "build integrations.sqlite.race.test", timeout: "30m"
					command: "../../helpers/go-test-binary.sh forgejo.org/tests/integration integrations.sqlite.race.test -tags \"sqlite sqlite_unlock_notify\" -race"
				}]
			}
			race: {
				fixture: fixtures.sqlite & {setup: "../../helpers/shard-config.sh acquire sqlite {shard_index} integration", release: "../../helpers/shard-config.sh release"}
				shards: "auto", needs: ["build_race"], resources: raceResources, target_scope: fromSqlite
				tasks: [{
					name: "integration tests under -race", timeout: "120m", env: raceEnabled
					command: "../../helpers/integration.sh sqlite {shard_index} {shard_total} {targets}"
				}]
			}
		}

		frontend: {
			title: "Web frontend", kind: "app", domain: "frontend", technology: "typescript", root: ".", depends_on: ["js-root", "templates"]
			uses: [{protocol: schema.#Protocol.Http, target: "backend", title: "Calls Forgejo web & API routes"}]
			watch_paths: [
				"web_src/**", "eslint.config.ts", "stylelint.config.ts", "tailwind.config.ts",
				"tsconfig.json", "vitest.config.ts", "webpack.config.ts", "tools/*.js", "tools/*.ts",
				"helpers/vitest.sh", "helpers/svg-check.sh", "helpers/lint-js.sh",
			]
			workspace_scope: include: ["web_src", "tools"]
			resources: {cpus: 2, memory_mb: 4096}
			jobs: lint: tasks: [
				{name: "ESLint", command: "helpers/lint-js.sh"},
				{name: "Stylelint", command: "make --no-print-directory lint-css"},
			]
			typecheck: "make tsc"
			test:      "helpers/vitest.sh {targets}"
			target_scope: {
				tests: ["web_src/**/*.test.{js,ts}"]
				rules: [{match: ["web_src/**/*.{js,ts,vue,css}", "vitest.config.ts", "tsconfig.json", "helpers/vitest.sh"], engine: "typescript"}]
			}
			jobs: checks: tasks: [{name: "SVG icons", command: "helpers/svg-check.sh"}]
			jobs: build: {
				outputs: {
					paths: ["public/assets/js", "public/assets/css", "public/assets/fonts"]
					key:   ["package.json", "package-lock.json", "webpack.config.ts", "tailwind.config.ts", "tsconfig.json", "web_src/**"]
				}
				tasks: [{name: "webpack", lock: "webpack", command: "helpers/exclusive.sh webpack make --no-print-directory webpack", timeout: "20m"}]
			}
		}

		e2e: {
			title: "End-to-end tests (Playwright, sqlite)", kind: "verification", domain: "verification", technology: "typescript", root: "tests/e2e"
			watch_paths: list.Concat([goSources, [
				"tests/e2e/**", "playwright.config.ts", "web_src/**", "templates/**",
				"helpers/e2e.sh", "helpers/e2e-specs.sh",
			]])
			workspace_scope: include: ["tests/e2e"]
			depends_on: ["backend", "frontend"]
			resources:  {cpus: 2, memory_mb: 8192}, shards: 2
			jobs: test: {
				needs: ["frontend:build"]
				tasks: [{command: "../../helpers/e2e.sh {shard_index} {shard_total} {targets}", timeout: "120m"}]
			}
			target_scope: {
				fallback: "none", tests: ["tests/e2e/*.test.e2e.ts"]
				rules: [
					{match: ["tests/e2e/*.test.e2e.ts", "web_src/**", "templates/**", "**/*.go"], engine: "watch_annotations"},
					{match: list.Concat([[packageTestdata, "eslint.config.ts", "stylelint.config.ts", "vitest.config.ts", "tsconfig.json"], goLintConfigs]), action: "ignore"},
				]
			}
		}

		"release-notes-assistant": {
			title: "Release notes assistant", root: ".", technology: "shell", depends_on: ["root"]
			watch_paths: ["release-notes-assistant.sh"]
			test: "bash release-notes-assistant.sh test_main"
		}

		semgrep: {
			title: "Semgrep rules", root: ".", depends_on: ["root"]
			watch_paths: list.Concat([[".semgrep/**", "helpers/semgrep-test.sh", "tests/**/*.go"], goSources])
			jobs: lint: {
				direct: true, services: false, resources: {cpus: 2, memory_mb: 2048}
				let quiet = {env: SEMGREP_ENABLE_VERSION_CHECK: "0"}
				let rules = quiet & {filter: include: [".semgrep/**", "helpers/semgrep-test.sh"]}
				let scanned = quiet & {
					filter: {
						include: [".semgrep/config/**", "**/*.go"]
						exclude: ["**/*_test.go", "**/test/**", "**/tests/**", "**/build/**"]
					}
				}
				tasks: [
					rules & {name: "validate rules", command: "semgrep validate .semgrep/config"},
					rules & {name: "rule tests", command: "helpers/semgrep-test.sh"},
					scanned & {name: "semgrep ci", command: "semgrep ci --config .semgrep/config/ --metrics=off", timeout: "10m"},
				]
			}
		}

		repository: {
			title: "Docs, release notes and packaging", root: ".", depends_on: ["root"]
			watch_paths: [
				"*.md", "LICENSE", "DCO", "CODEOWNERS", "release-notes/**", "release-notes-published/**",
				"releases/**", ".release-notes-assistant.yaml", ".forgejo/**", "contrib/**", "docker/**",
				"Dockerfile", "Dockerfile.rootless", ".dockerignore", ".devcontainer/**", ".gitpod.yml",
				".air.toml", ".envrc.example", "flake.nix", "flake.lock", "shell.nix", "manifest.scm",
				".gitattributes", ".gitignore", ".gitmodules", ".ignore", ".mailmap",
				".markdownlint.yaml", ".yamllint.yaml", "helpers/renovate-check.sh",
			]
			jobs: checks: {
				resources: {cpus: 1, memory_mb: 1024}
				tasks: [{
					name: "Renovate config", command: "helpers/renovate-check.sh"
					filter: include: [".forgejo/renovate.json", "helpers/renovate-check.sh"]
				}]
			}
		}
	}
}
