#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  WORK="${BATS_TEST_TMPDIR}/repo"
  mkdir -p "$WORK"
  sed -e 's/\${xfg:megalinterImage}/example.test\/megalinter:1/' -e 's/\$\$/$/g' \
    "$REPO_ROOT/src/templates/lint.sh.tmpl" >"$WORK/lint.sh"
  chmod +x "$WORK/lint.sh"
  STUB="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" >"%s/docker-args"\n' "$BATS_TEST_TMPDIR" >"$STUB/docker"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$STUB/sudo"
  chmod +x "$STUB/docker" "$STUB/sudo"
  export PATH="$STUB:$PATH"
  unset ENABLE_LINTERS DISABLE_LINTERS ENABLE_DISABLE_LINTERS_PRIORITY GITHUB_STEP_SUMMARY GITHUB_TOKEN
  ARGS="${BATS_TEST_TMPDIR}/docker-args"
}

@test "the root lint.sh is the template rendered with the base pin" {
  pin=$(yq -r '.conditionalGroups[] | select(.when.allOf[0] == "megalinter-flavor" and (.when.allOf | length) == 1) | .files["lint.sh"].vars.megalinterImage' "$REPO_ROOT/src/groups.yaml")
  diff <(sed -e "s|\\\${xfg:megalinterImage}|$pin|" -e 's/\$\$/$/g' "$REPO_ROOT/src/templates/lint.sh.tmpl") "$REPO_ROOT/lint.sh"
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
