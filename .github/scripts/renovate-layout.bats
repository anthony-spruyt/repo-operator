#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  TEMPLATE="$SRC/templates/renovate.json5"
}

@test "the renovate group syncs a root renovate.json and seeds root overrides once" {
  run yq -o=json -I0 '.groups.renovate.files | with_entries(select(.key | test("renovate")))' "$SRC/groups.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = '{"renovate.json":{"template":true,"content":"@templates/renovate.json5"},"renovate-overrides.json5":{"createOnly":true,"content":"@templates/renovate-overrides.json5"}}' ]
}

@test "the template enables forks and extends the repo's own overrides last" {
  run grep -c 'forkProcessing: "enabled"' "$TEMPLATE"
  [ "$output" = "1" ]
  run grep -o '"[^"]*"' <(sed -n '/extends: \[/,/\]/p' "$TEMPLATE")
  [ "${lines[-1]}" = '"local>${xfg:repo.fullName}//renovate-overrides.json5"' ]
}

@test "no repo or other group configures Renovate files" {
  run yq -r '[.groups | to_entries[] | select(.key != "renovate") | .value.files // {} | keys[] | select(test("renovate"))] | length' "$SRC/groups.yaml"
  [ "$output" = "0" ]
  run yq -r '[.repos[].files // {} | keys[] | select(test("renovate"))] | length' "$SRC/repos.yaml"
  [ "$output" = "0" ]
}

@test "every repo uses the plain renovate group" {
  run yq -r '[.repos[] | select((.groups // []) | any_c(. == "renovate") | not) | .git] | join(" ")' "$SRC/repos.yaml"
  [ -z "$output" ]
  run yq -r '.groups | has("renovate-fork")' "$SRC/groups.yaml"
  [ "$output" = "false" ]
}
