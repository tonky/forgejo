#!/usr/bin/env bash
# `make lint-js` as upstream CI runs it, in a fresh checkout. ESLint's flat config reads no
# .gitignore, so in a checkout local runs have used it also lints what they leave in
# ignored directories: vitest's `coverage/` report (helpers/vitest.sh, as upstream's
# test-frontend-coverage) and enact's run logs under `.enact/`, whose
# `<component>.test.<i>-of-<n>.log` names match the config's `**/*.test.*`.
set -euo pipefail

# Commands run in their component's directory: work from the repository root.
cd "$(dirname "$0")/.."

recipe="$(make --no-print-directory -n lint-js 2>/dev/null | tail -n 1)"
[[ "${recipe}" == "npx eslint "* ]] || { echo "lint-js: the Makefile's lint-js is no longer \`npx eslint …\`: ${recipe}" >&2; exit 1; }
# shellcheck disable=SC2086 # the recipe's own words
exec ${recipe} --ignore-pattern coverage/ --ignore-pattern .enact/
