#!/usr/bin/env bats
#
# The claude settings template denies AskUserQuestion so questions go through plain chat.

SRC="${BATS_TEST_DIRNAME}/../src"
SETTINGS="${SRC}/templates/.claude/settings.json"

@test "the claude settings template denies the AskUserQuestion tool" {
  run jq -r '.permissions.deny | index("AskUserQuestion") != null' "${SETTINGS}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "true" ]
}

