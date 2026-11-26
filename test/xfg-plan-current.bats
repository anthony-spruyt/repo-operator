#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/scripts/xfg-plan-current.sh"
  REPO="$BATS_TEST_TMPDIR/repo"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b main "$REPO"
  mkdir -p "$REPO/src"
  echo base >"$REPO/src/base.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  cd "$REPO" || exit
}

# commit <file> - one commit that edits the file; prints its sha
commit() {
  mkdir -p "$(dirname "$1")"
  echo "change $RANDOM" >>"$1"
  git add -- "$1"
  git commit -q -m "edit $1"
  git rev-parse HEAD
}

@test "a run is stale when a later merge changed src/, and the later merge is current" {
  a=$(commit README.md)
  b=$(commit src/groups.yaml)
  run "$SCRIPT" "$a" "$b"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  run "$SCRIPT" "$b" "$b"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "a newer main commit that leaves src/ alone keeps the run current" {
  commit README.md >/dev/null
  b=$(commit src/groups.yaml)
  c=$(commit .github/workflows/ci.yaml)
  run "$SCRIPT" "$b" "$c"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "a run is current again when a later commit puts src/ back as it was" {
  a=$(commit src/groups.yaml)
  git revert --no-edit HEAD >/dev/null
  run "$SCRIPT" "$a" HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
  run "$SCRIPT" HEAD~2 HEAD
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "fails, printing no verdict, on a sha git does not know" {
  b=$(commit src/groups.yaml)
  run --separate-stderr "$SCRIPT" "$b" 0000000000000000000000000000000000000000
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run --separate-stderr "$SCRIPT" 0000000000000000000000000000000000000000 "$b"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "fails, printing no verdict, when a commit has no src/" {
  git rm -rq src
  git commit -q -m "drop src"
  run --separate-stderr "$SCRIPT" HEAD HEAD
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "fails without both shas" {
  run "$SCRIPT" HEAD
  [ "$status" -eq 2 ]
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}
