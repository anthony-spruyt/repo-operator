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

days() {
  sed -n 's/^\([0-9]\+\) days\?$/\1/p' <<<"$1"
}

@test "the go directive only moves to the first release of a Go minor" {
  allowed="$(directive_rule | yq -p json -r '.allowedVersions')"
  [[ "$allowed" == /*/ ]]
  regex="${allowed:1:-1}"
  for v in 1.28.0 1.30.0 2.0.0; do grep -Eq "$regex" <<<"$v"; done
  for v in 1.27.2 1.28.1 1.28rc1 1.28.0-rc.1; do
    if grep -Eq "$regex" <<<"$v"; then return 1; fi
  done
}

@test "the go directive waits two weeks past the default age, for the lint image to ship that Go" {
  default="$(days "$(rules "$RULES" '.packageRules[0].minimumReleaseAge')")"
  directive="$(days "$(directive_rule | yq -p json -r '.minimumReleaseAge')")"
  [ -n "$default" ]
  [ -n "$directive" ]
  [ "$directive" -ge $((default + 14)) ]
}

@test "the Go toolchain group leaves the go directive out" {
  run rules "$GROUPS_FILE" '.packageRules[] | select(.groupName == "Go toolchain") | [(.matchDatasources // [])[], (.matchPackageNames // [])[]] | join(",")'
  [ "$output" = "docker,golang" ]
}
