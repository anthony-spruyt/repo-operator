#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WF="$REPO_ROOT/.github/workflows"
}

@test "_images.yaml builds each image with its own language, falling back to the input, in its own workdir" {
  run yq -o=json -I0 '.jobs.build.with | [.language, .workdir]' "$WF/_images.yaml"
  [ "$output" = '["${{ matrix.language || inputs.language }}","${{ matrix.workdir }}"]' ]
  run yq -r '.on.workflow_call.inputs | has("workdir")' "$WF/_images.yaml"
  [ "$output" = "false" ]
}

@test "_build-image.yaml accepts node as a language, in the build and the publish job" {
  local validate
  validate=$(yq -r '.jobs.build.steps[] | select(.name == "Validate inputs") | .run' "$WF/_build-image.yaml")
  LANGUAGE=node run bash -c "$validate"
  [ "$status" -eq 0 ]
  LANGUAGE=rust run bash -c "$validate"
  [ "$status" -eq 1 ]
  [[ "$output" == *"language must be go, python, node or none, got 'rust'"* ]]
  run yq -r '.jobs.publish.steps[] | select(.id == "verify") | .run' "$WF/_build-image.yaml"
  [[ "$output" == *"$(head -n 4 <<<"$validate")"* ]]
}

@test "_build-image.yaml's test-node job type-checks and tests a node image in its workdir" {
  run yq -o=json -I0 '.on.workflow_call.inputs["node-version"] | [.type, .default]' "$WF/_build-image.yaml"
  [ "$output" = '["string","24"]' ]
  run yq -o=json -I0 '.jobs["test-node"] | [.if, .permissions, .["runs-on"]]' "$WF/_build-image.yaml"
  [ "$output" = '["inputs.language == '"'node'"'",{"contents":"read"},"ubuntu-latest"]' ]
  run yq -o=json -I0 '[.jobs["test-node"].steps[] | select(.uses) | (.uses | sub("@[0-9a-f]{40}$"; "@<sha>"))]' "$WF/_build-image.yaml"
  [ "$output" = '["step-security/harden-runner@<sha>","actions/checkout@<sha>","actions/setup-node@<sha>"]' ]
  run yq -o=json -I0 '.jobs["test-node"].steps[] | select(.uses | test("^actions/setup-node@")) | .with' "$WF/_build-image.yaml"
  [ "$output" = '{"node-version":"${{ inputs.node-version }}"}' ]
  run yq -o=json -I0 '[.jobs["test-node"].steps[] | select(.run) | .["working-directory"]] | unique' "$WF/_build-image.yaml"
  [ "$output" = '["${{ inputs.workdir }}"]' ]
  run yq -r '[.jobs["test-node"].steps[] | select(.run) | .run] | join("\n")' "$WF/_build-image.yaml"
  [[ "$output" == "npm ci --ignore-scripts"$'\n'"./node_modules/.bin/tsc --noEmit"$'\n'* ]]
  [[ "$output" == *'scripts?.test'*'npm test'* ]]
}

@test "_build-image.yaml's test-node job runs npm test only when package.json has a test script" {
  command -v node >/dev/null || skip "node is not installed"
  local script dir="$BATS_TEST_TMPDIR/pkg"
  script=$(yq -r '.jobs["test-node"].steps[] | select(.name == "Run tests") | .run' "$WF/_build-image.yaml")
  mkdir -p "$dir/bin"
  printf '#!/bin/sh\necho "npm $*"\n' >"$dir/bin/npm"
  chmod +x "$dir/bin/npm"
  echo '{"scripts":{"build":"tsc"}}' >"$dir/package.json"
  run env -C "$dir" PATH="$dir/bin:$PATH" WORKDIR=pkg bash -c "$script"
  [ "$status" -eq 0 ]
  [ "$output" = "::notice::No test script in pkg/package.json, skipping tests" ]
  echo '{"scripts":{"test":"vitest run"}}' >"$dir/package.json"
  run env -C "$dir" PATH="$dir/bin:$PATH" WORKDIR=pkg bash -c "$script"
  [ "$status" -eq 0 ]
  [ "$output" = "npm test" ]
}

@test "_build-image.yaml's build and publish wait for test-node like the other test jobs" {
  local job
  for job in build publish; do
    run yq -o=json -I0 ".jobs.$job.needs" "$WF/_build-image.yaml"
    echo "$job needs: $output"
    [ "$output" = '["test-go","test-python","test-node"]' ]
    run yq -r ".jobs.$job.if" "$WF/_build-image.yaml"
    echo "$job if: $output"
    [[ "$output" == *"(needs.test-node.result == 'success' || needs.test-node.result == 'skipped')"* ]]
  done
}

@test "_build-image.yaml passes go-mod only for go, from the image's workdir" {
  run yq -r '[(.jobs.build.steps[], .jobs.publish.steps[]) | select(.uses == "$/.github/actions/build-image") | .with["go-mod"]] | unique | .[]' "$WF/_build-image.yaml"
  [ "$output" = "\${{ inputs.language == 'go' && format('{0}/go.mod', inputs.workdir) || '' }}" ]
}

@test "_release-please.yaml publishes each package with its own language and workdir" {
  run yq -o=json -I0 '.jobs.build.with | [.language, .workdir]' "$WF/_release-please.yaml"
  [ "$output" = '["${{ matrix.language || inputs.language }}","${{ matrix.workdir }}"]' ]
  run yq -r '.on.workflow_call.inputs | has("workdir")' "$WF/_release-please.yaml"
  [ "$output" = "false" ]
}

@test "the image workflows pass actionlint with this repo's config" {
  cd "$REPO_ROOT"
  run actionlint -no-color .github/workflows/_images.yaml .github/workflows/_build-image.yaml \
    .github/workflows/_release-please.yaml
  echo "$output"
  [ "$status" -eq 0 ]
}
