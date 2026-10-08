#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  TEMPLATE="$SRC/templates/.mergify.yml"
  PURE_RENOVATE='[
    "author = renovate[bot]",
    "-commits[*].author~=^(?!renovate\\[bot\\]$)",
    "-commits[*].email_author~=^(?!29139614\\+renovate\\[bot\\]@users\\.noreply\\.github\\.com$)",
    "-commits[*].email_committer~=^(?!noreply@github\\.com$)",
    "#commits-unverified = 0"
  ]'
  OWNER_ONLY='[
    "author = anthony-spruyt",
    "-commits[*].email_author~=^(?!(aspruyt@hotmail\\.co\\.uk|99536297\\+anthony-spruyt@users\\.noreply\\.github\\.com)$)",
    "-commits[*].email_committer~=^(?!(aspruyt@hotmail\\.co\\.uk|99536297\\+anthony-spruyt@users\\.noreply\\.github\\.com|noreply@github\\.com)$)",
    "#commits-unverified = 0"
  ]'
}

# Renders the template the way xfg does for one repo: substitution runs on parsed strings, and per-repo vars win.
render() {
  local repo="$1" extra
  extra=$(yq -r ".repos[] | select(.git == \"https://github.com/anthony-spruyt/$repo.git\") | .files[\".mergify.yml\"].vars.gateFilesExtra // \"\"" "$SRC/repos.yaml")
  if [ -z "$extra" ]; then
    extra=$(yq -r '.groups.mergify.files[".mergify.yml"].vars.gateFilesExtra' "$SRC/groups.yaml")
  fi
  yq -o=json -I0 '.' "$TEMPLATE" | jq -c --arg x "$extra" 'walk(if type == "string" then gsub("\\$\\{xfg:gateFilesExtra\\}"; $x) else . end)'
}

gate_regex() {
  render "$1" | jq -r '.merge_protections[] | select(.name == "gate-files") | .if[] | select(startswith("files~=")) | ltrimstr("files~=")'
}

gate_matches() {
  python3 -c 'import re, sys; print("yes" if re.search(sys.argv[1], sys.argv[2]) else "no")' "$(gate_regex "$1")" "$2"
}

gated() {
  [ "$(gate_matches "$1" "$2")" = "yes" ]
}

not_gated() {
  [ "$(gate_matches "$1" "$2")" = "no" ]
}

@test "the template has exactly the approval, outsider and gate-files protections" {
  run yq -o=json -I0 '[.merge_protections[].name]' "$TEMPLATE"
  [ "$output" = '["approval","outsider","gate-files"]' ]
}

@test "every PR on main needs one approval" {
  run yq -o=json -I0 '.merge_protections[] | select(.name == "approval") | [.if, .success_conditions]' "$TEMPLATE"
  [ "$output" = '[["base = main"],["#approved-reviews-by >= 1"]]' ]
}

@test "a PR from outside the trusted list needs the owner" {
  run yq -o=json -I0 '.merge_protections[] | select(.name == "outsider") | [.if, .success_conditions]' "$TEMPLATE"
  [ "$output" = '[["base = main","-author = anthony-spruyt","-author = spruyt-labs-bot","-author = skynet-rw[bot]","-author = skynet-r[bot]","-author = renovate[bot]","-author = repo-operator-release-bot[bot]","-author = repo-operator[bot]"],["approved-reviews-by = anthony-spruyt"]]' ]
}

@test "a gate-file change needs the owner unless it is a pure Renovate PR or wholly the owner's" {
  run yq -o=json -I0 '.merge_protections[] | select(.name == "gate-files") | .success_conditions' "$TEMPLATE"
  [ "$output" = "$(jq -c --argjson pure "$PURE_RENOVATE" --argjson owner "$OWNER_ONLY" -n '[{"or": ["approved-reviews-by = anthony-spruyt", {"and": $pure}, {"and": $owner}]}]')" ]
}

owner_skip() {
  yq -o=json -I0 '.merge_protections[] | select(.name == "gate-files") | .success_conditions[0].or[2].and[]' "$TEMPLATE" | jq -r '.'
}

# Mimics Mergify: a "-commits[*].x~=re" condition fails when any commit's field matches re.
no_commit_matches() {
  local field="$1" value
  shift
  local re
  re=$(owner_skip | grep -F -- "-commits[*].$field~=" | sed "s/^-commits\\[\\*\\]\\.$field~=//")
  [ -n "$re" ] || return 2
  for value in "$@"; do
    python3 -c 'import re, sys; sys.exit(1 if re.search(sys.argv[1], sys.argv[2]) else 0)' "$re" "$value" || return 1
  done
}

@test "the owner skip accepts the owner's local and web-flow commits" {
  no_commit_matches email_author "aspruyt@hotmail.co.uk" "99536297+anthony-spruyt@users.noreply.github.com"
  no_commit_matches email_committer "aspruyt@hotmail.co.uk" "99536297+anthony-spruyt@users.noreply.github.com" "noreply@github.com"
}

@test "the owner skip rejects agent and bot commits" {
  for email in "spruyt-labs-bot@users.noreply.github.com" "aspruyt@hotmail.co.uk.evil" "xaspruyt@hotmail.co.uk" "ASPRUYT@hotmail.co.uk" "29139614+renovate[bot]@users.noreply.github.com"; do
    run no_commit_matches email_author "$email"
    [ "$status" -eq 1 ]
    run no_commit_matches email_committer "$email"
    [ "$status" -eq 1 ]
  done
  run no_commit_matches email_author "noreply@github.com"
  [ "$status" -eq 1 ]
}

@test "gate files are .github/ and .mergify.yml everywhere" {
  for repo in esphome spruyt-labs Chromance SunGather xfg; do
    gated "$repo" ".github/workflows/ci.yaml"
    gated "$repo" ".github/CODEOWNERS"
    gated "$repo" ".mergify.yml"
    not_gated "$repo" ".mergify.yml.bak"
    not_gated "$repo" "docs/.github/x"
  done
}

@test "the root Renovate config is a gate file everywhere" {
  for repo in esphome spruyt-labs Chromance SunGather xfg litellm-middleware repo-operator; do
    gated "$repo" "renovate.json"
    gated "$repo" "renovate-overrides.json5"
    not_gated "$repo" "renovate.json.bak"
    not_gated "$repo" "docs/renovate.json"
  done
}

@test "src/ is a gate path only in repo-operator" {
  gated repo-operator "src/groups.yaml"
  for repo in Chromance SunGather litellm-middleware spruyt-labs; do
    not_gated "$repo" "src/main.py"
  done
}

@test "litellm-middleware gates its release gate script" {
  gated litellm-middleware "scripts/release_gate.py"
  gated litellm-middleware "tests/unit/scripts/test_release_gate.py"
  not_gated litellm-middleware "scripts/release_gate.pyc"
  not_gated litellm-middleware "tests/unit/scripts/test_release_gate.pyc"
  not_gated litellm-middleware "tests/unit/scripts/test_other.py"
  not_gated litellm-middleware "scripts/other.py"
  not_gated repo-operator "scripts/release_gate.py"
}

@test "traefik-api-key-auth gates its image test script" {
  gated traefik-api-key-auth "scripts/test-image.sh"
  not_gated traefik-api-key-auth "scripts/test-image.sh.bak"
  not_gated traefik-api-key-auth "scripts/other.sh"
  not_gated traefik-api-key-auth "docs/scripts/test-image.sh"
  not_gated repo-operator "scripts/test-image.sh"
}

@test "only repo-operator, litellm-middleware and traefik-api-key-auth widen the gate files" {
  run yq -o=json -I0 '[.repos[] | select(.files[".mergify.yml"].vars.gateFilesExtra != null) | {(.git): .files[".mergify.yml"].vars.gateFilesExtra}] | .[] as $e ireduce ({}; . * $e)' "$SRC/repos.yaml"
  [ "$output" = '{"https://github.com/anthony-spruyt/litellm-middleware.git":"scripts/release_gate\\.py$|tests/unit/scripts/test_release_gate\\.py$|","https://github.com/anthony-spruyt/repo-operator.git":"src/|","https://github.com/anthony-spruyt/traefik-api-key-auth.git":"scripts/test-image\\.sh$|"}' ]
  run yq -o=json -I0 '.groups.mergify.files[".mergify.yml"] | [.template, .vars.gateFilesExtra]' "$SRC/groups.yaml"
  [ "$output" = '[true,""]' ]
}

@test "Mergify approves only a pure release-please PR in the Monday window" {
  run yq -o=json -I0 '[.pull_request_rules[] | select(.actions.review != null) | .name]' "$TEMPLATE"
  [ "$output" = '["release"]' ]
  run yq -o=json -I0 '.pull_request_rules[] | select(.name == "release") | [.conditions, .actions]' "$TEMPLATE"
  [ "$output" = '[["base = main","label=autorelease: pending","author = repo-operator-release-bot[bot]","head~=^release-please--branches--","files~=^\\.release-please-manifest\\.json$","-commits[*].author~=^(?!repo-operator-release-bot\\[bot\\]$)","-commits[*].email_author~=^(?!321986956\\+repo-operator-release-bot\\[bot\\]@users\\.noreply\\.github\\.com$)","-commits[*].email_committer~=^(?!noreply@github\\.com$)","#commits-unverified = 0","schedule = Mon-Mon 09:00-12:00[Australia/Melbourne]"],{"review":{"type":"APPROVE"}}]' ]
}

@test "the revert, emergency, priority, owner-review and refresh rules are gone" {
  run yq 'has("priority_rules")' "$TEMPLATE"
  [ "$output" = "false" ]
  run grep -cE 'agent/revert|emergency/merge|megalinter-refresh|request_reviews' "$TEMPLATE"
  [ "$output" = "0" ]
  run yq -o=json -I0 '[.pull_request_rules[].name]' "$TEMPLATE"
  [ "$output" = '["cleanup labels on close","release"]' ]
}

@test "the merge queue, blocked label and Monday window are kept" {
  run yq -o=json -I0 '.queue_rules[0] | [.name, .merge_method, .merge_conditions]' "$TEMPLATE"
  [ "$output" = '["default","squash",["-draft","check-success = summary / Check Results"]]' ]
  run yq -o=json -I0 '.merge_protections_settings.auto_merge_conditions' "$TEMPLATE"
  [ "$output" = '[{"or":["-label=autorelease: pending","schedule = Mon-Mon 09:00-12:00[Australia/Melbourne]"]},"-label = blocked"]' ]
}

@test "a repo that replaces queue_rules keeps the template's rule and only adds checks" {
  template=$(yq -o=json -I0 '.queue_rules' "$TEMPLATE")
  while IFS= read -r overlay; do
    [ "$(jq -c 'map(del(.merge_conditions))' <<<"$overlay")" = "$(jq -c 'map(del(.merge_conditions))' <<<"$template")" ]
    jq -e --argjson t "$template" '.[0].merge_conditions[:($t[0].merge_conditions | length)] == $t[0].merge_conditions' <<<"$overlay"
  done < <(yq -o=json -I0 '.repos[] | .files[".mergify.yml"].content.queue_rules | select(. != null)' "$SRC/repos.yaml")
}

@test "Chromance's merge queue also waits for repo-summary" {
  run yq -o=json -I0 '.repos[] | select(.git == "https://github.com/anthony-spruyt/Chromance.git") | .files[".mergify.yml"].content.queue_rules[0].merge_conditions' "$SRC/repos.yaml"
  [ "$output" = '["-draft","check-success = summary / Check Results","check-success = repo-summary / Check Results"]' ]
}

@test "the agent/revert and emergency/merge labels stay defined" {
  run yq -r '.groups.mergify.settings.labels | [has("agent/revert"), has("emergency/merge")] | all' "$SRC/groups.yaml"
  [ "$output" = "true" ]
}

@test "pr-rules needs one approval from someone other than the last pusher" {
  run yq -o=json -I0 '.groups["protected-main-branch"].settings.rulesets["pr-rules"].rules["$values"][] | select(.type == "pull_request") | .parameters' "$SRC/groups.yaml"
  [ "$output" = '{"allowedMergeMethods":["squash"],"dismissStaleReviewsOnPush":true,"requireCodeOwnerReview":false,"requireExtraApprovalForUnattributedChanges":true,"requiredApprovingReviewCount":1,"requiredReviewers":[],"requiredReviewThreadResolution":true,"requireLastPushApproval":true}' ]
}

@test "no repo or group syncs CODEOWNERS" {
  run grep -rl CODEOWNERS "$SRC"
  [ -z "$output" ]
}

@test "repo-operator's own .mergify.yml is the template rendered for it" {
  diff <(render repo-operator | jq -S .) <(yq -o=json '.' "$REPO_ROOT/.mergify.yml" | jq -S .)
}
