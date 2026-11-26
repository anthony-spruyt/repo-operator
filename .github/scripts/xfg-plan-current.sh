#!/usr/bin/env bash
# Decides whether an XFG Plan run is still current. Prints true when src/ is identical at both commits, else false.
# Exits 1 when a sha or its src/ cannot be resolved, so a broken check never reads as a verdict.
# Usage: xfg-plan-current.sh <run-sha> <main-sha>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: ${0##*/} <run-sha> <main-sha>" >&2
  exit 2
fi

# Equal tree ids mean identical content, whatever order the commits landed in
src_tree() {
  local sha="$1"
  git rev-parse --verify --quiet "$sha:src" || {
    echo "Cannot resolve src/ at '$sha'" >&2
    exit 1
  }
}

run_tree=$(src_tree "$1")
main_tree=$(src_tree "$2")

if [[ "$run_tree" == "$main_tree" ]]; then
  echo true
else
  echo false
fi
