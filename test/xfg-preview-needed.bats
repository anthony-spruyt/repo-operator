#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/scripts/xfg-preview-needed.sh"
  export EVENT_NAME=pull_request HEAD_REF=renovate/foo HAS_LABEL=false
}

needed() {
  run --separate-stderr "$SCRIPT" <<<"$1"
  [ "$status" -eq 0 ]
}

@test "skips a PR without the label that changes only src/" {
  needed "src/groups.yaml"
  [ "$output" = "false" ]
}

@test "runs a PR with the xfg/plan label" {
  HAS_LABEL=true needed "src/groups.yaml"
  [ "$output" = "true" ]
}

@test "runs a PR without the label that changes the plan's workflow or scripts" {
  for f in .github/workflows/ci.yaml .github/scripts/check-xfg-config.sh .github/scripts/xfg-preview-needed.sh; do
    needed "$(printf 'README.md\n%s' "$f")"
    [ "$output" = "true" ]
  done
}

@test "matches the plan's files by full path only" {
  needed "$(printf 'src/templates/.github/workflows/ci.yaml\n.github/workflows/ci.yaml.bak')"
  [ "$output" = "false" ]
}

@test "skips a merge queue PR, even with the label and a plan file change" {
  HEAD_REF=mergify/merge-queue/7953688327 HAS_LABEL=true needed ".github/workflows/ci.yaml"
  [ "$output" = "false" ]
}

@test "runs on a dispatch" {
  EVENT_NAME=workflow_dispatch HEAD_REF="" needed ""
  [ "$output" = "true" ]
}

@test "skips a PR with no changed files" {
  needed ""
  [ "$output" = "false" ]
}

@test "logs why to stderr" {
  HAS_LABEL=true needed "src/groups.yaml"
  [[ "$stderr" == *"xfg/plan"* ]]
}

@test "fails without EVENT_NAME" {
  unset EVENT_NAME
  run "$SCRIPT" <<<""
  [ "$status" -ne 0 ]
}
