#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables used by sourcing script (lint.sh)
# Lint configuration - customize per repository
# This file is sourced by lint.sh for both local and CI runs

# MegaLinter Docker image (use digest for reproducibility)
# renovate: datasource=docker depName=ghcr.io/anthony-spruyt/megalinter-container-images
MEGALINTER_IMAGE="ghcr.io/anthony-spruyt/megalinter-container-images:v11.0.2@sha256:e7bf0424d915bf78d5bb4ebfadfae54dc4671a96fbc62830e135f0a3a5e9251a"

# Skip linting for renovate/dependabot commits in CI
SKIP_BOT_COMMITS=false

# MegaLinter flavor (use "all" for custom images to bypass flavor validation)
MEGALINTER_FLAVOR="all"
