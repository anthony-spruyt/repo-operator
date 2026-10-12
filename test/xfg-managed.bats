#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/templates/.claude/xfg-managed.sh"
  T="$BATS_TEST_TMPDIR"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

  cat >"$T/list.json" <<'EOF'
{
  "anthony-spruyt/a": [".editorconfig", ".claude/settings.json", "lint.sh"],
  "anthony-spruyt/repo-operator": [".editorconfig"]
}
EOF
  export XFG_MANAGED_URL="file://$T/list.json"

  REPO="$T/a"
  new_repo "$REPO" git@github.com:anthony-spruyt/a.git
}

new_repo() {
  git init -q -b main "$1"
  git -C "$1" remote add origin "$2"
}

g() {
  git -C "$REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"
}

# Feeds a PreToolUse payload for tool $1 with input key $2 = $3 to the hook, from cwd $4
hook() {
  jq -n --arg tool "$1" --arg key "$2" --arg val "$3" --arg cwd "${4:-$REPO}" \
    '{hook_event_name: "PreToolUse", tool_name: $tool, tool_input: {($key): $val}, cwd: $cwd}' |
    bash "$SCRIPT" hook
}

bash_hook() { hook Bash command "$1"; }

@test "check says yes for a managed path" {
  cd "$REPO"
  run bash "$SCRIPT" check .editorconfig
  [ "$status" -eq 0 ]
  [ "$output" = "yes" ]
}

@test "check says no for an unlisted path" {
  cd "$REPO"
  run bash "$SCRIPT" check .gitignore
  [ "$status" -eq 0 ]
  [ "$output" = "no" ]
}

@test "check resolves absolute paths and paths from a subdirectory" {
  mkdir -p "$REPO/.claude"
  cd "$REPO/.claude"
  run bash "$SCRIPT" check settings.json
  [ "$output" = "yes" ]
  cd /
  run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "yes" ]
}

@test "check reads an https origin" {
  git -C "$REPO" remote set-url origin https://github.com/anthony-spruyt/a.git
  run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "yes" ]
}

@test "check says no for a repo that is not in the list" {
  new_repo "$T/other" git@github.com:anthony-spruyt/other.git
  run bash "$SCRIPT" check "$T/other/.editorconfig"
  [ "$output" = "no" ]
}

@test "check says no outside a git repo" {
  mkdir -p "$T/plain"
  run bash "$SCRIPT" check "$T/plain/.editorconfig"
  [ "$status" -eq 0 ]
  [ "$output" = "no" ]
}

@test "check says no when the list cannot be fetched and nothing is cached" {
  export XFG_MANAGED_URL="file://$T/missing.json"
  run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "no" ]
}

@test "a cached list answers when the fetch later fails" {
  run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "yes" ]
  rm "$T/list.json"
  XFG_MANAGED_TTL=0 run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "yes" ]
}

@test "a fresh cache is used without fetching" {
  run bash "$SCRIPT" check "$REPO/lint.sh"
  echo '{"anthony-spruyt/a": []}' >"$T/list.json"
  run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "yes" ]
  XFG_MANAGED_TTL=0 run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "no" ]
}

@test "an invalid list does not replace the cache" {
  run bash "$SCRIPT" check "$REPO/lint.sh"
  echo 'not json' >"$T/list.json"
  XFG_MANAGED_TTL=0 run bash "$SCRIPT" check "$REPO/lint.sh"
  [ "$output" = "yes" ]
}

@test "hook blocks Edit of a managed file and names repo-operator" {
  run --separate-stderr hook Edit file_path "$REPO/.claude/settings.json"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *".claude/settings.json"* ]]
  [[ "$stderr" == *"anthony-spruyt/repo-operator"* ]]
  [[ "$stderr" == *"Load the repo-operator skill"* ]]
}

@test "hook blocks Write and MultiEdit of a managed file" {
  run hook Write file_path "$REPO/lint.sh"
  [ "$status" -eq 2 ]
  run hook MultiEdit file_path "$REPO/lint.sh"
  [ "$status" -eq 2 ]
}

@test "hook blocks NotebookEdit of a managed notebook" {
  echo '{"anthony-spruyt/a": ["nb.ipynb"]}' >"$T/list.json"
  run hook NotebookEdit notebook_path "$REPO/nb.ipynb"
  [ "$status" -eq 2 ]
}

@test "hook allows Write of a new file in a new directory" {
  run hook Write file_path "$REPO/new/dir/file.txt"
  [ "$status" -eq 0 ]
}

@test "hook allows Edit of an unmanaged file" {
  run hook Edit file_path "$REPO/.gitignore"
  [ "$status" -eq 0 ]
}

@test "hook ignores other tools" {
  run hook Read file_path "$REPO/lint.sh"
  [ "$status" -eq 0 ]
}

@test "hook in repo-operator points at src/templates in this repo" {
  git -C "$REPO" remote set-url origin git@github.com:anthony-spruyt/repo-operator.git
  run --separate-stderr hook Edit file_path "$REPO/.editorconfig"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"src/templates/.editorconfig"* ]]
  [[ "$stderr" == *"Load the repo-operator skill"* ]]
}

@test "hook blocks Bash in-place edits" {
  run bash_hook "sed -i 's/a/b/' .editorconfig"
  [ "$status" -eq 2 ]
  run bash_hook "sed -E -i.bak 's/a/b/' lint.sh"
  [ "$status" -eq 2 ]
  run bash_hook "perl -pi -e 's/a/b/' lint.sh"
  [ "$status" -eq 2 ]
}

@test "hook blocks Bash redirects into a managed file" {
  run bash_hook "echo x > .claude/settings.json"
  [ "$status" -eq 2 ]
  run bash_hook "echo x >>lint.sh"
  [ "$status" -eq 2 ]
  run bash_hook "cat > \"./lint.sh\" <<'EOF'"
  [ "$status" -eq 2 ]
  run bash_hook "echo x > $REPO/lint.sh"
  [ "$status" -eq 2 ]
}

@test "hook blocks Bash commands that replace, move or delete a managed file" {
  for cmd in "cp /tmp/x lint.sh" "mv lint.sh old.sh" "rm -f lint.sh" "printf x | tee -a lint.sh" \
    "git rm lint.sh" "git mv lint.sh old.sh" "truncate -s0 lint.sh" "true && cp /tmp/x lint.sh"; do
    run bash_hook "$cmd"
    [ "$status" -eq 2 ] || {
      echo "not blocked: $cmd"
      return 1
    }
  done
}

@test "hook allows Bash commands that only read or run a managed file" {
  for cmd in "cat lint.sh" "./lint.sh" "APPLY_FIXES=none ./lint.sh" "grep x lint.sh > /tmp/out" \
    "cp lint.sh /tmp/x" "sed -n 1p lint.sh" "diff lint.sh src/templates/lint.sh" \
    "sed -i x src/templates/lint.sh" "echo x > lint.sh.bak" "git diff lint.sh"; do
    run bash_hook "$cmd"
    [ "$status" -eq 0 ] || {
      echo "blocked: $cmd"
      return 1
    }
  done
}

@test "staged fails on a staged change to a managed file" {
  cd "$REPO"
  echo x >lint.sh
  g add lint.sh
  run --separate-stderr bash "$SCRIPT" staged
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"lint.sh"* ]]
}

@test "staged fails on a staged delete of a managed file" {
  cd "$REPO"
  echo x >lint.sh
  g add lint.sh
  g commit -q -m init
  g rm -q lint.sh
  run bash "$SCRIPT" staged
  [ "$status" -eq 1 ]
}

@test "staged passes with only unmanaged changes" {
  cd "$REPO"
  echo x >README.md
  g add README.md
  run bash "$SCRIPT" staged
  [ "$status" -eq 0 ]
}
