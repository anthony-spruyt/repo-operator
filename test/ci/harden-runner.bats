#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="$REPO_ROOT/.github/actions/harden-runner/action.yaml"
  export COMPOSITE='$/.github/actions/harden-runner'
  # lychee checks links on arbitrary hosts; pr-title.yaml is synced from src/templates, which switches to the composite in a follow-up
  DIRECT_ALLOWED=(
    .github/workflows/_lint.yaml:lychee:audit
    .github/workflows/pr-title.yaml:check:block
  )
}

# direct_steps <root> <file>... - prints file:job:policy for each harden-runner step called without the composite
direct_steps() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | .key as $job | .value.steps[] | select((.uses // "") | test("^step-security/harden-runner@")) | $job + ":" + (.with["egress-policy"] // "")' "$root/$file" | sed "s|^|$file:|"
  done
}

# unswitched <root> <file>... - prints file:job for each job with steps whose first step is not the composite
unswitched() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | select((.value.steps[0].uses // "") != strenv(COMPOSITE)) | .key' "$root/$file" | sed "s|^|$file:|"
  done
}

# composite_calls <root> <file>... - prints file:job, step index, input names and allowlist length (tab separated) for each composite call
composite_calls() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -o=json '.' "$root/$file" | jq -r --arg c "$COMPOSITE" --arg f "$file" '(.jobs // {}) | to_entries[] | select(.value.steps != null) | .key as $job | .value.steps | to_entries[] | select(.value.uses == $c) | [$f + ":" + $job, (.key | tostring), ((.value.with // {}) | keys | join(",")), (((.value.with["allowed-endpoints"] // "") | split(" ") | map(select(. != "")) | length) | tostring)] | @tsv'
  done
}

workflows() {
  (cd "$1" && find .github/workflows -maxdepth 1 -name '*.y*ml' | sort)
}

allowed_jobs() {
  local entry
  for entry in "${DIRECT_ALLOWED[@]}"; do
    echo "${entry%:*}"
  done
}

@test "the helpers find a direct step, a late composite call, a stray input and a missing allowlist" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/w.yaml" <<'YAML'
jobs:
  good:
    steps:
      - uses: $/.github/actions/harden-runner
        with:
          disable-sudo-and-containers: true
          allowed-endpoints: >-
            api.github.com:443
            github.com:443
  late:
    steps:
      - uses: actions/checkout@0123456789abcdef0123456789abcdef01234567
      - uses: $/.github/actions/harden-runner
        with:
          allowed-endpoints: github.com:443
  stray:
    steps:
      - uses: $/.github/actions/harden-runner
        with:
          egress-policy: block
  direct:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
        with:
          egress-policy: audit
  bare:
    steps:
      - uses: "step-security/harden-runner@0123456789abcdef0123456789abcdef01234567"
  call:
    uses: $/.github/workflows/x.yaml
YAML
  run direct_steps "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:direct:audit\n.github/workflows/w.yaml:bare:' ]
  run unswitched "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:late\n.github/workflows/w.yaml:direct\n.github/workflows/w.yaml:bare' ]
  run composite_calls "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:good\t0\tallowed-endpoints,disable-sudo-and-containers\t2\n.github/workflows/w.yaml:late\t1\tallowed-endpoints\t1\n.github/workflows/w.yaml:stray\t0\tegress-policy\t0' ]
}

@test "the only direct harden-runner steps are the listed ones" {
  mapfile -t files < <(workflows "$REPO_ROOT")
  run direct_steps "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$(printf '%s\n' "${DIRECT_ALLOWED[@]}" | sort)" ]
}

@test "every other job with steps starts with the composite" {
  mapfile -t files < <(workflows "$REPO_ROOT")
  run unswitched "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$(allowed_jobs | sort)" ]
}

@test "every composite call is the first step, passes only the composite's inputs and names an allowlist" {
  mapfile -t files < <(workflows "$REPO_ROOT")
  run composite_calls "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local calls="$output" inputs
  inputs=$(yq -r '.inputs | keys | join(",")' "$ACTION")
  run awk -F'\t' '$2 != 0 { print $1 ": not the first step" }' <<<"$calls"
  [ -z "$output" ]
  run awk -F'\t' -v inputs="$inputs" 'BEGIN { n = split(inputs, a, ","); for (i = 1; i <= n; i++) ok[a[i]] = 1 } { m = split($3, k, ","); for (i = 1; i <= m; i++) if (!(k[i] in ok)) print $1 ": unknown input " k[i] }' <<<"$calls"
  [ -z "$output" ]
  run awk -F'\t' '$4 == 0 { print $1 ": no allowlist" }' <<<"$calls"
  [ -z "$output" ]
}

@test "the lychee job is the only audit job and keeps its link checks open" {
  run yq -o=json -I0 '.jobs.lychee.steps[0] | [.uses, .with]' "$REPO_ROOT/.github/workflows/_lint.yaml"
  [[ "$output" =~ ^\[\"step-security/harden-runner@[0-9a-f]{40}\",\{\"egress-policy\":\"audit\"\}\]$ ]]
}

@test "the composite runs one harden-runner step, pinned by full SHA with its tag, with a policy of audit or block" {
  run yq -o=json -I0 '[.runs.using, (.runs.steps | length), .runs.steps[0].with["egress-policy"]]' "$ACTION"
  [[ "$output" =~ ^\[\"composite\",1,\"(audit|block)\"\]$ ]]
  run yq -r '.runs.steps[0].uses' "$ACTION"
  [[ "$output" =~ ^step-security/harden-runner@[0-9a-f]{40}$ ]]
  run grep -cE '^ +uses: step-security/harden-runner@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$' "$ACTION"
  [ "$output" = "1" ]
}

@test "the composite passes through allowed-endpoints and the two disable flags with harden-runner's defaults, and takes no mode" {
  run yq -o=json -I0 '[.inputs | to_entries[] | [.key, .value.default]]' "$ACTION"
  [ "$output" = '[["allowed-endpoints",""],["disable-sudo-and-containers","false"],["disable-telemetry","false"]]' ]
  run yq -o=json -I0 '.runs.steps[0].with | del(.["egress-policy"])' "$ACTION"
  [ "$output" = '{"allowed-endpoints":"${{ inputs.allowed-endpoints }}","disable-sudo-and-containers":"${{ inputs.disable-sudo-and-containers }}","disable-telemetry":"${{ inputs.disable-telemetry }}"}' ]
}

@test "every direct harden-runner step uses the composite's pin" {
  local pin
  pin=$(yq -r '.runs.steps[0].uses' "$ACTION")
  run yq -N -r '(.jobs // {})[] | .steps[] | select((.uses // "") | test("^step-security/harden-runner@")) | .uses' "$REPO_ROOT/.github/workflows/_lint.yaml" "$REPO_ROOT/.github/workflows/pr-title.yaml" "$REPO_ROOT/src/templates/.github/workflows/pr-title.yaml"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run grep -vxF "$pin" <<<"$output"
  [ "$status" -eq 1 ]
}

@test "Lint Canary skips lychee, which the blocked egress would fail" {
  run yq -r '.jobs.lint.steps[] | select(.name == "Run MegaLinter") | .env | .DISABLE_LINTERS + " " + .ENABLE_DISABLE_LINTERS_PRIORITY' "$REPO_ROOT/.github/workflows/lint-canary.yaml"
  [ "$output" = "SPELL_LYCHEE DISABLE" ]
}
