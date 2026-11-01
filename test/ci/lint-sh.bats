#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORK="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$WORK"
  sed -e 's/\${xfg:megalinterImage}/example.test\/megalinter:1/' -e 's/\$\$/$/g' \
    "$REPO_ROOT/src/templates/lint.sh.tmpl" >"$WORK/lint.sh"
  chmod +x "$WORK/lint.sh"
  STUB="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB"
  cat >"$STUB/docker" <<STUBEOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$BATS_TEST_TMPDIR/docker-args"
if [ -n "\${STUB_REWRITE:-}" ]; then
  mkdir -p "$WORK/.output/updated_sources"
  echo rewritten >"$WORK/.output/updated_sources/\$STUB_REWRITE"
fi
exit "\${STUB_EXIT:-0}"
STUBEOF
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/sudo"
  chmod +x "$STUB/docker" "$STUB/sudo"
  export PATH="$STUB:$PATH"
  unset ENABLE_LINTERS DISABLE_LINTERS ENABLE_DISABLE_LINTERS_PRIORITY GITHUB_STEP_SUMMARY GITHUB_TOKEN
  ARGS="${BATS_TEST_TMPDIR}/docker-args"
}

@test "ci mode passes linter selection when set" {
  ENABLE_LINTERS=SPELL_LYCHEE DISABLE_LINTERS=SPELL_LYCHEE ENABLE_DISABLE_LINTERS_PRIORITY=DISABLE run "$WORK/lint.sh" --ci
  [ "$status" -eq 0 ]
  grep -qx 'ENABLE_LINTERS=SPELL_LYCHEE' "$ARGS"
  grep -qx 'DISABLE_LINTERS=SPELL_LYCHEE' "$ARGS"
  grep -qx 'ENABLE_DISABLE_LINTERS_PRIORITY=DISABLE' "$ARGS"
}

@test "ci mode leaves linter selection to the config when unset" {
  run "$WORK/lint.sh" --ci
  [ "$status" -eq 0 ]
  run grep -cE '^(ENABLE_LINTERS|DISABLE_LINTERS|ENABLE_DISABLE_LINTERS_PRIORITY)=' "$ARGS"
  [ "$output" = "0" ]
}

@test "ci mode does not pass an empty linter selection" {
  ENABLE_LINTERS='' DISABLE_LINTERS='' run "$WORK/lint.sh" --ci
  [ "$status" -eq 0 ]
  run grep -cE '^(ENABLE|DISABLE)_LINTERS=' "$ARGS"
  [ "$output" = "0" ]
}

@test "local mode passes linter selection when set" {
  DISABLE_LINTERS=SPELL_LYCHEE run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  grep -qx 'DISABLE_LINTERS=SPELL_LYCHEE' "$ARGS"
  run grep -c '^ENABLE_LINTERS=' "$ARGS"
  [ "$output" = "0" ]
}

@test "ci mode passes no token when none is set" {
  run "$WORK/lint.sh" --ci
  [ "$status" -eq 0 ]
  run grep -c 'GITHUB_TOKEN' "$ARGS"
  [ "$output" = "0" ]
}

@test "ci mode passes a set token by name, keeping its value out of argv" {
  GITHUB_TOKEN=dummy-token-value run "$WORK/lint.sh" --ci
  [ "$status" -eq 0 ]
  grep -qx 'GITHUB_TOKEN' "$ARGS"
  run grep -c 'dummy-token-value' "$ARGS"
  [ "$output" = "0" ]
}

@test "ci mode runs the container as the invoking user with HOME=/tmp" {
  run "$WORK/lint.sh" --ci
  [ "$status" -eq 0 ]
  grep -qx -- '-u' "$ARGS"
  grep -qx "$(id -u):$(id -g)" "$ARGS"
  grep -qx 'HOME=/tmp' "$ARGS"
}

@test "local mode leaves files alone when MegaLinter lists one and APPLY_FIXES=none" {
  echo original >"$WORK/tracked.txt"
  STUB_REWRITE=tracked.txt APPLY_FIXES=none run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/tracked.txt")" = "original" ]
}

@test "local mode leaves files alone when APPLY_FIXES=None, which MegaLinter treats as no fixes" {
  echo original >"$WORK/tracked.txt"
  STUB_REWRITE=tracked.txt APPLY_FIXES=None run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/tracked.txt")" = "original" ]
}

@test "local mode leaves files alone when APPLY_FIXES=false, which MegaLinter treats as no fixes" {
  echo original >"$WORK/tracked.txt"
  STUB_REWRITE=tracked.txt APPLY_FIXES=false run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/tracked.txt")" = "original" ]
}

@test "local mode leaves files alone when APPLY_FIXES=All, which MegaLinter matches case-sensitively" {
  echo original >"$WORK/tracked.txt"
  STUB_REWRITE=tracked.txt APPLY_FIXES=All run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/tracked.txt")" = "original" ]
}

@test "local mode copies back a file MegaLinter rewrote when APPLY_FIXES is unset" {
  echo original >"$WORK/tracked.txt"
  STUB_REWRITE=tracked.txt run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/tracked.txt")" = "rewritten" ]
}

@test "local mode copies back a file MegaLinter rewrote when APPLY_FIXES names linters" {
  echo original >"$WORK/tracked.txt"
  STUB_REWRITE=tracked.txt APPLY_FIXES=YAML_PRETTIER run "$WORK/lint.sh"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/tracked.txt")" = "rewritten" ]
}

@test "local mode failure output mentions copied-back files only when fixes were applied" {
  STUB_EXIT=1 APPLY_FIXES=none run "$WORK/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" != *"already copied back"* ]]
  STUB_EXIT=1 APPLY_FIXES=false run "$WORK/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" != *"already copied back"* ]]
  STUB_EXIT=1 run "$WORK/lint.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already copied back"* ]]
}
