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

@test "every repo but repo-operator bumps the shared CI pins daily" {
  run json5 "$RULES" "[.packageRules[] | select($PINS) | select(has(\"matchRepositories\") | not) | .schedule | join(\",\")] | join(\";\")"
  [ "$output" = "before 9am" ]
}

@test "the last rule for the shared CI pins limits the monthly schedule to repo-operator, so its self-bump cannot loop daily" {
  run json5 "$RULES" "[.packageRules[] | select($PINS)] | .[-1] | [(.matchRepositories // [] | join(\",\")), (.schedule | join(\",\"))] | join(\";\")"
  [ "$output" = "anthony-spruyt/repo-operator;before 9am on the first day of the month" ]
}
