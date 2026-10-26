#!/usr/bin/env bats
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  ACTION="${BATS_TEST_DIRNAME}/../.github/actions/trivy-scan/action.yaml"
  TRIVY_STEPS='.runs.steps[] | select((.uses // "") | test("^aquasecurity/trivy-action@"))'
  MAIN_STEPS='select(.name == "Trivy scan (SARIF with ignores)" or .name == "Trivy scan (SARIF)")'
  SECRET_STEPS='select(.name == "Trivy secret scan (SARIF with ignores)" or .name == "Trivy secret scan (SARIF)")'
}

# step_script <id> - prints the run script of the step with that id
step_script() {
  yq -r ".runs.steps[] | select(.id == \"$1\") | .run" "$ACTION"
}

# split_scanners <scanners> - runs the splitter step and prints what it wrote to GITHUB_OUTPUT
split_scanners() {
  local script
  script=$(step_script scanner-split)
  SCANNERS="$1" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash -e -o pipefail -c "$script"
  cat "$BATS_TEST_TMPDIR/out"
}

@test "four Trivy scans run: the non-secret pair, then the secret pair" {
  run yq -o=json -I0 "[$TRIVY_STEPS | .name]" "$ACTION"
  [ "$output" = '["Trivy scan (SARIF with ignores)","Trivy scan (SARIF)","Trivy secret scan (SARIF with ignores)","Trivy secret scan (SARIF)"]' ]
}

@test "the non-secret scans limit the SARIF to the configured severities" {
  run yq -o=json -I0 "[$TRIVY_STEPS | $MAIN_STEPS | [.name, .with.format, .with.severity, .with[\"limit-severities-for-sarif\"], .with.output]]" "$ACTION"
  [ "$output" = '[["Trivy scan (SARIF with ignores)","sarif","${{ inputs.severity }}","true","trivy-results.sarif"],["Trivy scan (SARIF)","sarif","${{ inputs.severity }}","true","trivy-results.sarif"]]' ]
}

@test "the non-secret scans run the scanners left after secret and skip when none are left" {
  run yq -o=json -I0 "[$TRIVY_STEPS | $MAIN_STEPS | [.name, .with.scanners, .if]]" "$ACTION"
  [ "$output" = $'[["Trivy scan (SARIF with ignores)","${{ steps.scanner-split.outputs.non-secret }}","${{ (success() || failure()) && inputs.trivyignores != \'\' && steps.scanner-split.outputs.non-secret != \'\' }}"],["Trivy scan (SARIF)","${{ steps.scanner-split.outputs.non-secret }}","${{ (success() || failure()) && inputs.trivyignores == \'\' && steps.scanner-split.outputs.non-secret != \'\' }}"]]' ]
}

@test "the secret scans run only secret, with no severity filter, into their own SARIF file" {
  run yq -o=json -I0 "[$TRIVY_STEPS | $SECRET_STEPS | [.name, .with.scanners, .with.format, .with.severity, .with[\"limit-severities-for-sarif\"], .with.output]]" "$ACTION"
  [ "$output" = '[["Trivy secret scan (SARIF with ignores)","secret","sarif",null,null,"trivy-secret-results.sarif"],["Trivy secret scan (SARIF)","secret","sarif",null,null,"trivy-secret-results.sarif"]]' ]
}

@test "the secret scans run when secret is requested and keep the trivyignores split" {
  run yq -o=json -I0 "[$TRIVY_STEPS | $SECRET_STEPS | [.name, .if, .with.trivyignores]]" "$ACTION"
  [ "$output" = $'[["Trivy secret scan (SARIF with ignores)","${{ (success() || failure()) && inputs.trivyignores != \'\' && steps.scanner-split.outputs.secret == \'true\' }}","${{ inputs.trivyignores }}"],["Trivy secret scan (SARIF)","${{ (success() || failure()) && inputs.trivyignores == \'\' && steps.scanner-split.outputs.secret == \'true\' }}",null]]' ]
}

@test "the secret scans skip the non-secret SARIF report" {
  run yq -o=json -I0 "[$TRIVY_STEPS | $SECRET_STEPS | .with[\"skip-files\"]]" "$ACTION"
  [ "$output" = '["trivy-results.sarif","trivy-results.sarif"]' ]
}

@test "all four scans target the same thing" {
  run yq -o=json -I0 "[$TRIVY_STEPS | [.with[\"scan-type\"], .with[\"image-ref\"], .with[\"scan-ref\"], .with[\"exit-code\"]]] | unique" "$ACTION"
  [ "$output" = '[["${{ inputs.scan-type }}","${{ inputs.image-ref }}",".","0"]]' ]
}

@test "the scanner splitter splits secret from the other scanners" {
  run split_scanners "misconfig,secret,vuln"
  [ "$status" -eq 0 ]
  [ "$output" = $'non-secret=misconfig,vuln\nsecret=true' ]
}

@test "the scanner splitter keeps the order of the other scanners" {
  run split_scanners "vuln,secret,misconfig"
  [ "$output" = $'non-secret=vuln,misconfig\nsecret=true' ]
}

@test "the scanner splitter leaves nothing for the non-secret scans when only secret is requested" {
  run split_scanners "secret"
  [ "$output" = $'non-secret=\nsecret=true' ]
}

@test "the scanner splitter reports no secret scan when secret is not requested" {
  run split_scanners "misconfig,vuln"
  [ "$output" = $'non-secret=misconfig,vuln\nsecret=false' ]
}

@test "the scanner splitter ignores spaces and empty entries" {
  run split_scanners " misconfig , secret ,,vuln "
  [ "$output" = $'non-secret=misconfig,vuln\nsecret=true' ]
}

@test "the scanner splitter matches secret exactly" {
  run split_scanners "vuln,secrets"
  [ "$output" = $'non-secret=vuln,secrets\nsecret=false' ]
}

@test "the scanner splitter handles an empty list" {
  run split_scanners ""
  [ "$output" = $'non-secret=\nsecret=false' ]
}

@test "the SARIF check reports each file that exists and is not empty" {
  local script work="$BATS_TEST_TMPDIR/work"
  script=$(step_script sarif-check)
  mkdir -p "$work"
  echo '{}' >"$work/trivy-results.sarif"
  : >"$work/trivy-secret-results.sarif"
  : >"$BATS_TEST_TMPDIR/out"
  (cd "$work" && GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash -e -o pipefail -c "$script")
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = "exists=true" ]

  echo '{}' >"$work/trivy-secret-results.sarif"
  rm "$work/trivy-results.sarif"
  : >"$BATS_TEST_TMPDIR/out"
  (cd "$work" && GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash -e -o pipefail -c "$script")
  run cat "$BATS_TEST_TMPDIR/out"
  [ "$output" = "secret-exists=true" ]
}

@test "the SARIF check reports nothing when neither file exists" {
  local script work="$BATS_TEST_TMPDIR/work"
  script=$(step_script sarif-check)
  mkdir -p "$work"
  : >"$BATS_TEST_TMPDIR/out"
  (cd "$work" && GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" bash -e -o pipefail -c "$script")
  run cat "$BATS_TEST_TMPDIR/out"
  [ -z "$output" ]
}

@test "the image name is injected into both SARIF files" {
  local script work="$BATS_TEST_TMPDIR/work" file
  script=$(yq -r '.runs.steps[] | select(.name == "Inject image name into SARIF") | .run' "$ACTION")
  mkdir -p "$work"
  for file in trivy-results.sarif trivy-secret-results.sarif; do
    echo '{"runs":[{"results":[{"message":{"text":"found"}}]}]}' >"$work/$file"
  done
  (cd "$work" && IMAGE_NAME=app bash -e -o pipefail -c "$script")
  for file in trivy-results.sarif trivy-secret-results.sarif; do
    run jq -r '.runs[0].results[0].message.text' "$work/$file"
    [ "$output" = $'Image: app\nfound' ]
  done
  [ -z "$(find "$work" -name '*.tmp')" ]
}

@test "the image name is injected when only one SARIF file exists" {
  local script work="$BATS_TEST_TMPDIR/work"
  script=$(yq -r '.runs.steps[] | select(.name == "Inject image name into SARIF") | .run' "$ACTION")
  mkdir -p "$work"
  echo '{"runs":[{"results":[{"message":{"text":"found"}}]}]}' >"$work/trivy-secret-results.sarif"
  (cd "$work" && IMAGE_NAME=app bash -e -o pipefail -c "$script")
  run jq -r '.runs[0].results[0].message.text' "$work/trivy-secret-results.sarif"
  [ "$output" = $'Image: app\nfound' ]
  [ ! -e "$work/trivy-results.sarif" ]
}

@test "the image name injection fails the step when a SARIF file is not valid JSON" {
  local script work="$BATS_TEST_TMPDIR/work"
  script=$(yq -r '.runs.steps[] | select(.name == "Inject image name into SARIF") | .run' "$ACTION")
  mkdir -p "$work"
  echo 'not json' >"$work/trivy-results.sarif"
  echo '{"runs":[]}' >"$work/trivy-secret-results.sarif"
  run bash -c 'cd "$1" && IMAGE_NAME=app bash -e -o pipefail -c "$2"' _ "$work" "$script"
  [ "$status" -ne 0 ]
}

@test "the image name injection runs when either SARIF file exists and an image name is set" {
  run yq -r '.runs.steps[] | select(.name == "Inject image name into SARIF") | .if' "$ACTION"
  [ "$output" = "\${{ (success() || failure()) && inputs.image-name != '' && (steps.sarif-check.outputs.exists == 'true' || steps.sarif-check.outputs.secret-exists == 'true') }}" ]
}

@test "each SARIF file uploads under its own category" {
  run yq -o=json -I0 '[.runs.steps[] | select((.uses // "") | test("^github/codeql-action/upload-sarif@")) | [.id, .if, .["continue-on-error"], .with.sarif_file, .with.category]]' "$ACTION"
  [ "$output" = $'[["sarif-upload","${{ (success() || failure()) && steps.sarif-check.outputs.exists == \'true\' }}",true,"trivy-results.sarif","${{ inputs.category }}"],["sarif-secret-upload","${{ (success() || failure()) && steps.sarif-check.outputs.secret-exists == \'true\' }}",true,"trivy-secret-results.sarif","${{ inputs.category }}-secret"]]' ]
}

@test "the upload warning fires when either upload fails" {
  run yq -r '.runs.steps[] | select(.name == "Warn on SARIF upload failure") | .if' "$ACTION"
  [ "$output" = "\${{ (success() || failure()) && (steps.sarif-upload.outcome == 'failure' || steps.sarif-secret-upload.outcome == 'failure') }}" ]
}

@test "every inputs reference in the action is a declared input" {
  local declared referenced
  declared=$(yq -r '.inputs | keys | .[]' "$ACTION" | sort)
  referenced=$(grep -o 'inputs[.][a-z-]*' "$ACTION" | sed 's/^inputs[.]//' | sort -u)
  [ -z "$(comm -13 <(echo "$declared") <(echo "$referenced"))" ]
}

@test "the action has no trivy-config input and no step reads one" {
  run yq -r '.inputs | has("trivy-config")' "$ACTION"
  [ "$output" = "false" ]
  run grep -c 'inputs[.]trivy-config' "$ACTION"
  [ "$output" = "0" ]
}
