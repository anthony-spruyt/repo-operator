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

@test "the ci.yaml template calls ci-repo.yaml after lint, then image, and summary judges all three" {
  repo_job_is_standard "$WORKFLOWS/ci.yaml"
  run yq -o=json -I0 '[(.jobs | keys), .jobs.summary.needs]' "$WORKFLOWS/ci.yaml"
  [ "$output" = '[["lint","repo","image","summary"],["lint","repo","image"]]' ]
}

@test "the ci.yaml template's image job calls _images.yaml after lint and repo, read-only" {
  run yq -o=json -I0 '.jobs.image | [.needs, .permissions, (.uses | sub("@[0-9a-f]{40}$"; "@<sha>")), has("with")]' "$WORKFLOWS/ci.yaml"
  [ "$output" = '[["lint","repo"],{"contents":"read"},"anthony-spruyt/repo-operator/.github/workflows/_images.yaml@<sha>",false]' ]
}

@test "the ci.yaml template's image job runs when repo is skipped, not when lint fails or the run is cancelled" {
  run yq -r '.jobs.image.if' "$WORKFLOWS/ci.yaml"
  [ "$output" = "!cancelled() && needs.lint.result == 'success' && (needs.repo.result == 'success' || needs.repo.result == 'skipped')" ]
}

@test "image-ci.yaml is retired: no group overrides ci.yaml, and the image groups only set its language" {
  [ ! -e "$WORKFLOWS/image-ci.yaml" ]
  run grep -rn 'image-ci' "$SRC"
  [ "$status" -eq 1 ]
  run yq -o=json -I0 '.groups | to_entries | map(select(.key != "github-ci" and .value.files[".github/workflows/ci.yaml"] != null) | [.key, .value.files[".github/workflows/ci.yaml"]])' "$SRC/groups.yaml"
  [ "$output" = '[["go-image",{"content":{"jobs":{"image":{"with":{"language":"go"}}}}}],["python-image",{"content":{"jobs":{"image":{"with":{"language":"python"}}}}}]]' ]
}

@test "the ci.yaml template holds no commented-out code" {
  run grep -nE '^\s*#\s*(workflow_dispatch|build|runs-on|steps|- uses|- run|uses|permissions|contents):' "$WORKFLOWS/ci.yaml"
  [ -z "$output" ]
}

@test "github-ci seeds ci-repo.yaml once" {
  run yq -o=json -I0 '.groups["github-ci"].files[".github/workflows/ci-repo.yaml"] | [.createOnly, .content]' "$SRC/groups.yaml"
  [ "$output" = '[true,"@templates/.github/workflows/ci-repo.yaml"]' ]
}

@test "github-ci enforces ci.yaml" {
  run yq -o=json -I0 '.groups["github-ci"].files[".github/workflows/ci.yaml"] | [.createOnly // false, .content]' "$SRC/groups.yaml"
  [ "$output" = '[false,"@templates/.github/workflows/ci.yaml"]' ]
}

@test "only container-images, repo-operator and spruyt-labs keep their own ci.yaml" {
  run yq -r '[.repos[] | select(.files[".github/workflows/ci.yaml"].createOnly == true) | .git | sub("^https://github.com/anthony-spruyt/"; "") | sub("\.git$"; "")] | sort | join(" ")' "$SRC/repos.yaml"
  [ "$output" = "container-images repo-operator spruyt-labs" ]
}

@test "xfg's ci.yaml overlay adds the labeled trigger and guards every template job with it" {
  overlay='.repos[] | select(.git == "https://github.com/anthony-spruyt/xfg.git") | .files[".github/workflows/ci.yaml"].content'
  guard="github.event.action != 'labeled' || github.event.label.name == 'run-integration'"
  run yq -o=json -I0 "$overlay | .on.pull_request.types" "$SRC/repos.yaml"
  [ "$output" = '["opened","synchronize","reopened","labeled"]' ]
  run yq -o=json -I0 "$overlay | [(.jobs | keys), (.jobs | to_entries | map(.value.if))]" "$SRC/repos.yaml"
  [ "$output" = "$(jq -cn --arg g "$guard" '[["lint","repo","image","summary"],[$g,$g,$g,"always() && (\($g))"]]')" ]
  run yq -o=json -I0 '.jobs | keys' "$WORKFLOWS/ci.yaml"
  [ "$output" = '["lint","repo","image","summary"]' ]
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

@test "the rendered ci.yaml and seed pass actionlint with the synced config" {
  target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target/.github/workflows"
  cp "$SRC/templates/.github/actionlint.yaml" "$target/.github/actionlint.yaml"
  cp "$WORKFLOWS/ci-repo.yaml" "$WORKFLOWS/ci.yaml" "$target/.github/workflows/"
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
  [[ "$output" == *"bats .github/scripts/ .github/actions/sonar-new-issues/test/ .github/actions/detect-images/test/"* ]]
  run yq -r '.jobs["guard-test"].steps[].name' "$REPO_ROOT/.github/workflows/ci-repo.yaml"
  [[ "$output" == *$'Install actionlint\nRun bats tests'* ]]
}

@test "every repo-operator ref pinned in src/templates is an ancestor of origin/main" {
  git -C "$REPO_ROOT" rev-parse --verify --quiet origin/main >/dev/null || { echo "origin/main is not fetched"; return 1; }
  bad=""
  while IFS=: read -r file line sha; do
    git -C "$REPO_ROOT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null || bad+="${file}:${line} ${sha}"$'\n'
  done < <(grep -rnoE 'anthony-spruyt/repo-operator/[^"@ ]*@[0-9a-f]{40}' "$SRC/templates" | sed -E 's/^([^:]+):([0-9]+):.*@([0-9a-f]{40})$/\1:\2:\3/')
  [ -z "$bad" ] || { echo "pins not reachable from origin/main:"; echo "$bad"; return 1; }
}
