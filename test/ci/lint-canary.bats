#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CI="$REPO_ROOT/.github/workflows/ci.yaml"
  CANARY="$REPO_ROOT/.github/workflows/lint-canary.yaml"
  GUARD="github.event.action != 'labeled' || github.event.label.name == 'xfg/plan'"
}

@test "ci.yaml calls the canary and summary judges it" {
  run yq -o=json -I0 '.jobs["lint-canary"] | del(.if)' "$CI"
  [ "$output" = '{"permissions":{"contents":"read"},"uses":"./.github/workflows/lint-canary.yaml","secrets":"inherit"}' ]
  run yq -r '.jobs["lint-canary"].if' "$CI"
  [ "$output" = "$GUARD" ]
  run yq -r '.jobs.summary.needs | any_c(. == "lint-canary")' "$CI"
  [ "$output" = "true" ]
}

@test "the canary only runs when ci.yaml calls it" {
  run yq -o=json -I0 '.on | keys' "$CANARY"
  [ "$output" = '["workflow_call"]' ]
}

@test "render decides with lint-canary-needed.sh from the PR's own changes" {
  run yq -o=json -I0 '.jobs.render.steps[] | select(.name == "Checkout") | .with["fetch-depth"]' "$CANARY"
  [ "$output" = "2" ]
  run yq -o=json -I0 '.jobs.render.steps[] | select(.id == "needed") | .env' "$CANARY"
  [ "$output" = '{"EVENT_NAME":"${{ github.event_name }}","HEAD_REF":"${{ github.head_ref }}"}' ]
  run yq -r '.jobs.render.steps[] | select(.id == "needed") | .run' "$CANARY"
  [[ "$output" == *"git diff --name-only HEAD^1 HEAD | .github/scripts/lint-canary-needed.sh"* ]]
}

@test "a skipped canary renders nothing and lints no repo" {
  run yq -o=json -I0 '[.jobs.render.steps[] | [.name, (.if // null)]]' "$CANARY"
  [ "$output" = '[["Harden Runner",null],["Checkout",null],["Decide",null],["Render planned files","steps.needed.outputs.run == '"'true'"'"],["Find repos whose lint files change","steps.needed.outputs.run == '"'true'"'"],["Upload render","steps.needed.outputs.run == '"'true'"'"]]' ]
  run yq -r '.jobs.render.outputs.repos' "$CANARY"
  [ "$output" = "\${{ steps.affected.outputs.repos || '[]' }}" ]
  run yq -r '.jobs.lint.if' "$CANARY"
  [ "$output" = "needs.render.outputs.repos != '[]'" ]
}
