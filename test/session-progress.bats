#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/templates/.claude/session-progress.sh"
  SID="11111111-2222-3333-4444-555555555555"
  ROOT="${BATS_TEST_TMPDIR}/repo"
  unset CLAUDE_PROJECT_DIR
  mkdir -p "$ROOT/.agent-progress"
  git -C "$ROOT" init -q -b main
  git -C "$ROOT" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false \
    commit -q --allow-empty -m init
}

hook() {
  run bash "$SCRIPT" <<<"{\"hook_event_name\":\"SessionStart\",\"session_id\":\"${2:-$SID}\",\"cwd\":\"$1\"}"
}

@test "tells the agent its notes path when the file does not exist yet" {
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "tells the agent its notes path when the file is empty" {
  : >"$ROOT/.agent-progress/$SID.md"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
  [ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "prints nothing outside a git repo" {
  hook "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing without a cwd" {
  run bash "$SCRIPT" <<<"{\"hook_event_name\":\"SessionStart\",\"session_id\":\"$SID\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing without a session_id" {
  printf 'notes\n' >"$ROOT/.agent-progress/main.md"
  run bash "$SCRIPT" <<<"{\"hook_event_name\":\"SessionStart\",\"cwd\":\"$ROOT\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing for a session_id that is not a plain identifier" {
  hook "$ROOT" "../escape"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "loads this session's notes with the path" {
  printf 'Next: wire the hook\n' >"$ROOT/.agent-progress/$SID.md"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Next: wire the hook"* ]]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "finds the repo root from a subdirectory cwd" {
  mkdir -p "$ROOT/src/deep"
  printf 'root notes\n' >"$ROOT/.agent-progress/$SID.md"
  hook "$ROOT/src/deep"
  [[ "$output" == *"root notes"* ]]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "ignores another session's notes" {
  printf 'other session notes\n' >"$ROOT/.agent-progress/other-session.md"
  hook "$ROOT"
  [[ "$output" != *"other session notes"* ]]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "ignores a branch-named notes file" {
  printf 'branch notes\n' >"$ROOT/.agent-progress/main.md"
  hook "$ROOT"
  [[ "$output" != *"branch notes"* ]]
}

@test "loads the same notes on a detached HEAD or another branch" {
  printf 'same notes\n' >"$ROOT/.agent-progress/$SID.md"
  git -C "$ROOT" checkout -q --detach
  hook "$ROOT"
  [[ "$output" == *"same notes"* ]]
  git -C "$ROOT" switch -q -c feat/x
  hook "$ROOT"
  [[ "$output" == *"same notes"* ]]
}

@test "uses a worktree's own root, not the main checkout's" {
  printf 'main checkout notes\n' >"$ROOT/.agent-progress/$SID.md"
  WT="$ROOT/.claude/worktrees/wt"
  git -C "$ROOT" worktree add -q -b wt "$WT"
  mkdir -p "$WT/.agent-progress"
  printf 'worktree notes\n' >"$WT/.agent-progress/$SID.md"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$WT"
  [[ "$output" == *"worktree notes"* ]]
  [[ "$output" != *"main checkout notes"* ]]
  [[ "$output" == *"$WT/.agent-progress/$SID.md"* ]]
}

@test "falls back to the project when cwd is in an unrelated repo" {
  printf 'project notes\n' >"$ROOT/.agent-progress/$SID.md"
  OTHER="${BATS_TEST_TMPDIR}/other"
  git -C "$BATS_TEST_TMPDIR" init -q -b main other
  mkdir -p "$OTHER/.agent-progress"
  printf 'other notes\n' >"$OTHER/.agent-progress/$SID.md"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$OTHER"
  [[ "$output" == *"project notes"* ]]
  [[ "$output" != *"other notes"* ]]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "truncates a large file below the 10,000 character hook cap" {
  head -c 20000 /dev/zero | tr '\0' 'a' >"$ROOT/.agent-progress/$SID.md"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [ "${#output}" -lt 10000 ]
  [[ "$output" == *"truncated"* ]]
}
