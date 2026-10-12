#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WF="$REPO_ROOT/.github/workflows/_container-retention.yaml"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output"
  : >"$GITHUB_OUTPUT"
}

step_script() {
  yq -r ".jobs.packages.steps[] | select(.name == \"$1\") | .run" "$WF"
}

@test "the packages job reads the repo it discovers images in, and the GHCR job only writes packages" {
  run yq -o=json -I0 '.jobs.packages.permissions' "$WF"
  [ "$output" = '{"contents":"read"}' ]
  run yq -o=json -I0 '.jobs.packages.outputs' "$WF"
  [ "$output" = '{"list":"${{ steps.packages.outputs.list }}"}' ]
  run yq -o=json -I0 '.jobs.cleanup | [.permissions, .needs, .if, ([.steps[] | select(has("uses")) | .uses | sub("@[0-9a-f]{40}$"; "@<sha>")])]' "$WF"
  [ "$output" = '[{"packages":"write"},"packages","needs.packages.outputs.list != '"''"'",["step-security/harden-runner@<sha>","dataaxiom/ghcr-cleanup-action@<sha>"]]' ]
  run yq -r '.jobs.cleanup.steps[] | select(.name == "Clean up package versions") | .with.package' "$WF"
  [ "$output" = '${{ needs.packages.outputs.list }}' ]
}

@test "the Docker Hub job runs only with a namespace, in its own main-only environment, with no GitHub token" {
  run yq -o=json -I0 '.jobs.dockerhub | [.needs, .if, .environment, .permissions]' "$WF"
  [ "$output" = '["packages","needs.packages.outputs.list != '"''"' && inputs.dockerhub-namespace != '"''"'","container-retention",{}]' ]
}

@test "Docker Hub runs for the same repo queue rather than overlap" {
  run yq -o=json -I0 '.jobs.dockerhub.concurrency' "$WF"
  [ "$output" = '{"group":"container-retention-dockerhub-${{ github.repository }}","cancel-in-progress":false}' ]
}

@test "the Docker Hub job reaches only Docker Hub" {
  run yq -o=json -I0 '.jobs.dockerhub.steps[0] | [(.uses | sub("@[0-9a-f]{40}$"; "@<sha>")), .with["egress-policy"], .with["allowed-endpoints"]]' "$WF"
  [ "$output" = '["step-security/harden-runner@<sha>","block","hub.docker.com:443"]' ]
}

@test "the Docker Hub job passes every cleanup input and the retention token to the action" {
  run yq -o=json -I0 '.jobs.dockerhub.steps[1] | [.uses, .with]' "$WF"
  [ "$output" = '["$/.github/actions/dockerhub-cleanup",{"namespace":"${{ inputs.dockerhub-namespace }}","username":"${{ inputs.dockerhub-username }}","token":"${{ secrets.DOCKERHUB_RETENTION_TOKEN }}","packages":"${{ needs.packages.outputs.list }}","older-than":"${{ inputs.older-than }}","keep-n-tagged":"${{ inputs.keep-n-tagged }}","dry-run":"${{ inputs.dry-run }}"}]' ]
  run yq -o=json -I0 '[.on.workflow_call.inputs | (.["dockerhub-namespace"], .["dockerhub-username"]) | [.required, .type, .default]]' "$WF"
  [ "$output" = '[[false,"string",""],[false,"string",""]]' ]
  run yq -o=json -I0 '.on.workflow_call.secrets' "$WF"
  [ "$output" = '{"DOCKERHUB_RETENTION_TOKEN":{"description":"Docker Hub token with the Read, Write, Delete scope; required with dockerhub-namespace","required":false}}' ]
}

@test "no job but the Docker Hub job reads a secret" {
  run yq -r '[.jobs | to_entries[] | select([.value | .. | select(tag == "!!str")] | any_c(test("secrets\\."))) | .key] | join(",")' "$WF"
  [ "$output" = "dockerhub" ]
}

@test "an empty packages input checks out the caller without credentials and detects every image" {
  run yq -o=json -I0 '.jobs.packages.steps[] | select(.name == "Checkout") | [.if, .with["persist-credentials"], (.uses | sub("@[0-9a-f]{40}$"; "@<sha>"))]' "$WF"
  [ "$output" = '["inputs.packages == '"''"'",false,"actions/checkout@<sha>"]' ]
  run yq -o=json -I0 '.jobs.packages.steps[] | select(.id == "detect") | [.if, .uses, .with]' "$WF"
  [ "$output" = '["inputs.packages == '"''"'","$/.github/actions/detect-images",{"mode":"all","root-name":"${{ inputs.image }}"}]' ]
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
  run yq -r '[.jobs.cleanup.if, .jobs.dockerhub.if] | map(test("^needs\\.packages\\.outputs\\.list != '"''"'")) | all' "$WF"
  [ "$output" = "true" ]
}

@test "an empty or malformed matrix fails instead of skipping" {
  for bad in "" "not json" "{}" '{"include":null}'; do
    run env PACKAGES="" MATRIX="$bad" bash -e -c "$(step_script "Resolve packages")"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [[ "$output" != *"::notice::"* ]]
    run grep -q '^list=' "$GITHUB_OUTPUT"
    [ "$status" -ne 0 ]
  done
}

@test "the image input defaults to empty and is passed to detect-images as root-name" {
  run yq -o=json -I0 '.on.workflow_call.inputs.image | [.required, .type, .default]' "$WF"
  [ "$output" = '[false,"string",""]' ]
  run yq -r '.on.workflow_call.inputs.image.description' "$WF"
  [ "$output" = "$(yq -r '.on.workflow_call.inputs.image.description' "$REPO_ROOT/.github/workflows/_images.yaml")" ]
  run yq -r '.jobs.packages.steps[] | select(.id == "detect") | .with["root-name"]' "$WF"
  [ "$output" = '${{ inputs.image }}' ]
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
  run env PACKAGES="" OLDER_THAN="4 weeks" KEEP_N_TAGGED=10000000000 bash -c "$(step_script "Validate inputs")"
  [ "$status" -eq 1 ]
  run env PACKAGES="" OLDER_THAN="4 weeks" KEEP_N_TAGGED=5 bash -c "$(step_script "Validate inputs")"
  [ "$status" -eq 0 ]
}
