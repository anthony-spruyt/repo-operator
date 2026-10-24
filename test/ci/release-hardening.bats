#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WF="$REPO_ROOT/.github/workflows"
  export PR_TRIGGERS='^(pull_request(_target|_review|_review_comment)?|merge_group|issue_comment|workflow_run|check_run|check_suite|status|deployment_status)$'
  RELEASE_ENTRIES=(.github/workflows/_release-please.yaml .github/workflows/_release-images.yaml src/templates/.github/workflows/release-please.yaml src/templates/.github/workflows/image-release-please.yaml)
}

# local_target <root> <from> <uses> - prints the repo path a same-repo uses: in <from> points at, or nothing for another repo's action; a template's $/ and ./ are its target repo
local_target() {
  local root="$1" from="$2" ref="${3%@*}"
  case "$ref" in
  '$/'* | ./*)
    ref="${ref#\$/}"
    ref="${ref#./}"
    [[ "$from" != src/templates/* ]] || ref="src/templates/$ref"
    ;;
  anthony-spruyt/repo-operator/*) ref="${ref#anthony-spruyt/repo-operator/}" ;;
  *) return 0 ;;
  esac
  case "$ref" in
  *.yaml | *.yml) echo "$ref" ;;
  *) if [ -f "$root/$ref/action.yml" ]; then echo "$ref/action.yml"; else echo "$ref/action.yaml"; fi ;;
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
      target=$(local_target "$root" "$file" "$use")
      [ -n "$target" ] && queue+=("$target")
    done < <(uses_of "$root/$file")
  done
}

# unhardened <root> <file>... - prints file:job for each job with steps whose first step is neither harden-runner nor the composite that wraps it
unhardened() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | select((.value.steps[0].uses // "") | test("^(step-security/harden-runner@|[$]/[.]github/actions/harden-runner$)") | not) | .key' "$root/$file" | sed "s|^|$file:|"
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

# unpinned <root> <file>... - prints file:uses for each action not pinned to a full commit SHA, other than a $/ or ./ path
unpinned() {
  local root="$1" file use
  shift
  for file in "$@"; do
    while IFS= read -r use; do
      [[ "$use" != '$/'* && "$use" != ./* ]] || continue
      [[ "$use" =~ @[0-9a-f]{40}$ ]] || echo "$file:$use"
    done < <(uses_of "$root/$file")
  done
}

# pr_triggered <file> - true when a pull request, its review or comments, or a run one finished can start <file>
pr_triggered() {
  yq -r '.on | (if tag == "!!map" then keys elif tag == "!!str" then [.] else . end) | .[] | select(test(strenv(PR_TRIGGERS)))' "$1" | grep -q .
}

# release_jobs <root> <file> - prints file:job for each job <file> reaches that calls a release workflow or a pushing image build
release_jobs() {
  local root="$1" file
  while IFS= read -r file; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.uses != null) | select((.value.uses | test("/_release-(please|images)\.yaml(@|$)")) or ((.value.uses | test("/_build-image\.yaml(@|$)")) and ((.value.with.push // false) != false))) | .key' "$root/$file" | sed "s|^|$file:|"
  done < <(reachable "$root" "$2")
}

# pr_release_calls <root> - prints start -> file:job for each call a pull request run reaches that releases
pr_release_calls() {
  local root="$1" start
  while IFS= read -r start; do
    pr_triggered "$root/$start" || continue
    release_jobs "$root" "$start" | sed "s|^|$start -> |"
  done < <(cd "$root" && find .github/workflows src/templates/.github/workflows -maxdepth 1 -name '*.y*ml' 2>/dev/null | sort)
}

# overlay_release_calls <src> - prints file: workflow for each workflow content overlay that calls a release or sets push, or adds a pull request trigger to a workflow whose template releases
overlay_release_calls() {
  local src="$1" file key tpl
  for file in "$src"/*.yaml; do
    yq -r 'explode(.) | [.. | select(tag == "!!map" and has("files")) | .files | select(tag == "!!map") | to_entries[] | select(.key | test("^\.github/workflows/")) | select(.value.content | tag == "!!map") | select([.value.content | .. | select(tag == "!!map") | select(((.uses // "") | test("/_release-(please|images)\.yaml(@|$)")) or ((.with // {}) | has("push")))] | length > 0) | .key] | unique | .[]' "$file" | sed "s|^|${file##*/}: |"
    while IFS= read -r key; do
      while IFS= read -r tpl; do
        [ -f "$src/templates/$tpl" ] || {
          echo "${file##*/}: $key: no src/templates/$tpl"
          continue
        }
        if [ -n "$(release_jobs "$src/.." "src/templates/$tpl")" ]; then
          echo "${file##*/}: $key"
          break
        fi
      done < <(KEY="$key" yq -r 'explode(.) | .. | select(tag == "!!map" and has("files")) | .files | select(tag == "!!map") | .[strenv(KEY)].content | select(tag == "!!str") | select(test("^@templates/")) | sub("^@templates/"; "")' "$src"/*.yaml | sort -u)
    done < <(yq -r 'explode(.) | [.. | select(tag == "!!map" and has("files")) | .files | select(tag == "!!map") | to_entries[] | select(.key | test("^\.github/workflows/")) | select(.value.content | tag == "!!map") | select(.value.content | has("on")) | select(.value.content.on | (if tag == "!!map" then keys elif tag == "!!str" then [.] else . end) | map(select(test(strenv(PR_TRIGGERS)))) | length > 0) | .key] | unique | .[]' "$file")
  done | sort -u
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

@test "reachable resolves ./ and $/ in a template inside the template tree, and finds action.yml" {
  mkdir -p "$BATS_TEST_TMPDIR/src/templates/.github/workflows" "$BATS_TEST_TMPDIR/src/templates/.github/actions/b"
  cat >"$BATS_TEST_TMPDIR/src/templates/.github/workflows/ci.yaml" <<'YAML'
jobs:
  repo:
    uses: "./.github/workflows/ci-repo.yaml"
  step:
    runs-on: ubuntu-latest
    steps:
      - uses: $/.github/actions/b
YAML
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/src/templates/.github/workflows/ci-repo.yaml"
  printf 'runs:\n  using: composite\n  steps: []\n' >"$BATS_TEST_TMPDIR/src/templates/.github/actions/b/action.yml"
  run reachable "$BATS_TEST_TMPDIR" src/templates/.github/workflows/ci.yaml
  [ "$output" = $'src/templates/.github/workflows/ci.yaml\nsrc/templates/.github/workflows/ci-repo.yaml\nsrc/templates/.github/actions/b/action.yml' ]
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
  switched:
    steps:
      - uses: $/.github/actions/harden-runner
  bad:
    steps:
      - uses: actions/checkout@v7
  call:
    uses: $/.github/workflows/x.yaml
  branch:
    uses: anthony-spruyt/repo-operator/.github/workflows/x.yaml@main
YAML
  run unhardened "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:bad" ]
  run persisted_checkouts "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:actions/checkout@v7" ]
  run unpinned "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:anthony-spruyt/repo-operator/.github/workflows/x.yaml@main\n.github/workflows/w.yaml:actions/checkout@v7' ]
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
  cat >"$BATS_TEST_TMPDIR/.github/workflows/after.yaml" <<'YAML'
on:
  workflow_run:
    workflows: [CI]
jobs:
  images:
    uses: $/.github/workflows/_release-images.yaml
YAML
  cat >"$BATS_TEST_TMPDIR/.github/workflows/check.yaml" <<'YAML'
on: [check_run]
jobs:
  images:
    uses: $/.github/workflows/_release-images.yaml
YAML
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/_build-image.yaml"
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/_release-please.yaml"
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/_release-images.yaml"
  run pr_release_calls "$BATS_TEST_TMPDIR"
  [ "$output" = $'.github/workflows/after.yaml -> .github/workflows/after.yaml:images\n.github/workflows/check.yaml -> .github/workflows/check.yaml:images\n.github/workflows/pr.yaml -> .github/workflows/mid.yaml:build\nsrc/templates/.github/workflows/ci.yaml -> src/templates/.github/workflows/ci.yaml:release' ]
}

@test "overlay_release_calls catches an overlay that adds a release call or a push, or a pull request trigger to a release caller" {
  mkdir -p "$BATS_TEST_TMPDIR/src"
  cat >"$BATS_TEST_TMPDIR/src/groups.yaml" <<'YAML'
groups:
  g:
    files:
      .github/workflows/ci.yaml:
        content:
          jobs:
            release:
              uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0123456789abcdef0123456789abcdef01234567
      .github/workflows/other.yaml:
        content: "@templates/.github/workflows/other.yaml"
YAML
  cat >"$BATS_TEST_TMPDIR/src/repos.yaml" <<'YAML'
repos:
  - git: https://github.com/anthony-spruyt/r.git
    files:
      .github/workflows/ci.yaml:
        content:
          jobs:
            image:
              with: &w
                push: true
      .github/workflows/release-please.yaml:
        content:
          jobs:
            images:
              with: *w
      .github/workflows/lint.yaml:
        content:
          jobs:
            image:
              with:
                test-command: ./t.sh
YAML
  cat >"$BATS_TEST_TMPDIR/src/files.yaml" <<'YAML'
files:
  .github/workflows/ci.yaml:
    content:
      jobs:
        images:
          uses: $/.github/workflows/_release-images.yaml
  .github/workflows/release-please.yaml:
    content:
      "on":
        pull_request_target: {}
YAML
  cat >>"$BATS_TEST_TMPDIR/src/groups.yaml" <<'YAML'
  rp:
    files:
      .github/workflows/release-please.yaml:
        content: "@templates/.github/workflows/rp.yaml"
  other-pr:
    files:
      .github/workflows/other.yaml:
        content:
          "on": [pull_request]
YAML
  mkdir -p "$BATS_TEST_TMPDIR/src/templates/.github/workflows" "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/src/templates/.github/workflows/rp.yaml" <<'YAML'
on: push
jobs:
  release:
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0123456789abcdef0123456789abcdef01234567
YAML
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/src/templates/.github/workflows/other.yaml"
  echo 'jobs: {}' >"$BATS_TEST_TMPDIR/.github/workflows/_release-please.yaml"
  run overlay_release_calls "$BATS_TEST_TMPDIR/src"
  [ "$output" = $'files.yaml: .github/workflows/ci.yaml\nfiles.yaml: .github/workflows/release-please.yaml\ngroups.yaml: .github/workflows/ci.yaml\nrepos.yaml: .github/workflows/ci.yaml\nrepos.yaml: .github/workflows/release-please.yaml' ]
}

@test "no workflow overlay in src adds a release call, a push, or a pull request trigger to a release caller" {
  run overlay_release_calls "$REPO_ROOT/src"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "shared workflows and actions never use ./, which resolves in the caller's repo" {
  local file
  for file in "$WF"/_*.y*ml "$REPO_ROOT"/.github/actions/*/action.y*ml; do
    run uses_of "$file"
    [[ "$output" != *"./"* ]] || {
      echo "$file: $output"
      return 1
    }
  done
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
  [[ "$output" == *".github/actions/release-drafts/action.yaml"* ]]
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
