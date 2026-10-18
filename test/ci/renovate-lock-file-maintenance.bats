#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  PRESETS="$REPO_ROOT/.github/renovate"
}

# yq reads json5 as YAML flow style once the full-line comments are gone
json5() {
  sed '/^[[:space:]]*\/\//d' "$1" | yq -p yaml -o json -I0 "$2"
}

@test "npm lock file maintenance is on with the 7-day wait and no timestamp requirement" {
  run json5 "$PRESETS/managers.json5" '.npm.lockFileMaintenance'
  [ "$output" = '{"enabled":true,"minimumReleaseAge":"7 days","minimumReleaseAgeBehaviour":"timestamp-optional"}' ]
}

@test "no preset turns on lock file maintenance for any other manager" {
  for preset in "$PRESETS"/*.json5 "$PRESETS"/custom-managers/*.json5; do
    run json5 "$preset" '[.lockFileMaintenance, ([.packageRules[]? | select((.matchUpdateTypes // []) | contains(["lockFileMaintenance"]))] | length)]'
    [ "$output" = '[null,0]' ]
  done
}

@test "security fixes wait the same 7 days as every other update" {
  run json5 "$PRESETS/base.json5" '.vulnerabilityAlerts.minimumReleaseAge'
  [ "$output" = '"7 days"' ]
}
