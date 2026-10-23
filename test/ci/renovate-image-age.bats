#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/image-age.yaml"
  CI_REPO="$REPO_ROOT/.github/workflows/ci-repo.yaml"
  BUILD_IMAGE="$REPO_ROOT/.github/workflows/_build-image.yaml"
  SCRIPT="$REPO_ROOT/.github/scripts/image-age.sh"
  RULES="$REPO_ROOT/.github/renovate/package-rules.json5"
  SKIPS="$REPO_ROOT/.github/renovate/image-age-skips.yaml"
  REPOS="$REPO_ROOT/src/repos.yaml"
}

# yq reads json5 as YAML flow style once the full-line comments are gone
json5() {
  sed '/^[[:space:]]*\/\//d' "$1" | yq -p yaml -o json -I0 -r "$2"
}

@test "the workflow runs every six hours off the hour and on dispatch" {
  run yq -r '.on | keys | join(",")' "$WORKFLOW"
  [ "$output" = "schedule,workflow_dispatch" ]
  run yq -r '.on.schedule[0].cron' "$WORKFLOW"
  [ "$output" = "23 */6 * * *" ]
}

@test "the workflow has the four jobs in a chain and one run at a time" {
  run yq -r '.jobs | to_entries | map(.key + ":" + ((.value.needs // []) | (if type == "!!str" then [.] else . end) | join(","))) | join(" ")' "$WORKFLOW"
  [ "$output" = "extract: render:extract validate:render publish:render,validate" ]
  run yq -r '.concurrency.group + ":" + (.concurrency["cancel-in-progress"] | tostring)' "$WORKFLOW"
  [ "$output" = "image-age:false" ]
}

@test "each job runs the matching script commands" {
  run yq -r '.jobs | to_entries[] | .key + ":" + ([.value.steps[].run // "" | select(test("image-age[.]sh"))] | map(capture("image-age[.]sh (?<c>[a-z]+)").c) | join(","))' "$WORKFLOW"
  [ "$output" = $'extract:extract\nrender:render,hashes\nvalidate:validate\npublish:publish' ]
}

@test "every job runs the script from its own checkout of the commit, never from an artifact" {
  run yq -r '.jobs | to_entries[] | .key + ":" + ([.value.steps[] | select(.uses // "" | test("^actions/checkout@")) | .with.ref + "," + (.with["persist-credentials"] | tostring)] | join(" "))' "$WORKFLOW"
  [ "$output" = $'extract:${{ github.sha }},false\nrender:${{ github.sha }},false\nvalidate:${{ github.sha }},false\npublish:${{ github.sha }},false' ]
  run yq -r '[.jobs[].steps[].run // "" | split("\n")[] | select(test("image-age[.]sh")) | select(test("^[.]github/scripts/image-age[.]sh ") | not)] | length' "$WORKFLOW"
  [ "$output" = "0" ]
  run grep -E 'RUNNER_TEMP[^ ]*/image-age[.]sh|bash +"?[$]' "$WORKFLOW"
  [ "$status" -ne 0 ]
  run grep -E 'BASH_SOURCE\[0\]}" "\$out' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "the artifacts carry data only" {
  run yq -r '[.jobs[].steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .with.name] | join(",")' "$WORKFLOW"
  [ "$output" = "inventory,image-age-extract-logs,preset" ]
  run grep -cE 'chmod|[.]sh"?$' <<<"$(yq -r '.jobs[].steps[] | select(.uses // "" | test("^actions/upload-artifact@")) | .with.path' "$WORKFLOW")"
  [ "$output" = "0" ]
}

@test "the inventory artifact holds inventory.json and report.txt, not the Renovate logs" {
  run yq -r '.jobs.extract.steps[] | select(.with.name == "inventory") | .with.path' "$WORKFLOW"
  [ "$output" = $'${{ runner.temp }}/extract/inventory.json\n${{ runner.temp }}/extract/report.txt' ]
}

@test "the extract job uploads the Renovate logs of every run for three days, even after a failure" {
  step='.jobs.extract.steps[] | select(.with.name == "image-age-extract-logs")'
  run yq -r "[$step] | length" "$WORKFLOW"
  [ "$output" = "1" ]
  run yq -r "$step | .if" "$WORKFLOW"
  [ "$output" = "always()" ]
  run yq -r "$step | .with.path" "$WORKFLOW"
  [ "$output" = $'${{ runner.temp }}/extract/*.log\n${{ runner.temp }}/extract/*.err' ]
  run yq -r "$step | .with[\"retention-days\"]" "$WORKFLOW"
  [ "$output" = "3" ]
  run yq -r "$step | .uses" "$WORKFLOW"
  [ "$output" = "$(yq -r '.jobs.extract.steps[] | select(.with.name == "inventory") | .uses' "$WORKFLOW")" ]
}

@test "every job blocks egress and names the hosts it needs" {
  run yq -r '.jobs | to_entries[] | .key + ":" + ([.value.steps[] | select(.uses // "" | test("^step-security/harden-runner@")) | .with["egress-policy"]] | join(","))' "$WORKFLOW"
  [ "$output" = $'extract:block\nrender:block\nvalidate:block\npublish:block' ]
  hosts() { yq -r ".jobs.$1.steps[] | select(.uses // \"\" | test(\"^step-security/harden-runner@\")) | .with[\"allowed-endpoints\"]" "$WORKFLOW" | tr -s '[:space:]' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }
  run hosts extract
  [ "$output" = "*.blob.core.windows.net:443 api.github.com:443 github.com:443 objects.githubusercontent.com:443 registry.npmjs.org:443 results-receiver.actions.githubusercontent.com:443 " ]
  run hosts render
  [ "$output" = "*.blob.core.windows.net:443 *.pkg.dev:443 api.github.com:443 gcr.io:443 ghcr.io:443 github.com:443 mcr.microsoft.com:443 quay.io:443 registry.k8s.io:443 results-receiver.actions.githubusercontent.com:443 " ]
  run hosts validate
  [ "$output" = "*.blob.core.windows.net:443 github.com:443 objects.githubusercontent.com:443 registry.npmjs.org:443 results-receiver.actions.githubusercontent.com:443 " ]
  run hosts publish
  [ "$output" = "*.blob.core.windows.net:443 api.github.com:443 github.com:443 results-receiver.actions.githubusercontent.com:443 " ]
}

@test "no job writes with the job token, and only publish holds the App token and the environment" {
  run yq -r '.permissions | length' "$WORKFLOW"
  [ "$output" = "0" ]
  run yq -r '.jobs | to_entries[] | .key + ":" + (.value.permissions | to_entries | map(.key + "=" + .value) | sort | join(","))' "$WORKFLOW"
  [ "$output" = $'extract:contents=read\nrender:contents=read,packages=read\nvalidate:contents=read\npublish:contents=read' ]
  run grep -E '^[[:space:]]+(contents|packages|actions|id-token): write' "$WORKFLOW"
  [ "$status" -ne 0 ]
  run yq -r '.jobs | to_entries[] | select(.value.environment != null) | .key + ":" + .value.environment' "$WORKFLOW"
  [ "$output" = "publish:plan-main" ]
  run yq -r '.jobs | to_entries[] | .key + ":" + ([.value.steps[] | select(.uses // "" | test("^actions/create-github-app-token@"))] | length | tostring)' "$WORKFLOW"
  [ "$output" = $'extract:0\nrender:0\nvalidate:0\npublish:1' ]
  run grep -c 'secrets[.]' "$WORKFLOW"
  [ "$output" = "1" ]
  run grep -c 'vars[.]' "$WORKFLOW"
  [ "$output" = "1" ]
}

@test "publish mints a token for the data repo only, with contents write" {
  run yq -r '.jobs.publish.steps[] | select(.uses // "" | test("^actions/create-github-app-token@")) | .uses' "$WORKFLOW"
  [ "$output" = "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510" ]
  run yq -o=json -I0 '.jobs.publish.steps[] | select(.uses // "" | test("^actions/create-github-app-token@")) | .with' "$WORKFLOW"
  [ "$output" = '{"client-id":"${{ vars.APP_CLIENT_ID }}","private-key":"${{ secrets.APP_PRIVATE_KEY }}","owner":"anthony-spruyt","repositories":"renovate-data","permission-contents":"write"}' ]
  run yq -r '[.jobs.publish.steps[] | select(.run // "" | test("image-age[.]sh publish")) | .env.GITHUB_TOKEN] | join(",")' "$WORKFLOW"
  [[ "$output" == *steps.*.outputs.token* ]]
  run yq -r '.jobs.publish.steps[] | select(.run // "" | test("image-age[.]sh publish")) | .env | to_entries | map(.key) | sort | join(",")' "$WORKFLOW"
  [ "$output" = "DATA_SHA256,GITHUB_TOKEN,PRESET_SHA256" ]
}

@test "render hands the hashes of the two JSON files to publish through job outputs" {
  run yq -r '.jobs.render.outputs | to_entries | map(.key + "=" + .value) | join(" ")' "$WORKFLOW"
  [[ "$output" == *'preset-sha256='*'steps.'*'.outputs.preset'* ]]
  [[ "$output" == *'data-sha256='*'steps.'*'.outputs.data'* ]]
  run yq -r '.jobs.publish.steps[] | select(.run // "" | test("image-age[.]sh publish")) | .env.PRESET_SHA256 + " " + .env.DATA_SHA256' "$WORKFLOW"
  [ "$output" = '${{ needs.render.outputs.preset-sha256 }} ${{ needs.render.outputs.data-sha256 }}' ]
}

@test "publish waits for validate and only runs on main" {
  run yq -r '.jobs.publish.if' "$WORKFLOW"
  [ "$output" = "github.ref == 'refs/heads/main'" ]
}

@test "npx runs only in the extract and validate commands" {
  run grep -c 'npx' "$WORKFLOW"
  [ "$output" = "0" ]
  run awk '/^[a-z_]+\(\) \{/ { fn = $1 } /(^|[^a-z])npx / && !/^[[:space:]]*#/ { print fn }' "$SCRIPT"
  [ "$output" = $'extract_repo()\ncmd_validate()' ]
}

@test "the extract and validate jobs run Renovate on Node 24, set up before the script from the setup-node pin that _build-image uses" {
  pin=$(yq -r '[.jobs[].steps[] | select(.uses // "" | test("^actions/setup-node@")) | .uses] | .[0]' "$BUILD_IMAGE")
  [[ "$pin" =~ ^actions/setup-node@[0-9a-f]{40}$ ]]
  idx() { yq -r ".jobs.$1.steps | to_entries | map(select($2)) | .[0].key" "$WORKFLOW"; }
  for job in extract validate; do
    run yq -o=json -I0 "[.jobs.$job.steps[] | select(.uses // \"\" | test(\"^actions/setup-node@\"))] | map({\"name\": .name, \"uses\": .uses, \"with\": .with})" "$WORKFLOW"
    [ "$output" = "[{\"name\":\"Set up Node\",\"uses\":\"$pin\",\"with\":{\"node-version\":\"24\"}}]" ]
    checkout=$(idx "$job" '.value.uses // "" | test("^actions/checkout@")')
    node=$(idx "$job" '.value.uses // "" | test("^actions/setup-node@")')
    script=$(idx "$job" '.value.run // "" | test("image-age[.]sh")')
    [ "$checkout" -lt "$node" ]
    [ "$node" -lt "$script" ]
  done
  run yq -r '[.jobs | to_entries[] | select(.value.steps[] | .uses // "" | test("^actions/setup-node@")) | .key] | join(",")' "$WORKFLOW"
  [ "$output" = "extract,validate" ]
}

@test "the Renovate version is pinned once with a renovate annotation" {
  run grep -c 'RENOVATE_VERSION=' "$SCRIPT"
  [ "$output" = "1" ]
  run grep -B1 '^RENOVATE_VERSION="' "$SCRIPT"
  [ "${lines[0]}" = "# renovate: depName=renovate datasource=npm" ]
  [[ "${lines[1]}" =~ ^RENOVATE_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"$ ]]
}

@test "the guard-test job installs jsonata at an annotated pin and may reach npm for it" {
  run yq -r '.jobs.guard-test.steps[] | select(.name == "Install jsonata") | .env.JSONATA_VERSION' "$CI_REPO"
  [ "$output" = "2.2.2" ]
  run grep -B2 'JSONATA_VERSION: "' "$CI_REPO"
  [[ "$output" == *"# renovate: depName=jsonata datasource=npm"* ]]
  run yq -r '.jobs.guard-test.steps[] | select(.name == "Install jsonata") | .run' "$CI_REPO"
  [[ "$output" == *'npm install --no-save --ignore-scripts'* ]]
  [[ "$output" == *'jsonata@"$JSONATA_VERSION"'* ]]
  [[ "$output" == *'NODE_PATH='* ]]
  [[ "$output" == *'GITHUB_ENV'* ]]
  run yq -r '.jobs.guard-test.steps[] | select(.uses // "" | test("^step-security/harden-runner@")) | .with["allowed-endpoints"]' "$CI_REPO"
  [[ "$output" == *"registry.npmjs.org:443"* ]]
  run yq -r '.jobs.guard-test.steps[] | select(.name == "Install jsonata" or .name == "Run bats tests") | .name' "$CI_REPO"
  [ "$output" = $'Install jsonata\nRun bats tests' ]
}

@test "the skips file maps images to lists of tags" {
  run yq -o=json -I0 -r 'to_entries | map(.key + ":" + (.value | map(tostring) | join(","))) | join(" ")' "$SKIPS"
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/victoriametrics/mcp-victoriametrics:v1.120.1,1.120.1" ]
  run yq -r '[to_entries[] | select((.value | tag) != "!!seq")] | length' "$SKIPS"
  [ "$output" = "0" ]
}

@test "the registry moves are docker-only replacements to a docker.io name, one old name each" {
  run json5 "$RULES" '[.packageRules[] | select(has("replacementName")) | select((.matchDatasources | join(",")) == "docker" and (.matchPackageNames | length) == 1) | .matchPackageNames[0] + ">" + .replacementName] | join(" ")'
  [ "$output" = "ghcr.io/static-web-server/static-web-server>docker.io/joseluisq/static-web-server ghcr.io/astral-sh/uv>docker.io/astral/uv ghcr.io/druggeri/nut_exporter>docker.io/druggeri/nut_exporter ghcr.io/felddy/foundryvtt>docker.io/felddy/foundryvtt ghcr.io/unpoller/unpoller>docker.io/golift/unifi-poller public.ecr.aws/docker/library/eclipse-mosquitto>docker.io/eclipse-mosquitto" ]
  run json5 "$RULES" '[.packageRules[] | select(has("replacementName"))] | length'
  [ "$output" = "6" ]
}

@test "the move rules come after the blanket image rule that enables updates" {
  run json5 "$RULES" '[.packageRules | to_entries[] | select(.value.enabled == true and (.value.matchDatasources | join(",")) == "docker,oci") | .key] | .[0]'
  blanket=$output
  run json5 "$RULES" '[.packageRules | to_entries[] | select(.value | has("replacementName")) | .key] | .[0]'
  [ "$blanket" -lt "$output" ]
}

@test "the image title shows the short digest for digest updates through updateType, the only field Renovate defines for it" {
  run json5 "$RULES" '.packageRules[] | select(.commitMessageTopic == "container image {{depName}}" and .enabled == true) | .commitMessageExtra'
  [ "$output" = 'to {{#if (equals updateType "digest")}}{{{newDigestShort}}}{{else}}{{#if isSingleVersion}}v{{{newVersion}}}{{else}}{{{newValue}}}{{/if}}{{/if}}' ]
  [[ "$output" != *isDigest* ]]
}

@test "the data repo is a public repo with no collaborators, no inherited files or labels, and outside the protected-main-branch group" {
  entry='.repos[] | select(.git == "https://github.com/anthony-spruyt/renovate-data.git")'
  run yq -r "[$entry] | length" "$REPOS"
  [ "$output" = "1" ]
  run yq -o=json -I0 "$entry | .files" "$REPOS"
  [ "$output" = '{"inherit":false}' ]
  run yq -o=json -I0 "$entry | .settings.labels" "$REPOS"
  [ "$output" = '{"inherit":false}' ]
  run yq -o=json -I0 "$entry | .settings.collaborators" "$REPOS"
  [ "$output" = '{"inherit":false,"users":[]}' ]
  run yq -r "$entry | (.groups // []) | map(select(. == \"protected-main-branch\" or . == \"private-repo\")) | length" "$REPOS"
  [ "$output" = "0" ]
  run yq -o=json -I0 "$entry | .settings.repo | pick([\"hasDiscussions\", \"hasIssues\", \"hasProjects\", \"hasWiki\"])" "$REPOS"
  [ "$output" = '{"hasDiscussions":false,"hasIssues":false,"hasProjects":false,"hasWiki":false}' ]
  run yq -r "$entry | .settings.repo | has(\"visibility\") | not" "$REPOS"
  [ "$output" = "true" ]
  run yq -r "$entry | .settings.repo.description" "$REPOS"
  [ "${#lines[@]}" -eq 1 ]
  [ -n "$output" ]
}

@test "the public text describes the controls as they are, with none of the words that point at a gap" {
  words='no write access|bypass|fails? open|can reach|accepted risk|residual risk|wins? over|load last|loads last|\brisk\b'
  section=$(sed -n '/^## Image age$/,/^## /p' "$REPO_ROOT/docs/ci.md")
  readme=$(grep -F 'Image Age` workflow' "$REPO_ROOT/README.md")
  [ -n "$section" ]
  [ -n "$readme" ]
  [ "$(grep -Eic "$words" <<<"$section")" -eq 0 ]
  [ "$(grep -Eic "$words" <<<"$readme")" -eq 0 ]
  [ "$(cat "$SCRIPT" "$WORKFLOW" | grep -Eic "$words")" -eq 0 ]
  [ "$(cat "$REPO_ROOT/test/image-age.bats" "$REPO_ROOT/test/ci/renovate-image-age.bats" | grep -E '^[[:space:]]*@test ' | grep -Eic "$words")" -eq 0 ]
}
