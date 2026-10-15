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

FORMS_DIR=".github/ISSUE_TEMPLATE"
FORMS="bug_report feature_request chore docs config"
TITLED="bug_report feature_request chore docs infra"

@test "the claude group syncs every issue form from its template file" {
  for form in ${FORMS}; do
    run yq -r ".groups.claude.files.\"${FORMS_DIR}/${form}.yml\".content" "${SRC}/groups.yaml"
    [ "${status}" -eq 0 ]
    [ "${output}" = "@templates/${FORMS_DIR}/${form}.yml" ]
    [ -f "${SRC}/templates/${FORMS_DIR}/${form}.yml" ]
    run yq -r ".groups.claude.files.\"${FORMS_DIR}/${form}.yml\".createOnly // false" "${SRC}/groups.yaml"
    [ "${output}" = "false" ]
  done
}

@test "the issue forms hold no brace-dollar reference, which xfg would substitute on sync" {
  for form in ${FORMS}; do
    f="${SRC}/templates/${FORMS_DIR}/${form}.yml"
    [ -f "${f}" ]
    # shellcheck disable=SC2016
    run grep -c '[^$]\${' "${f}"
    [ "${output}" = "0" ]
  done
}

@test "config.yml turns blank issues off" {
  run yq -r '.blank_issues_enabled' "${SRC}/templates/${FORMS_DIR}/config.yml"
  [ "${output}" = "false" ]
}

@test "each form title prefix is a type the PR title check accepts" {
  types="$(yq -r '.jobs.check.steps[] | select(.with.types) | .with.types' "${SRC}/templates/.github/workflows/pr-title.yaml")"
  for form in ${TITLED}; do
    f="${SRC}/templates/${FORMS_DIR}/${form}.yml"
    [ -f "${f}" ]
    run yq -r '.title' "${f}"
    [[ "${output}" =~ ^([a-z]+)\(scope\):\ $ ]]
    grep -qx "${BASH_REMATCH[1]}" <<<"${types}"
  done
}

@test "each form label is one the settings manage in every repo" {
  for form in ${TITLED}; do
    f="${SRC}/templates/${FORMS_DIR}/${form}.yml"
    [ -f "${f}" ]
    for label in $(yq -r '.labels[]' "${f}"); do
      run yq -r ".settings.labels.\"${label}\".color // \"\"" "${SRC}/settings.yaml"
      [ -n "${output}" ]
    done
  done
}

@test "the issue forms carry no homelab-only or public-repo-unsafe wording" {
  [ -f "${SRC}/templates/${FORMS_DIR}/bug_report.yml" ]
  run grep -rniE 'risk level|security|talos|ceph|k8s|kubectl|cluster' "${SRC}/templates/${FORMS_DIR}"/{bug_report,feature_request,chore,docs,config}.yml
  [ "${status}" -eq 1 ]
}

@test "every form that asks for logs tells the reporter to leave out secrets, IPs and domains" {
  for form in ${TITLED}; do
    f="${SRC}/templates/${FORMS_DIR}/${form}.yml"
    [ -f "${f}" ]
    if grep -qi 'logs' "${f}"; then
      grep -qi 'secrets' "${f}"
      grep -qi 'IPs' "${f}"
      grep -qi 'domains' "${f}"
    fi
  done
}

@test "spruyt-labs alone adds the infra form, with the chore prefix and the infra label" {
  run yq -r '.repos[] | select(.git | test("/spruyt-labs")) | .files."'"${FORMS_DIR}"'/infra.yml".content' "${SRC}/repos.yaml"
  [ "${output}" = "@templates/${FORMS_DIR}/infra.yml" ]
  run yq -r '[.repos[] | select(.files."'"${FORMS_DIR}"'/infra.yml")] | length' "${SRC}/repos.yaml"
  [ "${output}" = "1" ]
  run yq -r '.title, .labels[0]' "${SRC}/templates/${FORMS_DIR}/infra.yml"
  [ "${lines[0]}" = "chore(scope): " ]
  [ "${lines[1]}" = "infra" ]
  run yq -r '.. | select(tag == "!!str") | select(test("(?i)risk|security"))' "${SRC}/templates/${FORMS_DIR}/infra.yml"
  [ -z "${output}" ]
}

@test "the PR template hints at the issue reference in a comment, not a bare Ref line" {
  run grep -c '^Ref #' "${SRC}/templates/${FILE}"
  [ "${output}" = "0" ]
  grep -q '<!-- Ref #<issue>' "${SRC}/templates/${FILE}"
}
