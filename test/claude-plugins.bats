#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../src/templates/.devcontainer/post-start.d/claude-plugins.sh"
  WS="${BATS_TEST_TMPDIR}/ws"
  HOME="${BATS_TEST_TMPDIR}/home"
  BIN="${BATS_TEST_TMPDIR}/bin"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  mkdir -p "$WS/.claude" "$HOME/.claude" "$BIN" "${BATS_TEST_TMPDIR}/installed"
  WS="$(cd "$WS" && pwd -P)"
  : >"$CALLS"
  echo '[]' >"${BATS_TEST_TMPDIR}/list.json"
  echo '[]' >"${BATS_TEST_TMPDIR}/markets.json"
  export HOME CALLS
  export FAKE_LIST="${BATS_TEST_TMPDIR}/list.json"
  export FAKE_MARKETS="${BATS_TEST_TMPDIR}/markets.json"

  cat >"$BIN/claude" <<'FAKE'
#!/bin/bash
echo "$*" >>"$CALLS"
case "$*" in
  "plugin list --json") cat "$FAKE_LIST" ;;
  "plugin marketplace list --json") cat "$FAKE_MARKETS" ;;
  "plugin install "*) [ -z "${FAKE_FAIL_INSTALL:-}" ] ;;
  "plugin marketplace add "*) [ -z "${FAKE_FAIL_MARKET_ADD:-}" ] ;;
  *) true ;;
esac
FAKE
  chmod +x "$BIN/claude"
  PATH="$BIN:$PATH"
}

settings() {
  printf '%s\n' "$1" >"$WS/.claude/settings.json"
}

installed() {
  local id="$1" scope="$2" path="${BATS_TEST_TMPDIR}/installed/${1}-${2}" project="${3:-}"
  mkdir -p "$path"
  jq --arg id "$id" --arg scope "$scope" --arg path "$path" --arg project "$project" \
    '. + [{id: $id, scope: $scope, installPath: $path} + (if $project == "" then {} else {projectPath: $project} end)]' \
    "$FAKE_LIST" >"$FAKE_LIST.tmp"
  mv "$FAKE_LIST.tmp" "$FAKE_LIST"
}

run_script() {
  cd "$WS" || return
  run bash "$SCRIPT"
}

@test "installs an enabled plugin that is not installed" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin install agent-kit@aspruyt-plugins --scope user' "$CALLS"
}

@test "does not reinstall a user-scope plugin" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  installed agent-kit@aspruyt-plugins user
  run_script
  [ "$status" -eq 0 ]
  run ! grep -q '^plugin install' "$CALLS"
}

@test "does not reinstall a plugin installed at project scope for this workspace" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  installed agent-kit@aspruyt-plugins project "$WS"
  run_script
  [ "$status" -eq 0 ]
  run ! grep -q '^plugin install' "$CALLS"
}

@test "installs when the plugin is only project-scoped to another workspace" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  installed agent-kit@aspruyt-plugins project /somewhere/else
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin install agent-kit@aspruyt-plugins --scope user' "$CALLS"
}

@test "installs when the recorded install path is gone" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  installed agent-kit@aspruyt-plugins user
  rm -rf "${BATS_TEST_TMPDIR}/installed/agent-kit@aspruyt-plugins-user"
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin install agent-kit@aspruyt-plugins --scope user' "$CALLS"
}

@test "skips official-marketplace and disabled plugins" {
  settings '{"enabledPlugins":{"context7@claude-plugins-official":true,"off@aspruyt-plugins":false,"str@aspruyt-plugins":"false"}}'
  run_script
  [ "$status" -eq 0 ]
  run ! grep -q '^plugin install' "$CALLS"
}

@test "installs plugins enabled in the user settings file" {
  printf '%s\n' '{"enabledPlugins":{"mine@aspruyt-plugins":true}}' >"$HOME/.claude/settings.json"
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin install mine@aspruyt-plugins --scope user' "$CALLS"
}

@test "a project-scope install does not satisfy a user settings entry" {
  printf '%s\n' '{"enabledPlugins":{"mine@aspruyt-plugins":true}}' >"$HOME/.claude/settings.json"
  installed mine@aspruyt-plugins project "$WS"
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin install mine@aspruyt-plugins --scope user' "$CALLS"
}

@test "adds a missing marketplace before installing" {
  settings '{"extraKnownMarketplaces":{"aspruyt-plugins":{"source":{"source":"github","repo":"anthony-spruyt/claude-plugins"}}},"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  run_script
  [ "$status" -eq 0 ]
  add=$(grep -nxF 'plugin marketplace add anthony-spruyt/claude-plugins --scope user' "$CALLS" | cut -d: -f1)
  inst=$(grep -nxF 'plugin install agent-kit@aspruyt-plugins --scope user' "$CALLS" | cut -d: -f1)
  [ -n "$add" ] && [ -n "$inst" ] && [ "$add" -lt "$inst" ]
}

@test "does not re-add a marketplace that is already known" {
  settings '{"extraKnownMarketplaces":{"aspruyt-plugins":{"source":{"source":"github","repo":"anthony-spruyt/claude-plugins"}}}}'
  mkdir -p "${BATS_TEST_TMPDIR}/mkt"
  jq -n --arg p "${BATS_TEST_TMPDIR}/mkt" '[{repo: "anthony-spruyt/claude-plugins", installLocation: $p}]' >"$FAKE_MARKETS"
  run_script
  [ "$status" -eq 0 ]
  run ! grep -q '^plugin marketplace add' "$CALLS"
}

@test "a failing install refreshes the marketplace, retries once, warns and exits 0" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true,"other@aspruyt-plugins":true}}'
  FAKE_FAIL_INSTALL=1 run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: failed to install agent-kit@aspruyt-plugins"* ]]
  [ "$(grep -cxF 'plugin install agent-kit@aspruyt-plugins --scope user' "$CALLS")" -eq 2 ]
  [ "$(grep -cxF 'plugin install other@aspruyt-plugins --scope user' "$CALLS")" -eq 1 ]
  [ "$(grep -cxF 'plugin marketplace update aspruyt-plugins' "$CALLS")" -eq 1 ]
}

@test "a failing marketplace add warns and the script carries on" {
  settings '{"extraKnownMarketplaces":{"aspruyt-plugins":{"source":{"source":"github","repo":"anthony-spruyt/claude-plugins"}}},"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  FAKE_FAIL_MARKET_ADD=1 run_script
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: failed to add marketplace"* ]]
  grep -qxF 'plugin marketplace update' "$CALLS"
}

@test "still updates installed user-scope and this-project plugins" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  installed agent-kit@aspruyt-plugins user
  installed proj@aspruyt-plugins project "$WS"
  installed foreign@aspruyt-plugins project /somewhere/else
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin marketplace update' "$CALLS"
  grep -qxF 'plugin update agent-kit@aspruyt-plugins --scope user' "$CALLS"
  grep -qxF 'plugin update proj@aspruyt-plugins --scope project' "$CALLS"
  run ! grep -q 'foreign@' "$CALLS"
}

@test "updates run after installs" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  run_script
  [ "$status" -eq 0 ]
  inst=$(grep -nxF 'plugin install agent-kit@aspruyt-plugins --scope user' "$CALLS" | cut -d: -f1)
  upd=$(grep -nxF 'plugin marketplace update' "$CALLS" | cut -d: -f1)
  [ "$inst" -lt "$upd" ]
}

@test "still updates when there is no settings file" {
  rm -f "$WS/.claude/settings.json"
  installed agent-kit@aspruyt-plugins user
  run_script
  [ "$status" -eq 0 ]
  grep -qxF 'plugin update agent-kit@aspruyt-plugins --scope user' "$CALLS"
}

@test "invalid settings JSON warns and exits 0" {
  settings '{not json'
  run_script
  [ "$status" -eq 0 ]
  run ! grep -q '^plugin install' "$CALLS"
}

@test "exits quietly when claude is missing" {
  settings '{"enabledPlugins":{"agent-kit@aspruyt-plugins":true}}'
  rm "$BIN/claude"
  cd "$WS"
  PATH="$BIN:/usr/bin:/bin" run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
