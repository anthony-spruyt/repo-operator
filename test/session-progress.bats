#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/templates/.claude/session-progress.sh"
  ROOT="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$ROOT/.agent-progress"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

hook() {
  run bash "$SCRIPT" <<<"{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$1\"}"
}

@test "prints nothing when the branch has no progress file" {
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing outside a git repo" {
  hook "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing without a cwd" {
  run bash "$SCRIPT" <<<'{"hook_event_name":"SessionStart"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing on a detached HEAD" {
  printf 'notes\n' >"$ROOT/.agent-progress/main.md"
  git -C "$ROOT" checkout -q --detach
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints the current branch's progress file with its path" {
  printf 'Next: wire the hook\n' >"$ROOT/.agent-progress/main.md"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Next: wire the hook"* ]]
  [[ "$output" == *"$ROOT/.agent-progress/main.md"* ]]
}

@test "finds the repo root from a subdirectory cwd" {
  mkdir -p "$ROOT/src/deep"
  printf 'root notes\n' >"$ROOT/.agent-progress/main.md"
  hook "$ROOT/src/deep"
  [[ "$output" == *"root notes"* ]]
}

@test "maps slashes in the branch name to dashes" {
  git -C "$ROOT" switch -q -c feat/x
  printf 'feature notes\n' >"$ROOT/.agent-progress/feat-x.md"
  hook "$ROOT"
  [[ "$output" == *"feature notes"* ]]
}

@test "ignores another branch's progress file" {
  printf 'main notes\n' >"$ROOT/.agent-progress/main.md"
  git -C "$ROOT" switch -q -c other
  hook "$ROOT"
  [ -z "$output" ]
}

@test "reads a worktree's own branch and notes, not the main checkout's" {
  printf 'main notes\n' >"$ROOT/.agent-progress/main.md"
  WT="$ROOT/.claude/worktrees/wt"
  git -C "$ROOT" worktree add -q -b wt "$WT"
  mkdir -p "$WT/.agent-progress"
  printf 'worktree notes\n' >"$WT/.agent-progress/wt.md"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$WT"
  [[ "$output" == *"worktree notes"* ]]
  [[ "$output" != *"main notes"* ]]
}

@test "falls back to the project when cwd is in an unrelated repo" {
  printf 'project notes\n' >"$ROOT/.agent-progress/main.md"
  OTHER="${BATS_TEST_TMPDIR}/other"
  git -C "$BATS_TEST_TMPDIR" init -q -b main other
  mkdir -p "$OTHER/.agent-progress"
  printf 'other notes\n' >"$OTHER/.agent-progress/main.md"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$OTHER"
  [[ "$output" == *"project notes"* ]]
  [[ "$output" != *"other notes"* ]]
}

@test "truncates a large file below the 10,000 character hook cap" {
  head -c 20000 /dev/zero | tr '\0' 'a' >"$ROOT/.agent-progress/main.md"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 10000 ]
  [[ "$output" == *"truncated"* ]]
}
