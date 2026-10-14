#!/usr/bin/env bash
# Decides whether XFG Plan (preview) runs. Prints true or false, and why to stderr.
# Usage: git diff --name-only ... | EVENT_NAME=... HEAD_REF=... HAS_LABEL=... xfg-preview-needed.sh
set -euo pipefail

: "${EVENT_NAME:?}"
readonly PLAN_FILES='^(\.github/workflows/ci\.yaml|\.github/scripts/(check-xfg-config|xfg-preview-needed)\.sh)$'

changed=$(cat)

decide() {
  echo "$2" >&2
  echo "$1"
}

if [ "$EVENT_NAME" != "pull_request" ]; then
  decide true "Not a PR: plan runs"
elif [[ "${HEAD_REF:-}" == mergify/merge-queue/* ]]; then
  decide false "Merge queue PR: the PR already planned this change"
elif [ "${HAS_LABEL:-false}" = "true" ]; then
  decide true "PR has the xfg/plan label: plan runs"
elif grep -qE "$PLAN_FILES" <<<"$changed"; then
  decide true "PR changes the plan's workflow or scripts: plan runs"
else
  decide false "No xfg/plan label: add it to run the plan"
fi
