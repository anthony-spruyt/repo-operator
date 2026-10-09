#!/usr/bin/env bats

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/scripts/gen-xfg-managed-renovate.sh"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  CFG="${BATS_TEST_TMPDIR}/src"
  mkdir -p "$CFG"
  printf 'id: test\n' >"$CFG/base.yaml"
}

# Prints "<repo> <file>" for every file the generated preset disables
disabled_files() {
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -v '^//' | jq -r '.packageRules[] | .matchRepositories[0] as $r | .matchFileNames[] | "\($r) \(.)"'
}

@test "committed preset matches src/" {
  run "$SCRIPT" "$REPO_ROOT/src"
  [ "$status" -eq 0 ]
  diff <(printf '%s\n' "$output") "$REPO_ROOT/.github/renovate/xfg-managed.json5"
}

@test "disables a managed file and leaves a createOnly file bumpable" {
  cat >"$CFG/files.yaml" <<'EOF'
files:
  .devcontainer/Dockerfile:
    content: "FROM x"
  .devcontainer/setup-devcontainer.sh:
    createOnly: true
    content: "echo"
EOF
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n' >"$CFG/repos.yaml"
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/a .devcontainer/Dockerfile" ]
}

@test "follows group extends and later createOnly overrides" {
  cat >"$CFG/groups.yaml" <<'EOF'
groups:
  github-ci:
    files:
      .github/workflows/ci.yaml:
        createOnly: true
        content: {}
  image:
    extends: github-ci
    files:
      .github/workflows/ci.yaml:
        createOnly: false
        content: {}
      .github/workflows/release-please.yaml:
        content: {}
EOF
  cat >"$CFG/repos.yaml" <<'EOF'
repos:
  - git: https://github.com/anthony-spruyt/ci-only.git
    groups: [github-ci]
  - git: https://github.com/anthony-spruyt/img.git
    groups: [image]
EOF
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/img .github/workflows/ci.yaml
anthony-spruyt/img .github/workflows/release-please.yaml" ]
}

@test "applies conditional groups after groups" {
  cat >"$CFG/groups.yaml" <<'EOF'
groups:
  megalinter:
    files:
      lint.sh:
        content: "x"
  trivy: {}
  go: {}
conditionalGroups:
  - when:
      anyOf: [megalinter, trivy]
    files:
      .trivyignore.yaml:
        createOnly: true
        content: {}
  - when:
      allOf: [megalinter]
      noneOf: [go]
    files:
      .pre-commit-config.yaml:
        content: {}
EOF
  cat >"$CFG/repos.yaml" <<'EOF'
repos:
  - git: https://github.com/anthony-spruyt/plain.git
    groups: [megalinter]
  - git: https://github.com/anthony-spruyt/gopher.git
    groups: [megalinter, go]
EOF
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/gopher lint.sh
anthony-spruyt/plain .pre-commit-config.yaml
anthony-spruyt/plain lint.sh" ]
}

@test "honours repo-level false, createOnly and repo-only files" {
  cat >"$CFG/files.yaml" <<'EOF'
files:
  LICENSE:
    content: "MIT"
  .yamllint.yml:
    content: {}
EOF
  cat >"$CFG/repos.yaml" <<'EOF'
repos:
  - git: https://github.com/anthony-spruyt/a.git
    files:
      LICENSE: false
      .yamllint.yml:
        createOnly: true
      .mcp.json:
        content: {}
EOF
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/a .mcp.json" ]
}

@test "file false in a group removes the file" {
  cat >"$CFG/groups.yaml" <<'EOF'
groups:
  base:
    files:
      old.json:
        content: {}
  variant:
    extends: base
    files:
      old.json: false
      new.json:
        content: {}
EOF
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n    groups: [variant]\n' >"$CFG/repos.yaml"
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/a new.json" ]
}

@test "repo files inherit false keeps only the repo's own files" {
  printf 'files:\n  .editorconfig:\n    content: "root = true"\n' >"$CFG/files.yaml"
  cat >"$CFG/repos.yaml" <<'EOF'
repos:
  - git: https://github.com/anthony-spruyt/a.git
    files:
      inherit: false
      .mcp.json:
        content: {}
EOF
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/a .mcp.json" ]
}

@test "skips repo-operator, which bumps the templates itself" {
  printf 'files:\n  .editorconfig:\n    content: "root = true"\n' >"$CFG/files.yaml"
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/repo-operator.git\n' >"$CFG/repos.yaml"
  run disabled_files
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "expands a list of git URLs" {
  printf 'files:\n  .editorconfig:\n    content: "root = true"\n' >"$CFG/files.yaml"
  cat >"$CFG/repos.yaml" <<'EOF'
repos:
  - git:
      - https://github.com/anthony-spruyt/b.git
      - https://github.com/anthony-spruyt/a
EOF
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/a .editorconfig
anthony-spruyt/b .editorconfig" ]
}

@test "rejects a file name that is a glob pattern" {
  printf 'files:\n  "*.yaml":\n    content: {}\n' >"$CFG/files.yaml"
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n' >"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -ne 0 ]
}

@test "fails on an unknown group" {
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n    groups: [nope]\n' >"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -ne 0 ]
}

@test "rejects a git URL it cannot turn into a repo name" {
  printf 'files:\n  .editorconfig:\n    content: "root = true"\n' >"$CFG/files.yaml"
  printf 'repos:\n  - git: git@github.com:anthony-spruyt/a.git\n' >"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -ne 0 ]
}

@test "reads config fragments in subdirectories" {
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n' >"$CFG/repos.yaml"
  mkdir -p "$CFG/more"
  printf 'files:\n  .editorconfig:\n    content: "root = true"\n' >"$CFG/more/files.yaml"
  run disabled_files
  [ "$status" -eq 0 ]
  [ "$output" = "anthony-spruyt/a .editorconfig" ]
}

@test "rejects conditionalGroups split across files, whose order it does not mirror" {
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n' >"$CFG/repos.yaml"
  printf 'conditionalGroups: []\n' >"$CFG/a.yaml"
  mkdir -p "$CFG/more"
  printf 'conditionalGroups: []\n' >"$CFG/more/cg.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -ne 0 ]
}

@test "prints nothing when a fragment fails to parse" {
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/a.git\n' >"$CFG/repos.yaml"
  printf 'files: [unclosed\n' >"$CFG/files.yaml"
  run --separate-stderr "$SCRIPT" "$CFG"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "fails when the config directory is missing" {
  run "$SCRIPT" "$CFG/nope"
  [ "$status" -ne 0 ]
}
