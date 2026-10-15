#!/usr/bin/env bats
#
# The claude group syncs a generic PR template to every repo in it.

SRC="${BATS_TEST_DIRNAME}/../src"
FILE=".github/pull_request_template.md"

@test "the claude group syncs the PR template from its template file" {
  run yq -r ".groups.claude.files.\"${FILE}\".content" "${SRC}/groups.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = "@templates/${FILE}" ]
  [ -f "${SRC}/templates/${FILE}" ]
}

@test "the PR template is a normal synced file, not createOnly" {
  run yq -r ".groups.claude.files.\"${FILE}\".createOnly // false" "${SRC}/groups.yaml"
  [ "${status}" -eq 0 ]
  [ "${output}" = "false" ]
}

@test "the PR template has no brace-dollar reference, which xfg would substitute on sync" {
  # shellcheck disable=SC2016
  run grep -c '[^$]\${' "${SRC}/templates/${FILE}"
  [ "${output}" = "0" ]
}
