#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WF="$REPO_ROOT/.github/workflows/_container-retention.yaml"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : >"$GITHUB_OUTPUT"
}

step_script() {
  yq -r ".jobs.cleanup.steps[] | select(.name == \"$1\") | .run" "$WF"
}

@test "the cleanup job can read the repo it discovers images in and write packages" {
  run yq -o=json -I0 '.jobs.cleanup.permissions' "$WF"
  [ "$output" = '{"contents":"read","packages":"write"}' ]
}

@test "an empty packages input checks out the caller without credentials and detects every image" {
  run yq -o=json -I0 '.jobs.cleanup.steps[] | select(.name == "Checkout") | [.if, .with["persist-credentials"], (.uses | sub("@[0-9a-f]{40}$"; "@<sha>"))]' "$WF"
  [ "$output" = '["inputs.packages == '"''"'",false,"actions/checkout@<sha>"]' ]
  run yq -o=json -I0 '.jobs.cleanup.steps[] | select(.id == "detect") | [.if, .uses, .with]' "$WF"
  [ "$output" = '["inputs.packages == '"''"'","$/.github/actions/detect-images",{"mode":"all"}]' ]
}

@test "discovered images become the comma-separated package list" {
  run env PACKAGES="" MATRIX='{"include":[{"name":"chrony"},{"name":"llm-guard"},{"name":"llm-tool-guard"}]}' \
    bash -c "$(step_script "Resolve packages")"
  [ "$status" -eq 0 ]
  grep -qx 'list=chrony,llm-guard,llm-tool-guard' "$GITHUB_OUTPUT"
}

@test "a single discovered image is that image alone" {
  run env PACKAGES="" MATRIX='{"include":[{"name":"sungather"}]}' bash -c "$(step_script "Resolve packages")"
  [ "$status" -eq 0 ]
  grep -qx 'list=sungather' "$GITHUB_OUTPUT"
}

@test "no discovered images skips the cleanup with a notice, not a failure" {
  run env PACKAGES="" MATRIX='{"include":[]}' bash -c "$(step_script "Resolve packages")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::notice::"* ]]
  grep -qx 'list=' "$GITHUB_OUTPUT"
  run yq -r '.jobs.cleanup.steps[] | select(.name == "Clean up package versions") | .if' "$WF"
  [ "$output" = "steps.packages.outputs.list != ''" ]
}

@test "a non-empty packages input overrides discovery" {
  run env PACKAGES="a,b" MATRIX='{"include":[{"name":"chrony"}]}' bash -c "$(step_script "Resolve packages")"
  [ "$status" -eq 0 ]
  grep -qx 'list=a,b' "$GITHUB_OUTPUT"
}

@test "wildcards in packages are refused" {
  run env PACKAGES="foo*" OLDER_THAN="4 weeks" KEEP_N_TAGGED=5 bash -c "$(step_script "Validate inputs")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Wildcards need a PAT"* ]]
}

@test "older-than and keep-n-tagged keep their guards" {
  run env PACKAGES="" OLDER_THAN="0 days" KEEP_N_TAGGED=5 bash -c "$(step_script "Validate inputs")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"older-than must be a positive interval"* ]]
  run env PACKAGES="" OLDER_THAN="4 weeks" KEEP_N_TAGGED=0 bash -c "$(step_script "Validate inputs")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"keep-n-tagged must be a whole number"* ]]
  run env PACKAGES="" OLDER_THAN="4 weeks" KEEP_N_TAGGED=5 bash -c "$(step_script "Validate inputs")"
  [ "$status" -eq 0 ]
}
