#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="$REPO_ROOT/.github/scripts/devcontainer-image.sh"
  DIGEST="sha256:$(printf 'a%.0s' {1..64})"
}

dockerfile() {
  printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/Dockerfile"
  echo "$BATS_TEST_TMPDIR/Dockerfile"
}

@test "resolves the registry ARG in the FROM line to the image the devcontainer pulls" {
  run --separate-stderr "$SCRIPT" "$(dockerfile \
    '# comment' \
    'ARG BASE_REGISTRY=docker.io' \
    "FROM \$BASE_REGISTRY/org/img:1.2.3@$DIGEST" \
    'USER 1001')"
  [ "$status" -eq 0 ]
  [ "$output" = "docker.io/org/img:1.2.3@$DIGEST" ]
}

@test "resolves the braced form and ignores a build flag and a stage name" {
  run --separate-stderr "$SCRIPT" "$(dockerfile \
    'ARG BASE_REGISTRY="docker.io"' \
    "FROM --platform=linux/amd64 \${BASE_REGISTRY}/org/img:1.2.3 AS base")"
  [ "$status" -eq 0 ]
  [ "$output" = "docker.io/org/img:1.2.3" ]
}

@test "takes the first FROM only" {
  run --separate-stderr "$SCRIPT" "$(dockerfile \
    'FROM docker.io/org/first:1' \
    'FROM docker.io/org/second:2')"
  [ "$status" -eq 0 ]
  [ "$output" = "docker.io/org/first:1" ]
}

@test "prints a FROM line with no variable as it is" {
  run --separate-stderr "$SCRIPT" "$(dockerfile 'FROM ghcr.io/org/img:3')"
  [ "$status" -eq 0 ]
  [ "$output" = "ghcr.io/org/img:3" ]
}

@test "fails when the FROM line names an ARG the file never sets" {
  run --separate-stderr "$SCRIPT" "$(dockerfile "FROM \$BASE_REGISTRY/org/img:1")"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"BASE_REGISTRY"* ]]
}

@test "fails on a variable with a default or no closing brace, rather than printing a mangled image" {
  for from in "FROM \${BASE_REGISTRY:-docker.io}/org/img:1" "FROM \${BASE_REGISTRY/org/img:1"; do
    run --separate-stderr "$SCRIPT" "$(dockerfile 'ARG BASE_REGISTRY=docker.io' "$from")"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"\${BASE_REGISTRY"* ]]
  done
}

@test "fails on a brace left over after resolving" {
  run --separate-stderr "$SCRIPT" "$(dockerfile 'ARG BASE_REGISTRY=docker.io' "FROM \$BASE_REGISTRY}/org/img:1")"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"docker.io}/org/img:1"* ]]
}

@test "fails when there is no FROM line" {
  run --separate-stderr "$SCRIPT" "$(dockerfile 'ARG BASE_REGISTRY=docker.io' 'USER 1001')"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"FROM"* ]]
}

@test "fails without a readable Dockerfile" {
  for args in "$BATS_TEST_TMPDIR/missing" ""; do
    run --separate-stderr "$SCRIPT" ${args:+"$args"}
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Usage"* ]]
  done
}

@test "the devcontainer template resolves to a docker.io image pinned by tag and digest" {
  run --separate-stderr "$SCRIPT" "$REPO_ROOT/src/templates/.devcontainer/Dockerfile"
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^docker\.io/aspruyt/devcontainer-common:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$ ]]
}
