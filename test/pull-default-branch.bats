#!/usr/bin/env bats

setup() {
  REPO_ROOT="${BATS_TEST_DIRNAME}/.."
  SCRIPT="${REPO_ROOT}/src/templates/.claude/pull-default-branch.sh"
  T="$BATS_TEST_TMPDIR"
  unset CLAUDE_PROJECT_DIR
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0

  git init -q --bare -b main "$T/remote.git"
  git clone -q "$T/remote.git" "$T/seed" 2>/dev/null
  echo one >"$T/seed/a.txt"
  echo one >"$T/seed/b.txt"
  g "$T/seed" add a.txt b.txt
  g "$T/seed" commit -q -m init
  g "$T/seed" push -q origin main

  git clone -q "$T/remote.git" "$T/main"
  MAIN="$T/main"
}

g() {
  local dir=$1
  shift
  git -C "$dir" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@"
}

# Commit a change to $1 (file) on the remote's main via a second clone
upstream() {
  echo "$2" >"$T/seed/$1"
  g "$T/seed" add "$1"
  g "$T/seed" commit -q -m "change $1"
  g "$T/seed" push -q origin main
}

upstream_sha() { git -C "$T/remote.git" rev-parse main; }
head_of() { git -C "$1" rev-parse HEAD; }

hook() {
  run bash "$SCRIPT" <<<"{\"hook_event_name\":\"SubagentStop\",\"cwd\":\"${1:-$MAIN}\"}"
}

@test "fast-forwards the default branch when behind" {
  upstream a.txt two
  [ "$(head_of "$MAIN")" != "$(upstream_sha)" ]
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
  [ "$(cat "$MAIN/a.txt")" = "two" ]
}

@test "uses CLAUDE_PROJECT_DIR over the cwd in the payload" {
  upstream a.txt two
  CLAUDE_PROJECT_DIR=$MAIN run bash "$SCRIPT" <<<"{\"cwd\":\"$T\"}"
  [ "$status" -eq 0 ]
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
}

@test "falls back to the working directory without a payload" {
  upstream a.txt two
  cd "$MAIN"
  run bash "$SCRIPT" </dev/null
  [ "$status" -eq 0 ]
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
}

@test "from a linked worktree fast-forwards the main worktree and leaves the linked one alone" {
  g "$MAIN" worktree add -q "$T/linked" -b feature
  linked_before=$(head_of "$T/linked")
  upstream a.txt two
  CLAUDE_PROJECT_DIR=$T/linked run bash "$SCRIPT" <<<'{}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
  [ "$(head_of "$T/linked")" = "$linked_before" ]
  [ "$(cat "$T/linked/a.txt")" = "one" ]
}

@test "keeps a dirty tracked file upstream does not touch and still fast-forwards" {
  echo local >"$MAIN/b.txt"
  upstream a.txt two
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
  [ "$(cat "$MAIN/b.txt")" = "local" ]
}

@test "changes nothing when a dirty tracked file is also changed upstream" {
  echo local >"$MAIN/a.txt"
  before=$(head_of "$MAIN")
  upstream a.txt two
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$before" ]
  [ "$(cat "$MAIN/a.txt")" = "local" ]
}

@test "changes nothing when an untracked file is in the way of an upstream file" {
  before=$(head_of "$MAIN")
  upstream n.txt upstream
  echo local >"$MAIN/n.txt"
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$before" ]
  [ "$(cat "$MAIN/n.txt")" = "local" ]
}

@test "leaves untracked files that do not collide" {
  echo local >"$MAIN/scratch.txt"
  upstream a.txt two
  hook
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
  [ "$(cat "$MAIN/scratch.txt")" = "local" ]
}

@test "changes nothing when the main worktree is on another branch" {
  g "$MAIN" checkout -q -b other
  before=$(head_of "$MAIN")
  upstream a.txt two
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$before" ]
  [ "$(git -C "$MAIN" rev-parse main)" != "$(upstream_sha)" ]
}

@test "changes nothing when HEAD is detached" {
  g "$MAIN" checkout -q --detach
  before=$(head_of "$MAIN")
  upstream a.txt two
  hook
  [ "$status" -eq 0 ]
  [ "$(head_of "$MAIN")" = "$before" ]
}

@test "changes nothing while a rebase, merge, cherry-pick, revert or bisect is in progress" {
  before=$(head_of "$MAIN")
  upstream a.txt two
  gitdir=$(git -C "$MAIN" rev-parse --absolute-git-dir)
  for marker in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    if [ "$marker" = rebase-merge ] || [ "$marker" = rebase-apply ]; then
      mkdir "$gitdir/$marker"
    else
      : >"$gitdir/$marker"
    fi
    hook
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ "$(head_of "$MAIN")" = "$before" ]
    rm -rf "${gitdir:?}/$marker"
  done
  hook
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
}

@test "changes nothing and stays quiet when the remote is unreachable" {
  before=$(head_of "$MAIN")
  git -C "$MAIN" remote set-url origin "$T/missing.git"
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$before" ]
}

@test "gives up on a hanging fetch within the timeout" {
  before=$(head_of "$MAIN")
  git -C "$MAIN" remote set-url origin "ext::sleep 60"
  GIT_ALLOW_PROTOCOL=ext
  export GIT_ALLOW_PROTOCOL
  start=$SECONDS
  hook
  elapsed=$((SECONDS - start))
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$elapsed" -lt 15 ]
  [ "$(head_of "$MAIN")" = "$before" ]
}

@test "does nothing without origin/HEAD" {
  before=$(head_of "$MAIN")
  git -C "$MAIN" remote set-head origin --delete
  upstream a.txt two
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$before" ]
}

@test "does nothing without an origin remote" {
  git -C "$MAIN" remote remove origin
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does nothing outside a git repo" {
  hook "$T"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does nothing when already up to date" {
  before=$(head_of "$MAIN")
  hook
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$before" ]
}

@test "follows a default branch that is not main" {
  g "$MAIN" checkout -q -b trunk
  g "$MAIN" push -q origin trunk
  git -C "$T/remote.git" symbolic-ref HEAD refs/heads/trunk
  git -C "$MAIN" remote set-head origin trunk
  g "$T/seed" fetch -q origin
  g "$T/seed" checkout -q -b trunk origin/trunk
  echo two >"$T/seed/a.txt"
  g "$T/seed" commit -q -am "trunk change"
  g "$T/seed" push -q origin trunk
  hook
  [ "$status" -eq 0 ]
  [ "$(head_of "$MAIN")" = "$(git -C "$T/remote.git" rev-parse trunk)" ]
}

@test "tolerates an empty or malformed payload" {
  upstream a.txt two
  cd "$MAIN"
  run bash "$SCRIPT" <<<'not json'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(head_of "$MAIN")" = "$(upstream_sha)" ]
}

@test "settings.json runs the script in the background on SubagentStop and UserPromptSubmit" {
  settings="${REPO_ROOT}/src/templates/.claude/settings.json"
  for event in SubagentStop UserPromptSubmit; do
    run jq -r --arg e "$event" '[.hooks[$e][].hooks[] | select(.type == "command" and (.command | contains("pull-default-branch.sh")) and .async == true)] | length' "$settings"
    [ "$status" -eq 0 ]
    [ "$output" -eq 1 ]
  done
}

@test "the claude group syncs the script" {
  run yq -r '.groups.claude.files[".claude/pull-default-branch.sh"].content' "${REPO_ROOT}/src/groups.yaml"
  [ "$output" = "@templates/.claude/pull-default-branch.sh" ]
}

@test "the claude+terraform settings.json only adds to the base, so it keeps the hooks" {
  run yq -r '.conditionalGroups[] | select((.when.allOf | contains(["claude", "terraform"])) and .files.".claude/settings.json") | .files.".claude/settings.json".content | keys | join(",")' "${REPO_ROOT}/src/groups.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "permissions" ]
}
