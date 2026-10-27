#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  RULES="$REPO_ROOT/.github/renovate/package-rules.json5"
  PINS='(.matchPackageNames // []) | contains(["anthony-spruyt/repo-operator"])'
}

# yq reads json5 as YAML flow style once the full-line comments are gone
json5() {
  sed '/^[[:space:]]*\/\//d' "$1" | yq -p yaml -o json -I0 -r "$2"
}

pin_rules() {
  json5 "$RULES" "[.packageRules[] | select($PINS)] | $1"
}

@test "the last rule for the shared CI pins is limited to repo-operator and has its own schedule, so its self-bump cannot loop on the other repos' daily one" {
  scope=$(pin_rules '.[-1].matchRepositories // [] | join(",")')
  last=$(pin_rules '.[-1].schedule // [] | join(",")')
  group=$(pin_rules 'map(select(has("matchRepositories") | not)) | .[0].schedule // [] | join(",")')
  [ "$scope" = "anthony-spruyt/repo-operator" ]
  [ -n "$group" ]
  [ -n "$last" ]
  [ "$last" != "$group" ]
}
