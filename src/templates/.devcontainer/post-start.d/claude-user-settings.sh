#!/bin/bash
set -uo pipefail

# Happy reads only ~/.claude/settings.json (not project settings) and adds its co-author ad to commits unless this is false.

command -v jq >/dev/null || exit 0
settings="$HOME/.claude/settings.json"
mkdir -p "$(dirname "$settings")"
[ -s "$settings" ] || echo '{}' >"$settings"

if jq '.includeCoAuthoredBy = false' "$settings" >"$settings.tmp"; then
  mv "$settings.tmp" "$settings"
else
  rm -f "$settings.tmp"
  echo "WARNING: could not update $settings"
fi

exit 0
