#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  TEMPLATE="$SRC/templates/.github/workflows/pr-title.yaml"
  export ACTION="amannn/action-semantic-pull-request@48f256284bd46cdaab1048c3721360e808335d50"
  export CONTEXT="PR Title"
}

subject_pattern() {
  yq -r '.jobs.check.steps[] | select(.uses == env(ACTION)) | .with.subjectPattern' "$TEMPLATE"
}

@test "github-ci syncs pr-title.yaml from its template on every sync" {
  run yq -o=json -I0 '.groups["github-ci"].files[".github/workflows/pr-title.yaml"] | [.createOnly // false, .content, .schemaUrl, .header]' "$SRC/groups.yaml"
  [ "$output" = '[false,"@templates/.github/workflows/pr-title.yaml","https://raw.githubusercontent.com/SchemaStore/schemastore/master/src/schemas/json/github-workflow.json","See https://github.com/anthony-spruyt/repo-operator/blob/main/src/templates/.github/workflows/pr-title.yaml for template comments"]' ]
  run grep -rn 'pr-title.yaml' "$SRC/repos.yaml"
  [ "$status" -eq 1 ]
}

@test "pr-title.yaml runs only on pull_request into main, title edits included" {
  run yq -o=json -I0 '.on' "$TEMPLATE"
  [ "$output" = '{"pull_request":{"types":["opened","edited","synchronize","reopened"],"branches":["main"]}}' ]
  run grep -n 'pull_request_target' "$TEMPLATE"
  [ "$status" -eq 1 ]
}

@test "pr-title.yaml grants nothing at the top and only pull-requests: read to its one job" {
  run yq -o=json -I0 '[.permissions, (.jobs | keys), .jobs.check.permissions]' "$TEMPLATE"
  [ "$output" = '[{},["check"],{"pull-requests":"read"}]' ]
}

@test "the job's name is the required check context" {
  run yq -r '.jobs.check.name' "$TEMPLATE"
  [ "$output" = "$CONTEXT" ]
}

@test "pr-title.yaml skips Mergify merge-queue PRs with the same condition as _sonar-new-issues.yaml" {
  want=$(yq -r '.jobs.check.if' "$REPO_ROOT/.github/workflows/_sonar-new-issues.yaml")
  run yq -r '.jobs.check.if' "$TEMPLATE"
  [ "$(tr -s ' \n' ' ' <<<"$output")" = "$(tr -s ' \n' ' ' <<<"$want")" ]
}

@test "pr-title.yaml hardens the runner with egress block, then runs the pinned action, with no checkout" {
  harden=$(yq -r '.jobs.check.steps[0].uses' "$REPO_ROOT/.github/workflows/_sonar-new-issues.yaml")
  run yq -o=json -I0 '[.jobs.check.steps[].uses]' "$TEMPLATE"
  [ "$output" = "$(jq -cn --arg h "$harden" --arg a "$ACTION" '[$h, $a]')" ]
  run yq -o=json -I0 '.jobs.check.steps[0].with | [.["egress-policy"], .["disable-sudo-and-containers"], (.["allowed-endpoints"] | split(" "))]' "$TEMPLATE"
  [ "$output" = '["block",true,["api.github.com:443","results-receiver.actions.githubusercontent.com:443"]]' ]
  run grep -n 'actions/checkout' "$TEMPLATE"
  [ "$status" -eq 1 ]
}

@test "the action pin is commented with its tag so Renovate keeps it current" {
  run grep -cF "uses: \"$ACTION\" # v6.1.1" "$TEMPLATE"
  [ "$output" = "1" ]
}

@test "the action reads the PR with the job's GITHUB_TOKEN and checks Conventional Commits types, any scope, no WIP or single-commit check" {
  run yq -o=json -I0 '.jobs.check.steps[1] | [.env, (.with | del(.subjectPattern, .subjectPatternError) | .types |= (split("\n") | map(select(. != ""))))]' "$TEMPLATE"
  [ "$output" = '[{"GITHUB_TOKEN":"${{ secrets.GITHUB_TOKEN }}"},{"types":["feat","fix","docs","style","refactor","perf","test","build","ci","chore","revert"],"requireScope":false,"validateSingleCommit":false,"wip":false}]' ]
  run yq -o=json -I0 '.jobs.check.steps[1].with | has("headerPattern") or has("scopes") or has("disallowScopes")' "$TEMPLATE"
  [ "$output" = "false" ]
}

@test "the subject pattern rejects a subject that starts with an uppercase letter, and says so" {
  pattern=$(subject_pattern)
  [ "$pattern" = '^(?![A-Z]).+$' ]
  for ok in "add a check" "bump x to v2" "1.2.3 release" "\`ci.yaml\` runs sonar"; do
    printf '%s\n' "$ok" | grep -qP "$pattern" || {
      echo "rejected: $ok"
      return 1
    }
  done
  for bad in "Add a check" "Bump x" ""; do
    if printf '%s\n' "$bad" | grep -qP "$pattern"; then
      echo "accepted: $bad"
      return 1
    fi
  done
  run yq -r '.jobs.check.steps[1].with.subjectPatternError' "$TEMPLATE"
  [[ "$output" == *'{subject}'* ]]
  [[ "$output" == *lowercase* ]]
}

@test "every pr-rules required_status_checks rule in groups.yaml requires the PR title check" {
  run yq -r '[.conditionalGroups[] | .settings.rulesets["pr-rules"].rules["$values"][]? | select(.type == "required_status_checks") | .parameters.requiredStatusChecks | map(.context) | any_c(. == env(CONTEXT))] | (length > 0 and all)' "$SRC/groups.yaml"
  [ "$output" = "true" ]
}

@test "every pr-rules entry that requires summary / Check Results also requires the PR title check" {
  run yq -r '[.conditionalGroups[] | .settings.rulesets["pr-rules"].rules["$values"][]? | select(.type == "required_status_checks") | .parameters.requiredStatusChecks | map(.context) | select(any_c(. == "summary / Check Results")) | select(any_c(. == env(CONTEXT)) | not)] | length' "$SRC/groups.yaml"
  [ "$output" = "0" ]
  run yq -r '[.conditionalGroups[] | .settings.rulesets["pr-rules"].rules["$values"][]? | select(.type == "required_status_checks")] | length' "$SRC/groups.yaml"
  [ "$output" -ge 4 ]
}

@test "repo-operator's own pr-title.yaml matches the template xfg syncs" {
  [ -f "$TEMPLATE" ]
  [ -f "$REPO_ROOT/.github/workflows/pr-title.yaml" ]
  [ "$(yq -o=json '.' "$REPO_ROOT/.github/workflows/pr-title.yaml" | jq -cS .)" = "$(yq -o=json '.' "$TEMPLATE" | jq -cS .)" ]
}

@test "pr-title.yaml passes actionlint with the synced config" {
  target="$BATS_TEST_TMPDIR/target"
  mkdir -p "$target/.github/workflows"
  cp "$SRC/templates/.github/actionlint.yaml" "$target/.github/actionlint.yaml"
  cp "$TEMPLATE" "$target/.github/workflows/"
  git init -q "$target"
  cd "$target"
  run actionlint -no-color
  echo "$output"
  [ "$status" -eq 0 ]
}
