#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  WORKFLOWS="$SRC/templates/.github/workflows"
  REPO_JOB='{"needs":["lint"],"uses":"./.github/workflows/ci-repo.yaml","permissions":{"contents":"read"},"secrets":"inherit"}'
}

# eval_if <expr> <lint result> <repo result> <cancelled> - a job's if, rewritten to jq; any other function or context fails jq
eval_if() {
  local jq_expr
  jq_expr=$(sed -E -e 's/!cancelled\(\)/($cancelled | not)/g' -e 's/needs\.(lint|repo)\.result/$\1/g' \
    -e 's/&&/and/g' -e 's/\|\|/or/g' -e "s/'/\"/g" <<<"$1")
  jq -n --arg lint "$2" --arg repo "$3" --argjson cancelled "$4" "$jq_expr"
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
  expr=$(yq -r '.jobs.image.if' "$WORKFLOWS/ci.yaml")
  while read -r lint repo cancelled want; do
    run eval_if "$expr" "$lint" "$repo" "$cancelled"
    [ "$output" = "$want" ] || {
      echo "lint=$lint repo=$repo cancelled=$cancelled: got '$output', want $want"
      return 1
    }
  done <<'EOF'
success success false true
success skipped false true
success failure false false
success cancelled false false
failure success false false
failure skipped false false
skipped skipped false false
cancelled skipped false false
success success true false
success skipped true false
EOF
}

@test "image-ci.yaml is retired: no group overrides ci.yaml, the image groups only set its language, and sonar only adds its job" {
  [ ! -e "$WORKFLOWS/image-ci.yaml" ]
  run grep -rn 'image-ci' "$SRC"
  [ "$status" -eq 1 ]
  run yq -o=json -I0 '.groups | to_entries | map(select(.key != "github-ci" and .key != "sonar" and .value.files[".github/workflows/ci.yaml"] != null) | [.key, .value.files[".github/workflows/ci.yaml"]])' "$SRC/groups.yaml"
  [ "$output" = '[["go-image",{"content":{"jobs":{"image":{"with":{"language":"go"}}}}}],["python-image",{"content":{"jobs":{"image":{"with":{"language":"python"}}}}}]]' ]
}

@test "the ci.yaml template cancels a PR's older run, and gives every other run its own group" {
  pr="github.event_name == 'pull_request' && github.event.action != 'labeled'"
  run yq -o=json -I0 '.concurrency' "$WORKFLOWS/ci.yaml"
  [ "$output" = "$(jq -cn --arg pr "$pr" '{group: "${{ github.workflow }}-${{ \($pr) && github.event.pull_request.number || github.run_id }}", "cancel-in-progress": "${{ \($pr) }}"}')" ]
}

@test "the ci.yaml template holds no commented-out code" {
  run grep -nE '^\s*#\s*(workflow_dispatch|build|runs-on|steps|- uses|- run|uses|permissions|contents):' "$WORKFLOWS/ci.yaml"
  [ -z "$output" ]
}

@test "the sonar group adds a no-permission sonar job calling _sonar-new-issues.yaml, and appends it to summary.needs" {
  run yq -o=json -I0 '.groups.sonar.files[".github/workflows/ci.yaml"].content | [(.jobs | keys), (.jobs.sonar | keys), .jobs.sonar.permissions, (.jobs.sonar.uses | sub("@[0-9a-f]{40}$"; "@<sha>")), .jobs.summary]' "$SRC/groups.yaml"
  [ "$output" = '[["sonar","summary"],["permissions","uses"],{},"anthony-spruyt/repo-operator/.github/workflows/_sonar-new-issues.yaml@<sha>",{"needs":{"$arrayMerge":"append","$values":["sonar"]}}]' ]
}

@test "the sonar job is pinned to the same main commit as the ci.yaml template's shared workflows" {
  sonar=$(yq -r '.groups.sonar.files[".github/workflows/ci.yaml"].content.jobs.sonar.uses | sub("^.*@"; "")' "$SRC/groups.yaml")
  run yq -r '[.jobs[].uses | select(test("^anthony-spruyt/repo-operator/")) | sub("^.*@"; "")] | unique | join(" ")' "$WORKFLOWS/ci.yaml"
  [ "$output" = "$sonar" ]
}

@test "every sonar repo lists github-ci before sonar, so the job lands on the synced ci.yaml" {
  run yq -r '[.repos[] | select(.groups // [] | any_c(. == "sonar")) | select((.groups | to_entries | map(select(.value == "github-ci")) | .[0].key // 999) > (.groups | to_entries | map(select(.value == "sonar")) | .[0].key)) | .git] | join(" ")' "$SRC/repos.yaml"
  [ -z "$output" ]
}

@test "the ci.yaml template with the sonar overlay passes actionlint, and summary judges sonar last" {
  target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target/.github/workflows"
  cp "$SRC/templates/.github/actionlint.yaml" "$target/.github/actionlint.yaml"
  cp "$WORKFLOWS/ci-repo.yaml" "$target/.github/workflows/"
  job=$(yq -o=json -I0 '.groups.sonar.files[".github/workflows/ci.yaml"].content.jobs.sonar' "$SRC/groups.yaml")
  SONAR_JOB="$job" yq '.jobs.sonar = env(SONAR_JOB) | .jobs.summary.needs += ["sonar"]' "$WORKFLOWS/ci.yaml" >"$target/.github/workflows/ci.yaml"
  run yq -o=json -I0 '.jobs.summary.needs' "$target/.github/workflows/ci.yaml"
  [ "$output" = '["lint","repo","image","sonar"]' ]
  git init -q "$target"
  cd "$target"
  run actionlint -no-color
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "repo-operator's ci.yaml runs the sonar job like the synced one, summary judges it, and no separate caller is left" {
  run yq -o=json -I0 '.jobs.sonar' "$REPO_ROOT/.github/workflows/ci.yaml"
  [ "$output" = '{"permissions":{},"uses":"./.github/workflows/_sonar-new-issues.yaml"}' ]
  run yq -r '.jobs.summary.needs | any_c(. == "sonar")' "$REPO_ROOT/.github/workflows/ci.yaml"
  [ "$output" = "true" ]
  [ ! -e "$REPO_ROOT/.github/workflows/sonar-new-issues.yaml" ]
  run grep -rlE '^\s*uses:\s*"?\./\.github/workflows/_sonar-new-issues\.yaml' "$REPO_ROOT/.github/workflows"
  [ "$output" = "$REPO_ROOT/.github/workflows/ci.yaml" ]
}

@test "repo-operator's Renovate reads src/groups.yaml with the github-actions manager, so the sonar pin moves with the template pins" {
  run jq -r '.["github-actions"].managerFilePatterns | join(" ")' "$REPO_ROOT/renovate-overrides.json5"
  [ "$output" = '/(^|/)src/groups\.yaml$/' ]
}

@test "github-ci seeds ci-repo.yaml once" {
  run yq -o=json -I0 '.groups["github-ci"].files[".github/workflows/ci-repo.yaml"] | [.createOnly, .content]' "$SRC/groups.yaml"
  [ "$output" = '[true,"@templates/.github/workflows/ci-repo.yaml"]' ]
}

@test "github-ci enforces ci.yaml" {
  run yq -o=json -I0 '.groups["github-ci"].files[".github/workflows/ci.yaml"] | [.createOnly // false, .content]' "$SRC/groups.yaml"
  [ "$output" = '[false,"@templates/.github/workflows/ci.yaml"]' ]
}

@test "only repo-operator keeps its own ci.yaml" {
  run yq -r '[.repos[] | select(.files[".github/workflows/ci.yaml"].createOnly == true) | .git | sub("^https://github.com/anthony-spruyt/"; "") | sub("\.git$"; "")] | sort | join(" ")' "$SRC/repos.yaml"
  [ "$output" = "repo-operator" ]
}

@test "spruyt-labs joins image with no language group, so each image's metadata.yaml sets its language" {
  repo='.repos[] | select(.git == "https://github.com/anthony-spruyt/spruyt-labs.git")'
  run yq -o=json -I0 "$repo | .groups | [any_c(. == \"image\"), any_c(. == \"go-image\" or . == \"python-image\")]" "$SRC/repos.yaml"
  [ "$output" = '[true,false]' ]
  run yq -o=json -I0 "$repo | .files[\".github/workflows/ci.yaml\"].content.jobs | [(.repo.permissions | to_entries | sort_by(.key) | from_entries), (.image.with.language // null)]" "$SRC/repos.yaml"
  [ "$output" = '[{"actions":"read","contents":"read","pull-requests":"read"},null]' ]
  run yq -r "$repo | .files[\".github/workflows/container-retention.yaml\"].vars.retentionPackages" "$SRC/repos.yaml"
  [ "$output" = "shutdown-orchestrator,agent-queue-worker,bull-board" ]
}

@test "container-images joins image with retention for its 16 packages and no separate dockerhub group" {
  repo='.repos[] | select(.git == "https://github.com/anthony-spruyt/container-images.git")'
  run yq -o=json -I0 "$repo | .groups | [any_c(. == \"image\"), any_c(. == \"dockerhub\")]" "$SRC/repos.yaml"
  [ "$output" = '[true,false]' ]
  run yq -r "$repo | .files[\".github/workflows/container-retention.yaml\"].vars.retentionPackages" "$SRC/repos.yaml"
  [ "$output" = "chrony,claude-agent-read,claude-agent-spruyt-labs,claude-agent-write,coder-gitops,devcontainer-common,happy-server,llm-guard,llm-guard-cuda,megalinter-base,megalinter-cpp,megalinter-go,megalinter-python,megalinter-spruyt-labs,megalinter-typescript,ssh-key-rotation" ]
}

@test "the 7 image repos all get the image group, directly or through go-image or python-image" {
  run yq -r '[.repos[] | select(.groups | any_c(. == "image" or . == "go-image" or . == "python-image")) | .git | sub("^https://github.com/anthony-spruyt/"; "") | sub("\.git$"; "")] | sort | join(" ")' "$SRC/repos.yaml"
  [ "$output" = "SunGather container-images kata-tap-qdisc-fix litellm-middleware mcp-header-proxy spruyt-labs traefik-api-key-auth" ]
}

@test "the image group defaults the release caller's language to none, and no repo repeats it" {
  run yq -o=json -I0 '.groups.image.files | [.[".github/workflows/release-please.yaml"].vars.language]' "$SRC/groups.yaml"
  [ "$output" = '["none"]' ]
  run yq -o=json -I0 '[.repos[] | select(.files[".github/workflows/release-please.yaml"].vars.language == "none") | .git]' "$SRC/repos.yaml"
  [ "$output" = '[]' ]
}

@test "the image group syncs DOCKERHUB_TOKEN through the dockerhub group, and no image repo also lists dockerhub" {
  run yq -r '.groups.image.extends | any_c(. == "dockerhub")' "$SRC/groups.yaml"
  [ "$output" = "true" ]
  run yq -o=json -I0 '[.groups | to_entries[] | select(.value.settings | .. | select(tag == "!!map" and has("DOCKERHUB_TOKEN"))) | .key] | unique' "$SRC/groups.yaml"
  [ "$output" = '["dockerhub"]' ]
  run yq -o=json -I0 '[.repos[] | select((.groups | any_c(. == "image" or . == "go-image" or . == "python-image")) and (.groups | any_c(. == "dockerhub"))) | .git]' "$SRC/repos.yaml"
  [ "$output" = '[]' ]
}

@test "the image release caller publishes to Docker Hub as aspruyt with the DOCKERHUB_TOKEN secret" {
  run yq -o=json -I0 '.jobs.release | [.with["dockerhub-namespace"], .secrets.DOCKERHUB_TOKEN]' "$WORKFLOWS/image-release-please.yaml"
  [ "$output" = '["aspruyt","${{ secrets.DOCKERHUB_TOKEN }}"]' ]
  run yq -o=json -I0 '[(.on.workflow_call.inputs["dockerhub-namespace"].type), (.on.workflow_call.secrets | has("DOCKERHUB_TOKEN")), .jobs.build.with["dockerhub-namespace"], .jobs.build.secrets.DOCKERHUB_TOKEN]' "$REPO_ROOT/.github/workflows/_release-please.yaml"
  [ "$output" = '["string",true,"${{ inputs.dockerhub-namespace }}","${{ secrets.DOCKERHUB_TOKEN }}"]' ]
}

@test "xfg's ci.yaml overlay adds the labeled trigger and guards every template job with it" {
  overlay='.repos[] | select(.git == "https://github.com/anthony-spruyt/xfg.git") | .files[".github/workflows/ci.yaml"].content'
  guard="github.event.action != 'labeled' || github.event.label.name == 'run-integration'"
  run yq -o=json -I0 "$overlay | .on.pull_request.types" "$SRC/repos.yaml"
  [ "$output" = '["opened","synchronize","reopened","labeled"]' ]
  run yq -o=json -I0 "$overlay | [(.jobs | keys), (.jobs | to_entries | map(.value.if))]" "$SRC/repos.yaml"
  [ "$output" = "$(jq -cn --arg g "$guard" '[["lint","repo","image","sonar","summary"],[$g,$g,$g,$g,"always() && (\($g))"]]')" ]
  run yq -o=json -I0 '.jobs | keys' "$WORKFLOWS/ci.yaml"
  [ "$output" = '["lint","repo","image","summary"]' ]
  run yq -o=json -I0 '.groups.sonar.files[".github/workflows/ci.yaml"].content.jobs | keys' "$SRC/groups.yaml"
  [ "$output" = '["sonar","summary"]' ]
}

@test "every group that syncs a ci.yaml calling ci-repo.yaml also gets the seed" {
  run yq -r '[.groups | to_entries[] | select(.value.files[".github/workflows/ci.yaml"] != null) | select(.key != "github-ci" and .key != "sonar") | select((.value.extends // []) | any_c(. == "github-ci") | not) | .key] | join(" ")' "$SRC/groups.yaml"
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
  [[ "$output" == *"bats -r test/"* ]]
  run yq -r '.jobs["guard-test"].steps[].name' "$REPO_ROOT/.github/workflows/ci-repo.yaml"
  [[ "$output" == *$'Install actionlint\nRun bats tests'* ]]
}

# check_pins <dir> <min> - fails listing each repo-operator pin under dir that is not on origin/main, or with fewer than min pins
check_pins() {
  local dir="$1" min="$2" file line sha count=0 bad=""
  git -C "$REPO_ROOT" rev-parse --verify --quiet origin/main >/dev/null || {
    echo "origin/main is not fetched"
    return 1
  }
  while IFS=: read -r file line sha; do
    count=$((count + 1))
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      bad+="${file}:${line} ${sha} is not a full lowercase SHA"$'\n'
    elif ! git -C "$REPO_ROOT" merge-base --is-ancestor "$sha" origin/main 2>/dev/null; then
      bad+="${file}:${line} ${sha} is not on origin/main"$'\n'
    fi
  done < <(grep -HrnoiE 'anthony-spruyt/repo-operator(/[^"@[:space:]]*)?@[^"#[:space:]]+' "$dir" | sed -E 's/^([^:]+):([0-9]+):.*@/\1:\2:/')
  [ -z "$bad" ] || {
    echo "bad repo-operator pins:"
    echo "$bad"
    return 1
  }
  [ "$count" -ge "$min" ] || {
    echo "found $count repo-operator pins, expected at least $min"
    return 1
  }
}

@test "every repo-operator ref pinned in src/templates and src/groups.yaml is an ancestor of origin/main" {
  check_pins "$SRC/templates" 7
  check_pins "$SRC/groups.yaml" 1
}

@test "the pin guard flags short, pathless and mixed-case repo-operator pins" {
  main_sha=$(git -C "$REPO_ROOT" rev-parse origin/main)
  dir="$BATS_TEST_TMPDIR/pins"
  mkdir -p "$dir"
  printf 'uses: "anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@%s" # main\n' "$main_sha" >"$dir/good.yaml"
  printf 'uses: "anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@%s" # main\n' "${main_sha:0:7}" >"$dir/short.yaml"
  printf 'uses: anthony-spruyt/repo-operator@0123456789abcdef0123456789abcdef01234567\n' >"$dir/pathless.yaml"
  printf 'uses: Anthony-Spruyt/Repo-Operator/.github/workflows/_lint.yaml@0123456789abcdef0123456789abcdef01234567\n' >"$dir/owner-case.yaml"
  printf 'uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@%s\n' "${main_sha^^}" >"$dir/sha-case.yaml"
  run check_pins "$dir" 1
  echo "$output"
  [ "$status" -eq 1 ]
  for f in short pathless owner-case sha-case; do
    [[ "$output" == *"$dir/$f.yaml:1 "* ]]
  done
  [[ "$output" != *"good.yaml"* ]]
}

@test "the pin guard fails when it finds fewer pins than the minimum" {
  main_sha=$(git -C "$REPO_ROOT" rev-parse origin/main)
  dir="$BATS_TEST_TMPDIR/pins"
  mkdir -p "$dir"
  run check_pins "$dir" 1
  [ "$status" -eq 1 ]
  printf 'uses: "anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@%s" # main\n' "$main_sha" >"$dir/good.yaml"
  run check_pins "$dir" 2
  [ "$status" -eq 1 ]
  [[ "$output" == *"found 1 repo-operator pins, expected at least 2"* ]]
  run check_pins "$dir" 1
  [ "$status" -eq 0 ]
}

@test "nothing syncs or calls Rebuild Release (#604)" {
  run grep -rIl -e 'rebuild-release' -e 'Rebuild Release' "$SRC" "$REPO_ROOT/.github/workflows" "$REPO_ROOT/.github/actions"
  echo "$output"
  [ "$status" -eq 1 ]
}
