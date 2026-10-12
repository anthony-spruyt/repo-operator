#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/templates/.claude/restore-shell-tools.sh"
  ENV_FILE="${BATS_TEST_TMPDIR}/claude-env.sh"
  LINE='unset -f grep find 2>/dev/null || true'
}

@test "appends the unset line when CLAUDE_ENV_FILE is set" {
  CLAUDE_ENV_FILE="$ENV_FILE" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "$LINE" "$ENV_FILE")" -eq 1 ]
}

@test "keeps existing env file content" {
  printf 'export FOO=bar\n' >"$ENV_FILE"
  CLAUDE_ENV_FILE="$ENV_FILE" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF 'export FOO=bar' "$ENV_FILE"
  [ "$(grep -cxF "$LINE" "$ENV_FILE")" -eq 1 ]
}

@test "does not append the line twice to the same file" {
  CLAUDE_ENV_FILE="$ENV_FILE" run bash "$SCRIPT"
  CLAUDE_ENV_FILE="$ENV_FILE" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF "$LINE" "$ENV_FILE")" -eq 1 ]
}

@test "starts a new line when the file lacks a trailing newline" {
  printf 'export FOO=bar' >"$ENV_FILE"
  CLAUDE_ENV_FILE="$ENV_FILE" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qxF 'export FOO=bar' "$ENV_FILE"
  [ "$(grep -cxF "$LINE" "$ENV_FILE")" -eq 1 ]
}

@test "does nothing when CLAUDE_ENV_FILE is unset" {
  cd "$BATS_TEST_TMPDIR"
  unset CLAUDE_ENV_FILE
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR")" ]
}

@test "does nothing when CLAUDE_ENV_FILE is empty" {
  cd "$BATS_TEST_TMPDIR"
  CLAUDE_ENV_FILE="" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR")" ]
}

@test "prints nothing to stdout or stderr when it appends" {
  CLAUDE_ENV_FILE="$ENV_FILE" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the appended line restores the real grep and find" {
  CLAUDE_ENV_FILE="$ENV_FILE" bash "$SCRIPT"
  run bash -c "grep() { echo shadow; }; find() { echo shadow; }; source '$ENV_FILE'; type -t grep; type -t find"
  [ "$status" -eq 0 ]
  [ "$output" = $'file\nfile' ]
}

@test "is registered as a SessionStart hook in the settings template" {
  run jq -r '.hooks.SessionStart[].hooks[].command' "${BATS_TEST_DIRNAME}/../src/templates/.claude/settings.json"
  [ "$status" -eq 0 ]
  [[ "$output" == *'.claude/restore-shell-tools.sh'* ]]
}
