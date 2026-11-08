#!/usr/bin/env bash
# Upstream's `make lint-renovate`: renovate-config-validator over .forgejo/renovate.json.
# The validator is the env's renovate, not `npx --yes --package renovate@…` (a download per
# run), and its output goes to a temporary file, not `.lint-renovate` in the checkout.
#
# Upstream ignores the validator's exit (`|| true`) and greps `^( ERROR:)`, which renovate's
# log never prints: its level is `ERROR:` at the line's start (` INFO:` and ` WARN:` are the
# padded ones), so an invalid config passes there. This fails as the validator does: it
# exits 1 on a configuration error, 0 on warnings.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v renovate-config-validator >/dev/null \
    || { echo "renovate-check: renovate-config-validator isn't in the env" >&2; exit 2; }
out="$(mktemp)"
trap 'rm -f "${out}"' EXIT
if ! renovate-config-validator --no-global .forgejo/renovate.json >"${out}" 2>&1; then
    cat "${out}"
    exit 1
fi
echo "renovate-config-validator: .forgejo/renovate.json has no error"
