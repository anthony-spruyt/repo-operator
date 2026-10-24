#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ACTION="$REPO_ROOT/.github/actions/harden-runner/action.yaml"
  OWN_RE='^[$]/[.]github/actions/harden-runner$'
  SYNCED_RE='^anthony-spruyt/repo-operator/[.]github/actions/harden-runner@[0-9a-f]{40}$'
  DIRECT_ALLOWED=(
    # Link checks reach arbitrary hosts
    .github/workflows/_lint.yaml:lychee:audit
    # Audit mode sends telemetry whatever disable-telemetry says, so a job with telemetry off stays on block
    .github/workflows/ci.yaml:xfg-apply:block
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

# unswitched <root> <regex> <file>... - prints file:job for each job with steps whose first step's uses does not match the regex
unswitched() {
  local root="$1" file
  export RE="$2"
  shift 2
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | select(((.value.steps[0].uses // "") | test(strenv(RE))) | not) | .key' "$root/$file" | sed "s|^|$file:|"
  done
}

# telemetry_off <root> <file>... - prints file:job for each step that turns telemetry off without being a direct harden-runner step on block
telemetry_off() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | select([.value.steps[] | select(((.with["disable-telemetry"] // "") | tostring | downcase) == "true") | select((((.uses // "") | test("^step-security/harden-runner@")) and ((.with["egress-policy"] // "") == "block")) | not)] | length > 0) | .key' "$root/$file" | sed "s|^|$file:|"
  done
}

# composite_calls <root> <regex> <file>... - prints file:job, step index, input names and allowlist length (tab separated) for each step whose uses matches the regex
composite_calls() {
  local root="$1" re="$2" file
  shift 2
  for file in "$@"; do
    yq -o=json '.' "$root/$file" | jq -r --arg re "$re" --arg f "$file" '(.jobs // {}) | to_entries[] | select(.value.steps != null) | .key as $job | .value.steps | to_entries[] | select((.value.uses // "") | test($re)) | [$f + ":" + $job, (.key | tostring), ((.value.with // {}) | keys | join(",")), (((.value.with["allowed-endpoints"] // "") | split(" ") | map(select(. != "")) | length) | tostring)] | @tsv'
  done
}

workflows() {
  (cd "$1" && find .github/workflows -maxdepth 1 -name '*.y*ml' | sort)
}

template_workflows() {
  (cd "$1" && find src/templates/.github/workflows -maxdepth 1 -name '*.y*ml' | sort)
}

# synced <root> - prints the workflows under .github/workflows that xfg writes into repo-operator from src/templates
synced() {
  jq -r '.["anthony-spruyt/repo-operator"][] | select(startswith(".github/workflows/"))' "$1/.github/xfg-managed.json"
}

# owned <root> - prints the workflows under .github/workflows that repo-operator owns, leaving the synced copies out
owned() {
  workflows "$1" | grep -vxFf <(synced "$1")
}

# synced_sources <root> - prints the src/templates source of each synced workflow, which stays right before and after xfg rewrites the copy
synced_sources() {
  synced "$1" | sed 's|^|src/templates/|'
}

# all_workflows <root> - prints the owned workflows, then every template
all_workflows() {
  owned "$1"
  template_workflows "$1"
}

# allowed_jobs - prints file:job for each listed direct step
allowed_jobs() {
  printf '%s\n' "${DIRECT_ALLOWED[@]%:*}"
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
  run unswitched "$BATS_TEST_TMPDIR" "$OWN_RE" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:late\n.github/workflows/w.yaml:direct\n.github/workflows/w.yaml:bare' ]
  run composite_calls "$BATS_TEST_TMPDIR" "$OWN_RE" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:good\t0\tallowed-endpoints,disable-sudo-and-containers\t2\n.github/workflows/w.yaml:late\t1\tallowed-endpoints\t1\n.github/workflows/w.yaml:stray\t0\tegress-policy\t0' ]
}

@test "the synced pattern takes only a full-SHA pin of this repo's composite, and flags a short SHA, a tag, another owner and the local form" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/s.yaml" <<'YAML'
jobs:
  pinned:
    steps:
      - uses: "anthony-spruyt/repo-operator/.github/actions/harden-runner@0123456789abcdef0123456789abcdef01234567" # main
        with:
          allowed-endpoints: github.com:443
  short:
    steps:
      - uses: anthony-spruyt/repo-operator/.github/actions/harden-runner@0123456
  tag:
    steps:
      - uses: anthony-spruyt/repo-operator/.github/actions/harden-runner@main
  foreign:
    steps:
      - uses: someone/else/.github/actions/harden-runner@0123456789abcdef0123456789abcdef01234567
  local:
    steps:
      - uses: $/.github/actions/harden-runner
  late:
    steps:
      - run: "true"
      - uses: anthony-spruyt/repo-operator/.github/actions/harden-runner@0123456789abcdef0123456789abcdef01234567
YAML
  run unswitched "$BATS_TEST_TMPDIR" "$SYNCED_RE" .github/workflows/s.yaml
  [ "$output" = $'.github/workflows/s.yaml:short\n.github/workflows/s.yaml:tag\n.github/workflows/s.yaml:foreign\n.github/workflows/s.yaml:local\n.github/workflows/s.yaml:late' ]
  run composite_calls "$BATS_TEST_TMPDIR" "$SYNCED_RE" .github/workflows/s.yaml
  [ "$output" = $'.github/workflows/s.yaml:pinned\t0\tallowed-endpoints\t1\n.github/workflows/s.yaml:late\t1\t\t0' ]
}

@test "the ownership helpers drop the synced workflows from the owned list and map each to its template" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  touch "$BATS_TEST_TMPDIR/.github/workflows/own.yaml" "$BATS_TEST_TMPDIR/.github/workflows/copy.yaml"
  echo '{"anthony-spruyt/repo-operator":["lint.sh",".github/workflows/copy.yaml"],"anthony-spruyt/other":[".github/workflows/own.yaml"]}' >"$BATS_TEST_TMPDIR/.github/xfg-managed.json"
  run owned "$BATS_TEST_TMPDIR"
  [ "$output" = ".github/workflows/own.yaml" ]
  run synced_sources "$BATS_TEST_TMPDIR"
  [ "$output" = "src/templates/.github/workflows/copy.yaml" ]
}

@test "the telemetry helper flags telemetry off on a composite call, an audit step and a quoted value, not on a direct block step" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/t.yaml" <<'YAML'
jobs:
  composite:
    steps:
      - uses: $/.github/actions/harden-runner
        with:
          disable-telemetry: true
  audit:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
        with:
          egress-policy: audit
          disable-telemetry: true
  quoted:
    steps:
      - uses: $/.github/actions/harden-runner
        with:
          disable-telemetry: "true"
  block:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
        with:
          egress-policy: block
          disable-telemetry: true
  off:
    steps:
      - uses: $/.github/actions/harden-runner
        with:
          disable-telemetry: false
  call:
    uses: $/.github/workflows/x.yaml
YAML
  run telemetry_off "$BATS_TEST_TMPDIR" .github/workflows/t.yaml
  [ "$output" = $'.github/workflows/t.yaml:composite\n.github/workflows/t.yaml:audit\n.github/workflows/t.yaml:quoted' ]
}

@test "the only direct harden-runner steps are the listed ones" {
  mapfile -t files < <(all_workflows "$REPO_ROOT")
  run direct_steps "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$(printf '%s\n' "${DIRECT_ALLOWED[@]}" | sort)" ]
}

@test "every other job with steps starts with the composite" {
  mapfile -t files < <(owned "$REPO_ROOT")
  run unswitched "$REPO_ROOT" "$OWN_RE" "${files[@]}"
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$(allowed_jobs | sort)" ]
}

@test "every synced workflow, read at its template, starts each job with the composite pinned by a full SHA of this repo" {
  mapfile -t files < <(synced_sources "$REPO_ROOT")
  [ "${#files[@]}" -gt 0 ]
  run unswitched "$REPO_ROOT" "$SYNCED_RE" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run awk '/[.]github\/actions\/harden-runner@/ && !/^ +uses: "anthony-spruyt\/repo-operator\/[.]github\/actions\/harden-runner@[0-9a-f]{40}" # main$/ { print FILENAME ": " $0 }' "${files[@]/#/$REPO_ROOT/}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every composite call is the first step, passes only the composite's inputs and names an allowlist" {
  mapfile -t own_files < <(owned "$REPO_ROOT")
  mapfile -t synced_files < <(synced_sources "$REPO_ROOT")
  run composite_calls "$REPO_ROOT" "$OWN_RE" "${own_files[@]}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  local calls="$output" inputs
  run composite_calls "$REPO_ROOT" "$SYNCED_RE" "${synced_files[@]}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  calls+=$'\n'"$output"
  inputs=$(yq -r '.inputs | keys | join(",")' "$ACTION")
  run awk -F'\t' '$2 != 0 { print $1 ": not the first step" }' <<<"$calls"
  [ -z "$output" ]
  run awk -F'\t' -v inputs="$inputs" 'BEGIN { n = split(inputs, a, ","); for (i = 1; i <= n; i++) ok[a[i]] = 1 } { m = split($3, k, ","); for (i = 1; i <= m; i++) if (!(k[i] in ok)) print $1 ": unknown input " k[i] }' <<<"$calls"
  [ -z "$output" ]
  run awk -F'\t' '$4 == 0 { print $1 ": no allowlist" }' <<<"$calls"
  [ -z "$output" ]
}

@test "xfg-apply keeps its direct block step with telemetry off" {
  run yq -o=json -I0 '[.jobs["xfg-apply"].steps[] | select((.uses // "") | test("^step-security/harden-runner@")) | .with | [.["egress-policy"], .["disable-telemetry"]]]' "$REPO_ROOT/.github/workflows/ci.yaml"
  [ "$output" = '[["block",true]]' ]
}

@test "lychee always runs in audit and keeps its link checks open" {
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

@test "the composite passes through allowed-endpoints and disable-sudo-and-containers with harden-runner's defaults, and takes no mode" {
  run yq -o=json -I0 '[.inputs | to_entries[] | [.key, .value.default]]' "$ACTION"
  [ "$output" = '[["allowed-endpoints",""],["disable-sudo-and-containers","false"]]' ]
  run yq -o=json -I0 '.runs.steps[0].with | del(.["egress-policy"])' "$ACTION"
  [ "$output" = '{"allowed-endpoints":"${{ inputs.allowed-endpoints }}","disable-sudo-and-containers":"${{ inputs.disable-sudo-and-containers }}"}' ]
}

@test "the composite has no disable-telemetry input, because audit mode sends telemetry whatever it says" {
  run yq -r '.inputs | has("disable-telemetry")' "$ACTION"
  [ "$output" = "false" ]
  run grep -c 'disable-telemetry' "$ACTION"
  [ "$output" = "0" ]
}

@test "a job that turns telemetry off keeps a direct harden-runner step on block" {
  mapfile -t files < <(all_workflows "$REPO_ROOT")
  run telemetry_off "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "every direct harden-runner step uses the composite's pin" {
  local pin
  pin=$(yq -r '.runs.steps[0].uses' "$ACTION")
  mapfile -t files < <(printf '%s\n' "${DIRECT_ALLOWED[@]%%:*}" | sort -u)
  run yq -N -r '(.jobs // {})[] | select(.steps != null) | .steps[] | select((.uses // "") | test("^step-security/harden-runner@")) | .uses' "${files[@]/#/$REPO_ROOT/}"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
  run grep -vxF "$pin" <<<"$output"
  [ "$status" -eq 1 ]
}

@test "Lint Canary skips lychee, which egress under block would fail" {
  run yq -r '.jobs.lint.steps[] | select(.name == "Run MegaLinter") | .env | .DISABLE_LINTERS + " " + .ENABLE_DISABLE_LINTERS_PRIORITY' "$REPO_ROOT/.github/workflows/lint-canary.yaml"
  [ "$output" = "SPELL_LYCHEE DISABLE" ]
}
