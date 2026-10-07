#!/usr/bin/env bash
# Fails when SonarCloud reports any unresolved issue (or hotspot to review) on a pull request,
# after waiting until SonarCloud has analysed the pull request's head commit. See docs/ci.md.
set -euo pipefail

readonly SONAR_URL="https://sonarcloud.io"
readonly PAGE_SIZE=500
readonly MAX_ATTEMPTS=5

project="${SONAR_PROJECT_KEY:-}"
pr="${PR_NUMBER:-}"
head_sha="${HEAD_SHA:-}"
min_severity="${MIN_SEVERITY:-INFO}"
include_hotspots="${INCLUDE_HOTSPOTS:-true}"
timeout="${TIMEOUT_SECONDS:-900}"
interval="${POLL_INTERVAL_SECONDS:-15}"

# Annotation data escaping, plus ##[ which the runner parses anywhere in a line (legacy commands)
readonly JQ_ESC='
def defang: gsub("##\\["; "#-#[");
def esc_data: defang | gsub("%"; "%25") | gsub("\r"; "%0D") | gsub("\n"; "%0A");
def esc_prop: esc_data | gsub(":"; "%3A") | gsub(","; "%2C");
def plain: defang | gsub("[\u0000-\u001f\u007f]"; " ");
'

die() {
  local message="$1"
  jq -nr --arg m "$message" "$JQ_ESC"' "::error::\($m | esc_data)"' >&2
  exit 1
}

validate() {
  [[ "$project" =~ ^[A-Za-z0-9_.:-]{1,400}$ ]] || die "Invalid SonarCloud project key"
  [[ "$pr" =~ ^[1-9][0-9]{0,9}$ ]] || die "Invalid pull request number"
  [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || die "Invalid head SHA"
  [[ "$min_severity" =~ ^(INFO|LOW|MEDIUM|HIGH|BLOCKER)$ ]] || die "min-severity must be INFO, LOW, MEDIUM, HIGH or BLOCKER"
  [[ "$include_hotspots" =~ ^(true|false)$ ]] || die "include-hotspots must be true or false"
  [[ "$timeout" =~ ^(0|[1-9][0-9]{0,4})$ ]] || die "Invalid timeout"
  [[ "$interval" =~ ^(0|[1-9][0-9]{0,3})$ ]] || die "Invalid poll interval"
  return 0
}

# sonar_get <out-file> <api-path> <name=value>... - retries network errors, 429 and 5xx
sonar_get() {
  local out="$1" path="$2" code attempt
  shift 2
  local args=() p
  for p in "$@"; do args+=(--data-urlencode "$p"); done

  for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    code=$(curl -sS -G --proto =https --max-time 30 -o "$out" -w '%{http_code}' \
      "${SONAR_URL}/api/${path}" "${args[@]}") || code="000"
    case "$code" in
    200) break ;;
    000 | 429 | 5??)
      echo "SonarCloud ${path} returned HTTP ${code} (attempt ${attempt}/${MAX_ATTEMPTS})"
      sleep "$interval"
      ;;
    *)
      local msg
      msg=$(jq -r '[.errors[]?.msg] | join("; ")' "$out" 2>/dev/null || true)
      die "SonarCloud ${path} returned HTTP ${code}: ${msg:-no error message}"
      ;;
    esac
  done
  [[ "$code" == "200" ]] || die "SonarCloud ${path} kept failing (last HTTP ${code})"
  return 0
}

wait_for_analysis() {
  local analysed last
  while :; do
    sonar_get "$prs_raw" project_pull_requests/list "project=${project}"
    jq --arg pr "$pr" 'first(.pullRequests[]? | select(.key == $pr)) // {}' "$prs_raw" >"$pr_json"
    analysed=$(jq -r '.commit.sha // empty | strings | select(test("^[0-9a-f]{40}$"))' "$pr_json")
    if [[ "$analysed" == "$head_sha" ]]; then
      expected=$(jq '[.status.bugs, .status.vulnerabilities, .status.codeSmells] | if all(type == "number") then add else empty end' "$pr_json")
      [[ "$expected" =~ ^[0-9]+$ ]] || die "SonarCloud's analysis of PR #${pr} has no issue counts; re-run this job."
      echo "SonarCloud has analysed ${head_sha}"
      return 0
    fi

    last="no analysis of PR #${pr} yet"
    [[ -n "$analysed" ]] && last="last analysed commit is ${analysed}"
    if ((SECONDS >= deadline)); then
      die "SonarCloud has not analysed ${head_sha} within ${timeout}s (${last}). Check the SonarCloud Code Analysis check on this PR, then re-run this job."
    fi
    echo "Waiting for SonarCloud to analyse ${head_sha} (${last})"
    sleep "$interval"
  done
  return 0
}

# The issue index can trail the analysis, so retry until it holds every issue the analysis counted
fetch_issues() {
  local total
  while :; do
    sonar_get "$issues_raw" issues/search "componentKeys=${project}" "$pr_param" \
      "resolved=false" "ps=${PAGE_SIZE}"
    total=$(jq '[.total, .paging.total, 0] | map(numbers) | max' "$issues_raw")
    if ((total > PAGE_SIZE)) || ! jq -e '(.issues | length) >= ([.total, .paging.total, 0] | map(numbers) | max)' "$issues_raw" >/dev/null; then
      die "SonarCloud reports ${total} open issues, more than one page (${PAGE_SIZE}); fix or accept some, then re-run"
    fi
    ((total >= expected)) && break
    if ((SECONDS >= deadline)); then
      die "SonarCloud counts ${expected} open issue(s) on PR #${pr} but the issue search returned ${total}; re-run this job."
    fi
    echo "Waiting for the SonarCloud issue search to catch up (${total} of ${expected} issues)"
    sleep "$interval"
  done

  # Issues with no impact severity count at any threshold, so the check fails closed
  jq --arg min "$min_severity" --arg key "$project" '
    {"INFO": 0, "LOW": 1, "MEDIUM": 2, "HIGH": 3, "BLOCKER": 4} as $rank
    | [.issues[]
      | select(.resolution == null and ((.issueStatus // "OPEN") | IN("ACCEPTED", "FALSE_POSITIVE", "FIXED", "CLOSED") | not))
      | select(([.impacts[]?.severity | $rank[.] // 4] | max // 4) >= $rank[$min])
      | {key, rule, message, line,
         path: ((.component // "") | if startswith($key + ":") then ltrimstr($key + ":") else sub("^[^:]*:"; "") end)}]
  ' "$issues_raw" >"$found_issues"
  return 0
}

fetch_hotspots() {
  if [[ "$include_hotspots" != "true" ]]; then
    echo '[]' >"$found_hotspots"
    return 0
  fi
  local expected_hotspots total
  sonar_get "$measures_raw" measures/component "component=${project}" "$pr_param" \
    "metricKeys=security_hotspots_to_review_status"
  expected_hotspots=$(jq -r 'first(.component.measures[]? | select(.metric == "security_hotspots_to_review_status") | .value) // empty' "$measures_raw")
  [[ "$expected_hotspots" =~ ^[0-9]+$ ]] || die "SonarCloud returned no security hotspot count for PR #${pr}; re-run this job."

  # The hotspot index trails the analysis like the issue index
  while :; do
    sonar_get "$hotspots_raw" hotspots/search "projectKey=${project}" "$pr_param" \
      "status=TO_REVIEW" "ps=${PAGE_SIZE}"
    total=$(jq '[.paging.total, 0] | map(numbers) | max' "$hotspots_raw")
    if ((total > PAGE_SIZE)) || ! jq -e '(.hotspots | length) >= ([.paging.total, 0] | map(numbers) | max)' "$hotspots_raw" >/dev/null; then
      die "SonarCloud reports ${total} security hotspots to review, more than one page (${PAGE_SIZE}); review some, then re-run"
    fi
    ((total >= expected_hotspots)) && break
    if ((SECONDS >= deadline)); then
      die "SonarCloud counts ${expected_hotspots} security hotspot(s) to review on PR #${pr} but the hotspot search returned ${total}; re-run this job."
    fi
    echo "Waiting for the SonarCloud hotspot search to catch up (${total} of ${expected_hotspots} hotspots)"
    sleep "$interval"
  done
  jq --arg key "$project" '
    [.hotspots[]
      | select((.status // "TO_REVIEW") == "TO_REVIEW")
      | {key, rule: .ruleKey, message, line,
         path: ((.component // "") | if startswith($key + ":") then ltrimstr($key + ":") else sub("^[^:]*:"; "") end)}]
  ' "$hotspots_raw" >"$found_hotspots"
  return 0
}

# report <found-file> <noun> <link-prefix>
report() {
  local found="$1" noun="$2" link="$3"
  jq -r --arg noun "$noun" --arg link "$link" "$JQ_ESC"'
    def loc: (.path // "") + (if (.line | type) == "number" then ":\(.line)" else "" end);
    if length == 0 then empty else
      (.[] | "::error file=\(.path // "" | esc_prop)"
        + (if (.line | type) == "number" then ",line=\(.line)" else "" end)
        + ",title=\(.rule // "sonar" | tostring | esc_prop)::\(.message // "" | tostring | esc_data)"),
      "\(length) \($noun):",
      (.[] | "  - \(.rule // "?" | tostring | plain) \(loc | plain) \(.message // "" | tostring | plain)"
        + (if (.key | type) == "string" then " \($link)\(.key | @uri)" else "" end))
    end
  ' "$found"
  return 0
}

summarise() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0
  local issues="$1" hotspots="$2"
  {
    echo "## SonarCloud new issues"
    echo ""
    echo "Analysed commit \`${head_sha}\`: ${issues} new issue(s), ${hotspots} security hotspot(s) to review, at min-severity ${min_severity}."
    echo ""
    jq -rs 'add | map(.rule | strings | select(test("^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$")))
      | group_by(.) | map("- `\(.[0])`: \(length)") | .[]' \
      "$found_issues" "$found_hotspots"
    echo ""
    echo "[Open in SonarCloud](${new_code_url})"
  } >>"$GITHUB_STEP_SUMMARY"
  return 0
}

main() {
  validate
  deadline=$((SECONDS + timeout))
  expected=0
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  prs_raw="$tmp/prs.json"
  pr_json="$tmp/pr.json"
  issues_raw="$tmp/issues.json"
  hotspots_raw="$tmp/hotspots.json"
  measures_raw="$tmp/measures.json"
  pr_param="pullRequest=${pr}"
  found_issues="$tmp/found-issues.json"
  found_hotspots="$tmp/found-hotspots.json"
  new_code_url="${SONAR_URL}/summary/new_code?id=${project}&pullRequest=${pr}"

  wait_for_analysis
  fetch_issues
  fetch_hotspots

  local issues hotspots
  issues=$(jq length "$found_issues")
  hotspots=$(jq length "$found_hotspots")

  report "$found_issues" "new SonarCloud issue(s) on PR #${pr}" \
    "${SONAR_URL}/project/issues?id=${project}&pullRequest=${pr}&open="
  report "$found_hotspots" "security hotspot(s) to review on PR #${pr}" \
    "${SONAR_URL}/project/security_hotspots?id=${project}&pullRequest=${pr}&hotspots="
  summarise "$issues" "$hotspots"

  if ((issues + hotspots > 0)); then
    echo "Fix them, or mark them Accepted or False positive in SonarCloud, then re-run this job." >&2
    echo "$new_code_url" >&2
    exit 1
  fi
  echo "No new SonarCloud issues on PR #${pr}"
  return 0
}

main
