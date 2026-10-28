#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RULES="$REPO_ROOT/.github/renovate/package-rules.json5"
  DATASOURCES="$REPO_ROOT/.github/renovate/custom-datasources.json5"
  GROUPS_FILE="$REPO_ROOT/.github/renovate/groups.json5"
}

# yq reads json5 as YAML flow style once the full-line comments are gone
json5() {
  sed '/^[[:space:]]*\/\//d' "$1" | yq -p yaml -o json -I0 -r "$2"
}

@test "the first rule is the 7-day wait for version and digest updates, taking updates without a release date" {
  run json5 "$RULES" '.packageRules[0] | [(.matchUpdateTypes | join(",")), .minimumReleaseAge, .minimumReleaseAgeBehaviour] | join(";")'
  [ "$output" = "major,minor,patch,digest;7 days;timestamp-optional" ]
}

@test "the first rule carries nothing but the description, the update types and the wait" {
  run json5 "$RULES" '.packageRules[0] | keys | sort | join(",")'
  [ "$output" = "description,matchUpdateTypes,minimumReleaseAge,minimumReleaseAgeBehaviour" ]
}

@test "no other rule changes the release date behaviour" {
  run json5 "$RULES" '[.packageRules[] | select(has("minimumReleaseAgeBehaviour"))] | length'
  [ "$output" = "1" ]
}

@test "own packages keep skipping the wait because their rules come after the default" {
  run json5 "$RULES" '[.packageRules | to_entries[] | select(.value.minimumReleaseAge == "0 days") | .key > 0] | (length >= 3 and all)'
  [ "$output" = "true" ]
}

@test "no rule that skips the wait is limited to some update types" {
  run json5 "$RULES" '[.packageRules[] | select(.minimumReleaseAge == "0 days" and has("matchUpdateTypes"))] | length'
  [ "$output" = "0" ]
}

@test "the own container image rule skips the wait for the ghcr.io images" {
  run json5 "$RULES" '[.packageRules[] | select(.minimumReleaseAge == "0 days" and (.matchDatasources | any_c(. == "docker")) and (.matchPackageNames | any_c(test("^ghcr[.]io/anthony-spruyt/[*][*]$"))))] | length'
  [ "$output" = "1" ]
}

@test "the group rules set no release age checks" {
  run json5 "$GROUPS_FILE" '[.packageRules[] | select(has("matchJsonata") or has("prCreation") or has("internalChecksAsSuccess") or has("internalChecksFilter") or has("minimumReleaseAge") or has("minimumReleaseAgeBehaviour"))] | length'
  [ "$output" = "0" ]
}

@test "every group rule names a group" {
  run json5 "$GROUPS_FILE" '[.packageRules[] | select(has("groupName") | not)] | length'
  [ "$output" = "0" ]
}

@test "the Victoria Metrics group matches its chart images and keeps one rolling branch" {
  run json5 "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Victoria Metrics") | .matchPackageNames'
  [ "$output" = '["ghcr.io/victoriametrics/helm-charts/**"]' ]
  run json5 "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Victoria Metrics") | .group.branchTopic'
  [ "$output" = '{{{groupName}}}' ]
}

@test "the Flux group puts flux2 and the operator charts on one rolling branch" {
  run json5 "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Flux") | ((.matchPackageNames | (any_c(. == "fluxcd/*") and any_c(. == "ghcr.io/controlplaneio-fluxcd/**"))) and (.matchDatasources | any_c(. == "github-releases")))'
  [ "$output" = "true" ]
  run json5 "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Flux") | .group.branchTopic'
  [ "$output" = '{{{groupName}}}' ]
}

@test "flux2 waits longer than the 7-day image-age hold on the operator charts, so its Flux PR never goes green first" {
  run json5 "$RULES" '[.packageRules[] | select((.matchPackageNames // []) | any_c(. == "fluxcd/flux2")) | select(has("minimumReleaseAge"))] | map((.matchDatasources | any_c(. == "github-releases")) and ((.minimumReleaseAge | split(" ") | .[1]) == "days") and ((.minimumReleaseAge | split(" ") | .[0] | to_number) > 7)) | (length == 1 and all)'
  [ "$output" = "true" ]
}

@test "the App Template group matches the docker datasource its chart is read from" {
  run json5 "$GROUPS_FILE" '.packageRules[] | select(.groupName == "App Template") | .matchDatasources | any_c(. == "docker")'
  [ "$output" = "true" ]
}

@test "the Authentik group matches the authentik chart" {
  run json5 "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Authentik") | .matchPackageNames | any_c(. == "authentik")'
  [ "$output" = "true" ]
}

@test "the Coder stable datasource passes on the release date GitHub gives" {
  run json5 "$DATASOURCES" '.customDatasources["coder-stable"].transformTemplates[0]'
  [[ "$output" == *"\"releaseTimestamp\": published_at"* ]]
}

@test "the Headlamp datasource passes on the release date Artifact Hub gives in seconds" {
  run json5 "$DATASOURCES" '.customDatasources["artifacthub-headlamp"].transformTemplates[0]'
  [[ "$output" == *"\"releaseTimestamp\": \$fromMillis(\$v.ts * 1000)"* ]]
}
