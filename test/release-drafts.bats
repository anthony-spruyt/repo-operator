#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # $vars in single quotes are jq's; each @test runs in its own subshell by design

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/actions/release-drafts/drafts.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures"

  export FAKE_STATE="${BATS_TEST_TMPDIR}/state"
  mkdir -p "$FAKE_STATE/contents" "$FAKE_STATE/runs" "${BATS_TEST_TMPDIR}/bin"
  : >"$FAKE_STATE/calls"
  cp "$FX/release-drafts/fake-gh.sh" "${BATS_TEST_TMPDIR}/bin/gh"
  chmod +x "${BATS_TEST_TMPDIR}/bin/gh"
  export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"

  export GH_REPO="anthony-spruyt/example"
  export GH_TOKEN="job-token"
  export APP_TOKEN="app-token"
  export WORKFLOW_REF="anthony-spruyt/example/.github/workflows/release-please.yaml@refs/heads/main"
  export MAX_FAILURES="3"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : >"$GITHUB_OUTPUT"
  unset GITHUB_STEP_SUMMARY
}

# put_repo REF CONFIG_JSON MANIFEST_JSON
put_repo() {
  local dir="$FAKE_STATE/contents/${1//\//%2F}"
  mkdir -p "$dir"
  printf '%s\n' "$2" >"$dir/release-please-config.json"
  printf '%s\n' "$3" >"$dir/.release-please-manifest.json"
}

# put_fixture REF DETECT-IMAGES-FIXTURE
put_fixture() {
  local d="$FX/detect-images/$2"
  put_repo "$1" "$(<"$d/release-please-config.json")" "$(<"$d/.release-please-manifest.json")"
}

# put_file REF PATH [CONTENT]
put_file() {
  local f="$FAKE_STATE/contents/${1//\//%2F}/$2"
  mkdir -p "${f%/*}"
  printf '%s\n' "${3:-content}" >"$f"
}

output_of() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

# same_on_main REF - the default branch holds what REF holds, so the release of REF is the newest
same_on_main() {
  local dir="$FAKE_STATE/contents/${1//\//%2F}"
  mkdir -p "$FAKE_STATE/contents/main"
  cp "$dir/release-please-config.json" "$dir/.release-please-manifest.json" "$FAKE_STATE/contents/main/"
}

synthesize() {
  MODE=synthesize TAG="$1" run "$SCRIPT"
}

@test "synthesize maps a component tag with a slash separator to its image package" {
  put_fixture shutdown-orchestrator/v1.1.25 spruyt-labs
  put_file shutdown-orchestrator/v1.1.25 cmd/shutdown-orchestrator/Dockerfile
  same_on_main shutdown-orchestrator/v1.1.25
  synthesize shutdown-orchestrator/v1.1.25
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.["cmd/shutdown-orchestrator--tag_name"]')" = "shutdown-orchestrator/v1.1.25" ]
}

@test "synthesize maps a root package without a component to a bare v tag" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  same_on_main v3.0.0
  synthesize v3.0.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.tag_name')" = "v3.0.0" ]
}

@test "synthesize maps a component tag with a dash separator and no v" {
  put_fixture chrony-5.0.6 container-images
  put_file chrony-5.0.6 chrony/Dockerfile
  same_on_main chrony-5.0.6
  synthesize chrony-5.0.6
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.["chrony--tag_name"]')" = "chrony-5.0.6" ]
}

@test "synthesize counts a package holding flavor.yaml as an image" {
  put_fixture chrony-5.0.6 container-images
  put_file chrony-5.0.6 chrony/flavor.yaml
  same_on_main chrony-5.0.6
  synthesize chrony-5.0.6
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "synthesize applies the top-level defaults and a dot separator" {
  put_repo dotted.0.2.0 '{"include-v-in-tag":false,"packages":{"tools/dotted":{"release-type":"simple","component":"dotted","tag-separator":"."}}}' '{"tools/dotted":"0.2.0"}'
  put_file dotted.0.2.0 tools/dotted/Dockerfile
  same_on_main dotted.0.2.0
  synthesize dotted.0.2.0
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.["tools/dotted--version"]')" = "0.2.0" ]
}

@test "synthesize refuses a tag that is not the manifest version at that tag" {
  put_fixture v3.0.1 sungather
  put_file v3.0.1 Dockerfile
  synthesize v3.0.1
  echo "$output"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "synthesize refuses a package that holds no Dockerfile or flavor.yaml" {
  put_fixture v3.0.0 sungather
  synthesize v3.0.0
  echo "$output"
  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "synthesize refuses a package whose component release-please would read from a package file" {
  put_repo ts/v1.0.0 '{"packages":{"ts/unnamed":{"release-type":"node"}}}' '{"ts/unnamed":"1.0.0"}'
  put_file ts/v1.0.0 ts/unnamed/Dockerfile
  synthesize ts/v1.0.0
  echo "$output"
  [ "$status" -ne 0 ]
}

@test "synthesize refuses a tag with characters outside the tag pattern" {
  synthesize 'v1.0.0;rm -rf'
  echo "$output"
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_STATE/calls" ]
}

@test "synthesize writes the outputs release-please-action would, as strings keyed by package path" {
  put_fixture shutdown-orchestrator/v1.1.25 spruyt-labs
  put_file shutdown-orchestrator/v1.1.25 cmd/shutdown-orchestrator/Dockerfile
  same_on_main shutdown-orchestrator/v1.1.25
  synthesize shutdown-orchestrator/v1.1.25
  [ "$status" -eq 0 ]
  [ "$(output_of release-created)" = "true" ]
  [ "$(output_of releases)" = '{"paths_released":"[\"cmd/shutdown-orchestrator\"]","cmd/shutdown-orchestrator--tag_name":"shutdown-orchestrator/v1.1.25","cmd/shutdown-orchestrator--version":"1.1.25","cmd/shutdown-orchestrator--superseded":"false"}' ]
}

@test "synthesize leaves the keys of a root package unprefixed" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  same_on_main v3.0.0
  synthesize v3.0.0
  [ "$status" -eq 0 ]
  [ "$(output_of releases)" = '{"paths_released":"[\".\"]","tag_name":"v3.0.0","version":"3.0.0","superseded":"false"}' ]
}

@test "synthesize marks the release superseded when the default branch manifest holds a newer version" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_repo main "$(<"$FX/detect-images/sungather/release-please-config.json")" '{".":"3.1.0"}'
  synthesize v3.0.0
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.superseded')" = "true" ]
}

@test "synthesize does not mark the newest release superseded" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_fixture main sungather
  synthesize v3.0.0
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.superseded')" = "false" ]
}

@test "synthesize orders a prerelease below its release" {
  local config='{"include-component-in-tag":false,"packages":{".":{"release-type":"simple"}}}'
  put_repo v3.1.0-rc.1 "$config" '{".":"3.1.0-rc.1"}'
  put_file v3.1.0-rc.1 Dockerfile
  put_repo main "$config" '{".":"3.1.0"}'
  synthesize v3.1.0-rc.1
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.superseded')" = "true" ]
  : >"$GITHUB_OUTPUT"
  put_repo v3.1.0 "$config" '{".":"3.1.0"}'
  put_file v3.1.0 Dockerfile
  put_repo main "$config" '{".":"3.1.0-rc.2"}'
  synthesize v3.1.0
  [ "$status" -eq 0 ]
  [ "$(output_of releases | jq -r '.superseded')" = "false" ]
}

@test "synthesize compares versions numerically, not as text" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_repo main "$(<"$FX/detect-images/sungather/release-please-config.json")" '{".":"10.0.0"}'
  synthesize v3.0.0
  [ "$(output_of releases | jq -r '.superseded')" = "true" ]
}

@test "synthesize reads the default branch from the API" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  echo trunk >"$FAKE_STATE/default_branch"
  put_repo trunk "$(<"$FX/detect-images/sungather/release-please-config.json")" '{".":"4.0.0"}'
  synthesize v3.0.0
  [ "$(output_of releases | jq -r '.superseded')" = "true" ]
}

# refuses_synthesis - synthesize failed with an error and wrote no outputs
refuses_synthesis() {
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ -z "$(output_of releases)" ]
}

@test "synthesize refuses when the default branch cannot be read" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  touch "$FAKE_STATE/repo-fail"
  synthesize v3.0.0
  refuses_synthesis
}

@test "synthesize refuses when the default branch manifest cannot be read" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  synthesize v3.0.0
  refuses_synthesis
  [[ "$output" == *".release-please-manifest.json"* ]]
}

@test "synthesize refuses when the default branch manifest is not JSON" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_file main .release-please-manifest.json 'not json'
  synthesize v3.0.0
  refuses_synthesis
}

@test "synthesize refuses when the default branch no longer lists the package" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_repo main '{"packages":{}}' '{}'
  synthesize v3.0.0
  refuses_synthesis
}

@test "synthesize refuses when a version cannot be compared" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_repo main "$(<"$FX/detect-images/sungather/release-please-config.json")" '{".":"latest"}'
  synthesize v3.0.0
  refuses_synthesis
}

# add_release TAG DRAFT
add_release() {
  local f="$FAKE_STATE/releases.json"
  [[ -f "$f" ]] || echo '[]' >"$f"
  jq -c --arg t "$1" --argjson d "$2" '. + [{tag_name: $t, draft: $d}]' "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

# caller_at REF [without]: the caller file at REF, with a job that calls _release-recover.yaml unless "without"
caller_at() {
  local uses="anthony-spruyt/repo-operator/.github/workflows/_release-recover.yaml@0000000000000000000000000000000000000000"
  [[ "${2:-}" != "without" ]] || uses="anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0000000000000000000000000000000000000000"
  put_file "$1" .github/workflows/release-please.yaml "on:
  push:
    branches: [main]
jobs:
  release:
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0000000000000000000000000000000000000000
  recover:
    uses: $uses"
}

# stuck_draft TAG FIXTURE IMAGE_DIR: a draft whose tag exists and is an image package's release tag
stuck_draft() {
  add_release "$1" true
  echo "$1" >>"$FAKE_STATE/tags"
  put_fixture "$1" "$2"
  put_file "$1" "$3Dockerfile"
  caller_at "$1"
}

# add_run TAG STATUS CONCLUSION [EVENT]
add_run() {
  local f="$FAKE_STATE/runs/${1//\//%2F}.json"
  [[ -f "$f" ]] || echo '{"workflow_runs":[]}' >"$f"
  jq -c --arg s "$2" --arg c "$3" --arg e "${4:-workflow_dispatch}" '.workflow_runs += [{status: $s, conclusion: (if $c == "" then null else $c end), event: $e}]' "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

recover() {
  MODE=recover RELEASES="${RELEASES:-{\}}" run "$SCRIPT"
}

dispatched() {
  cat "$FAKE_STATE/dispatched" 2>/dev/null || true
}

@test "recover dispatches the caller workflow on the tag of a stuck draft" {
  stuck_draft v3.0.0 sungather ""
  recover
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
  grep -qxF "token=job-token workflow run release-please.yaml --ref v3.0.0" "$FAKE_STATE/calls"
}

@test "recover lists the releases with the app token" {
  recover
  [ "$status" -eq 0 ]
  grep -q '^token=app-token api .*repos/anthony-spruyt/example/releases' "$FAKE_STATE/calls"
  run ! grep -q '^token=job-token api .*/releases' "$FAKE_STATE/calls"
}

@test "recover dispatches the caller file named by the workflow ref" {
  export WORKFLOW_REF="anthony-spruyt/example/.github/workflows/image-release-please.yaml@refs/heads/main"
  stuck_draft v3.0.0 sungather ""
  put_file v3.0.0 .github/workflows/image-release-please.yaml "$(<"$FAKE_STATE/contents/v3.0.0/.github/workflows/release-please.yaml")"
  recover
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = "image-release-please.yaml v3.0.0" ]
}

@test "recover leaves published releases alone" {
  stuck_draft v3.0.0 sungather ""
  : >"$FAKE_STATE/releases.json"
  echo '[]' >"$FAKE_STATE/releases.json"
  add_release v3.0.0 false
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover skips a draft whose tag name is invalid without printing the name" {
  stuck_draft v3.0.0 sungather ""
  add_release $'bad name\r::warning::forged' true
  recover
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
  [[ "$output" != *forged* ]]
}

@test "recover leaves a draft without a tag alone" {
  stuck_draft v3.0.0 sungather ""
  : >"$FAKE_STATE/tags"
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover leaves a draft whose tag is not an image package's release tag alone" {
  stuck_draft v9.9.9 sungather ""
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover leaves a draft of a package without a Dockerfile alone" {
  stuck_draft v3.0.0 sungather ""
  rm "$FAKE_STATE/contents/v3.0.0/Dockerfile"
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover skips the drafts this run's release-please step created" {
  stuck_draft shutdown-orchestrator/v1.1.25 spruyt-labs cmd/shutdown-orchestrator/
  stuck_draft v3.0.0 sungather ""
  RELEASES='{"paths_released":"[\"cmd/shutdown-orchestrator\"]","cmd/shutdown-orchestrator--tag_name":"shutdown-orchestrator/v1.1.25","cmd/shutdown-orchestrator--version":"1.1.25"}' recover
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
}

@test "recover skips a draft whose caller at the tag does not recover drafts" {
  stuck_draft v3.0.0 sungather ""
  caller_at v3.0.0 without
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover takes a caller with a job that calls _release-recover.yaml for one that recovers, and nothing else" {
  stuck_draft v3.0.0 sungather ""
  put_file v3.0.0 .github/workflows/release-please.yaml "jobs:
  recover:
    uses: someone-else/repo-operator/.github/workflows/_release-recover.yaml@0000000000000000000000000000000000000000"
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
  put_file v3.0.0 .github/workflows/release-please.yaml "jobs:
  release:
    name: _release-recover.yaml
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0000000000000000000000000000000000000000"
  recover
  [ -z "$(dispatched)" ]
  put_file v3.0.0 .github/workflows/release-please.yaml "jobs:
  release:
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@0000000000000000000000000000000000000000
    with:
      recover-drafts: true"
  recover
  [ -z "$(dispatched)" ]
}

@test "recover skips a draft whose caller file is missing at the tag" {
  stuck_draft v3.0.0 sungather ""
  rm "$FAKE_STATE/contents/v3.0.0/.github/workflows/release-please.yaml"
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover dispatches every recoverable draft and only those" {
  stuck_draft shutdown-orchestrator/v1.1.25 spruyt-labs cmd/shutdown-orchestrator/
  stuck_draft v3.0.0 sungather ""
  caller_at v3.0.0 without
  stuck_draft chrony-5.0.6 container-images chrony/
  recover
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = $'release-please.yaml shutdown-orchestrator/v1.1.25\nrelease-please.yaml chrony-5.0.6' ]
}

@test "recover skips a tag that has a queued or running run" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 queued ""
  recover
  [ "$status" -eq 0 ]
  grep -q 'actions/workflows/release-please.yaml/runs' "$FAKE_STATE/calls"
  [ -z "$(dispatched)" ]
  rm "$FAKE_STATE/runs/v3.0.0.json"
  add_run v3.0.0 in_progress ""
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover looks up the runs of the tag on the caller workflow" {
  stuck_draft shutdown-orchestrator/v1.1.25 spruyt-labs cmd/shutdown-orchestrator/
  recover
  grep -q 'repos/anthony-spruyt/example/actions/workflows/release-please.yaml/runs?branch=shutdown-orchestrator%2Fv1.1.25' "$FAKE_STATE/calls"
}

@test "recover dispatches again after finished runs that did not fail" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 completed cancelled
  add_run v3.0.0 completed success
  recover
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
}

@test "recover stops after the failure cap and leaves a warning" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 completed failure
  add_run v3.0.0 completed timed_out
  add_run v3.0.0 completed failure
  recover
  echo "$output"
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
  [[ "$output" == *"::warning::"*"v3.0.0"*"3"* ]]
}

@test "recover keeps retrying below the failure cap" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 completed failure
  add_run v3.0.0 completed failure
  recover
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
}

@test "recover counts only the runs it dispatched toward the cap" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 completed failure push
  add_run v3.0.0 completed failure push
  add_run v3.0.0 completed failure push
  recover
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
}

@test "recover warns about a failed dispatch and goes on to the next draft" {
  stuck_draft shutdown-orchestrator/v1.1.25 spruyt-labs cmd/shutdown-orchestrator/
  stuck_draft chrony-5.0.6 container-images chrony/
  echo shutdown-orchestrator/v1.1.25 >"$FAKE_STATE/dispatch-fail"
  recover
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = "release-please.yaml chrony-5.0.6" ]
  [[ "$output" == *"::warning::"*"shutdown-orchestrator/v1.1.25"* ]]
}

@test "recover never dispatches from a tag-ref run" {
  stuck_draft v3.0.0 sungather ""
  GITHUB_REF_TYPE=tag recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
  [ ! -s "$FAKE_STATE/calls" ]
}

@test "recover warns and fails when the draft listing fails" {
  stuck_draft v3.0.0 sungather ""
  touch "$FAKE_STATE/releases-fail"
  recover
  [ "$status" -ne 0 ]
  [[ "$output" == *"::warning::"* ]]
  [ -z "$(dispatched)" ]
}

@test "recover skips a tag whose run is waiting, requested or pending" {
  stuck_draft v3.0.0 sungather ""
  local state
  for state in waiting requested pending; do
    rm -f "$FAKE_STATE/runs/v3.0.0.json"
    add_run v3.0.0 "$state" ""
    recover
    [ "$status" -eq 0 ]
    [ -z "$(dispatched)" ]
  done
}

@test "recover counts a dispatched run that failed to start toward the cap" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 completed failure
  add_run v3.0.0 completed failure
  add_run v3.0.0 completed startup_failure
  recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
  [[ "$output" == *"::warning::"* ]]
}

@test "recover caps at three failures when max-failures is empty" {
  stuck_draft v3.0.0 sungather ""
  add_run v3.0.0 completed failure
  add_run v3.0.0 completed failure
  add_run v3.0.0 completed failure
  MAX_FAILURES="" recover
  [ "$status" -eq 0 ]
  [ -z "$(dispatched)" ]
}

@test "recover refuses a max-failures that is not a number" {
  stuck_draft v3.0.0 sungather ""
  MAX_FAILURES=abc recover
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ -z "$(dispatched)" ]
}

@test "recover refuses a workflow ref it cannot read the caller file from" {
  stuck_draft v3.0.0 sungather ""
  local ref
  for ref in \
    "someone/else/.github/workflows/release-please.yaml@refs/heads/main" \
    "anthony-spruyt/example/.github/workflows/sub/release-please.yaml@refs/heads/main" \
    "anthony-spruyt/example/.github/workflows/../release-please.yaml@refs/heads/main" \
    "anthony-spruyt/example/release-please.yaml@refs/heads/main" \
    ""; do
    WORKFLOW_REF="$ref" recover
    echo "$ref: $output"
    [ "$status" -ne 0 ]
    [[ "$output" == *"::error::"* ]]
    [ -z "$(dispatched)" ]
  done
}

@test "recover refuses to run without a repository, a mode or an app token" {
  stuck_draft v3.0.0 sungather ""
  GH_REPO="" recover
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"GH_REPO"* ]]
  MODE="" run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  MODE=other run "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  APP_TOKEN="" recover
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"APP_TOKEN"* ]]
  [ -z "$(dispatched)" ]
}

@test "recover treats a missing releases input as no releases and refuses one that is not JSON" {
  stuck_draft v3.0.0 sungather ""
  MODE=recover run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
  rm "$FAKE_STATE/dispatched"
  RELEASES="not json" recover
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"RELEASES"* ]]
  [ -z "$(dispatched)" ]
}

@test "synthesize refuses a package path that leaves the repo or holds characters outside the path pattern" {
  local key
  for key in "../x" "x y" "x?y"; do
    : >"$GITHUB_OUTPUT"
    rm -rf "$FAKE_STATE/contents"
    put_repo x-1.0.0 "{\"include-v-in-tag\":false,\"packages\":{\"$key\":{\"release-type\":\"simple\",\"component\":\"x\"}}}" "{\"$key\":\"1.0.0\"}"
    put_file x-1.0.0 "$key/Dockerfile"
    same_on_main x-1.0.0
    synthesize x-1.0.0
    echo "$key: $output"
    [ "$status" -ne 0 ]
    [ -z "$(output_of releases)" ]
  done
}

@test "recover reads every page of the releases" {
  stuck_draft v3.0.0 sungather ""
  jq -c '[., [{tag_name: "v0.0.1", draft: false}]]' "$FAKE_STATE/releases.json" | jq -c '.[0], .[1]' >"$FAKE_STATE/releases.json.pages"
  mv "$FAKE_STATE/releases.json.pages" "$FAKE_STATE/releases.json"
  recover
  [ "$(dispatched)" = "release-please.yaml v3.0.0" ]
}

packages_jq() {
  sed -n "/^readonly PACKAGES_JQ='/,/^'\$/p" "$1"
}

@test "drafts.sh holds the same PACKAGES_JQ as detect.sh, so both read a package's tag the same way" {
  local detect="${BATS_TEST_DIRNAME}/../.github/actions/detect-images/detect.sh"
  [ -n "$(packages_jq "$detect")" ]
  [ "$(packages_jq "$SCRIPT")" = "$(packages_jq "$detect")" ]
}

# detect_released FIXTURE REPOSITORY: detect.sh released mode over the fixture, reading the synthesized releases
detect_released() {
  local repo="$BATS_TEST_TMPDIR/repo" out="$BATS_TEST_TMPDIR/detect-output"
  mkdir -p "$repo"
  cp -R "$FX/detect-images/$1/." "$repo/"
  : >"$out"
  (cd "$repo" && MODE=released RELEASES="$(output_of releases)" GITHUB_OUTPUT="$out" GITHUB_REPOSITORY="$2" "${BATS_TEST_DIRNAME}/../.github/actions/detect-images/detect.sh") >/dev/null
  sed -n 's/^matrix=//p' "$out"
}

@test "detect.sh released mode reads a synthesized root release and marks it not the latest when superseded" {
  put_fixture v3.0.0 sungather
  put_file v3.0.0 Dockerfile
  put_repo main "$(<"$FX/detect-images/sungather/release-please-config.json")" '{".":"3.1.0"}'
  synthesize v3.0.0
  [ "$status" -eq 0 ]
  run detect_released sungather anthony-spruyt/SunGather
  [ "$status" -eq 0 ]
  [ "$(jq -c '.include | map([.name, .version, ."tag-name", ."tag-prefix", .latest])' <<<"$output")" = '[["sungather","3.0.0","v3.0.0","",false]]' ]
}

@test "detect.sh released mode reads a synthesized nested release" {
  put_fixture shutdown-orchestrator/v1.1.25 spruyt-labs
  put_file shutdown-orchestrator/v1.1.25 cmd/shutdown-orchestrator/Dockerfile
  put_fixture main spruyt-labs
  synthesize shutdown-orchestrator/v1.1.25
  [ "$status" -eq 0 ]
  run detect_released spruyt-labs anthony-spruyt/spruyt-labs
  [ "$status" -eq 0 ]
  [ "$(jq -c '.include | map([.name, .version, ."tag-name", ."tag-prefix", .latest])' <<<"$output")" = '[["shutdown-orchestrator","1.1.25","shutdown-orchestrator/v1.1.25","",true]]' ]
}
