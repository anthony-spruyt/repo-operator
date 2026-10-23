#!/usr/bin/env bash
# Stands in for npx in the bats tests: logs its arguments, serves the recorded Renovate log of the repo named
# last on the command line from $FAKE_NPX_DIR, and answers the config validator with $FAKE_VALIDATOR_STATUS.
set -euo pipefail

printf '%s | token=%s format=%s\n' "$*" "${RENOVATE_TOKEN:+set}" "${LOG_FORMAT:-}" >>"$FAKE_NPX_LOG"
case "$*" in
*renovate-config-validator*)
  echo "fake validator: ${*: -1}" >&2
  exit "${FAKE_VALIDATOR_STATUS:-0}"
  ;;
esac

repo="${*: -1}"
log="$FAKE_NPX_DIR/${repo//\//__}.log"
if [[ ! -f "$log" ]]; then
  echo "fake renovate: no recorded run for $repo" >&2
  exit 1
fi
echo "npm warn deprecated fake@1.0.0: not JSON on purpose" >&2
cat "$log"
