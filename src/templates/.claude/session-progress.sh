#!/bin/bash
# No ${...} here - xfg would substitute it on sync.
set -eu

# cwd, not CLAUDE_PROJECT_DIR: only cwd follows Claude into a worktree
cwd=$(jq -r '.cwd // empty')
[ -n "$cwd" ] || exit 0
root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || exit 0
branch=$(git -C "$root" branch --show-current)
[ -n "$branch" ] || exit 0

file="$root/.agent-progress/$(printf '%s' "$branch" | tr '/' '-').md"
[ -s "$file" ] || exit 0

printf 'Progress notes for branch %s from an earlier session (%s). Check them against git log before acting on them.\n\n' "$branch" "$file"
# Hook output is capped at 10,000 characters
head -c 9000 "$file"
if [ "$(wc -c <"$file")" -gt 9000 ]; then
  printf '\n\n[truncated - read the rest of %s]\n' "$file"
fi
