#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # each @test runs in its own subshell by design

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CI="$REPO_ROOT/.github/workflows/ci.yaml"
  CANARY="$REPO_ROOT/.github/workflows/lint-canary.yaml"
  GUARD="github.event.action != 'labeled' || github.event.label.name == 'xfg/plan'"
  SRC="$REPO_ROOT/src"
}

# step_run <job> <step name>: the shell script of a canary step, written to $BATS_TEST_TMPDIR/step.sh
step_run() {
  yq -r ".jobs.$1.steps[] | select(.name == \"$2\") | .run" "$CANARY" >"$BATS_TEST_TMPDIR/step.sh"
  [ -s "$BATS_TEST_TMPDIR/step.sh" ]
}

# step_at <job> <step name>: the position of a canary step in its job
step_at() {
  yq -r ".jobs.$1.steps | to_entries | .[] | select(.value.name == \"$2\") | .key" "$CANARY"
}

# allowlist <file> <job>: the sorted hosts of a job's harden-runner allowlist, one per line
allowlist() {
  yq -r ".jobs.$2.steps[0].with[\"allowed-endpoints\"]" "$1" | tr -s '[:space:]' '\n' | grep -v '^$' | sort
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
  [ "$output" = '[["Harden Runner",null],["Checkout",null],["Decide",null],["Render planned files","steps.needed.outputs.run == '"'true'"'"],["Find repos whose lint files change","steps.needed.outputs.run == '"'true'"'"],["Name the devcontainer image","steps.needed.outputs.run == '"'true'"'"],["Upload render","steps.needed.outputs.run == '"'true'"'"]]' ]
  run yq -r '.jobs.render.outputs.repos' "$CANARY"
  [ "$output" = "\${{ steps.affected.outputs.repos || '[]' }}" ]
  run yq -r '.jobs.lint.if' "$CANARY"
  [ "$output" = "needs.render.outputs.repos != '[]'" ]
}

@test "a repo whose pre-commit config, a hook's config or devcontainer image changes is linted, and so is one whose config is deleted" {
  step_run render "Find repos whose lint files change"
  mkdir -p "$BATS_TEST_TMPDIR/render"
  cat >"$BATS_TEST_TMPDIR/render/render.json" <<'JSON'
{"repos":{
  "o/changed":{"files":[".pre-commit-config.yaml","README.md"],"deleted":[]},
  "o/deleted":{"files":[],"deleted":[".pre-commit-config.yaml"]},
  "o/image":{"files":[".devcontainer/Dockerfile"],"deleted":[]},
  "o/yamllint":{"files":[".yamllint.yml"],"deleted":[]},
  "o/markdownlint":{"files":[".markdownlint.json"],"deleted":[]},
  "o/editorconfig":{"files":[".editorconfig"],"deleted":[]},
  "o/other":{"files":["README.md",".github/workflows/ci.yaml"],"deleted":[]}
}}
JSON
  : >"$BATS_TEST_TMPDIR/output"
  : >"$BATS_TEST_TMPDIR/summary"
  RENDER="$BATS_TEST_TMPDIR/render" RUNNER_TEMP="$BATS_TEST_TMPDIR" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" \
    GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary" LINT_FILES="$(yq -r '.env.LINT_FILES' "$CANARY")" \
    run bash -e "$BATS_TEST_TMPDIR/step.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  run jq -r 'map(.full) | join(",")' <<<"$(sed 's/^repos=//' "$BATS_TEST_TMPDIR/output")"
  [ "$output" = "o/changed,o/deleted,o/image,o/yamllint,o/markdownlint,o/editorconfig" ]
}

@test "the render job names the image the devcontainer template pins, for the lint jobs to run pre-commit in" {
  step_run render "Name the devcontainer image"
  mkdir -p "$BATS_TEST_TMPDIR/repo/src/templates/.devcontainer" "$BATS_TEST_TMPDIR/repo/.github"
  ln -s "$REPO_ROOT/.github/scripts" "$BATS_TEST_TMPDIR/repo/.github/scripts"
  printf 'ARG BASE_REGISTRY=docker.io\nFROM $BASE_REGISTRY/org/img:9.9.9@sha256:%s\n' "$(printf 'b%.0s' {1..64})" \
    >"$BATS_TEST_TMPDIR/repo/src/templates/.devcontainer/Dockerfile"
  : >"$BATS_TEST_TMPDIR/output"
  cd "$BATS_TEST_TMPDIR/repo"
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" run bash -e "$BATS_TEST_TMPDIR/step.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/output")" = "image=docker.io/org/img:9.9.9@sha256:$(printf 'b%.0s' {1..64})" ]
  id="$(yq -r '.jobs.render.steps[] | select(.name == "Name the devcontainer image") | .id' "$CANARY")"
  run yq -r '.jobs.render.outputs["devcontainer-image"]' "$CANARY"
  [ "$output" = "\${{ steps.$id.outputs.image }}" ]
}

@test "the render job fails when the devcontainer image cannot be resolved, rather than handing the lint jobs an empty one" {
  step_run render "Name the devcontainer image"
  mkdir -p "$BATS_TEST_TMPDIR/repo/src/templates/.devcontainer" "$BATS_TEST_TMPDIR/repo/.github"
  ln -s "$REPO_ROOT/.github/scripts" "$BATS_TEST_TMPDIR/repo/.github/scripts"
  printf 'ARG OTHER=x\nFROM $BASE_REGISTRY/org/img:9.9.9\n' >"$BATS_TEST_TMPDIR/repo/src/templates/.devcontainer/Dockerfile"
  : >"$BATS_TEST_TMPDIR/output"
  cd "$BATS_TEST_TMPDIR/repo" || return 1
  GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" run bash -e "$BATS_TEST_TMPDIR/step.sh"
  echo "$output"
  [ "$status" -ne 0 ]
  [ ! -s "$BATS_TEST_TMPDIR/output" ]
}

# precommit_call: runs the canary's pre-commit step with docker stubbed out; the stub leaves its arguments in
# $BATS_TEST_TMPDIR/docker-args and the owner of the hook cache directory, as docker found it, in $BATS_TEST_TMPDIR/cache-owner
precommit_call() {
  step_run lint "Run pre-commit"
  mkdir -p "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/home" "$BATS_TEST_TMPDIR/target"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/docker-args"
stat -c %u "$HOME/.cache/pre-commit" >"$BATS_TEST_TMPDIR/cache-owner"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  cd "$BATS_TEST_TMPDIR/target" || return 1
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" HOME="$BATS_TEST_TMPDIR/home" DEVCONTAINER_IMAGE="docker.io/org/img:1@sha256:$(printf 'c%.0s' {1..64})" \
    run bash -e "$BATS_TEST_TMPDIR/step.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  mapfile -t args <"$BATS_TEST_TMPDIR/docker-args"
}

@test "the overlay stages what it adds and deletes, because pre-commit --all-files only checks the files git lists" {
  step_run lint "Overlay planned files"
  work="$BATS_TEST_TMPDIR/work"
  mkdir -p "$work/target" "$BATS_TEST_TMPDIR/pack/o/r"
  git -C "$work/target" init -q
  echo keep >"$work/target/keep.txt"
  echo old >"$work/target/old.txt"
  git -C "$work/target" add keep.txt old.txt
  echo changed >"$BATS_TEST_TMPDIR/pack/o/r/keep.txt"
  echo new >"$BATS_TEST_TMPDIR/pack/o/r/new.txt"
  echo '{"repos":{"o/r":{"files":["keep.txt","new.txt"],"deleted":["old.txt"]}}}' >"$BATS_TEST_TMPDIR/pack/render.json"
  tar -C "$BATS_TEST_TMPDIR/pack" -czf "$BATS_TEST_TMPDIR/render.tgz" .
  cd "$work" || return 1
  REPO=o/r RUNNER_TEMP="$BATS_TEST_TMPDIR" run bash -e "$BATS_TEST_TMPDIR/step.sh"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(git -C target ls-files | tr '\n' ' ')" = "keep.txt new.txt " ]
}

@test "pre-commit runs every file in the devcontainer image as the runner's user, with the checkout mounted and the hook cache kept outside it" {
  precommit_call
  [ "${args[0]}" = "run" ]
  joined=$'\n'"$(printf '%s\n' "${args[@]}")"$'\n'
  [[ "$joined" == *$'\n-u\n'"$(id -u):$(id -g)"$'\n'* ]]
  [[ "$joined" == *$'\n-v\n'"$BATS_TEST_TMPDIR/home/.cache/pre-commit:/cache"$'\n'* ]]
  [[ "$joined" == *$'\n-e\nPRE_COMMIT_HOME=/cache\n'* ]]
  [[ "$joined" == *$'\n-v\n'"$BATS_TEST_TMPDIR/target:/w"$'\n-w\n/w\n'* ]]
  [[ "$joined" == *$'\ndocker.io/org/img:1@sha256:'"$(printf 'c%.0s' {1..64})"$'\npre-commit\nrun\n--all-files\n--show-diff-on-failure\n' ]]
}

@test "the hook cache directory exists and is the runner's before docker starts, so docker does not create it as root" {
  precommit_call
  [ "$(cat "$BATS_TEST_TMPDIR/cache-owner")" = "$(id -u)" ]
}

@test "each hook pre-commit skips is a real hook, so a renamed hook does not slip back in unnoticed" {
  precommit_call
  skip_list="$(printf '%s\n' "${args[@]}" | sed -n 's/^SKIP=//p')"
  [ -n "$skip_list" ]
  ids="$(yq -N -r '.. | select(tag == "!!map" and has("hooks")) | .hooks[].id' "$SRC/groups.yaml" "$SRC/repos.yaml" "$SRC/templates/.pre-commit-config.yaml")"
  IFS=, read -ra skipped <<<"$skip_list"
  for id in "${skipped[@]}"; do
    grep -qxF "$id" <<<"$ids"
  done
}

@test "pre-commit runs after MegaLinter and also when MegaLinter fails, so one run reports both" {
  run yq -r '.jobs.lint.steps[] | select(.name == "Run pre-commit") | .if' "$CANARY"
  [ "$output" = '${{ !cancelled() }}' ]
  [ "$(step_at lint "Run MegaLinter")" -lt "$(step_at lint "Run pre-commit")" ]
}

@test "the lint job takes its image from the render job and keys the hook cache on the rendered config and that image" {
  run yq -r '.jobs.lint.steps[] | select(.name == "Run pre-commit") | .env.DEVCONTAINER_IMAGE' "$CANARY"
  [ "$output" = '${{ needs.render.outputs.devcontainer-image }}' ]
  run yq -o=json -I0 '.jobs.lint.steps[] | select(.uses != null and (.uses | test("^actions/cache@"))) | [.with.path, .with.key]' "$CANARY"
  [[ "$output" == '["~/.cache/pre-commit",'* ]]
  [[ "$output" == *"hashFiles('target/.pre-commit-config.yaml')"* ]]
  [[ "$output" == *'needs.render.outputs.devcontainer-image'* ]]
  [ "$(step_at lint "Overlay planned files")" -lt "$(step_at lint "Cache pre-commit hooks")" ]
}

@test "the lint job's allowlist keeps MegaLinter's hosts and adds the ones pre-commit's hook installs and image pull use" {
  lint="$(allowlist "$CANARY" lint)"
  megalinter="$(allowlist "$REPO_ROOT/.github/workflows/_lint.yaml" megalinter)"
  [ -n "$megalinter" ]
  [ -z "$(comm -13 <(echo "$lint") <(echo "$megalinter"))" ]
  for host in github.com release-assets.githubusercontent.com pypi.org files.pythonhosted.org registry.npmjs.org \
    go.dev dl.google.com proxy.golang.org registry-1.docker.io auth.docker.io production.cloudfront.docker.com \
    docker-images-prod.s3.dualstack.us-east-1.amazonaws.com; do
    grep -qxF "$host:443" <<<"$lint"
  done
}
