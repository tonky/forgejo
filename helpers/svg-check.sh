#!/usr/bin/env bash
# `make svg-check` for a checkout other jobs run in: upstream's target regenerates
# public/assets/img/svg in place (`make svg`) and `git add`s it to diff against HEAD.
# Here tools/generate-svg.ts writes into a scratch tree that links the checkout's
# node_modules and web_src/svg, and the result is compared with the checkout's
# public/assets/img/svg: files changed, missing or no longer generated all fail, as
# upstream's diff does, and neither the tree nor git's index is touched. Run it after
# node_modules is installed (helpers/with-node-modules.sh).
set -euo pipefail

cd "$(dirname "$0")/.."

svg_dir=public/assets/img/svg
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
# The generator resolves its inputs and output against its own directory's parent.
mkdir -p "${work}/tools" "${work}/web_src"
cp tools/generate-svg.ts "${work}/tools/"
ln -s "${PWD}/node_modules" "${work}/node_modules"
ln -s "${PWD}/web_src/svg" "${work}/web_src/svg"
node "${work}/tools/generate-svg.ts"
if ! diff -r "${svg_dir}" "${work}/${svg_dir}"; then
    echo "Please run 'make svg' and commit the result"
    exit 1
fi
