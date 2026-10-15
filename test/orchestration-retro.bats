#!/usr/bin/env bats
#
# The orchestration retro reports helper routing, review verdicts, review-fix rounds per PR and non-None feedback from session logs. Ref anthony-spruyt/spruyt-labs#3474

REPO_ROOT="${BATS_TEST_DIRNAME}/.."
SCRIPT="${REPO_ROOT}/src/templates/.claude/skills/orchestration-retro/retro.sh"
PROJECTS="${BATS_TEST_DIRNAME}/fixtures/orchestration-retro/projects"

# Prints one report section: from its "## " heading up to the next one.
section() {
  printf '%s\n' "${output}" | awk -v h="## $1" 'index($0, h) == 1 { on = 1; next } /^## / { on = 0 } on'
}

@test "counts helpers and output tokens per agent type and actual model" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  table="$(section "Helper runs by agent type and model")"
  # Tokens: one count per message id (max over its chunks), synthetic messages skipped.
  [[ "${table}" == *"| general-purpose | claude-opus-5-5 | 2 | 300 |"* ]]
  [[ "${table}" == *"| general-purpose | claude-sonnet-5-5 | 1 | 150 |"* ]]
  [[ "${table}" == *"| pr-builder | claude-sonnet-5-5 | 1 | 150 |"* ]]
  [[ "${table}" == *"| pr-reviewer | claude-opus-5-5 | 2 | 300 |"* ]]
}

@test "lists general-purpose helpers that ran on opus as routing misses" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  misses="$(section "Routing misses")"
  [[ "${misses}" == *"2026-03-10"*"Fix round 2 on demo PR 101"* ]]
  [[ "${misses}" == *"2026-01-05"*"Old miss helper"* ]]
  [[ "${misses}" != *"Build widget"* ]]
  [[ "${misses}" != *"Review #101"* ]]
}

@test "counts READY and NOT READY reviewer verdicts separately" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  verdicts="$(section "Review verdicts")"
  [[ "${verdicts}" == *"- NOT READY: 4"* ]]
  [[ "${verdicts}" == *"- READY: 10"* ]]
}

@test "reads the report a reviewer hands back through the SubagentHandback tool" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "$(section "Review verdicts")" == *"- NOT READY: 4"* ]]
  [[ "$(section "PRs with fix rounds")" == *"- demo/repo#301: 1 fix round"$'\n'* ]]
  feedback="$(section "Agent Definition Feedback")"
  [[ "${feedback}" == *"- [brief] items: 1"* ]]
  [[ "${feedback}" == *"Name the repo in the fix-check brief"* ]]
}

@test "does not read the input of any tool other than SubagentHandback" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *SENTINEL_OTHER_TOOL_MESSAGE* ]]
  [[ "$(section "Agent Definition Feedback")" != *chore-runner* ]]
}

@test "lists PRs by fix-check reviews, flags two as at cap, and skips full-mode reviews" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  rounds="$(section "PRs with fix rounds" | grep '^- ')"
  expected=$'- demo/repo#201: 2 fix rounds (at cap)\n- demo/repo#4500: 2 fix rounds (at cap)\n- demo/repo#202: 1 fix round\n- #205: 1 fix round\n- other/repo#207: 1 fix round\n- demo/repo#301: 1 fix round\n- demo/repo#302: 1 fix round\n- Fix-checks with no PR number: 1'
  [ "${rounds}" == "${expected}" ]
}

@test "takes the PR from the reviewer's PR line when the description has no number" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "$(section "PRs with fix rounds")" == *"- demo/repo#302: 1 fix round"$'\n'* ]]
}

@test "counts a fix-check reviewed before the push and one after it as the same PR" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  rounds="$(section "PRs with fix rounds")"
  [ "$(printf '%s\n' "${rounds}" | grep -c '4500')" -eq 1 ]
  [[ "${rounds}" == *"- demo/repo#4500: 2 fix rounds (at cap)"$'\n'* ]]
}

@test "falls back to the description number, shown as a bare #n" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "$(section "PRs with fix rounds")" == *"- #205: 1 fix round"$'\n'* ]]
}

@test "counts fix-checks with no PR number anywhere" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "$(section "PRs with fix rounds")" == *"- Fix-checks with no PR number: 1"* ]]
}

@test "does not print the no-number line when every fix-check has a PR" {
  tree="$(mktemp -d)"
  cp -R "${PROJECTS}/." "${tree}/"
  rm "${tree}"/-demo-repo/sess-4/subagents/agent-nopr.*
  run bash "${SCRIPT}" --projects-dir "${tree}"
  rm -rf "${tree}"
  [ "${status}" -eq 0 ]
  [[ "$(section "PRs with fix rounds")" != *"no PR number"* ]]
}

@test "a full-mode reply that mentions Mode: fix-check mid-line is not a fix-check" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "$(section "PRs with fix rounds")" != *"#206"* ]]
}

@test "shows non-None agent definition feedback with its agent type" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  feedback="$(section "Agent Definition Feedback")"
  [[ "${feedback}" == *"pr-reviewer"*'add a "Repo" input line to pr-reviewer.md.'* ]]
  [[ "${feedback}" != *"ignored"* ]]
  [ "$(printf '%s\n' "${feedback}" | grep -c 'pr-reviewer')" -eq 1 ]
}

@test "trims long feedback to about 300 characters" {
  tree="$(mktemp -d)"
  cp -R "${PROJECTS}/." "${tree}/"
  long="$(printf 'x%.0s' $(seq 1 600))"
  jq -c --arg t $'Done\n\n### Agent Definition Feedback\n\n'"${long}" \
    'if .message.id == "msg_B" then .message.content[0].text = $t else . end' \
    "${tree}/-demo-repo/sess-1/subagents/agent-builder.jsonl" >"${tree}/b.tmp"
  mv "${tree}/b.tmp" "${tree}/-demo-repo/sess-1/subagents/agent-builder.jsonl"
  run bash "${SCRIPT}" --projects-dir "${tree}"
  rm -rf "${tree}"
  [ "${status}" -eq 0 ]
  line="$(section "Agent Definition Feedback" | grep 'pr-builder')"
  [ "${#line}" -lt 400 ]
  [[ "${line}" == *"xxxxxxxxxx"*"..." ]]
}

@test "--since drops older helpers from every section" {
  run bash "${SCRIPT}" --since 2026-02-01 --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"Old miss helper"* ]]
  table="$(section "Helper runs by agent type and model")"
  [[ "${table}" == *"| general-purpose | claude-opus-5-5 | 1 | 150 |"* ]]
}

@test "--since after every helper reports no runs" {
  run bash "${SCRIPT}" --since 2027-01-01 --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No helper runs"* ]]
  [[ "${output}" != *"general-purpose"* ]]
}

@test "an empty projects dir still prints every section" {
  empty="$(mktemp -d)"
  run bash "${SCRIPT}" --projects-dir "${empty}"
  rmdir "${empty}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"## Helper runs by agent type and model"* ]]
  [[ "${output}" == *"## Routing misses"* ]]
  [[ "${output}" == *"## Review verdicts"* ]]
  [[ "${output}" == *"## PRs with fix rounds"* ]]
  [[ "${output}" == *"## Agent Definition Feedback"* ]]
  [[ "${output}" == *"No helper runs"* ]]
  [ "$(section "PRs with fix rounds" | grep -v '^$')" == "None." ]
}

@test "never prints tool inputs or tool results" {
  run bash "${SCRIPT}" --projects-dir "${PROJECTS}"
  [ "${status}" -eq 0 ]
  [[ "${output}" != *SENTINEL* ]]
}

@test "a missing projects dir is an error" {
  run bash "${SCRIPT}" --projects-dir "${BATS_TEST_DIRNAME}/does-not-exist"
  [ "${status}" -ne 0 ]
}

@test "a malformed --since is an error" {
  run bash "${SCRIPT}" --since yesterday --projects-dir "${PROJECTS}"
  [ "${status}" -ne 0 ]
}

@test "treats the builder and reviewer agent names like the old pr-builder and pr-reviewer" {
  tree="$(mktemp -d)"
  cp -R "${PROJECTS}/." "${tree}/"
  find "${tree}" -name '*.meta.json' -exec sed -i 's/"pr-builder"/"builder"/; s/"pr-reviewer"/"reviewer"/' {} +
  run bash "${SCRIPT}" --projects-dir "${tree}"
  rm -rf "${tree}"
  [ "${status}" -eq 0 ]
  verdicts="$(section "Review verdicts")"
  [[ "${verdicts}" == *"- NOT READY: 4"* ]]
  [[ "${verdicts}" == *"- READY: 10"* ]]
  rounds="$(section "PRs with fix rounds")"
  [[ "${rounds}" == *"- demo/repo#201: 2 fix rounds (at cap)"* ]]
  [[ "${rounds}" == *"- demo/repo#202: 1 fix round"$'\n'* ]]
}
