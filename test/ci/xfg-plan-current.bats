#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  command -v node >/dev/null || skip "node is not installed"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CI="$REPO_ROOT/.github/workflows/ci.yaml"
}

# gh_eval <expression> <contexts-json> - prints the expression's value once per context in the array; a context or function xfg-plan does not read throws
gh_eval() {
  node -e '
    const [expr, contexts] = process.argv.slice(1);
    const format = (f, ...a) => f.replace(/\{(\d+)\}/g, (_, i) => a[i]);
    const evaluate = (e, github, needs) => new Function("github", "needs", "format",
      `"use strict"; return (${e.replace(/always\(\)/g, "true").replace(/needs\.xfg-current\b/g, "needs[\"xfg-current\"]")});`)(github, needs, format);
    for (const { github, needs } of JSON.parse(contexts)) {
      console.log(expr.includes("${{")
        ? expr.replace(/\$\{\{([\s\S]*?)\}\}/g, (_, e) => String(evaluate(e, github, needs)))
        : String(evaluate(expr, github, needs)));
    }
  ' "$1" "$2"
}

# matrix <current> - every event, lint result, ref and actor, with the current check's output set to <current>
matrix() {
  jq -nc --arg current "$1" '[
    ("push", "workflow_dispatch", "pull_request") as $e | ("success", "failure", "skipped", "cancelled") as $l |
    ("refs/heads/main", "refs/heads/dev") as $r | ("someone", "repo-operator[bot]") as $a |
    {github: {event_name: $e, ref: $r, actor: $a, sha: "abc"}, needs: {lint: {result: $l}, "xfg-current": {outputs: {current: $current}}}}
  ]'
}

@test "xfg-plan waits for the current check, which waits for lint" {
  run yq -r '.jobs["xfg-plan"].needs | any_c(. == "xfg-current")' "$CI"
  [ "$output" = "true" ]
  run yq -r '.jobs["xfg-current"].needs | any_c(. == "lint")' "$CI"
  [ "$output" = "true" ]
}

@test "the current check runs whenever xfg-plan would, so a skipped check never hides a plannable run" {
  run gh_eval "$(yq -r '.jobs["xfg-current"].if' "$CI")" "$(matrix true)"
  [ "$status" -eq 0 ]
  gate="$output"
  run gh_eval "$(yq -r '.jobs["xfg-plan"].if' "$CI")" "$(matrix true)"
  [ "$status" -eq 0 ]
  [ "$output" = "$gate" ]
  [[ "$output" == *true* ]]
}

@test "xfg-plan skips a run the check did not mark current, on a push and on a dispatch" {
  for current in false ''; do
    run gh_eval "$(yq -r '.jobs["xfg-plan"].if' "$CI")" "$(matrix "$current")"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" != *true* ]]
  done
}

@test "a run that is not current gets a concurrency group of its own, so it never replaces the current run's Plan" {
  contexts=$(jq -nc '[["aaa", "true"], ["bbb", "true"], ["aaa", "false"], ["aaa", ""]] | map({
    github: {ref: "refs/heads/main", sha: .[0], run_attempt: "1"}, needs: {"xfg-current": {outputs: {current: .[1]}}}})')
  run gh_eval "$(yq -r '.jobs["xfg-plan"].concurrency.group' "$CI")" "$contexts"
  [ "$status" -eq 0 ]
  mapfile -t groups <<<"$output"
  [ "${groups[0]}" = "${groups[1]}" ]
  [ "${groups[2]}" != "${groups[0]}" ]
  [ "${groups[3]}" != "${groups[0]}" ]
}

@test "a re-run gets a concurrency group of its own, because Re-run failed jobs reuses the check's stale output" {
  contexts=$(jq -nc '[["aaa", "1"], ["aaa", "2"], ["bbb", "2"]] | map({
    github: {ref: "refs/heads/main", sha: .[0], run_attempt: .[1]}, needs: {"xfg-current": {outputs: {current: "true"}}}})')
  run gh_eval "$(yq -r '.jobs["xfg-plan"].concurrency.group' "$CI")" "$contexts"
  [ "$status" -eq 0 ]
  mapfile -t groups <<<"$output"
  [ "${groups[1]}" != "${groups[0]}" ]
  [ "${groups[2]}" != "${groups[0]}" ]
  [ "${groups[1]}" != "${groups[2]}" ]
}

@test "the current check holds no secrets, no environment and only read access" {
  run yq -o=json -I0 '.jobs["xfg-current"] | [.permissions, has("environment")]' "$CI"
  [ "$output" = '[{"contents":"read"},false]' ]
  run yq '[.jobs["xfg-current"] | .. | select(tag == "!!str") | select(test("secrets[.]"))] | length' "$CI"
  [ "$output" = "0" ]
}

# in_clone <clone> <sha> - the check's step as Actions runs it, in a shallow clone checked out at <sha>; $OUT holds its step outputs
in_clone() {
  OUT="$BATS_TEST_TMPDIR/step-output"
  : >"$OUT"
  run env -C "$1" GITHUB_SHA="$2" GITHUB_OUTPUT="$OUT" bash -e "$STEP"
}

# two_merges - an origin whose main moved twice, and a shallow clone of each state: $older (src/ since changed), $newer (src/ matches main's src/), $origin
two_merges() {
  export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  origin="$BATS_TEST_TMPDIR/origin"
  git init -q -b main "$origin"
  mkdir -p "$origin/.github/scripts" "$origin/src"
  cp "$REPO_ROOT/.github/scripts/xfg-plan-current.sh" "$origin/.github/scripts/"
  echo base >"$origin/src/base.yaml"
  git -C "$origin" add -A
  git -C "$origin" commit -q -m "older merge"
  older=$(git -C "$origin" rev-parse HEAD)
  git clone -q --depth=2 "file://$origin" "$BATS_TEST_TMPDIR/older"

  echo change >>"$origin/src/base.yaml"
  git -C "$origin" commit -q -am "newer merge changes src"
  newer=$(git -C "$origin" rev-parse HEAD)
  git clone -q --depth=2 "file://$origin" "$BATS_TEST_TMPDIR/newer"

  echo notes >"$origin/README.md"
  git -C "$origin" add README.md
  git -C "$origin" commit -q -m "later commit leaves src alone"
}

@test "the check decides from a fresh fetch of main, so of two merges landing close together only the newer plans" {
  STEP="$BATS_TEST_TMPDIR/step.sh"
  yq -r '.jobs["xfg-current"].steps[] | select((.run // "") | contains("xfg-plan-current.sh")) | .run' "$CI" >"$STEP"
  [ -s "$STEP" ]
  two_merges

  in_clone "$BATS_TEST_TMPDIR/older" "$older"
  [ "$status" -eq 0 ]
  [ "$(<"$OUT")" = "current=false" ]
  [[ "$output" == *"::notice::"* ]]

  in_clone "$BATS_TEST_TMPDIR/newer" "$newer"
  [ "$status" -eq 0 ]
  [ "$(<"$OUT")" = "current=true" ]
  [[ "$output" != *"::notice::"* ]]
}

# plan_step <event> <last-deploy-sha> - Plan's changes step with the two expressions it reads filled in the way Actions does
plan_step() {
  local body
  body=$(yq -r '.jobs["xfg-plan"].steps[] | select(.id == "changes") | .run' "$CI")
  body=${body//'${{ github.event_name }}'/$1}
  body=${body//'${{ vars.LAST_XFG_DEPLOY_SHA }}'/$2}
  [[ "$body" != *'${{'* ]]
  STEP="$BATS_TEST_TMPDIR/plan-step.sh"
  printf '%s\n' "$body" >"$STEP"
}

@test "Plan re-checks main itself, so a re-run of an older run never plans though the check said current" {
  two_merges
  for event in workflow_dispatch push; do
    for last in '' 0123456789abcdef0123456789abcdef01234567; do
      plan_step "$event" "$last"
      in_clone "$BATS_TEST_TMPDIR/older" "$older"
      [ "$status" -eq 0 ]
      [ "$(<"$OUT")" = "run_sync=false" ]
      [[ "$output" == *"::notice::"* ]]
    done
  done
}

@test "Plan on a run whose src/ matches main still decides from the deploy history" {
  two_merges
  plan_step workflow_dispatch ""
  in_clone "$BATS_TEST_TMPDIR/newer" "$newer"
  [ "$status" -eq 0 ]
  [ "$(<"$OUT")" = "run_sync=true" ]

  plan_step push ""
  in_clone "$BATS_TEST_TMPDIR/newer" "$newer"
  [ "$status" -eq 0 ]
  [ "$(<"$OUT")" = "run_sync=true" ]

  plan_step push "$older"
  in_clone "$BATS_TEST_TMPDIR/newer" "$newer"
  [ "$status" -eq 0 ]
  [ "$(<"$OUT")" = "run_sync=true" ]

  plan_step push "$newer"
  in_clone "$BATS_TEST_TMPDIR/newer" "$newer"
  [ "$status" -eq 0 ]
  [ "$(<"$OUT")" = "run_sync=false" ]
}

@test "Plan fails the step when it cannot compare with main, rather than planning on a guess" {
  two_merges
  git init -q -b main "$BATS_TEST_TMPDIR/no-src"
  git -C "$BATS_TEST_TMPDIR/no-src" commit -q --allow-empty -m "main without src"
  git -C "$BATS_TEST_TMPDIR/newer" remote set-url origin "file://$BATS_TEST_TMPDIR/no-src"
  plan_step workflow_dispatch ""
  in_clone "$BATS_TEST_TMPDIR/newer" "$newer"
  [ "$status" -ne 0 ]
  [[ "$(<"$OUT")" != *run_sync* ]]
}
