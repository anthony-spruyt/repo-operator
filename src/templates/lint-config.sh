#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables used by sourcing script (lint.sh)
# Lint configuration - customize per repository
# This file is sourced by lint.sh for both local and CI runs

# MegaLinter Docker image (use digest for reproducibility)
# renovate: datasource=docker depName=ghcr.io/anthony-spruyt/megalinter-container-images
MEGALINTER_IMAGE="ghcr.io/anthony-spruyt/megalinter-container-images:v10.0.53@sha256:6571cb020931b280fb5c38bf17c79f9e4b16e81bf0a4c1349018cf823c9df980"

# Skip linting for renovate/dependabot commits in CI
SKIP_BOT_COMMITS=false

# MegaLinter flavor (use "all" for custom images to bypass flavor validation)
MEGALINTER_FLAVOR="all"
