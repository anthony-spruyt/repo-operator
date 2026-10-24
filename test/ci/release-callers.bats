#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  WORKFLOWS="$SRC/templates/.github/workflows"
  APP_SECRETS='{"RELEASE_PLEASE_APP_CLIENT_ID":"${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}","RELEASE_PLEASE_APP_PRIVATE_KEY":"${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}"}'
  PUBLISH='{"attestations":"write","contents":"write","id-token":"write","packages":"write"}'
}

repo() {
  echo ".repos[] | select(.git == \"https://github.com/anthony-spruyt/$1.git\")"
}

@test "the release-please group syncs the plain release caller, and the image group merges the image caller over it" {
  run yq -r '.groups["release-please"].files[".github/workflows/release-please.yaml"].content' "$SRC/groups.yaml"
  [ "$output" = "@templates/.github/workflows/release-please.yaml" ]
  run yq -r '.groups.image.files[".github/workflows/release-please.yaml"].content' "$SRC/groups.yaml"
  [ "$output" = "@templates/.github/workflows/image-release-please.yaml" ]
}

@test "both release callers hold one concurrency group for the whole run and grant nothing at the top" {
  local wf
  for wf in release-please.yaml image-release-please.yaml; do
    run yq -o=json -I0 '[.concurrency, .permissions]' "$WORKFLOWS/$wf"
    echo "$wf: $output"
    [ "$output" = '[{"group":"release-please-${{ github.ref }}","cancel-in-progress":false},{}]' ]
  done
}

@test "the plain release caller runs only _release-please.yaml, read-only, with only the release App secrets" {
  run yq -o=json -I0 '[(.jobs | keys), .jobs.release.permissions, (.jobs.release.uses | sub("@[0-9a-f]{40}$"; "@<sha>")), has("with")]' "$WORKFLOWS/release-please.yaml"
  [ "$output" = '[["release"],{"contents":"read"},"anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@<sha>",false]' ]
  run yq -o=json -I0 '.jobs.release.secrets' "$WORKFLOWS/release-please.yaml"
  [ "$output" = "$APP_SECRETS" ]
}

@test "the image caller is the plain caller plus a schedule, the release ref guard, the recover job and the images job, since xfg deep-merges the two" {
  run yq -o=json -I0 'del(.jobs.images, .jobs.recover, .jobs.release.if, .on.schedule)' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = "$(yq -o=json -I0 '.' "$WORKFLOWS/release-please.yaml")" ]
}

@test "the image release caller also runs on a schedule, so a stuck draft recovers without a push" {
  run yq -o=json -I0 '[(.on | keys | sort), .on.push.branches, .on.schedule]' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = '[["push","schedule","workflow_dispatch"],["main"],[{"cron":"23 */6 * * *"}]]' ]
}

@test "the image release job runs on a branch ref only, with the plain caller's permissions and secrets" {
  run yq -o=json -I0 '[.jobs.release.if, .jobs.release.permissions, .jobs.release.secrets]' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = '["github.ref_type == '"'branch'"'",{"contents":"read"},'"$APP_SECRETS"']' ]
  run yq -o=json -I0 '.jobs.release | has("if")' "$WORKFLOWS/release-please.yaml"
  [ "$output" = "false" ]
  run yq -o=json -I0 '.jobs.release | del(.if)' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = "$(yq -o=json -I0 '.jobs.release' "$WORKFLOWS/release-please.yaml")" ]
}

@test "the image release caller runs recover after release, whatever release did, with the release App secrets and read contents plus write actions" {
  run yq -o=json -I0 '[(.jobs | keys), .jobs.recover.needs, .jobs.recover.if, (.jobs.recover.permissions | to_entries | sort_by(.key) | from_entries), (.jobs.recover.uses | sub("@[0-9a-f]{40}$"; "@<sha>")), .jobs.recover.with, .jobs.recover.secrets]' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = '[["release","recover","images"],"release","!cancelled()",{"actions":"write","contents":"read"},"anthony-spruyt/repo-operator/.github/workflows/_release-recover.yaml@<sha>",{"releases":"${{ needs.release.outputs.releases }}"},'"$APP_SECRETS"']' ]
}

@test "every job of the image release caller pins one repo-operator sha, and recover keeps the # main comment Renovate bumps it by" {
  run yq -o=json -I0 '[.jobs[].uses | sub(".*@"; "")] | [length, (unique | length)]' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = "[3,1]" ]
  run grep -cE '^    uses: "anthony-spruyt/repo-operator/[.]github/workflows/_release-(please|recover|images)[.]yaml@[0-9a-f]{40}" # main$' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = "3" ]
}

@test "the image release caller builds when its own release or a recovered tag made one, with the publishing permissions and only the Docker Hub secret" {
  run yq -o=json -I0 '[.jobs.images.needs, .jobs.images.if, (.jobs.images.uses | sub("@[0-9a-f]{40}$"; "@<sha>")), .jobs.images.with.releases, .jobs.images.secrets]' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = '[["release","recover"],"!cancelled() && (needs.release.outputs.release-created == '"'true'"' || needs.recover.outputs.release-created == '"'true'"')","anthony-spruyt/repo-operator/.github/workflows/_release-images.yaml@<sha>","${{ needs.recover.outputs.releases || needs.release.outputs.releases }}",{"DOCKERHUB_TOKEN":"${{ secrets.DOCKERHUB_TOKEN }}"}]' ]
  run yq -o=json -I0 '.jobs.images.permissions | to_entries | sort_by(.key) | from_entries' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = "$PUBLISH" ]
}

@test "the image group brings release-please and the hadolint config, so no repo lists release-please or docker beside it" {
  run yq -o=json -I0 '[(.groups.image.extends | any_c(. == "release-please")), .groups.image.files[".hadolint.yaml"].createOnly, (.groups | has("docker"))]' "$SRC/groups.yaml"
  [ "$output" = '[true,true,false]' ]
  run yq -o=json -I0 '[.repos[] | select(.groups | any_c(. == "docker")) | .git]' "$SRC/repos.yaml"
  [ "$output" = '[]' ]
  run yq -o=json -I0 '[.repos[] | select((.groups | any_c(. == "image" or . == "go-image" or . == "python-image")) and (.groups | any_c(. == "release-please"))) | .git]' "$SRC/repos.yaml"
  [ "$output" = '[]' ]
}

@test "claude-plugins releases with the release-please group alone" {
  run yq -o=json -I0 "$(repo claude-plugins) | .groups | [any_c(. == \"release-please\"), any_c(. == \"image\" or . == \"go-image\" or . == \"python-image\" or . == \"dockerhub\")]" "$SRC/repos.yaml"
  [ "$output" = '[true,false]' ]
}

@test "xfg keeps its own release.yaml and opts out of the synced release caller" {
  run yq -o=json -I0 "$(repo xfg) | [(.groups | any_c(. == \"release-please\")), .files[\".github/workflows/release-please.yaml\"]]" "$SRC/repos.yaml"
  [ "$output" = '[true,false]' ]
}

@test "repo overlays pass image inputs to the images job, never the release job" {
  run yq -o=json -I0 '[.repos[] | select(.files[".github/workflows/release-please.yaml"].content.jobs.release) | .git]' "$SRC/repos.yaml"
  [ "$output" = '[]' ]
  run yq -r '[.repos[] | select(.files[".github/workflows/release-please.yaml"].content.jobs.images.with) | .git | sub("^https://github.com/anthony-spruyt/"; "") | sub("\.git$"; "")] | sort | join(" ")' "$SRC/repos.yaml"
  [ "$output" = "SunGather litellm-middleware traefik-api-key-auth" ]
}

@test "the release callers pass actionlint" {
  cd "$REPO_ROOT"
  run actionlint -no-color "$WORKFLOWS/release-please.yaml" "$WORKFLOWS/image-release-please.yaml"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "every image repo lints its Dockerfiles with hadolint" {
  run yq -o=json -I0 '[.conditionalGroups[] | select(.files[".mega-linter-base.yml"].content.ENABLE_LINTERS["$values"] | any_c(. == "DOCKERFILE_HADOLINT")) | .when]' "$SRC/groups.yaml"
  [ "$output" = '[{"allOf":["megalinter","image"]}]' ]
}
