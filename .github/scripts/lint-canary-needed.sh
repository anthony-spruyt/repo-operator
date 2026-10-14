#!/usr/bin/env bash
# Decides whether Lint Canary runs. Prints true or false, and why to stderr.
# Usage: git diff --name-only ... | EVENT_NAME=... HEAD_REF=... lint-canary-needed.sh
set -euo pipefail

: "${EVENT_NAME:?}"
readonly LINT_PATHS='^(\.github/workflows/lint-canary\.yaml|\.github/scripts/lint-canary-needed\.sh|src/(groups|repos)\.yaml|src/templates/(\.golangci\.yml|\.mega-linter-base\.yml|\.mega-linter\.yml|lint\.sh\.tmpl|ruff-base\.toml|trivy-mega-linter\.yaml))$'

changed=$(cat)

decide() {
  echo "$2" >&2
  echo "$1"
}

if [[ "$EVENT_NAME" != "pull_request" ]]; then
  decide false "Not a PR: the canary only checks PRs"
elif [[ "${HEAD_REF:-}" == mergify/merge-queue/* ]]; then
  decide false "Merge queue PR: the PR already ran the canary"
elif grep -qE "$LINT_PATHS" <<<"$changed"; then
  decide true "PR changes a lint pin or lint template: canary runs"
else
  decide false "PR changes no lint path: canary skips"
fi
