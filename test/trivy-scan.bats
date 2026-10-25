#!/usr/bin/env bats
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  ACTION="${BATS_TEST_DIRNAME}/../.github/actions/trivy-scan/action.yaml"
  TRIVY_STEPS='.runs.steps[] | select((.uses // "") | test("^aquasecurity/trivy-action@"))'
}

@test "both SARIF scan steps limit the report to the configured severities" {
  run yq -o=json -I0 "[$TRIVY_STEPS | [.name, .with[\"limit-severities-for-sarif\"]]]" "$ACTION"
  [ "$output" = '[["Trivy scan (SARIF with ignores)","true"],["Trivy scan (SARIF)","true"]]' ]
}

@test "the SARIF scan steps take their severity from the action input" {
  run yq -o=json -I0 "[$TRIVY_STEPS | [.with.format, .with.severity]]" "$ACTION"
  [ "$output" = '[["sarif","${{ inputs.severity }}"],["sarif","${{ inputs.severity }}"]]' ]
}
