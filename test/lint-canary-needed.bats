#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/scripts/lint-canary-needed.sh"
  export EVENT_NAME=pull_request HEAD_REF=renovate/foo
}

needed() {
  run --separate-stderr "$SCRIPT" <<<"$1"
  [ "$status" -eq 0 ]
}

@test "runs a PR that changes a lint pin or lint template" {
  for f in src/groups.yaml src/repos.yaml src/templates/.golangci.yml src/templates/.mega-linter-base.yml \
    src/templates/.mega-linter.yml src/templates/lint.sh.tmpl src/templates/ruff-base.toml \
    src/templates/trivy-mega-linter.yaml; do
    needed "$(printf 'README.md\n%s' "$f")"
    [ "$output" = "true" ]
  done
}

@test "runs a PR that changes the canary's workflow or script" {
  for f in .github/workflows/lint-canary.yaml .github/scripts/lint-canary-needed.sh; do
    needed "$f"
    [ "$output" = "true" ]
  done
}

@test "skips a PR that changes no lint path" {
  needed "$(printf 'README.md\nsrc/templates/.github/workflows/ci.yaml\nsrc/settings.yaml')"
  [ "$output" = "false" ]
}

@test "matches lint paths by full path only" {
  needed "$(printf 'src/groups.yaml.bak\ndocs/src/groups.yaml')"
  [ "$output" = "false" ]
}

@test "skips a merge queue PR that changes a lint path" {
  HEAD_REF=mergify/merge-queue/7953688327 needed "src/groups.yaml"
  [ "$output" = "false" ]
}

@test "skips anything but a PR" {
  for e in push workflow_dispatch; do
    EVENT_NAME=$e HEAD_REF="" needed "src/groups.yaml"
    [ "$output" = "false" ]
  done
}

@test "logs why to stderr" {
  needed "src/groups.yaml"
  [[ "$stderr" == *"lint"* ]]
}

@test "fails without EVENT_NAME" {
  unset EVENT_NAME
  run "$SCRIPT" <<<""
  [ "$status" -ne 0 ]
}
