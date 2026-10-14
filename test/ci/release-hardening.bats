#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WF="$REPO_ROOT/.github/workflows"
  RELEASE_ENTRIES=(.github/workflows/_release-please.yaml .github/workflows/_release-images.yaml)
}

# local_target <uses> - prints the repo path a same-repo uses: points at, or nothing for another repo's action
local_target() {
  local ref="${1%@*}"
  case "$ref" in
    '$/'*) ref="${ref#\$/}" ;;
    ./*) ref="${ref#./}" ;;
    anthony-spruyt/repo-operator/*) ref="${ref#anthony-spruyt/repo-operator/}" ;;
    *) return 0 ;;
  esac
  case "$ref" in
    *.yaml | *.yml) echo "$ref" ;;
    *) echo "$ref/action.yaml" ;;
  esac
}

uses_of() {
  yq -r '[((.jobs // {})[] | (.uses, ((.steps // [])[] | .uses))), ((.runs.steps // [])[] | .uses)] | .[] | select(. != null)' "$1"
}

# reachable <root> <file>... - prints each file, then every same-repo workflow and action it reaches, once
reachable() {
  local root="$1" file use target
  shift
  local -a queue=("$@")
  local -A seen=()
  while [ "${#queue[@]}" -gt 0 ]; do
    file="${queue[0]}"
    queue=("${queue[@]:1}")
    [ -z "${seen[$file]:-}" ] || continue
    seen[$file]=1
    echo "$file"
    while IFS= read -r use; do
      target=$(local_target "$use")
      [ -n "$target" ] && queue+=("$target")
    done < <(uses_of "$root/$file")
  done
}

# unhardened <root> <file>... - prints file:job for each job with steps whose first step is not harden-runner
unhardened() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | select((.value.steps[0].uses // "") | test("^step-security/harden-runner@") | not) | .key' "$root/$file" | sed "s|^|$file:|"
  done
}

# persisted_checkouts <root> <file>... - prints file:uses for each checkout that keeps the token in git config
persisted_checkouts() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '[((.jobs // {})[] | (.steps // [])[]), ((.runs.steps // [])[])] | .[] | select((.uses // "") | test("^actions/checkout@")) | select(.with["persist-credentials"] != false) | .uses' "$root/$file" | sed "s|^|$file:|"
  done
}

# unpinned <root> <file>... - prints file:uses for each other-repo action not pinned to a full commit SHA
unpinned() {
  local root="$1" file use
  shift
  for file in "$@"; do
    while IFS= read -r use; do
      [ -z "$(local_target "$use")" ] || continue
      [[ "$use" =~ @[0-9a-f]{40}$ ]] || echo "$file:$use"
    done < <(uses_of "$root/$file")
  done
}

pr_triggered() {
  yq -r '.on | (if tag == "!!map" then keys elif tag == "!!str" then [.] else . end) | .[] | select(. == "pull_request" or . == "pull_request_target")' "$1" | grep -q .
}

# pr_release_calls <root> - prints start -> file:job for each call a pull request run reaches that releases
pr_release_calls() {
  local root="$1" start file
  while IFS= read -r start; do
    pr_triggered "$root/$start" || continue
    while IFS= read -r file; do
      yq -r '(.jobs // {}) | to_entries[] | select(.value.uses != null) | select((.value.uses | test("/_release-(please|images)\.yaml(@|$)")) or ((.value.uses | test("/_build-image\.yaml(@|$)")) and ((.value.with.push // false) != false))) | .key' "$root/$file" | sed "s|^|$start -> $file:|"
    done < <(reachable "$root" "$start")
  done < <(cd "$root" && find .github/workflows src/templates/.github/workflows -maxdepth 1 -name '*.y*ml' 2>/dev/null | sort)
}

@test "reachable follows same-repo workflows and actions, once each" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows" "$BATS_TEST_TMPDIR/.github/actions/a"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/top.yaml" <<'YAML'
jobs:
  one:
    uses: $/.github/workflows/mid.yaml
  two:
    uses: anthony-spruyt/repo-operator/.github/workflows/mid.yaml@0123456789abcdef0123456789abcdef01234567
  three:
    runs-on: ubuntu-latest
    steps:
      - uses: ./.github/actions/a
      - uses: actions/checkout@v7
YAML
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/mid.yaml"
  printf 'runs:\n  using: composite\n  steps:\n    - uses: $/.github/workflows/mid.yaml\n' >"$BATS_TEST_TMPDIR/.github/actions/a/action.yaml"
  run reachable "$BATS_TEST_TMPDIR" .github/workflows/top.yaml
  [ "$output" = $'.github/workflows/top.yaml\n.github/workflows/mid.yaml\n.github/actions/a/action.yaml' ]
}

@test "the guards catch an unhardened job, a persisted checkout and a tag pin" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/w.yaml" <<'YAML'
jobs:
  good:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567
        with:
          persist-credentials: false
  bad:
    steps:
      - uses: actions/checkout@v7
  call:
    uses: $/.github/workflows/x.yaml
YAML
  run unhardened "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:bad" ]
  run persisted_checkouts "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:actions/checkout@v7" ]
  run unpinned "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:actions/checkout@v7" ]
}

@test "pr_release_calls catches a pull request run that reaches a release, directly or through another workflow" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows" "$BATS_TEST_TMPDIR/src/templates/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/pr.yaml" <<'YAML'
on: [pull_request]
jobs:
  via:
    uses: $/.github/workflows/mid.yaml
YAML
  cat >"$BATS_TEST_TMPDIR/.github/workflows/mid.yaml" <<'YAML'
on: workflow_call
jobs:
  build:
    uses: $/.github/workflows/_build-image.yaml
    with:
      push: true
  check:
    uses: $/.github/workflows/_build-image.yaml
YAML
  cat >"$BATS_TEST_TMPDIR/src/templates/.github/workflows/ci.yaml" <<'YAML'
on:
  pull_request_target: {}
jobs:
  release:
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0123456789abcdef0123456789abcdef01234567
YAML
  cat >"$BATS_TEST_TMPDIR/src/templates/.github/workflows/release.yaml" <<'YAML'
on:
  push:
    branches: [main]
jobs:
  release:
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0123456789abcdef0123456789abcdef01234567
YAML
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/_build-image.yaml"
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/_release-please.yaml"
  run pr_release_calls "$BATS_TEST_TMPDIR"
  [ "$output" = $'.github/workflows/pr.yaml -> .github/workflows/mid.yaml:build\nsrc/templates/.github/workflows/ci.yaml -> src/templates/.github/workflows/ci.yaml:release' ]
}

@test "no workflow a pull request triggers reaches a release" {
  run pr_release_calls "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the release path covers the image build, its tests and its actions" {
  run reachable "$REPO_ROOT" "${RELEASE_ENTRIES[@]}"
  [[ "$output" == *".github/workflows/_build-image.yaml"* ]]
  [[ "$output" == *".github/actions/build-image/action.yaml"* ]]
  [[ "$output" == *".github/actions/publish-release/action.yaml"* ]]
  [[ "$output" == *".github/actions/detect-images/action.yaml"* ]]
}

@test "every release path job starts with harden-runner" {
  mapfile -t files < <(reachable "$REPO_ROOT" "${RELEASE_ENTRIES[@]}")
  run unhardened "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every release path checkout drops its token" {
  mapfile -t files < <(reachable "$REPO_ROOT" "${RELEASE_ENTRIES[@]}")
  run persisted_checkouts "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every release path action from another repo is pinned to a full commit SHA" {
  mapfile -t files < <(reachable "$REPO_ROOT" "${RELEASE_ENTRIES[@]}")
  run unpinned "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the release App token asks for only what release-please uses" {
  run yq -o=json -I0 '.jobs.release-please.steps[] | select(.id == "app-token") | .with | with_entries(select(.key | test("^permission-")))' "$WF/_release-please.yaml"
  [ "$output" = '{"permission-contents":"write","permission-pull-requests":"write"}' ]
}
