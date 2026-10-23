#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/image-age.yaml"
  SCRIPT="$REPO_ROOT/.github/scripts/image-age.sh"
  RULES="$REPO_ROOT/.github/renovate/package-rules.json5"
  SKIPS="$REPO_ROOT/.github/renovate/image-age-skips.yaml"
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
  run yq -r '.jobs | to_entries | map(.key + ":" + ((.value.needs // "") | tostring)) | join(" ")' "$WORKFLOW"
  [ "$output" = "extract: render:extract validate:render publish:validate" ]
  run yq -r '.concurrency.group + ":" + (.concurrency["cancel-in-progress"] | tostring)' "$WORKFLOW"
  [ "$output" = "image-age:false" ]
}

@test "each job runs the matching script command" {
  run yq -r '.jobs | to_entries[] | .key + ":" + ([.value.steps[].run // "" | select(test("image-age[.]sh"))] | map(capture("image-age[.]sh\"? (?<c>[a-z]+)").c) | join(","))' "$WORKFLOW"
  [ "$output" = $'extract:extract\nrender:render\nvalidate:validate\npublish:publish' ]
}

@test "every job blocks egress and names the hosts it needs" {
  run yq -r '.jobs | to_entries[] | .key + ":" + ([.value.steps[] | select(.uses | test("^step-security/harden-runner@")) | .with["egress-policy"]] | join(","))' "$WORKFLOW"
  [ "$output" = $'extract:block\nrender:block\nvalidate:block\npublish:block' ]
  hosts() { yq -r ".jobs.$1.steps[] | select(.uses | test(\"^step-security/harden-runner@\")) | .with[\"allowed-endpoints\"]" "$WORKFLOW" | tr -s '[:space:]' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }
  run hosts extract
  [ "$output" = "*.blob.core.windows.net:443 api.github.com:443 github.com:443 objects.githubusercontent.com:443 registry.npmjs.org:443 results-receiver.actions.githubusercontent.com:443 " ]
  run hosts render
  [ "$output" = "*.blob.core.windows.net:443 *.pkg.dev:443 api.github.com:443 gcr.io:443 ghcr.io:443 github.com:443 mcr.microsoft.com:443 quay.io:443 registry.k8s.io:443 results-receiver.actions.githubusercontent.com:443 " ]
  run hosts validate
  [ "$output" = "*.blob.core.windows.net:443 objects.githubusercontent.com:443 registry.npmjs.org:443 results-receiver.actions.githubusercontent.com:443 " ]
  run hosts publish
  [ "$output" = "*.blob.core.windows.net:443 api.github.com:443 results-receiver.actions.githubusercontent.com:443 " ]
}

@test "only publish can write, only render reads packages, and validate holds no token" {
  run yq -r '.permissions | length' "$WORKFLOW"
  [ "$output" = "0" ]
  run yq -r '.jobs | to_entries[] | .key + ":" + (.value.permissions | to_entries | map(.key + "=" + .value) | sort | join(","))' "$WORKFLOW"
  [ "$output" = $'extract:contents=read\nrender:contents=read,packages=read\nvalidate:\npublish:contents=write' ]
  run grep -c 'contents: write' "$WORKFLOW"
  [ "$output" = "1" ]
  run yq -r '[.jobs.validate.steps[] | select(has("env"))] | length' "$WORKFLOW"
  [ "$output" = "0" ]
}

@test "publish waits for validate and only runs on main" {
  run yq -r '.jobs.publish.if' "$WORKFLOW"
  [ "$output" = "github.ref == 'refs/heads/main'" ]
}

@test "checkouts keep no credentials and validate and publish check nothing out" {
  run yq -r '[.jobs[].steps[] | select(.uses | test("^actions/checkout@")) | .with["persist-credentials"]] | unique | join(",")' "$WORKFLOW"
  [ "$output" = "false" ]
  run yq -r '.jobs | to_entries[] | select(.value.steps | any_c(.uses | test("^actions/checkout@"))) | .key' "$WORKFLOW"
  [ "$output" = $'extract\nrender' ]
}

@test "npx runs only in the extract and validate commands" {
  run grep -c 'npx' "$WORKFLOW"
  [ "$output" = "0" ]
  run awk '/^[a-z_]+\(\) \{/ { fn = $1 } /(^|[^a-z])npx / && !/^[[:space:]]*#/ { print fn }' "$SCRIPT"
  [ "$output" = $'extract_repo()\ncmd_validate()' ]
}

@test "the Renovate version is pinned once with a renovate annotation" {
  run grep -c 'RENOVATE_VERSION=' "$SCRIPT"
  [ "$output" = "1" ]
  run grep -B1 '^RENOVATE_VERSION="' "$SCRIPT"
  [ "${lines[0]}" = "# renovate: depName=renovate datasource=npm" ]
  [[ "${lines[1]}" =~ ^RENOVATE_VERSION=\"[0-9]+\.[0-9]+\.[0-9]+\"$ ]]
}

@test "the skips file maps images to lists of tags" {
  run yq -o=json -I0 -r 'to_entries | map(.key + ":" + (.value | map(tostring) | join(","))) | join(" ")' "$SKIPS"
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/victoriametrics/mcp-victoriametrics:v1.120.1,1.120.1" ]
  run yq -r '[to_entries[] | select((.value | tag) != "!!seq")] | length' "$SKIPS"
  [ "$output" = "0" ]
}

@test "the registry moves are docker-only replacements, one old name each" {
  run json5 "$RULES" '[.packageRules[] | select(has("replacementName")) | select((.matchDatasources | join(",")) == "docker" and (.matchPackageNames | length) == 1) | .matchPackageNames[0] + ">" + .replacementName] | join(" ")'
  [ "$output" = "ghcr.io/static-web-server/static-web-server>joseluisq/static-web-server ghcr.io/astral-sh/uv>astral/uv ghcr.io/druggeri/nut_exporter>druggeri/nut_exporter ghcr.io/felddy/foundryvtt>felddy/foundryvtt ghcr.io/unpoller/unpoller>golift/unifi-poller public.ecr.aws/docker/library/eclipse-mosquitto>eclipse-mosquitto" ]
  run json5 "$RULES" '[.packageRules[] | select(has("replacementName"))] | length'
  [ "$output" = "6" ]
}

@test "the move rules come after the blanket image rule that enables updates" {
  run json5 "$RULES" '[.packageRules | to_entries[] | select(.value.enabled == true and (.value.matchDatasources | join(",")) == "docker,oci") | .key] | .[0]'
  blanket=$output
  run json5 "$RULES" '[.packageRules | to_entries[] | select(.value | has("replacementName")) | .key] | .[0]'
  [ "$blanket" -lt "$output" ]
}

@test "the image title shows the short digest for digest updates" {
  run json5 "$RULES" '.packageRules[] | select(.commitMessageTopic == "container image {{depName}}" and .enabled == true) | .commitMessageExtra'
  [ "$output" = 'to {{#if isDigest}}{{{newDigestShort}}}{{else}}{{#if isSingleVersion}}v{{{newVersion}}}{{else}}{{{newValue}}}{{/if}}{{/if}}' ]
}
