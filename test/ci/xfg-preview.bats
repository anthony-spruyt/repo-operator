#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CI="$REPO_ROOT/.github/workflows/ci.yaml"
  GUARD="github.event.action != 'labeled' || github.event.label.name == 'xfg/plan'"
}

@test "ci.yaml reruns on the labeled trigger" {
  run yq -o=json -I0 '.on.pull_request.types' "$CI"
  [ "$output" = '["opened","synchronize","reopened","labeled"]' ]
}

@test "a label other than xfg/plan runs no job, so it never posts a green summary over a failed run" {
  run yq -o=json -I0 '.jobs | to_entries | map(select(.value | has("needs") | not) | .key)' "$CI"
  [ "$output" = '["lint","sonar","lint-canary"]' ]
  run yq -r '.jobs.lint.if' "$CI"
  [ "$output" = "github.event_name != 'workflow_dispatch' && ($GUARD)" ]
  run yq -r '.jobs.sonar.if' "$CI"
  [ "$output" = "$GUARD" ]
  run yq -r '.jobs.summary.if' "$CI"
  [ "$output" = "always() && ($GUARD)" ]
  run yq -r '.jobs["xfg-preview"].if' "$CI"
  [[ "$output" == "always() && ($GUARD) && "* ]]
}

@test "xfg-preview decides with xfg-preview-needed.sh from the PR's own changes" {
  run yq -o=json -I0 '.jobs["xfg-preview"].steps[] | select(.name == "Checkout") | .with["fetch-depth"]' "$CI"
  [ "$output" = "2" ]
  run yq -o=json -I0 '.jobs["xfg-preview"].steps[] | select(.id == "needed") | .env' "$CI"
  [ "$output" = '{"EVENT_NAME":"${{ github.event_name }}","HEAD_REF":"${{ github.head_ref }}","HAS_LABEL":"${{ contains(github.event.pull_request.labels.*.name, '"'xfg/plan'"') }}"}' ]
  run yq -r '.jobs["xfg-preview"].steps[] | select(.id == "needed") | .run' "$CI"
  [[ "$output" == *"git diff --name-only HEAD^1 HEAD | .github/scripts/xfg-preview-needed.sh"* ]]
}

@test "xfg-preview always runs the config guard, and only the Plan App steps wait on the decision" {
  run yq -o=json -I0 '[.jobs["xfg-preview"].steps[] | [.name, (.if // null)]]' "$CI"
  [ "$output" = '[["Harden Runner",null],["Checkout",null],["Check xfg config",null],["Decide",null],["Preview notice","steps.needed.outputs.run == '"'true'"'"],["Preview Sync","steps.needed.outputs.run == '"'true'"'"],["Preview Secrets Sync","steps.needed.outputs.run == '"'true'"'"]]' ]
}

@test "repo-operator defines the xfg/plan label, so label sync keeps it" {
  run yq -r '.repos[] | select(.git == "https://github.com/anthony-spruyt/repo-operator.git") | .settings.labels["xfg/plan"].description' "$REPO_ROOT/src/repos.yaml"
  [ -n "$output" ]
  [ "$output" != "null" ]
}
