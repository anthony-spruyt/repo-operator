#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # each @test runs in its own subshell by design
# Fixtures copy the release-please config of SunGather, container-images, spruyt-labs and xfg on 2026-10-09,
# with empty Dockerfiles and flavor.yaml files. The megalinter-*/ and spruyt-labs metadata.yaml files are the planned additions.
# diffs/*.txt are the files changed by the real PR named in each file name; *-only.txt are synthetic.
# releases/*.json are release-please-action v5 outputs for the real releases named in each file name, built from
# the GitHub releases API the way the action's outputReleases maps them; release-matrix-scratch-* is a run's own
# toJSON(steps.release.outputs). scratch/ is release-matrix-scratch's layout. top-level-v/ and its release are synthetic.

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/actions/detect-images/detect.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures/detect-images"
  REPO="${BATS_TEST_TMPDIR}/repo"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : >"$GITHUB_OUTPUT"
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export MODE=changed
  unset IMAGE BASE_SHA REPO_NAME GITHUB_STEP_SUMMARY RELEASES
  export GITHUB_REPOSITORY=anthony-spruyt/fixture
}

# use_layout <fixture> - a git repo holding the fixture as its first commit
use_layout() {
  mkdir -p "$REPO"
  cp -R "$FX/$1/." "$REPO/"
  git -C "$REPO" init -q -b main
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
}

# commit_files <file>... - one commit that edits every listed path
commit_files() {
  local f
  for f in "$@"; do
    mkdir -p "$REPO/$(dirname "$f")"
    echo "change $RANDOM" >>"$REPO/$f"
    git -C "$REPO" add -- "$f"
  done
  git -C "$REPO" commit -q -m change
}

# commit_diff <diff-name> - one commit that edits every file a recorded diff lists
commit_diff() {
  local files
  mapfile -t files <"$FX/diffs/$1.txt"
  commit_files "${files[@]}"
}

detect() {
  run --separate-stderr bash -c 'cd "$1" && "$2"' _ "$REPO" "$SCRIPT"
}

output_value() {
  sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

images() {
  output_value matrix | jq -r '[.include[].name] | join(",")'
}

image_entry() {
  output_value matrix | jq -c --arg n "$1" '.include[] | select(.name == $n)'
}

# release_of <name> - the image's [version, tag-name, tag-prefix]
release_of() {
  image_entry "$1" | jq -c '[.version, ."tag-name", ."tag-prefix"]'
}

released() {
  RELEASES=$(cat "$FX/releases/$1.json") MODE=released detect
}

@test "single-image repo: path . is named after the lowercased repo and rebuilds on any change" {
  use_layout sungather
  export GITHUB_REPOSITORY=anthony-spruyt/SunGather
  commit_files src/sungather/sungather.py
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "sungather" ]
  [ "$(output_value has-images)" = "true" ]
  [ "$(image_entry sungather)" = '{"name":"sungather","path":".","context":".","dockerfile":"Dockerfile","watch":[],"prepare-command":"","free-disk":false,"extra-tags":"","test-command":"","language":"","workdir":"."}' ]
}

@test "single-image repo: REPO_NAME overrides the repository name" {
  use_layout sungather
  export REPO_NAME=mcp-header-proxy
  commit_files main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "mcp-header-proxy" ]
}

@test "single-image repo: a release PR that bumps its extra-files builds nothing (SunGather#402)" {
  use_layout sungather
  export GITHUB_REPOSITORY=anthony-spruyt/SunGather
  commit_diff sungather-402-release
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "single-image repo: a dependency bump of the extra-files still builds" {
  use_layout sungather
  export GITHUB_REPOSITORY=anthony-spruyt/SunGather
  commit_files pyproject.toml uv.lock
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "sungather" ]
}

@test "single-image repo: exclude-paths take files out of the package (SunGather)" {
  use_layout sungather
  export GITHUB_REPOSITORY=anthony-spruyt/SunGather
  commit_files .github/workflows/ci.yaml docs/index.md img/logo.png
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "single-image repo: an excluded path alongside a source change still builds" {
  use_layout sungather
  export GITHUB_REPOSITORY=anthony-spruyt/SunGather
  commit_files .github/workflows/ci.yaml src/sungather/sungather.py
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "sungather" ]
}

@test "python release-type: a release PR bumping version.py builds nothing (SunGather#378)" {
  use_layout sungather
  jq '.packages = {"SunGather": {"release-type": "python", "component": "sungather", "changelog-path": "/CHANGELOG.md"}}' \
    "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  mkdir "$REPO/SunGather"
  git -C "$REPO" mv Dockerfile SunGather/Dockerfile
  git -C "$REPO" commit -qam python
  commit_diff sungather-378-release-python
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "python release-type: version files without the manifest still build" {
  use_layout sungather
  jq '.packages = {".": {"release-type": "python"}}' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam python
  commit_files src/sungather/__init__.py src/sungather/version.py pyproject.toml setup.py setup.cfg
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "fixture" ]
  : >"$GITHUB_OUTPUT"
  commit_files .release-please-manifest.json CHANGELOG.md src/sungather/__init__.py src/sungather/version.py pyproject.toml setup.py setup.cfg
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "release-only changes build nothing (container-images#2107)" {
  use_layout container-images
  commit_diff container-images-2107-release-only
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value matrix)" = '{"include":[]}' ]
  [ "$(output_value has-images)" = "false" ]
}

@test "single-image repo: only CHANGELOG.md and the manifest build nothing" {
  use_layout sungather
  commit_files CHANGELOG.md .release-please-manifest.json
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "container-images: lists packages with a Dockerfile or flavor.yaml, not test-images or .devcontainer" {
  use_layout container-images
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "chrony,claude-agent-read,claude-agent-spruyt-labs,claude-agent-write,coder-gitops,devcontainer-common,happy-server,llm-guard,llm-guard-cuda,megalinter-base,megalinter-cpp,megalinter-go,megalinter-python,megalinter-spruyt-labs,megalinter-typescript,ssh-key-rotation" ]
}

@test "container-images: a build_context source change also rebuilds its dependent (container-images#2191)" {
  use_layout container-images
  commit_diff container-images-2191-llm-guard-app
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "llm-guard,llm-guard-cuda" ]
  [ "$(image_entry llm-guard-cuda | jq -c '[.path, .context, .dockerfile]')" = '["llm-guard-cuda","llm-guard","llm-guard-cuda/Dockerfile"]' ]
}

@test "container-images: a change to the dependent alone does not rebuild its build_context source" {
  use_layout container-images
  commit_files llm-guard-cuda/Dockerfile
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "llm-guard-cuda" ]
}

@test "container-images: a megalinter-factory change rebuilds every flavor through watch (container-images#2154)" {
  use_layout container-images
  commit_diff container-images-2154-factory
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "megalinter-base,megalinter-cpp,megalinter-go,megalinter-python,megalinter-spruyt-labs,megalinter-typescript" ]
}

@test "container-images: mixed change picks direct, build_context and watch images (container-images#2185)" {
  use_layout container-images
  commit_diff container-images-2185-refactor
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "llm-guard,llm-guard-cuda,megalinter-base,megalinter-cpp,megalinter-go,megalinter-python,megalinter-spruyt-labs,megalinter-typescript" ]
}

@test "container-images: a biome plugin change rebuilds megalinter-spruyt-labs" {
  use_layout container-images
  commit_diff container-images-biome-plugin-only
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "megalinter-spruyt-labs" ]
}

@test "simple release-type: version.txt counts as a release file only in a release PR" {
  use_layout container-images
  commit_files .release-please-manifest.json chrony/CHANGELOG.md chrony/version.txt
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
  : >"$GITHUB_OUTPUT"
  commit_files chrony/version.txt
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "chrony" ]
}

@test "simple release-type: version-file replaces version.txt" {
  use_layout container-images
  jq '.packages.chrony."version-file" = "VERSION"' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam version-file
  commit_files .release-please-manifest.json chrony/CHANGELOG.md chrony/version.txt
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "chrony" ]
  : >"$GITHUB_OUTPUT"
  commit_files .release-please-manifest.json chrony/CHANGELOG.md chrony/VERSION
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "node release-type: root extra-files and a root changelog-path make a release PR (xfg#1121)" {
  use_layout xfg
  : >"$REPO/packages/xfg/Dockerfile"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm image
  commit_diff xfg-1121-release
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "container-images: flavor settings come from metadata.yaml" {
  use_layout container-images
  MODE=all detect
  [ "$status" -eq 0 ]
  run jq -r '.watch[0], ."free-disk", ."prepare-command", ."test-command", .dockerfile' <<<"$(image_entry megalinter-go)"
  [ "${lines[0]}" = "megalinter-factory/" ]
  [ "${lines[1]}" = "true" ]
  [ "${lines[2]}" = "pip install -q --require-hashes --only-binary :all: -r megalinter-factory/requirements.txt && python megalinter-factory/generate.py megalinter-go" ]
  [ "${lines[3]}" = 'bash ./megalinter-go/test.sh "$IMAGE_REF"' ]
  [ "${lines[4]}" = "megalinter-go/Dockerfile" ]
}

@test "container-images: an image without metadata.yaml gets defaults" {
  use_layout container-images
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(image_entry chrony)" = '{"name":"chrony","path":"chrony","context":"chrony","dockerfile":"chrony/Dockerfile","watch":[],"prepare-command":"","free-disk":false,"extra-tags":"","test-command":"","language":"","workdir":"chrony"}' ]
}

@test "spruyt-labs: lists nested packages and the Go service" {
  use_layout spruyt-labs
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator,agent-queue-worker,bull-board" ]
}

@test "spruyt-labs: each image takes its language from its metadata.yaml" {
  use_layout spruyt-labs
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(output_value matrix | jq -c '[.include[] | [.name, .context, .language]]')" = '[["shutdown-orchestrator","cmd/shutdown-orchestrator","go"],["agent-queue-worker","ts/agent-queue-worker","node"],["bull-board","ts/agent-queue-worker/bull-board","node"]]' ]
}

@test "spruyt-labs: each image's workdir defaults to its package path" {
  use_layout spruyt-labs
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(output_value matrix | jq -c '[.include[] | [.name, .workdir]]')" = '[["shutdown-orchestrator","cmd/shutdown-orchestrator"],["agent-queue-worker","ts/agent-queue-worker"],["bull-board","ts/agent-queue-worker/bull-board"]]' ]
}

@test "spruyt-labs: metadata.yaml workdir overrides the package path" {
  use_layout spruyt-labs
  printf 'language: go\nworkdir: ./cmd/\n' >"$REPO/cmd/shutdown-orchestrator/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(image_entry shutdown-orchestrator | jq -c '[.context, .workdir]')" = '["cmd/shutdown-orchestrator","cmd"]' ]
}

@test "spruyt-labs: an image without metadata.yaml leaves language empty, so the workflow's input applies" {
  use_layout spruyt-labs
  git -C "$REPO" rm -q ts/agent-queue-worker/bull-board/metadata.yaml
  git -C "$REPO" commit -q -m no-metadata
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(image_entry bull-board | jq -c '.language')" = '""' ]
}

@test "spruyt-labs: a nested bull-board change does not rebuild the parent agent-queue-worker" {
  use_layout spruyt-labs
  commit_diff spruyt-labs-bull-board-src-only
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "bull-board" ]
}

@test "spruyt-labs: a parent change does not rebuild bull-board, and cluster files map to nothing (spruyt-labs#1462)" {
  use_layout spruyt-labs
  commit_diff spruyt-labs-1462-agent-queue-worker
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker" ]
}

@test "spruyt-labs: a source-only change in ts/agent-queue-worker/src builds only agent-queue-worker" {
  use_layout spruyt-labs
  commit_files ts/agent-queue-worker/src/processor.ts ts/agent-queue-worker/src/queue/lifecycle.ts
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker" ]
}

@test "spruyt-labs: a cmd/ change builds only shutdown-orchestrator" {
  use_layout spruyt-labs
  commit_files cmd/shutdown-orchestrator/main.go cmd/shutdown-orchestrator/go.mod
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator" ]
}

@test "spruyt-labs: a release PR that bumps package.json builds nothing (spruyt-labs#3380)" {
  use_layout spruyt-labs
  commit_diff spruyt-labs-3380-release-bull-board
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "spruyt-labs: a release PR covering both nested node packages builds nothing (spruyt-labs#3183)" {
  use_layout spruyt-labs
  commit_diff spruyt-labs-3183-release-both
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "spruyt-labs: a release PR with a source change too builds the changed package" {
  use_layout spruyt-labs
  commit_diff spruyt-labs-3380-release-bull-board
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD~1)
  export BASE_SHA
  commit_files ts/agent-queue-worker/bull-board/src/index.ts
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "bull-board" ]
}

@test "spruyt-labs: a Renovate lockfile-only bump builds both packages (spruyt-labs#2675)" {
  use_layout spruyt-labs
  commit_diff spruyt-labs-2675-renovate-lockfiles
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker,bull-board" ]
}

@test "spruyt-labs: a Renovate package.json bump builds that package" {
  use_layout spruyt-labs
  commit_files ts/agent-queue-worker/package.json ts/agent-queue-worker/package-lock.json
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker" ]
}

@test "extra-files: top-level entries apply to each package, relative to its path" {
  use_layout spruyt-labs
  jq '."extra-files" = [{"type": "json", "path": "version.json", "jsonpath": "$.version"}]' \
    "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam extra-files
  commit_files .release-please-manifest.json ts/agent-queue-worker/bull-board/CHANGELOG.md ts/agent-queue-worker/bull-board/version.json
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "extra-files: string entries are relative to the package unless they start with /" {
  use_layout spruyt-labs
  jq '.packages["cmd/shutdown-orchestrator"]."extra-files" = ["VERSION"]' \
    "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam extra-files
  commit_files .release-please-manifest.json cmd/shutdown-orchestrator/CHANGELOG.md cmd/shutdown-orchestrator/VERSION
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
  : >"$GITHUB_OUTPUT"
  jq '.packages["cmd/shutdown-orchestrator"]."extra-files" = ["/VERSION"]' \
    "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam root
  commit_files .release-please-manifest.json cmd/shutdown-orchestrator/CHANGELOG.md cmd/shutdown-orchestrator/VERSION
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator" ]
}

@test "exclude-paths: an excluded file falls through to the next-longest package" {
  use_layout spruyt-labs
  jq '.packages["ts/agent-queue-worker/bull-board"]."exclude-paths" = ["ts/agent-queue-worker/bull-board/docs/"]' \
    "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam exclude
  commit_files ts/agent-queue-worker/bull-board/docs/usage.md
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
  : >"$GITHUB_OUTPUT"
  jq 'del(.packages["ts/agent-queue-worker"]."exclude-paths")' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam parent
  commit_files ts/agent-queue-worker/bull-board/docs/usage.md
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker" ]
}

@test "longest path: a nested file goes only to the nested package, without exclude-paths" {
  use_layout spruyt-labs
  jq 'del(.packages["ts/agent-queue-worker"]."exclude-paths")' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam parent
  commit_diff spruyt-labs-bull-board-src-only
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "bull-board" ]
}

@test "longest path: a parent file outside the nested package goes only to the parent, without exclude-paths" {
  use_layout spruyt-labs
  jq 'del(.packages["ts/agent-queue-worker"]."exclude-paths")' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam parent
  commit_files ts/agent-queue-worker/src/index.ts
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker" ]
}

@test "go release-type: a release PR bumping version-file builds nothing" {
  use_layout spruyt-labs
  jq '.packages["cmd/shutdown-orchestrator"] += {"release-type": "go", "version-file": "version.go"}' \
    "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" commit -qam go
  commit_files .release-please-manifest.json cmd/shutdown-orchestrator/CHANGELOG.md cmd/shutdown-orchestrator/version.go
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "spruyt-labs: cmd/shutdown-orchestrator builds from its own path" {
  use_layout spruyt-labs
  commit_files cmd/shutdown-orchestrator/main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(image_entry shutdown-orchestrator | jq -c '[.path, .context, .dockerfile]')" = '["cmd/shutdown-orchestrator","cmd/shutdown-orchestrator","cmd/shutdown-orchestrator/Dockerfile"]' ]
}

@test "xfg: an npm package without a Dockerfile is not an image (xfg#1140)" {
  use_layout xfg
  commit_diff xfg-1140-feat
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(output_value matrix | tail -n1)" = '{"include":[]}' ]
}

@test "a repo without release-please-config.json has no images" {
  mkdir -p "$REPO"
  : >"$REPO/Dockerfile"
  git -C "$REPO" init -q -b main
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  commit_files Dockerfile
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value matrix)" = '{"include":[]}' ]
  [ "$(output_value has-images)" = "false" ]
}

@test "push: diffs HEAD~1 only, so earlier commits do not rebuild" {
  use_layout container-images
  commit_files chrony/Dockerfile
  commit_files happy-server/Dockerfile
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "happy-server" ]
}

@test "pull request: diffs against the merge base, ignoring later commits on the base branch" {
  use_layout container-images
  git -C "$REPO" checkout -q -b feature
  commit_files happy-server/Dockerfile
  commit_files coder-gitops/Dockerfile
  git -C "$REPO" checkout -q main
  commit_files chrony/Dockerfile
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  git -C "$REPO" checkout -q feature
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "coder-gitops,happy-server" ]
}

@test "pull request: a diff too large for one argument still selects images" {
  use_layout container-images
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  mkdir -p "$REPO/happy-server/generated"
  for i in $(seq 1 5000); do
    : >"$REPO/happy-server/generated/file-with-a-long-name-to-pass-the-argument-limit-$i.txt"
  done
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m generated
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "happy-server" ]
}

@test "pull request: a renamed file rebuilds both the old and the new package" {
  use_layout container-images
  commit_files chrony/chrony.conf
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  git -C "$REPO" mv chrony/chrony.conf happy-server/chrony.conf
  git -C "$REPO" commit -q -m move
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "chrony,happy-server" ]
}

# edit_config <jq filter> - rewrite release-please-config.json in the work tree, uncommitted
edit_config() {
  jq "$1" "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  git -C "$REPO" add release-please-config.json
}

@test "pull request: adding its own files to exclude-paths does not skip the build" {
  use_layout spruyt-labs
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  edit_config '.packages["cmd/shutdown-orchestrator"]."exclude-paths" = ["cmd/shutdown-orchestrator"]'
  commit_files cmd/shutdown-orchestrator/main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator" ]
}

@test "pull request: adding its own files to extra-files does not make it a release PR" {
  use_layout spruyt-labs
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  edit_config '.packages["cmd/shutdown-orchestrator"]."extra-files" = ["main.go", "/release-please-config.json"]'
  commit_files .release-please-manifest.json cmd/shutdown-orchestrator/CHANGELOG.md cmd/shutdown-orchestrator/main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator" ]
}

@test "pull request: removing its own package from the config does not skip the build" {
  use_layout spruyt-labs
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  edit_config 'del(.packages["cmd/shutdown-orchestrator"])'
  commit_files cmd/shutdown-orchestrator/main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator" ]
}

@test "pull request: deleting the config does not skip the build" {
  use_layout spruyt-labs
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  git -C "$REPO" rm -q release-please-config.json
  commit_files ts/agent-queue-worker/src/index.ts
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker" ]
}

@test "pull request: a package the PR adds builds from the PR's config" {
  use_layout spruyt-labs
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  edit_config '.packages["cmd/new-svc"] = {"release-type": "simple", "component": "new-svc"}'
  commit_files cmd/new-svc/Dockerfile cmd/shutdown-orchestrator/main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator,new-svc" ]
}

@test "pull request: a repo whose base has no config builds the packages the PR adds" {
  mkdir -p "$REPO"
  : >"$REPO/Dockerfile"
  git -C "$REPO" init -q -b main
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m base
  BASE_SHA=$(git -C "$REPO" rev-parse HEAD)
  export BASE_SHA
  echo '{"packages": {".": {"release-type": "simple"}}}' >"$REPO/release-please-config.json"
  git -C "$REPO" add release-please-config.json
  git -C "$REPO" commit -q -m release-please
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "fixture" ]
}

@test "push: the pushed commit's config applies, including its own exclude-paths" {
  use_layout spruyt-labs
  edit_config '.packages["cmd/shutdown-orchestrator"]."exclude-paths" = ["cmd/shutdown-orchestrator"]'
  commit_files cmd/shutdown-orchestrator/main.go
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "pull request: a base commit missing from the clone fails clearly" {
  use_layout container-images
  export BASE_SHA=0123456789abcdef0123456789abcdef01234567
  detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Base commit 0123456789abcdef0123456789abcdef01234567 is not in the clone"* ]]
}

@test "push: a clone without HEAD~1 fails clearly" {
  use_layout container-images
  detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::HEAD~1 is not in the clone"* ]]
}

@test "dispatch: IMAGE builds exactly that image, whatever changed" {
  use_layout container-images
  commit_files chrony/Dockerfile
  IMAGE=llm-guard-cuda detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "llm-guard-cuda" ]
  [ "$(output_value has-images)" = "true" ]
}

@test "dispatch: an unknown image fails and lists the images" {
  use_layout spruyt-labs
  IMAGE=nope detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Unknown image: nope. Images: shutdown-orchestrator, agent-queue-worker, bull-board"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "dispatch: an image that is a package without a Dockerfile is unknown" {
  use_layout xfg
  IMAGE=xfg detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Unknown image: xfg. Images: (none)"* ]]
}

@test "dispatch: an image name with unsafe characters is rejected" {
  use_layout spruyt-labs
  IMAGE='bull-board%0A::warning::x' detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Invalid image name"* ]]
}

@test "an unknown mode fails" {
  use_layout spruyt-labs
  MODE=everything detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::mode must be changed, all or released, got: everything"* ]]
}

@test "rebuild mode is refused" {
  use_layout scratch
  IMAGE=dot VERSION=1.0.0 MODE=rebuild detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::mode must be changed, all or released, got: rebuild"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "an invalid base SHA fails" {
  use_layout spruyt-labs
  BASE_SHA='main; rm -rf /' detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Invalid base SHA"* ]]
}

@test "metadata.yaml: extra-tags accepts a list and watch matches a single file" {
  use_layout spruyt-labs
  printf 'watch:\n  - go.work\nextra-tags:\n  - type=sha,prefix=\n  - type=raw,value=edge\n' >"$REPO/cmd/shutdown-orchestrator/metadata.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m metadata
  commit_files go.work
  detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator" ]
  [ "$(image_entry shutdown-orchestrator | jq -r '."extra-tags"')" = $'type=sha,prefix=\ntype=raw,value=edge' ]
}

@test "metadata.yaml: watch is a path prefix, not a string prefix" {
  use_layout spruyt-labs
  printf 'watch:\n  - go\n' >"$REPO/cmd/shutdown-orchestrator/metadata.yaml"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m metadata
  commit_files go.work
  detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "metadata.yaml: a build_context that escapes the repo fails" {
  use_layout spruyt-labs
  printf 'build_context: ../secrets\n' >"$REPO/ts/agent-queue-worker/bull-board/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/bull-board/metadata.yaml: build_context must be a relative path inside the repo"* ]]
}

@test "metadata.yaml: a workdir that escapes the repo fails" {
  use_layout spruyt-labs
  printf 'workdir: ts/../../secrets\n' >"$REPO/ts/agent-queue-worker/bull-board/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/bull-board/metadata.yaml: workdir must be a relative path inside the repo"* ]]
}

@test "metadata.yaml: a build_context that does not exist fails" {
  use_layout spruyt-labs
  printf 'build_context: ts/missing\n' >"$REPO/ts/agent-queue-worker/bull-board/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/bull-board/metadata.yaml: build_context directory does not exist: ts/missing"* ]]
}

@test "metadata.yaml: a workdir that does not exist fails" {
  use_layout spruyt-labs
  printf 'language: node\nworkdir: ./ts/missing/\n' >"$REPO/ts/agent-queue-worker/bull-board/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/bull-board/metadata.yaml: workdir directory does not exist: ts/missing"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "metadata.yaml: free-disk must be a boolean" {
  use_layout spruyt-labs
  printf 'free-disk: yes please\n' >"$REPO/ts/agent-queue-worker/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/metadata.yaml: free-disk must be true or false"* ]]
}

@test "metadata.yaml: language must be go, node, python or none" {
  use_layout spruyt-labs
  printf 'language: rust\n' >"$REPO/ts/agent-queue-worker/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/metadata.yaml: language must be go, node, python or none"* ]]
}

@test "metadata.yaml: watch must be a list of paths" {
  use_layout spruyt-labs
  printf 'watch: go.work\n' >"$REPO/ts/agent-queue-worker/metadata.yaml"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::ts/agent-queue-worker/metadata.yaml: watch must be a list of relative paths inside the repo"* ]]
}

@test "an image name that is not a valid image reference fails" {
  use_layout spruyt-labs
  jq '.packages["cmd/shutdown-orchestrator"].component = "Shutdown"' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Invalid image name for package cmd/shutdown-orchestrator: Shutdown"* ]]
}

@test "two packages with the same image name fail" {
  use_layout spruyt-labs
  jq '.packages["ts/agent-queue-worker/bull-board"].component = "agent-queue-worker"' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  MODE=all detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Duplicate image name: agent-queue-worker"* ]]
}

@test "a package without component is named after its path's basename" {
  use_layout spruyt-labs
  jq 'del(.packages["ts/agent-queue-worker/bull-board"].component)' "$REPO/release-please-config.json" >"$REPO/c.json"
  mv "$REPO/c.json" "$REPO/release-please-config.json"
  MODE=all detect
  [ "$status" -eq 0 ]
  [ "$(images)" = "shutdown-orchestrator,agent-queue-worker,bull-board" ]
}

@test "the step summary lists the images" {
  use_layout spruyt-labs
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary"
  MODE=all detect
  [ "$status" -eq 0 ]
  grep -qx -- '- `bull-board` (`ts/agent-queue-worker/bull-board`)' "$GITHUB_STEP_SUMMARY"
}

@test "released: one merge releasing two nested packages publishes each with its own tag (spruyt-labs#3183)" {
  use_layout spruyt-labs
  released spruyt-labs-3183-release-both
  [ "$status" -eq 0 ]
  [ "$(images)" = "agent-queue-worker,bull-board" ]
  [ "$(release_of agent-queue-worker)" = '["3.3.61","agent-queue-worker/v3.3.61",""]' ]
  [ "$(release_of bull-board)" = '["0.2.40","bull-board/v0.2.40",""]' ]
  [ "$(output_value matrix | jq -c '[.include[] | [.language, .workdir]]')" = '[["node","ts/agent-queue-worker"],["node","ts/agent-queue-worker/bull-board"]]' ]
  [ "$(image_entry bull-board | jq -c '[.path, .context, .dockerfile]')" = '["ts/agent-queue-worker/bull-board","ts/agent-queue-worker/bull-board","ts/agent-queue-worker/bull-board/Dockerfile"]' ]
}

@test "released: eight releases on one merge publish the six that are images, each with its own tag (container-images#2088)" {
  use_layout container-images
  released container-images-2088-release
  [ "$status" -eq 0 ]
  [ "$(images)" = "claude-agent-read,happy-server,llm-guard,llm-guard-cuda,megalinter-go,megalinter-spruyt-labs" ]
  [ "$(release_of llm-guard)" = '["1.0.43","llm-guard-1.0.43",""]' ]
  [ "$(release_of llm-guard-cuda)" = '["1.0.15","llm-guard-cuda-1.0.15",""]' ]
  [ "$(release_of megalinter-go)" = '["2.0.0","megalinter-go-2.0.0",""]' ]
  [ "$(release_of megalinter-spruyt-labs)" = '["3.0.0","megalinter-spruyt-labs-v3.0.0","v"]' ]
  [ "$(image_entry llm-guard-cuda | jq -r .context)" = "llm-guard" ]
  [ "$(image_entry megalinter-go | jq -r '."free-disk"')" = "true" ]
}

@test "released: a root package's release uses the unprefixed outputs (SunGather v3.0.0)" {
  use_layout sungather
  export GITHUB_REPOSITORY=anthony-spruyt/SunGather
  released sungather-v3.0.0
  [ "$status" -eq 0 ]
  [ "$(images)" = "sungather" ]
  [ "$(release_of sungather)" = '["3.0.0","v3.0.0",""]' ]
  [ "$(output_value has-images)" = "true" ]
}

@test "released: the '.' and '/'+v tags of one release run, as release-please-action output them (release-matrix-scratch#7)" {
  use_layout scratch
  released release-matrix-scratch-7-release-two
  [ "$status" -eq 0 ]
  [ "$(images)" = "dot,slash" ]
  [ "$(release_of dot)" = '["0.2.0","dot.0.2.0",""]' ]
  [ "$(release_of slash)" = '["0.2.0","slash/v0.2.0","v"]' ]
}

@test "released: a top-level include-v-in-tag gives a package that sets none a v docker tag, and a package's own false wins" {
  use_layout top-level-v
  released top-level-v-release
  [ "$status" -eq 0 ]
  [ "$(images)" = "app,plain" ]
  [ "$(release_of app)" = '["1.2.0","app-v1.2.0","v"]' ]
  [ "$(release_of plain)" = '["1.0.0","plain-1.0.0",""]' ]
}

@test "released: a run that created no release publishes nothing" {
  use_layout spruyt-labs
  RELEASES='{"releases_created":"false","paths_released":"[]","prs_created":"true"}' MODE=released detect
  [ "$status" -eq 0 ]
  [ "$(output_value matrix)" = '{"include":[]}' ]
  [ "$(output_value has-images)" = "false" ]
}

@test "released: a released package without a Dockerfile is not published" {
  use_layout xfg
  RELEASES='{"releases_created":"true","paths_released":"[\"packages/xfg\"]","packages/xfg--tag_name":"v8.1.0","packages/xfg--version":"8.1.0"}' MODE=released detect
  [ "$status" -eq 0 ]
  [ "$(output_value has-images)" = "false" ]
}

@test "released: a released path written with ./ still matches its package" {
  use_layout spruyt-labs
  RELEASES='{"releases_created":"true","paths_released":"[\"./cmd/shutdown-orchestrator\"]","./cmd/shutdown-orchestrator--tag_name":"shutdown-orchestrator/v1.1.25","./cmd/shutdown-orchestrator--version":"1.1.25"}' MODE=released detect
  [ "$status" -eq 0 ]
  [ "$(release_of shutdown-orchestrator)" = '["1.1.25","shutdown-orchestrator/v1.1.25",""]' ]
}

@test "released: a release without a tag_name fails clearly" {
  use_layout spruyt-labs
  RELEASES=$(jq -c 'del(.["ts/agent-queue-worker/bull-board--tag_name"])' "$FX/releases/spruyt-labs-3183-release-both.json") MODE=released detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Release of ts/agent-queue-worker/bull-board has no valid tag_name and version"* ]]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "released: a tag that does not end with the version fails" {
  use_layout spruyt-labs
  RELEASES=$(jq -c '.["ts/agent-queue-worker/bull-board--version"] = "9.9.9"' "$FX/releases/spruyt-labs-3183-release-both.json") MODE=released detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::Release of ts/agent-queue-worker/bull-board has no valid tag_name and version"* ]]
}

@test "released: outputs that are not JSON fail" {
  use_layout spruyt-labs
  RELEASES='not json' MODE=released detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::releases must be the release-please outputs as JSON"* ]]
}

@test "released: image is refused, so a release never builds an image it did not release" {
  use_layout spruyt-labs
  IMAGE=bull-board RELEASES='{"releases_created":"false"}' MODE=released detect
  [ "$status" -eq 1 ]
  [[ "$stderr" == *"::error::image does not apply to released mode"* ]]
}

@test "action.yaml passes its inputs to detect.sh through env" {
  ACTION="${BATS_TEST_DIRNAME}/../.github/actions/detect-images/action.yaml"
  run yq -r '.runs.steps[0].run' "$ACTION"
  [ "$output" = '"$DETECT_SCRIPT"' ]
  run yq -o=json -I0 '.runs.steps[0].env' "$ACTION"
  [ "$output" = '{"MODE":"${{ inputs.mode }}","IMAGE":"${{ inputs.image }}","BASE_SHA":"${{ inputs.base-sha }}","RELEASES":"${{ inputs.releases }}","REPO_NAME":"${{ inputs.root-name }}","DETECT_SCRIPT":"${{ github.action_path }}/detect.sh"}' ]
}
