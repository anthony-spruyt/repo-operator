#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SCRIPT="$BATS_TEST_TMPDIR/check-job-results.sh"
  yq -r '.jobs.summary.steps[] | select(.name == "Check job results") | .run' \
    "$REPO_ROOT/.github/workflows/_summary.yaml" >"$SCRIPT"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mimics gh api paging: one page without --paginate, --jq per page, --slurp wraps pages in an array.
set -euo pipefail
echo "gh $*" >>"$FAKE_CALLS"
[[ -z "${FAKE_GH_FAIL:-}" ]] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
paginate=false slurp=false jq_expr=""
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
  --paginate) paginate=true ;;
  --slurp) slurp=true ;;
  --jq | -q)
    jq_expr="$2"
    shift
    ;;
  esac
  shift
done
read -r -a pages <<<"$FAKE_GH_PAGES"
[[ "$paginate" == true ]] || pages=("${pages[0]}")
if [[ "$slurp" == true ]]; then
  [[ -z "$jq_expr" ]] || { echo "the --slurp option is not supported with --jq or --template" >&2; exit 1; }
  jq -s . "${pages[@]}"
elif [[ -n "$jq_expr" ]]; then
  for page in "${pages[@]}"; do jq -c "$jq_expr" "$page"; done
else
  cat "${pages[@]}"
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FAKE_CALLS="$BATS_TEST_TMPDIR/calls"
  export GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export REPO="anthony-spruyt/repo-operator" RUN_ID="1"
  : >"$FAKE_CALLS"
}

# page <file> <first> <last> [failing job number]: jobs "job <n>" that succeed, except the failing one
page() {
  jq -n --argjson first "$2" --argjson last "$3" --argjson fail "${4:-0}" \
    '{total_count: 0, jobs: [range($first; $last + 1) | {name: "job \(.)", conclusion: (if . == $fail then "failure" else "success" end)}]}' >"$BATS_TEST_TMPDIR/$1"
}

two_pages() {
  page p1.json 1 30
  page p2.json 31 34 "${1:-0}"
  jq '.jobs += [{name: "repo / Guard Tests", conclusion: "success"}, {name: "summary / Check Results", conclusion: null}]' \
    "$BATS_TEST_TMPDIR/p2.json" >"$BATS_TEST_TMPDIR/p2.tmp" && mv "$BATS_TEST_TMPDIR/p2.tmp" "$BATS_TEST_TMPDIR/p2.json"
  export FAKE_GH_PAGES="$BATS_TEST_TMPDIR/p1.json $BATS_TEST_TMPDIR/p2.json"
}

@test "fails on a failed job past the first page of 30" {
  two_pages 33
  run bash -e "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"One or more jobs failed or were cancelled"* ]]
  grep -qF '| job 33 | ❌ failure |' "$GITHUB_STEP_SUMMARY"
}

@test "passes when every job on every page passes, and lists them all but itself" {
  two_pages
  run bash -e "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All jobs passed"* ]]
  [ "$(grep -c '| ✅ success |' "$GITHUB_STEP_SUMMARY")" -eq 35 ]
  grep -qF '| repo / Guard Tests | ✅ success |' "$GITHUB_STEP_SUMMARY"
  run grep -F 'summary / Check Results' "$GITHUB_STEP_SUMMARY"
  [ "$status" -eq 1 ]
}

@test "judges one job list merged from every page, not one list per page" {
  two_pages 33
  export JOBS_DUMP="$BATS_TEST_TMPDIR/jobs.json"
  { echo 'trap '\''printf "%s" "$jobs_json" >"$JOBS_DUMP"'\'' EXIT'; cat "$SCRIPT"; } >"$BATS_TEST_TMPDIR/traced.sh"
  run bash -e "$BATS_TEST_TMPDIR/traced.sh"
  [ "$status" -eq 1 ]
  run jq -c '[length, (map(type) | unique)]' "$JOBS_DUMP"
  [ "$output" = '[35,["object"]]' ]
}

@test "fails on a failed job on the first page" {
  page p1.json 1 30 2
  export FAKE_GH_PAGES="$BATS_TEST_TMPDIR/p1.json"
  run bash -e "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails when the jobs API call fails" {
  two_pages
  export FAKE_GH_FAIL=1
  run bash -e "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" != *"All jobs passed"* ]]
}
