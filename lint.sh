#!/usr/bin/env bash
set -euo pipefail

# Runs mega-linter against the repository.
# Can be run from any directory.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# TODO: update to default image / default custom flavor
MEGALINTER_IMAGE="ghcr.io/anthony-spruyt/megalinter-container-images@sha256:575587d9caf54235888e3749734aec1ef094bdbd876dd0e0c88f443114a415ee"
# MEGALINTER_FLAVOR=all bypasses flavor validation (custom flavors aren't recognized)
MEGALINTER_FLAVOR="all"

rm -rf "$REPO_ROOT/.output"
mkdir "$REPO_ROOT/.output"

docker run \
  -a STDOUT \
  -a STDERR \
  -u "$(id -u):$(id -g)" \
  -w /tmp/lint \
  -e HOME=/tmp \
  -e MEGALINTER_FLAVOR=$MEGALINTER_FLAVOR \
  -e APPLY_FIXES="all" \
  -e UPDATED_SOURCES_REPORTER="true" \
  -e REPORT_OUTPUT_FOLDER="/tmp/lint/.output" \
  -v "$REPO_ROOT:/tmp/lint:rw" \
  --rm \
  $MEGALINTER_IMAGE

# Capture MegaLinter exit code
LINT_EXIT_CODE=$?

# Copy fixed files back to workspace
if compgen -G "$REPO_ROOT/.output/updated_sources/*" >/dev/null; then
  cp -r "$REPO_ROOT/.output/updated_sources"/* "$REPO_ROOT/"
fi

exit $LINT_EXIT_CODE
