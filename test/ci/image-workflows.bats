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
  [ "$output" = '["$/.github/actions/harden-runner","actions/checkout@<sha>","actions/setup-node@<sha>"]' ]
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
  run yq -o=json -I0 ".jobs.build.needs" "$WF/_build-image.yaml"
  [ "$output" = '["test-go","test-python","test-node"]' ]
  run yq -o=json -I0 ".jobs.publish.needs" "$WF/_build-image.yaml"
  [ "$output" = '["test-go","test-python","test-node","build"]' ]
  for job in build publish; do
    run yq -r ".jobs.$job.if" "$WF/_build-image.yaml"
    echo "$job if: $output"
    [[ "$output" == *"(needs.test-node.result == 'success' || needs.test-node.result == 'skipped')"* ]]
  done
}

@test "_build-image.yaml passes go-mod only for go, from the image's workdir" {
  run yq -r '[(.jobs.build.steps[], .jobs.publish.steps[]) | select(.uses == "$/.github/actions/build-image") | .with["go-mod"]] | unique | .[]' "$WF/_build-image.yaml"
  [ "$output" = "\${{ inputs.language == 'go' && format('{0}/go.mod', inputs.workdir) || '' }}" ]
}

@test "build-image's Go build args leave GO_VERSION to the Dockerfile" {
  local script work
  script=$(yq -r '.runs.steps[] | select(.name == "Go build args") | .run' "$REPO_ROOT/.github/actions/build-image/action.yaml")
  work="$BATS_TEST_TMPDIR/ctx"
  mkdir -p "$work"
  printf 'module example.com/m\n\ngo 1.27.1\n' >"$work/go.mod"
  git -C "$work" init -q
  git -C "$work" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" VERSION=1.2.3 CONTEXT="$work" EXTRA_BUILD_ARGS="FOO=bar" run bash -c "$script"
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/out"
  [[ "$output" != *GO_VERSION* ]]
  [[ "$output" == *$'\nVERSION=v1.2.3\n'* ]]
  [[ "$output" == *$'\nCOMMIT='* ]]
  [[ "$output" == *$'\nFOO=bar\n'* ]]
}

@test "_build-image.yaml hands _go-test the image's Dockerfile, defaulting to the context's" {
  run yq -r '.jobs["test-go"].with.dockerfile' "$WF/_build-image.yaml"
  [ "$output" = "\${{ inputs.dockerfile || format('{0}/Dockerfile', inputs.context) }}" ]
}

@test "_go-test.yaml takes a dockerfile input, empty by default" {
  run yq -o=json -I0 '.on.workflow_call.inputs.dockerfile | [.type, .required, .default]' "$WF/_go-test.yaml"
  [ "$output" = '["string",false,""]' ]
}

@test "_go-test.yaml sets up Go from the resolved version, falling back to go.mod" {
  run yq -o=json -I0 '.jobs.test.steps[] | select(.name == "Setup Go") | .with | [.["go-version"], .["go-version-file"]]' "$WF/_go-test.yaml"
  [ "$output" = '["${{ steps.go.outputs.go-version }}","${{ steps.go.outputs.go-version-file }}"]' ]
  run yq -r '.jobs.test.steps[] | select(.id == "go") | .["working-directory"]' "$WF/_go-test.yaml"
  [ "$output" = "." ]
}

go_version_step() {
  local script work="$BATS_TEST_TMPDIR/repo"
  script=$(yq -r '.jobs.test.steps[] | select(.id == "go") | .run' "$WF/_go-test.yaml")
  mkdir -p "$work"
  (cd "$work" && GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash -c "$script")
}

@test "_go-test.yaml takes Go from the Dockerfile's ARG GO_VERSION" {
  mkdir -p "$BATS_TEST_TMPDIR/repo/cmd/app"
  printf '# renovate: depName=golang datasource=docker\nARG GO_VERSION=1.27.1\nFROM golang:${GO_VERSION}-alpine AS builder\n' >"$BATS_TEST_TMPDIR/repo/cmd/app/Dockerfile"
  DOCKERFILE=cmd/app/Dockerfile WORKDIR=cmd/app run go_version_step
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = $'go-version=1.27.1\ngo-version-file=' ]
}

@test "_go-test.yaml falls back to go.mod when the Dockerfile has no ARG GO_VERSION" {
  mkdir -p "$BATS_TEST_TMPDIR/repo"
  printf 'FROM scratch\nCOPY plugin /plugin\n' >"$BATS_TEST_TMPDIR/repo/Dockerfile"
  DOCKERFILE=Dockerfile WORKDIR=. run go_version_step
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = $'go-version=\ngo-version-file=./go.mod' ]
}

@test "_go-test.yaml falls back to go.mod when there is no Dockerfile or the ARG is not a version" {
  DOCKERFILE=Dockerfile WORKDIR=svc run go_version_step
  [ "$status" -eq 0 ]
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = $'go-version=\ngo-version-file=svc/go.mod' ]
  rm "$BATS_TEST_TMPDIR/out"
  printf 'ARG GO_VERSION\nARG GO_VERSION=${OTHER}\n' >"$BATS_TEST_TMPDIR/repo/Dockerfile"
  DOCKERFILE=Dockerfile WORKDIR=svc run go_version_step
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = $'go-version=\ngo-version-file=svc/go.mod' ]
  rm "$BATS_TEST_TMPDIR/out"
  DOCKERFILE="" WORKDIR=svc run go_version_step
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = $'go-version=\ngo-version-file=svc/go.mod' ]
}

@test "_release-please.yaml runs only release-please and outputs what it released" {
  run yq -o=json -I0 '[(.jobs | keys), (.on.workflow_call.inputs // {} | keys), (.on.workflow_call.secrets | keys), (.on.workflow_call.outputs | keys)]' "$WF/_release-please.yaml"
  [ "$output" = '[["release-please"],[],["RELEASE_PLEASE_APP_CLIENT_ID","RELEASE_PLEASE_APP_PRIVATE_KEY"],["release-created","releases"]]' ]
  run yq -o=json -I0 '.on.workflow_call.outputs | [.["release-created"].value, .releases.value]' "$WF/_release-please.yaml"
  [ "$output" = '["${{ jobs.release-please.outputs.release-created }}","${{ jobs.release-please.outputs.releases }}"]' ]
  run yq -o=json -I0 '.jobs["release-please"].outputs' "$WF/_release-please.yaml"
  [ "$output" = '{"release-created":"${{ steps.release.outputs.releases_created }}","releases":"${{ toJSON(steps.release.outputs) }}"}' ]
}

@test "_release-images.yaml detects the images in the releases it is given" {
  run yq -o=json -I0 '.on.workflow_call.inputs.releases | [.type, .required]' "$WF/_release-images.yaml"
  [ "$output" = '["string",true]' ]
  run yq -o=json -I0 '.jobs.detect.steps[] | select(.id == "detect") | [.uses, .with]' "$WF/_release-images.yaml"
  [ "$output" = '["$/.github/actions/detect-images",{"mode":"released","releases":"${{ inputs.releases }}","root-name":"${{ inputs.image }}"}]' ]
  run yq -o=json -I0 '[(.jobs | keys), (.on.workflow_call.secrets | keys), (.on.workflow_call.outputs | keys)]' "$WF/_release-images.yaml"
  [ "$output" = '[["detect","build"],["DOCKERHUB_TOKEN"],["images"]]' ]
  run yq -o=json -I0 '.jobs.build | [.needs, .if, .strategy.matrix]' "$WF/_release-images.yaml"
  [ "$output" = '["detect","needs.detect.outputs.has-images == '"'true'"'","${{ fromJSON(needs.detect.outputs.matrix) }}"]' ]
}

@test "_release-images.yaml publishes each image with its own language and workdir" {
  run yq -o=json -I0 '.jobs.build.with | [.language, .workdir, .push]' "$WF/_release-images.yaml"
  [ "$output" = '["${{ matrix.language || inputs.language }}","${{ matrix.workdir }}",true]' ]
  run yq -r '.on.workflow_call.inputs | has("workdir")' "$WF/_release-images.yaml"
  [ "$output" = "false" ]
}

@test "the release workflows leave concurrency to their caller, which runs both" {
  local wf
  for wf in _release-please.yaml _release-images.yaml; do
    run yq -r '[.. | select(tag == "!!map" and has("concurrency"))] | length' "$WF/$wf"
    echo "$wf: $output"
    [ "$output" = "0" ]
  done
}

@test "the image workflows pass actionlint with this repo's config" {
  cd "$REPO_ROOT"
  run actionlint -no-color .github/workflows/_images.yaml .github/workflows/_build-image.yaml \
    .github/workflows/_release-please.yaml .github/workflows/_release-images.yaml
  echo "$output"
  [ "$status" -eq 0 ]
}

restore_script() {
  yq -r '.jobs.publish.steps[] | select(.name == "Restore prepared context") | .run' "$WF/_build-image.yaml"
}

# restore <dir> - runs the publish job's restore step on <dir>/prepared/prepared-context.tar, into <dir>/ctx
restore() {
  mkdir -p "$1/ctx"
  env -C "$1" RUNNER_TEMP="$1" CONTEXT=ctx bash -euo pipefail -c "$(restore_script)"
}

@test "_build-image.yaml builds and tests every image, releases included, in a read-only job" {
  run yq -o=json -I0 '.jobs.build | [has("environment"), .permissions, (.if | test("inputs\\.push"))]' "$WF/_build-image.yaml"
  [ "$output" = '[false,{"contents":"read"},false]' ]
  run yq -o=json -I0 '[.jobs.build.steps[] | select(.uses == "$/.github/actions/build-image") | .with | [has("push"), .["test-command"]]]' "$WF/_build-image.yaml"
  [ "$output" = '[[false,"${{ inputs.test-command }}"]]' ]
}

@test "_build-image.yaml's publish job runs neither the prepare nor the test command" {
  run yq -r '[.jobs.publish.steps[] | select(.run != null) | (.["env"] // {} | keys[])] | unique | .[]' "$WF/_build-image.yaml"
  [[ "$output" != *PREPARE_COMMAND* && "$output" != *TEST_COMMAND* ]]
  run yq -r '[.jobs.publish.steps[] | .run // "" | test("inputs\\.(prepare|test)-command")] | any' "$WF/_build-image.yaml"
  [ "$output" = "false" ]
  run yq -r '.jobs.publish.steps[] | select(.uses == "$/.github/actions/build-image") | .with | has("test-command")' "$WF/_build-image.yaml"
  [ "$output" = "false" ]
}

@test "_build-image.yaml publishes only after the build and its tests pass" {
  run yq -r '.jobs.publish.if' "$WF/_build-image.yaml"
  [[ "$output" == *"&& needs.build.result == 'success'"* ]]
}

@test "_build-image.yaml packs the prepared context after prepare, and publish restores it before its build" {
  run yq -o=json -I0 '[.jobs.build.steps[].name]' "$WF/_build-image.yaml"
  [[ "$output" == *'"Check the Dockerfile is in the context","Prepare build","Pack prepared context","Upload prepared context","Build image"'* ]]
  run yq -r '.jobs.build.steps[] | select(.name == "Check the Dockerfile is in the context") | .if' "$WF/_build-image.yaml"
  [ "$output" = "inputs.prepare-command != ''" ]
  run yq -r '.jobs.build.steps[] | select(.name == "Upload prepared context") | .with["retention-days"]' "$WF/_build-image.yaml"
  [ "$output" = "7" ]
  run yq -o=json -I0 '[.jobs.build.steps[] | select(.name == "Pack prepared context" or .name == "Upload prepared context") | .if] | unique' "$WF/_build-image.yaml"
  [ "$output" = "[\"inputs.push && inputs.prepare-command != ''\"]" ]
  run yq -o=json -I0 '[.jobs.publish.steps[].name]' "$WF/_build-image.yaml"
  [[ "$output" == *'"Download prepared context","Restore prepared context","Build and push image"'* ]]
  run yq -o=json -I0 '[.jobs.publish.steps[] | select(.name == "Download prepared context" or .name == "Restore prepared context") | .if] | unique' "$WF/_build-image.yaml"
  [ "$output" = "[\"steps.verify.outputs.published != 'true' && inputs.prepare-command != ''\"]" ]
  run yq -r '[(.jobs.build.steps[] | select(.name == "Upload prepared context") | .with.name), (.jobs.publish.steps[] | select(.name == "Download prepared context") | .with.name)] | unique | .[]' "$WF/_build-image.yaml"
  [ "$output" = 'prepared-context-${{ inputs.image || github.event.repository.name }}' ]
}

@test "the restore step unpacks plain files and directories into the context, keeping modes" {
  local src="$BATS_TEST_TMPDIR/src"
  mkdir -p "$src/sub" "$BATS_TEST_TMPDIR/prepared"
  printf 'FROM scratch\n' >"$src/Dockerfile"
  printf '#!/bin/sh\n' >"$src/sub/run.sh"
  chmod 755 "$src/sub/run.sh"
  tar -C "$src" -cf "$BATS_TEST_TMPDIR/prepared/prepared-context.tar" .
  run restore "$BATS_TEST_TMPDIR"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/ctx/Dockerfile")" = "FROM scratch" ]
  [ -x "$BATS_TEST_TMPDIR/ctx/sub/run.sh" ]
}

@test "the restore step refuses a link or a path outside the context" {
  local src="$BATS_TEST_TMPDIR/src" tarball="$BATS_TEST_TMPDIR/prepared/prepared-context.tar" kind
  for kind in symlink hardlink parent absolute parent-long; do
    rm -rf "$src" "$BATS_TEST_TMPDIR/prepared" "$BATS_TEST_TMPDIR/ctx"
    mkdir -p "$src" "$BATS_TEST_TMPDIR/prepared"
    printf 'x\n' >"$src/f"
    case "$kind" in
    symlink)
      ln -s /usr "$src/link"
      tar -C "$src" -cf "$tarball" .
      ;;
    hardlink)
      ln "$src/f" "$src/g"
      tar -C "$src" -cf "$tarball" .
      ;;
    parent) tar -C "$src" -cf "$tarball" --transform 's|^\./f$|../escape|' ./f ;;
    absolute) tar -C "$src" -cf "$tarball" -P --transform 's|^\./f$|/tmp/escape|' ./f ;;
    parent-long)
      # A listing longer than the pipe buffer, so a piped grep -q exits before tar does
      mkdir "$src/d"
      for i in $(seq 400); do : >"$src/d/$(printf 'n%.0s' $(seq 200))$i"; done
      tar -C "$src" -cf "$tarball" --transform 's|^\./f$|../escape|' ./f ./d
      ;;
    esac
    run restore "$BATS_TEST_TMPDIR"
    echo "$kind: $status $output"
    [ "$status" -ne 0 ]
    [ -z "$(ls -A "$BATS_TEST_TMPDIR/ctx")" ]
  done
}

dockerfile_check_script() {
  yq -r '.jobs.build.steps[] | select(.name == "Check the Dockerfile is in the context") | .run' "$WF/_build-image.yaml"
}

@test "with a prepare-command, the build fails unless the Dockerfile is in the context" {
  local ctx dockerfile want
  mkdir -p "$BATS_TEST_TMPDIR/img" "$BATS_TEST_TMPDIR/img-other"
  while IFS='|' read -r ctx dockerfile want; do
    run env -C "$BATS_TEST_TMPDIR" CONTEXT="$ctx" DOCKERFILE="$dockerfile" bash -euo pipefail -c "$(dockerfile_check_script)"
    echo "$ctx|$dockerfile: $status $output"
    [ "$status" -eq "$want" ]
  done <<'EOF'
img||0
./img/||0
.||0
img|img/sub/Dockerfile|0
.|img-other/Dockerfile|0
img|img-other/Dockerfile|1
img|img/../img-other/Dockerfile|1
img|/tmp/Dockerfile|1
EOF
}

@test "the image workflows hand each image's egress from detect-images to _build-image" {
  local f
  for f in _images.yaml _release-images.yaml; do
    run yq -o=json -I0 '.jobs.build.with | [.egress, has("egress-policy")]' "$WF/$f"
    [ "$output" = '["${{ matrix.egress }}",false]' ]
  done
}

@test "_build-image.yaml passes its egress to the Go and Python tests" {
  local job
  for job in test-go test-python; do
    run yq -o=json -I0 ".jobs.$job.with | [.egress, has(\"egress-policy\")]" "$WF/_build-image.yaml"
    [ "$output" = '["${{ inputs.egress }}",false]' ]
  done
}

@test "every image chain job hardens the runner and appends egress to its allowlist" {
  local f job
  for f in _build-image.yaml:test-node _build-image.yaml:build _build-image.yaml:publish _go-test.yaml:test _python-uv-test.yaml:test; do
    job="${f#*:}"
    run yq -o=json -I0 ".on.workflow_call.inputs | [.egress.default, has(\"egress-policy\")]" "$WF/${f%%:*}"
    [ "$output" = '["",false]' ]
    run yq -o=json -I0 ".jobs.$job.steps[0] | [.uses, (.with.\"allowed-endpoints\" | test(\" \\\\$\\\\{\\\\{ inputs\\\\.egress }}$\"))]" "$WF/${f%%:*}"
    [ "$output" = '["$/.github/actions/harden-runner",true]' ] || {
      echo "$f: $output"
      return 1
    }
  done
}
