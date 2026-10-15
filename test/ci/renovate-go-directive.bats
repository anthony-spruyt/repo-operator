#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RULES="$REPO_ROOT/.github/renovate/package-rules.json5"
  GROUPS_FILE="$REPO_ROOT/.github/renovate/groups.json5"
}

# yq reads json5 as YAML flow style once the full-line comments are gone
rules() {
  sed '/^[[:space:]]*\/\//d' "$1" | yq -p yaml -o json -I0 -r "$2"
}

directive_rule() {
  rules "$RULES" '[.packageRules[] | select(((.matchManagers // []) | join(",")) == "gomod" and ((.matchDepTypes // []) | join(",")) == "golang")] | .[0]'
}

@test "Renovate never updates the go.mod go directive" {
  rule="$(directive_rule)"
  run yq -p json -o json -I0 '[.enabled, .rangeStrategy, .allowedVersions, .minimumReleaseAge]' <<<"$rule"
  [ "$output" = '[false,null,null,null]' ]
}

@test "the go directive rule matches the golang depType only, so toolchain and module updates stay" {
  rule="$(directive_rule)"
  run yq -p json -o json -I0 '[.matchManagers, .matchDepTypes, .matchPackageNames, .matchDepNames, .matchDatasources]' <<<"$rule"
  [ "$output" = '[["gomod"],["golang"],null,null,null]' ]
}

@test "the Go toolchain group leaves the go directive out" {
  run rules "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Go toolchain") | [(.matchDatasources // [])[], (.matchPackageNames // [])[]] | join(",")'
  [ "$output" = "docker,golang" ]
}
