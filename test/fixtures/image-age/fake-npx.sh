#!/usr/bin/env bash
# Serves the recorded Renovate log of the repo named last from $FAKE_NPX_DIR, with its .err file as stderr and .status as
# exit code when they exist; the config validator answers with $FAKE_VALIDATOR_STATUS.
set -euo pipefail

printf '%s | omit=%s token=%s format=%s user=%s author=%s\n' "$*" "${npm_config_omit:-}" "${RENOVATE_TOKEN:+set}" "${LOG_FORMAT:-}" "${RENOVATE_USERNAME:-}" "${RENOVATE_GIT_AUTHOR:-}" >>"$FAKE_NPX_LOG"
case "$*" in
*renovate-config-validator*)
  echo "fake validator: ${*: -1}" >&2
  exit "${FAKE_VALIDATOR_STATUS:-0}"
  ;;
*--dry-run=extract*)
  repo="${*: -1}"
  base="$FAKE_NPX_DIR/${repo//\//__}"
  log="$base.log"
  if [[ ! -f "$log" ]]; then
    echo "fake renovate: no recorded run for $repo" >&2
    exit 1
  fi
  echo "npm warn deprecated fake@1.0.0: not JSON on purpose" >&2
  if [[ -f "$base.err" ]]; then cat "$base.err" >&2; fi
  cat "$log"
  if [[ -f "$base.status" ]]; then exit "$(cat "$base.status")"; fi
  ;;
*)
  echo "fake npx: unexpected arguments: $*" >&2
  exit 1
  ;;
esac
