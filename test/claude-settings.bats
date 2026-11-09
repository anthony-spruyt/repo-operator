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

DEVCONTAINER="${SRC}/templates/.devcontainer/devcontainer.json5"
RM_SWITCHES="CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT"

# yq reads the JSON5 as YAML flow style once the full-line comments are gone
devcontainer_json() {
  sed '/^[[:space:]]*\/\//d' "${DEVCONTAINER}" | yq -p yaml -o json -I0
}

# Claude Code drops these keys from a settings env block, so only the process env reaches it
@test "the devcontainer remoteEnv switches off both rm prompts" {
  for key in ${RM_SWITCHES}; do
    value="$(devcontainer_json | jq -r --arg k "${key}" '.remoteEnv[$k]')"
    [ "${value}" = "1" ]
  done
}

@test "the settings env block holds no permission switch Claude Code drops" {
  for key in ${RM_SWITCHES} CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS; do
    run jq -e --arg k "${key}" '.env | has($k) | not' "${SETTINGS}"
    [ "${status}" -eq 0 ]
  done
}
