#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  WF="$REPO_ROOT/.github/workflows"
  TEMPLATES="$SRC/templates/.github/workflows"
  MAIN_ONLY='{"custom":[{"type":"branch","name":"main"}]}'
  XFG_GIT='https://github.com/anthony-spruyt/xfg.git'
}

release_env() {
  yq -o=json -I0 "explode(.) | .groups[\"$1\"].settings.environments.release" "$SRC/groups.yaml"
}

@test "the release-please group defines a main-only release environment holding the release App secrets" {
  run release_env release-please
  [ "$(jq -cS . <<<"$output")" = "$(jq -cS --argjson p "$MAIN_ONLY" -n '{deploymentBranchPolicy: $p, secrets: {RELEASE_PLEASE_APP_CLIENT_ID: {env: "RELEASE_PLEASE_APP_CLIENT_ID"}, RELEASE_PLEASE_APP_PRIVATE_KEY: {env: "RELEASE_PLEASE_APP_PRIVATE_KEY"}}}')" ]
}

@test "the dockerhub group adds DOCKERHUB_TOKEN to the same main-only release environment" {
  run release_env dockerhub
  [ "$(jq -cS . <<<"$output")" = "$(jq -cS --argjson p "$MAIN_ONLY" -n '{deploymentBranchPolicy: $p, secrets: {DOCKERHUB_TOKEN: {env: "DOCKERHUB_TOKEN"}}}')" ]
}

@test "only the release-please and dockerhub groups define environments, only release, and only xfg overrides one, release" {
  run yq -o=json -I0 '[.groups | to_entries[] | select(.value.settings.environments != null) | {(.key): (.value.settings.environments | keys)}]' "$SRC/groups.yaml"
  [ "$output" = '[{"dockerhub":["release"]},{"release-please":["release"]}]' ]
  local f
  for f in settings.yaml base.yaml; do
    run yq -r '[.. | select(tag == "!!map" and has("environments"))] | length' "$SRC/$f"
    echo "$f: $output"
    [ "$output" = "0" ]
  done
  run yq -r '[.conditionalGroups[] | .. | select(tag == "!!map" and has("environments"))] | length' "$SRC/groups.yaml"
  [ "$output" = "0" ]
  run yq -o=json -I0 '[.repos[] | select([.. | select(tag == "!!map" and has("environments"))] | length > 0) | {(.git): (.settings.environments | keys)}]' "$SRC/repos.yaml"
  [ "$output" = "[{\"$XFG_GIT\":[\"release\"]}]" ]
}

@test "xfg's release environment allows main and v*.*.* tags, inheriting the release App secrets" {
  run yq -o=json -I0 ".repos[] | select(.git == \"$XFG_GIT\") | .settings.environments.release" "$SRC/repos.yaml"
  [ "$(jq -cS . <<<"$output")" = '{"deploymentBranchPolicy":{"custom":[{"name":"main","type":"branch"},{"name":"v*.*.*","type":"tag"}]}}' ]
}

@test "every other repo's release environment is main only" {
  local repo
  while IFS= read -r repo; do
    run yq -o=json -I0 ".repos[] | select(.git == \"$repo\") | .settings.environments.release.deploymentBranchPolicy" "$SRC/repos.yaml"
    echo "$repo: $output"
    [ "$output" = "null" ]
  done < <(yq -r ".repos[] | select(.groups[] == \"release-please\" or .groups[] == \"dockerhub\") | .git | select(. != \"$XFG_GIT\")" "$SRC/repos.yaml" | sort -u)
  local g
  for g in release-please dockerhub; do
    run release_env "$g"
    [ "$(jq -cS .deploymentBranchPolicy <<<"$output")" = "$(jq -cS . <<<"$MAIN_ONLY")" ]
  done
}

@test "no npm environment remains in config" {
  local f
  for f in "$SRC"/*.yaml; do
    run yq -r '[.. | select(tag == "!!map" and has("environments")) | .environments | select(tag == "!!map") | keys[] | select(test("(?i)^npm$"))] | length' "$f"
    echo "$f: $output"
    [ "$output" = "0" ]
  done
}

@test "the release-please job and the publish job use the release environment" {
  run yq -r '.jobs["release-please"].environment' "$WF/_release-please.yaml"
  [ "$output" = "release" ]
  run yq -r '.jobs.publish.environment' "$WF/_build-image.yaml"
  [ "$output" = "release" ]
}

@test "every shared-workflow job that reads a release secret uses the release environment, and no other job does" {
  local secret_jobs env_jobs
  secret_jobs=$(cd "$WF" && yq --no-doc -r '.jobs | to_entries[] | select(.value.steps != null and ([.value.steps[] | .. | select(tag == "!!str")] | any_c(test("secrets\.(RELEASE_PLEASE_APP_[A-Z_]+|DOCKERHUB_TOKEN)")))) | filename + ":" + .key' _*.yaml | sort)
  env_jobs=$(cd "$WF" && yq --no-doc -r '.jobs | to_entries[] | select(.value.environment != null) | filename + ":" + .key + "=" + (.value.environment | tostring)' _*.yaml | sort)
  echo "secret jobs: $secret_jobs"
  echo "environment jobs: $env_jobs"
  [ "$secret_jobs" = $'_build-image.yaml:publish\n_release-please.yaml:release-please' ]
  [ "$env_jobs" = $'_build-image.yaml:publish=release\n_release-please.yaml:release-please=release' ]
}

@test "no pull request path reaches the release environment" {
  run yq -r '[.jobs[] | select(.environment != null)] | length' "$WF/_images.yaml"
  [ "$output" = "0" ]
  run yq -r '.jobs.build.with | has("push")' "$WF/_images.yaml"
  [ "$output" = "false" ]
  run yq -r '.on.workflow_call.inputs.push.default' "$WF/_build-image.yaml"
  [ "$output" = "false" ]
  run yq -r '.jobs.build | [has("environment"), (.if | test("!inputs\.push"))] | @tsv' "$WF/_build-image.yaml"
  [ "$output" = $'false\ttrue' ]
  run yq -r '.jobs.publish.if | test("&& inputs\.push\s")' "$WF/_build-image.yaml"
  [ "$output" = "true" ]
  run yq -r '[.jobs[] | select(.environment != null)] | length' "$TEMPLATES/ci.yaml" "$REPO_ROOT/.github/workflows/ci-repo.yaml"
  [ "$output" = $'0\n0' ]
}

@test "the release callers run only from main pushes or dispatch, and pass every release secret by name" {
  run yq -o=json -I0 '[(.on | keys), .on.push.branches]' "$TEMPLATES/image-release-please.yaml"
  [ "$output" = '[["push","workflow_dispatch"],["main"]]' ]
  run yq -o=json -I0 '.on | keys' "$TEMPLATES/image-rebuild-release.yaml"
  [ "$output" = '["workflow_dispatch"]' ]
  run yq -o=json -I0 '.jobs.release.secrets' "$TEMPLATES/image-release-please.yaml"
  [ "$output" = '{"RELEASE_PLEASE_APP_CLIENT_ID":"${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}","RELEASE_PLEASE_APP_PRIVATE_KEY":"${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}","DOCKERHUB_TOKEN":"${{ secrets.DOCKERHUB_TOKEN }}"}' ]
  run yq -o=json -I0 '.jobs.rebuild.secrets' "$TEMPLATES/image-rebuild-release.yaml"
  [ "$output" = '{"DOCKERHUB_TOKEN":"${{ secrets.DOCKERHUB_TOKEN }}"}' ]
}
