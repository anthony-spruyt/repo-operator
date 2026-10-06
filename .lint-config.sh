#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables used by sourcing script (lint.sh)
# This file is automatically updated - do not modify directly
# The image pin lives in repo-operator (src/groups.yaml, or src/repos.yaml for a per-repo flavor), where Renovate bumps it

MEGALINTER_IMAGE="ghcr.io/anthony-spruyt/megalinter-container-images:v11.0.3@sha256:ae40d08f9bd0345b3f852518f7c29960cd68252234959765bbe4a2ddfc643c40"

SKIP_BOT_COMMITS=false

# MegaLinter flavor (use "all" for custom images to bypass flavor validation)
MEGALINTER_FLAVOR="all"
