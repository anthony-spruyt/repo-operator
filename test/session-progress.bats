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

@test "loads the same notes on a detached HEAD or another branch" {
  printf 'same notes\n' >"$ROOT/.agent-progress/$SID.md"
  git -C "$ROOT" checkout -q --detach
  hook "$ROOT"
  [[ "$output" == *"same notes"* ]]
  git -C "$ROOT" switch -q -c feat/x
  hook "$ROOT"
  [[ "$output" == *"same notes"* ]]
}

@test "a worktree session gets the worktree's own notes path" {
  printf 'main checkout notes\n' >"$ROOT/.agent-progress/$SID.md"
  WT="$ROOT/.claude/worktrees/wt"
  git -C "$ROOT" worktree add -q -b wt "$WT"
  CLAUDE_PROJECT_DIR="$WT" hook "$WT"
  [[ "$output" == *"$WT/.agent-progress/$SID.md"* ]]
  [[ "$output" != *"main checkout notes"* ]]
}

@test "an EnterWorktree session (project dir is the main checkout) gets the worktree root" {
  WT="$ROOT/.claude/worktrees/wt"
  git -C "$ROOT" worktree add -q -b wt "$WT"
  mkdir -p "$WT/src/deep"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$WT/src/deep"
  [ "$output" == "Keep progress notes for this session in $WT/.agent-progress/$SID.md (none written yet)." ]
}

@test "a worktree outside the main checkout gets its own root" {
  WT="${BATS_TEST_TMPDIR}/elsewhere"
  git -C "$ROOT" worktree add -q -b wt2 "$WT"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$WT"
  [[ "$output" == *"$WT/.agent-progress/$SID.md"* ]]
}

@test "falls back to the project when cwd is not in a git repo" {
  CLAUDE_PROJECT_DIR="$ROOT" hook "$BATS_TEST_TMPDIR"
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "a plain checkout keeps its own root" {
  CLAUDE_PROJECT_DIR="$ROOT" hook "$ROOT"
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "a git dir that is not named .git falls back to the work tree root" {
  BARE="${BATS_TEST_TMPDIR}/gitdir-elsewhere"
  WORK="${BATS_TEST_TMPDIR}/work"
  mkdir -p "$WORK"
  git init -q -b main --separate-git-dir "$BARE" "$WORK"
  hook "$WORK"
  [[ "$output" == *"$WORK/.agent-progress/$SID.md"* ]]
}

@test "the SessionStart matcher covers startup, clear, fork, resume and compact" {
  matcher=$(jq -r '.hooks.SessionStart[0].matcher' "${BATS_TEST_DIRNAME}/../src/templates/.claude/settings.json")
  for event in startup clear fork resume compact; do
    [[ "$matcher" =~ (^|\|)${event}(\||$) ]]
  done
}

@test "only .gitignore is tracked in .agent-progress" {
  repo="${BATS_TEST_DIRNAME}/.."
  tracked=$(git -C "$repo" ls-files -- '.agent-progress' 'src/templates/.agent-progress' | grep -v '/\?\.gitignore$' || true)
  [ -z "$tracked" ] || { echo "only .gitignore is tracked in .agent-progress; also tracked: $tracked" >&2; return 1; }
  [ -f "$repo/src/templates/.agent-progress/.gitignore" ]
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

@test "reloads notes written in the project checkout after cwd moves to a worktree" {
  printf 'main checkout notes\n' >"$ROOT/.agent-progress/$SID.md"
  WT="$ROOT/.claude/worktrees/wt"
  git -C "$ROOT" worktree add -q -b wt "$WT"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"main checkout notes"* ]]
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
  [[ "$output" == *"$WT/.agent-progress/$SID.md"* ]]
}

@test "prefers the cwd checkout's notes over the project checkout's" {
  printf 'main checkout notes\n' >"$ROOT/.agent-progress/$SID.md"
  WT="$ROOT/.claude/worktrees/wt"
  git -C "$ROOT" worktree add -q -b wt "$WT"
  mkdir -p "$WT/.agent-progress"
  printf 'worktree notes\n' >"$WT/.agent-progress/$SID.md"
  CLAUDE_PROJECT_DIR="$ROOT" hook "$WT"
  [[ "$output" == *"worktree notes"* ]]
  [[ "$output" != *"main checkout notes"* ]]
}

@test "skips a symlinked notes folder" {
  rmdir "$ROOT/.agent-progress"
  mkdir "${BATS_TEST_TMPDIR}/elsewhere-notes"
  printf 'linked notes\n' >"${BATS_TEST_TMPDIR}/elsewhere-notes/$SID.md"
  ln -s "${BATS_TEST_TMPDIR}/elsewhere-notes" "$ROOT/.agent-progress"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "skips a symlinked notes file" {
  printf 'linked notes\n' >"${BATS_TEST_TMPDIR}/target.md"
  ln -s "${BATS_TEST_TMPDIR}/target.md" "$ROOT/.agent-progress/$SID.md"
  hook "$ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prints nothing for a session_id containing a newline" {
  run bash "$SCRIPT" <<<"{\"session_id\":\"abc\\ndef\",\"cwd\":\"$ROOT\"}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "falls back to the project when the cwd directory does not exist" {
  CLAUDE_PROJECT_DIR="$ROOT" hook "${BATS_TEST_TMPDIR}/gone"
  [[ "$output" == *"$ROOT/.agent-progress/$SID.md"* ]]
}

@test "prints nothing in a bare repo" {
  git init -q --bare "${BATS_TEST_TMPDIR}/bare.git"
  hook "${BATS_TEST_TMPDIR}/bare.git"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
