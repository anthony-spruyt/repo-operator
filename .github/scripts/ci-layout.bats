#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  WORKFLOWS="$SRC/templates/.github/workflows"
  REPO_JOB='{"needs":["lint"],"uses":"./.github/workflows/ci-repo.yaml","permissions":{"contents":"read"},"secrets":"inherit"}'
}

repo_job_is_standard() {
  [ "$(yq -o=json '.jobs.repo' "$1" | jq -cS .)" = "$(jq -cS . <<<"$REPO_JOB")" ]
}

@test "the ci.yaml template calls ci-repo.yaml after lint and summary judges it" {
  repo_job_is_standard "$WORKFLOWS/ci.yaml"
  run yq -o=json -I0 '[(.jobs | keys), .jobs.summary.needs]' "$WORKFLOWS/ci.yaml"
  [ "$output" = '[["lint","repo","summary"],["lint","repo"]]' ]
}

@test "the image-ci.yaml template calls ci-repo.yaml after lint and summary judges it" {
  repo_job_is_standard "$WORKFLOWS/image-ci.yaml"
  run yq -o=json -I0 '[(.jobs | keys), .jobs.summary.needs]' "$WORKFLOWS/image-ci.yaml"
  [ "$output" = '[["lint","image","repo","summary"],["lint","image","repo"]]' ]
}

@test "the ci.yaml template holds no commented-out code" {
  run grep -nE '^\s*#\s*(workflow_dispatch|build|runs-on|steps|- uses|- run|uses|permissions|contents):' "$WORKFLOWS/ci.yaml"
  [ -z "$output" ]
}

@test "github-ci seeds ci-repo.yaml once" {
  run yq -o=json -I0 '.groups["github-ci"].files[".github/workflows/ci-repo.yaml"] | [.createOnly, .content]' "$SRC/groups.yaml"
  [ "$output" = '[true,"@templates/.github/workflows/ci-repo.yaml"]' ]
}

@test "every group that syncs a ci.yaml calling ci-repo.yaml also gets the seed" {
  run yq -r '[.groups | to_entries[] | select(.value.files[".github/workflows/ci.yaml"] != null) | select(.key != "github-ci") | select((.value.extends // []) | any_c(. == "github-ci") | not) | .key] | join(" ")' "$SRC/groups.yaml"
  [ "$output" = "go-image python-image" ]
  run yq -r '[.groups["go-image", "python-image"].extends | any_c(. == "image")] | all' "$SRC/groups.yaml"
  [ "$output" = "true" ]
  run yq -r '.groups.image.extends | any_c(. == "github-ci")' "$SRC/groups.yaml"
  [ "$output" = "true" ]
}

@test "the seed is a callable workflow with one never-run job and nothing to pin" {
  run yq -o=json -I0 '[.name, (.on | keys), .permissions]' "$WORKFLOWS/ci-repo.yaml"
  [ "$output" = '["CI (repo)",["workflow_call"],{}]' ]
  run yq -o=json -I0 '.jobs | to_entries | map([.key, .value.name, .value.if])' "$WORKFLOWS/ci-repo.yaml"
  [ "$output" = '[["no-repo-jobs","No repo jobs yet","github.event_name == '"'never'"'"]]' ]
  run grep -c 'uses:' "$WORKFLOWS/ci-repo.yaml"
  [ "$output" = "0" ]
}

@test "the rendered ci.yaml, image-ci.yaml and seed pass actionlint with the synced config" {
  target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target/.github/workflows"
  cp "$SRC/templates/.github/actionlint.yaml" "$target/.github/actionlint.yaml"
  cp "$WORKFLOWS/ci-repo.yaml" "$WORKFLOWS/ci.yaml" "$target/.github/workflows/"
  sed 's/\${xfg:language}/go/' "$WORKFLOWS/image-ci.yaml" >"$target/.github/workflows/image-ci.yaml"
  run grep -rn 'xfg:' "$target/.github/workflows/"
  [ "$status" -eq 1 ]
  git init -q "$target"
  cd "$target"
  run actionlint -no-color
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "repo-operator's ci.yaml calls its ci-repo.yaml like the template and summary judges it" {
  repo_job_is_standard "$REPO_ROOT/.github/workflows/ci.yaml"
  run yq -r '.jobs.summary.needs | (any_c(. == "lint") and any_c(. == "repo"))' "$REPO_ROOT/.github/workflows/ci.yaml"
  [ "$output" = "true" ]
  run yq -r '.jobs | has("guard-test")' "$REPO_ROOT/.github/workflows/ci.yaml"
  [ "$output" = "false" ]
}

@test "repo-operator's ci-repo.yaml runs the bats tests" {
  run yq -o=json -I0 '[(.on | keys), .permissions]' "$REPO_ROOT/.github/workflows/ci-repo.yaml"
  [ "$output" = '[["workflow_call"],{}]' ]
  run yq -r '.jobs["guard-test"].steps[].run | select(. != null)' "$REPO_ROOT/.github/workflows/ci-repo.yaml"
  [[ "$output" == *"bats .github/scripts/ .github/actions/sonar-new-issues/test/"* ]]
  run yq -r '.jobs["guard-test"].steps[].name' "$REPO_ROOT/.github/workflows/ci-repo.yaml"
  [[ "$output" == *$'Install actionlint\nRun bats tests'* ]]
}
