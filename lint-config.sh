#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables used by sourcing script (lint.sh)
# Lint configuration - customize per repository
# This file is sourced by lint.sh for both local and CI runs

# MegaLinter Docker image (use digest for reproducibility)
# renovate: datasource=docker depName=ghcr.io/anthony-spruyt/megalinter-container-images
MEGALINTER_IMAGE="ghcr.io/anthony-spruyt/megalinter-container-images:v11.0.1@sha256:f7a7f147500f7c64585254cc1105e16acc4267dbd169f8a79d9154052d2cc3a7"

# Skip linting for renovate/dependabot commits in CI
SKIP_BOT_COMMITS=false

# MegaLinter flavor (use "all" for custom images to bypass flavor validation)
MEGALINTER_FLAVOR="all"
