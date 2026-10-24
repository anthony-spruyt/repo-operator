#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
}

workflows() {
  (cd "$1" && find .github/workflows src/templates/.github/workflows -maxdepth 1 -name '*.y*ml' | sort)
}

# without_timeout <root> <file>... - prints file:job for each job that runs steps and has no timeout-minutes
without_timeout() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.steps != null and .value["timeout-minutes"] == null) | .key' "$root/$file" | awk -v f="$file:" 'NF { print f $0 }'
  done
}

# calls_with_timeout <root> <file>... - prints file:job for each job that calls a reusable workflow and sets timeout-minutes
calls_with_timeout() {
  local root="$1" file
  shift
  for file in "$@"; do
    yq -r '(.jobs // {}) | to_entries[] | select(.value.uses != null and .value["timeout-minutes"] != null) | .key' "$root/$file" | awk -v f="$file:" 'NF { print f $0 }'
  done
}

@test "without_timeout and calls_with_timeout tell step jobs from reusable-workflow calls" {
  mkdir -p "$BATS_TEST_TMPDIR/.github/workflows"
  cat >"$BATS_TEST_TMPDIR/.github/workflows/w.yaml" <<'YAML'
jobs:
  timed:
    timeout-minutes: 5
    steps:
      - run: "true"
  untimed:
    steps:
      - run: "true"
  call:
    uses: ./.github/workflows/x.yaml
  timed-call:
    timeout-minutes: 5
    uses: ./.github/workflows/x.yaml
YAML
  run without_timeout "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:untimed" ]
  run calls_with_timeout "$BATS_TEST_TMPDIR" .github/workflows/w.yaml
  [ "$output" = ".github/workflows/w.yaml:timed-call" ]
}

@test "every job that runs steps sets timeout-minutes, in the shared workflows, the templates and this repo's workflows" {
  mapfile -t files < <(workflows "$REPO_ROOT")
  run without_timeout "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "no timeout-minutes: $output"
    return 1
  }
}

@test "no job that calls a reusable workflow sets timeout-minutes, which GitHub rejects there" {
  mapfile -t files < <(workflows "$REPO_ROOT")
  run calls_with_timeout "$REPO_ROOT" "${files[@]}"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || {
    echo "timeout-minutes on a call: $output"
    return 1
  }
}
