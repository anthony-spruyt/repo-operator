#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  # lychee checks links on arbitrary hosts
  AUDIT_ALLOWED=(
    .github/workflows/_lint.yaml:lychee
  )
}

# harden_steps <root> <file>... - prints file:job<TAB>policy<TAB>endpoint count for each harden-runner step
harden_steps() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null) | .key as $job | .value.steps[] | select((.uses // "") | test("^\"?step-security/harden-runner@")) | [$job, (.with["egress-policy"] // ""), ((.with["allowed-endpoints"] // "") | split(" ") | map(select(. != "")) | length)] | @tsv' "$root/$file" | awk -v f="$file:" 'NF { print f $0 }'
  done
}

# not_blocking <root> <file>... - prints file:job for each harden-runner step that does not block egress or allows nothing
not_blocking() {
  harden_steps "$@" | awk -F'\t' '$2 != "block" || $3 == 0 { print $1 }'
}

workflows() {
  (cd "$1" && find .github/workflows src/templates/.github/workflows -maxdepth 1 -name '*.y*ml' | sort)
}

@test "not_blocking catches audit, a missing policy and an empty allowlist" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/w.yaml" <<'YAML'
jobs:
  good:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
        with:
          egress-policy: block
          allowed-endpoints: >-
            api.github.com:443
            github.com:443
  audit:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
        with:
          egress-policy: audit
  missing:
    steps:
      - uses: "step-security/harden-runner@0123456789abcdef0123456789abcdef01234567"
  empty:
    steps:
      - uses: step-security/harden-runner@0123456789abcdef0123456789abcdef01234567
        with:
          egress-policy: block
  call:
    uses: $/.github/workflows/x.yaml
YAML
  run not_blocking "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = $'.github/workflows/w.yaml:audit\n.github/workflows/w.yaml:missing\n.github/workflows/w.yaml:empty' ]
}

@test "every harden-runner step blocks egress to an allowlist, except the listed audit jobs" {
  mapfile -t files < <(workflows "$REPO_ROOT")
  run not_blocking "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  local job allowed unexpected=""
  while IFS= read -r job; do
    [ -n "$job" ] || continue
    for allowed in "${AUDIT_ALLOWED[@]}"; do
      [ "$job" != "$allowed" ] || continue 2
    done
    unexpected+="$job"$'\n'
  done <<<"$output"
  [ -z "$unexpected" ] || {
    echo "not blocking: $unexpected"
    return 1
  }
}

@test "Lint Canary skips lychee, which the blocked egress would fail" {
  run yq -r '.jobs.lint.steps[] | select(.name == "Run MegaLinter") | .env | .DISABLE_LINTERS + " " + .ENABLE_DISABLE_LINTERS_PRIORITY' "$REPO_ROOT/.github/workflows/lint-canary.yaml"
  [ "$output" = "SPELL_LYCHEE DISABLE" ]
}
