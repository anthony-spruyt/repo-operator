#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # each @test runs in its own subshell by design
# Fixtures are SonarCloud API responses recorded on 2026-10-07 (SunGather#406, claude-plugins#121 and #133).

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../check.sh"
  FX="${BATS_TEST_DIRNAME}/fixtures"

  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cp "${BATS_TEST_DIRNAME}/fake-curl.sh" "${BATS_TEST_TMPDIR}/bin/curl"
  chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
  export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
  export FAKE_CALLS="${BATS_TEST_TMPDIR}/calls"
  : >"$FAKE_CALLS"

  export SONAR_PROJECT_KEY="anthony-spruyt_SunGather"
  export PR_NUMBER="406"
  export HEAD_SHA="14651171263f1c551699b28fbde3b66204b79c83"
  export MIN_SEVERITY="INFO"
  export INCLUDE_HOTSPOTS="true"
  export TIMEOUT_SECONDS="0"
  export POLL_INTERVAL_SECONDS="0"
  unset GITHUB_STEP_SUMMARY

  export FAKE_PRS="$FX/sungather-pull-requests.json"
  export FAKE_ISSUES="$FX/sungather-406-issues.json"
  export FAKE_HOTSPOTS="$FX/sungather-406-hotspots.json"
  export FAKE_MEASURES="$FX/sungather-406-measures.json"
}

hotspots_to_review() {
  jq --arg n "$1" '.component.measures[0].value = $n' "$FX/sungather-406-measures.json" >"${BATS_TEST_TMPDIR}/measures.json"
  export FAKE_MEASURES="${BATS_TEST_TMPDIR}/measures.json"
}

use_claude_plugins() {
  export SONAR_PROJECT_KEY="anthony-spruyt_claude-plugins"
  export PR_NUMBER="$1"
  export FAKE_PRS="$FX/claude-plugins-pull-requests.json"
  export FAKE_ISSUES="$FX/claude-plugins-$1-issues.json"
  export FAKE_HOTSPOTS="$FX/sungather-406-hotspots.json"
  if [[ "$1" == "133" ]]; then
    export HEAD_SHA="72b0b57ba3b4836eff2c75ddd1ce1ccd8c31670f"
  else
    export HEAD_SHA="50fb045a27e60d43a35aa90b93c9fb4f2f3f244a"
  fi
}

calls_to() {
  grep -c "sonarcloud.io/api/$1" "$FAKE_CALLS" || true
}

@test "fails on a new code smell and lists rule, file:line, message and link" {
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"python:S7632 src/sungather/sungather.py:82 Fix the syntax of this issue suppression comment."* ]]
  [[ "$output" == *"https://sonarcloud.io/project/issues?id=anthony-spruyt_SunGather&pullRequest=406&open=AaEVyiRjvGRnIyCZ-p68"* ]]
  [[ "$output" == *"1 new SonarCloud issue"* ]]
}

@test "annotates each issue on its file and line" {
  run "$SCRIPT"
  [[ "$output" == *"::error file=src/sungather/sungather.py,line=82,title=python%3AS7632::Fix the syntax of this issue suppression comment."* ]]
}

@test "counts every open issue on the pull request" {
  use_claude_plugins 133
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"5 new SonarCloud issue"* ]]
  [ "$(grep -c '^  - python:S3776 ' <<<"$output")" -eq 4 ]
  [[ "$output" == *"python:S7632 hookify-plus/core/masking.py:39 "* ]]
}

@test "passes a clean pull request" {
  use_claude_plugins 121
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No new SonarCloud issues"* ]]
}

@test "queries this pull request's unresolved issues without a token" {
  run "$SCRIPT"
  grep -q "issues/search componentKeys=anthony-spruyt_SunGather pullRequest=406 resolved=false" "$FAKE_CALLS"
  grep -q "hotspots/search projectKey=anthony-spruyt_SunGather pullRequest=406 status=TO_REVIEW" "$FAKE_CALLS"
  grep -q "measures/component component=anthony-spruyt_SunGather pullRequest=406 metricKeys=security_hotspots_to_review_status" "$FAKE_CALLS"
  run ! grep -qi "authorization" "$FAKE_CALLS"
}

@test "waits until SonarCloud has analysed the head commit" {
  export HEAD_SHA="72b0b57ba3b4836eff2c75ddd1ce1ccd8c31670f"
  export SONAR_PROJECT_KEY="anthony-spruyt_claude-plugins"
  export PR_NUMBER="133"
  export FAKE_PRS="$FX/sungather-pull-requests.json $FX/claude-plugins-pull-requests.json"
  export FAKE_ISSUES="$FX/claude-plugins-133-issues.json"
  export TIMEOUT_SECONDS="30"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(calls_to project_pull_requests/list)" -eq 2 ]
  [ "$(calls_to issues/search)" -eq 1 ]
}

@test "times out when SonarCloud never analyses the head commit" {
  export HEAD_SHA="0000000000000000000000000000000000000000"
  export TIMEOUT_SECONDS="2"
  export POLL_INTERVAL_SECONDS="1"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has not analysed 0000000000000000000000000000000000000000"* ]]
  [[ "$output" == *"14651171263f1c551699b28fbde3b66204b79c83"* ]]
  [ "$(calls_to project_pull_requests/list)" -ge 2 ]
  [ "$(calls_to issues/search)" -eq 0 ]
}

@test "times out when the pull request has no analysis yet" {
  export PR_NUMBER="9999"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"has not analysed"* ]]
  [[ "$output" == *"no analysis of PR #9999"* ]]
}

@test "fails at once when the SonarCloud project does not exist" {
  export FAKE_PRS="404:$FX/project-not-found.json"
  export TIMEOUT_SECONDS="30"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 404"* ]]
  [[ "$output" == *"not found"* ]]
  [ "$(calls_to project_pull_requests/list)" -eq 1 ]
}

@test "retries transient SonarCloud errors" {
  export FAKE_PRS="503:$FX/project-not-found.json 000:x $FX/sungather-pull-requests.json"
  export FAKE_ISSUES="502:$FX/project-not-found.json $FX/sungather-406-issues.json"
  export TIMEOUT_SECONDS="30"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"python:S7632"* ]]
  [ "$(calls_to project_pull_requests/list)" -eq 3 ]
}

@test "min-severity HIGH ignores the MEDIUM issue" {
  use_claude_plugins 133
  export MIN_SEVERITY="HIGH"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"4 new SonarCloud issue"* ]]
  [[ "$output" != *"python:S7632"* ]]
}

@test "min-severity BLOCKER passes when nothing reaches it" {
  use_claude_plugins 133
  export MIN_SEVERITY="BLOCKER"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "counts an issue that has no impact severity whatever the threshold" {
  jq '.issues[0].impacts = []' "$FX/sungather-406-issues.json" >"${BATS_TEST_TMPDIR}/issues.json"
  export FAKE_ISSUES="${BATS_TEST_TMPDIR}/issues.json"
  export MIN_SEVERITY="BLOCKER"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "ignores issues marked Accepted or False positive" {
  jq --slurpfile acc "$FX/container-images-accepted-issue.json" '
    .issues += [$acc[0].issues[0], ($acc[0].issues[0] | .resolution = "FALSE-POSITIVE" | .issueStatus = "FALSE_POSITIVE")]
    | .total += 2' "$FX/sungather-406-issues.json" >"${BATS_TEST_TMPDIR}/issues.json"
  export FAKE_ISSUES="${BATS_TEST_TMPDIR}/issues.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 new SonarCloud issue"* ]]
  [[ "$output" != *"AaAuie_gvKLTf8kM4ZKF"* ]]
}

@test "waits for the issue search to catch up with the analysis" {
  export FAKE_ISSUES="$FX/claude-plugins-121-issues.json $FX/sungather-406-issues.json"
  export TIMEOUT_SECONDS="30"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"python:S7632"* ]]
  [ "$(calls_to issues/search)" -eq 2 ]
}

@test "fails when the issue search never catches up with the analysis" {
  export FAKE_ISSUES="$FX/claude-plugins-121-issues.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SonarCloud counts 1 open issue(s) on PR #406 but the issue search returned 0"* ]]
}

@test "counts an issue in a status SonarCloud adds later" {
  jq '.issues[0].issueStatus = "IN_SANDBOX"' "$FX/sungather-406-issues.json" >"${BATS_TEST_TMPDIR}/issues.json"
  export FAKE_ISSUES="${BATS_TEST_TMPDIR}/issues.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
}

@test "fails closed when SonarCloud returns more issues than one page" {
  jq '.total = 600' "$FX/sungather-406-issues.json" >"${BATS_TEST_TMPDIR}/issues.json"
  export FAKE_ISSUES="${BATS_TEST_TMPDIR}/issues.json"
  export MIN_SEVERITY="BLOCKER"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"600"* ]]
}

@test "fails on security hotspots to review and links them" {
  use_claude_plugins 121
  export FAKE_HOTSPOTS="$FX/container-images-hotspots.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"8 security hotspot"* ]]
  [[ "$output" == *"docker:S6471 devcontainer-common/Dockerfile:1 "* ]]
  [[ "$output" == *"https://sonarcloud.io/project/security_hotspots?id=anthony-spruyt_claude-plugins&pullRequest=121&hotspots=AZ6C4A5RkASlgEhJSHUu"* ]]
}

@test "waits for the hotspot search to catch up with the analysis" {
  use_claude_plugins 121
  hotspots_to_review 8
  export FAKE_HOTSPOTS="$FX/sungather-406-hotspots.json $FX/container-images-hotspots.json"
  export TIMEOUT_SECONDS="30"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [ "$(calls_to hotspots/search)" -eq 2 ]
  [[ "$output" == *"8 security hotspot"* ]]
}

@test "fails when the hotspot search never catches up" {
  use_claude_plugins 121
  hotspots_to_review 8
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"SonarCloud counts 8 security hotspot(s) to review on PR #121 but the hotspot search returned 0; re-run this job."* ]]
}

@test "fails closed when the hotspot count is missing" {
  use_claude_plugins 121
  jq '.component.measures = []' "$FX/sungather-406-measures.json" >"${BATS_TEST_TMPDIR}/measures.json"
  export FAKE_MEASURES="${BATS_TEST_TMPDIR}/measures.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no security hotspot count"* ]]
}

@test "fails closed when SonarCloud returns more hotspots than one page" {
  use_claude_plugins 121
  jq '.paging.total = 600' "$FX/container-images-hotspots.json" >"${BATS_TEST_TMPDIR}/hotspots.json"
  export FAKE_HOTSPOTS="${BATS_TEST_TMPDIR}/hotspots.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"600 security hotspots to review, more than one page"* ]]
}

@test "fails closed when the analysis has no issue counts" {
  use_claude_plugins 121
  jq '(.pullRequests[] | select(.key == "121")) |= del(.status.codeSmells)' \
    "$FX/claude-plugins-pull-requests.json" >"${BATS_TEST_TMPDIR}/prs.json"
  export FAKE_PRS="${BATS_TEST_TMPDIR}/prs.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no issue counts"* ]]
  [ "$(calls_to issues/search)" -eq 0 ]
}

@test "skips hotspots when include-hotspots is false" {
  use_claude_plugins 121
  export FAKE_HOTSPOTS="$FX/container-images-hotspots.json"
  export INCLUDE_HOTSPOTS="false"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(calls_to hotspots/search)" -eq 0 ]
  [ "$(calls_to measures/component)" -eq 0 ]
}

@test "neutralises workflow commands in SonarCloud data" {
  jq '.issues[0].message = "x\n::error::pwned\r\n::add-mask::y ##[add-mask]z"
    | .issues[0].component = "k:a,b:c\n::warning::pwned.py"' \
    "$FX/sungather-406-issues.json" >"${BATS_TEST_TMPDIR}/issues.json"
  export FAKE_ISSUES="${BATS_TEST_TMPDIR}/issues.json"
  run "$SCRIPT"
  [ "$status" -eq 1 ]
  local injected=$'(^|\n)[[:space:]]*::(error|warning|add-mask)::(pwned|y)'
  [[ ! "$output" =~ $injected ]]
  [[ "$output" != *"##["* ]]
  [[ "$output" == *"::error file=a%2Cb%3Ac%0A%3A%3Awarning%3A%3Apwned.py,line=82,"* ]]
  [[ "$output" == *"title=python%3AS7632::x%0A::error::pwned%0D%0A::add-mask::y"* ]]
}

@test "writes a step summary with only validated values" {
  export GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  : >"$GITHUB_STEP_SUMMARY"
  run "$SCRIPT"
  grep -q "https://sonarcloud.io/summary/new_code?id=anthony-spruyt_SunGather&pullRequest=406" "$GITHUB_STEP_SUMMARY"
  run ! grep -q "suppression comment" "$GITHUB_STEP_SUMMARY"
}

@test "rejects bad inputs before calling SonarCloud" {
  for bad in "PR_NUMBER=12a" "PR_NUMBER=" "HEAD_SHA=abc" "HEAD_SHA=14651171263F1C551699B28FBDE3B66204B79C83" \
    "SONAR_PROJECT_KEY=a&b=c" "SONAR_PROJECT_KEY=" "MIN_SEVERITY=MAJOR" "INCLUDE_HOTSPOTS=yes" \
    "TIMEOUT_SECONDS=-1" "TIMEOUT_SECONDS=08" "POLL_INTERVAL_SECONDS=1s" "POLL_INTERVAL_SECONDS=09"; do
    run env "$bad" "$SCRIPT"
    [ "$status" -eq 1 ]
    [[ "$output" =~ ^::error::(Invalid|min-severity|include-hotspots) ]]
  done
  [ ! -s "$FAKE_CALLS" ]
}
