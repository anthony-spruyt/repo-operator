#!/usr/bin/env bats
#
# The agent-kit group ships the orchestration kit and adds the agent-kit plugin entry only in repos that have it.

SRC="${BATS_TEST_DIRNAME}/../src"

@test "the claude settings template has no agent-kit plugin entry" {
  run jq -r '.enabledPlugins | has("agent-kit@aspruyt-plugins")' "${SRC}/templates/.claude/settings.json"
  [ "${status}" -eq 0 ]
  [ "${output}" = "false" ]
}

@test "repos in both claude and agent-kit get the agent-kit plugin switched on" {
  run yq -r '[.conditionalGroups[] | select(.when.allOf | contains(["claude", "agent-kit"])) | .files.".claude/settings.json".content.enabledPlugins["agent-kit@aspruyt-plugins"]] | join(",")' "${SRC}/groups.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

@test "every repo in the claude group is also in the agent-kit group" {
  run yq -r '[.repos[] | select(.groups | contains(["claude"])) | select(.groups | contains(["agent-kit"]) | not) | .git] | join(",")' "${SRC}/repos.yaml"
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "every file the agent-kit group syncs has a template" {
  run yq -r '.groups.agent-kit.files[].content | sub("^@", "")' "${SRC}/groups.yaml"
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
  while IFS= read -r path; do
    [ -f "${SRC}/${path}" ]
  done <<<"${output}"
}

@test "no template the agent-kit group syncs has a brace-dollar reference, which xfg would substitute on sync" {
  run yq -r '.groups.agent-kit.files[].content | sub("^@", "")' "${SRC}/groups.yaml"
  [ "${status}" -eq 0 ]
  [ -n "${output}" ]
  templates="${output}"
  while IFS= read -r path; do
    # shellcheck disable=SC2016
    run grep -c '[^$]\${' "${SRC}/${path}"
    [ "${output}" = "0" ]
  done <<<"${templates}"
}
