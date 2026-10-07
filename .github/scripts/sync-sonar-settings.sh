#!/usr/bin/env bash
# Syncs SonarQube Cloud project settings for the `sonar` group from .github/sonar-settings.yaml.
# Usage: sync-sonar-settings.sh [--apply] [--config FILE] [--repos FILE]
# Dry-run by default: reads public settings and prints the diff. --apply needs SONAR_TOKEN.
set -euo pipefail

readonly API="https://sonarcloud.io/api"
readonly OWNER="anthony-spruyt"
readonly CURL_OPTS=(--proto "=https" --max-time 30 --retry 3 -sS -w "%{http_code}")

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
config="$root/.github/sonar-settings.yaml"
repos_file="$root/src/repos.yaml"
apply=false

while (($#)); do
  case "$1" in
  --apply) apply=true && shift ;;
  --config) config="$2" && shift 2 ;;
  --repos) repos_file="$2" && shift 2 ;;
  *)
    echo "usage: $0 [--apply] [--config FILE] [--repos FILE]" >&2
    exit 2
    ;;
  esac
done

die() {
  echo "::error::$*" >&2
  exit 1
}

tmp="$(umask 077 && mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
auth_header="$tmp/auth"
if [[ "$apply" == true ]]; then
  [[ -n "${SONAR_TOKEN:-}" ]] || die "--apply needs SONAR_TOKEN"
  [[ "$SONAR_TOKEN" =~ ^[A-Za-z0-9_-]+$ ]] || die "SONAR_TOKEN has characters a SonarQube Cloud token never has"
  # A header file keeps the token out of argv, where any process on the runner could read it
  printf 'Authorization: Bearer %s\n' "$SONAR_TOKEN" >"$auth_header"
fi

# shellcheck disable=SC2016
readonly JQ_VALIDATE='
def setting_key: type == "string" and test("\\Asonar\\.[A-Za-z0-9_.-]+\\z");
def clean: type == "string" and length > 0 and (test("\\p{Cc}") | not);
def setting_value:
  clean
  or (type == "array" and length > 0 and all(.[]; clean))
  or (type == "array" and length > 0 and all(.[];
      type == "object" and length > 0 and all(to_entries[]; (.key | test("\\A[A-Za-z0-9_]+\\z")) and (.value | clean))));
def settings($where):
  if type != "object" then "\($where): must be a map of settings"
  else to_entries[]
    | if (.key | setting_key | not) then "\($where): setting key not allowed: \(.key | tojson)"
      elif (.value | setting_value | not) then "\($where): \(.key): must be a string, a list of strings or a list of string maps"
      else empty end
  end;
if type != "object" then "config must be a map"
else
  (keys[] | select(IN("defaults", "repos") | not) | "unknown top-level key: \(tojson)"),
  (.defaults // {} | settings("defaults")),
  (.repos // {} | if type != "object" then "repos: must be a map"
    else to_entries[]
      | if (.key | test("\\A[A-Za-z0-9_.-]+\\z") | not) then "repo name not allowed: \(.key | tojson)"
        elif (.key | IN($sonar[]) | not) then "repos.\(.key): not in the sonar group in src/repos.yaml"
        else .key as $k | (.value | settings("repos.\($k)")) end
    end)
end
'

# shellcheck disable=SC2016
readonly JQ_SONAR_REPOS='
[.repos[]? | select((.groups // []) | arrays | any(. == "sonar")) | .git | if type == "array" then .[] else . end]
| map(if type == "string" and test("\\Ahttps://github\\.com/" + $owner + "/[A-Za-z0-9_.-]+?(\\.git)?\\z")
      then capture("/(?<n>[A-Za-z0-9_.-]+?)(\\.git)?\\z").n
      else error("sonar repo URL not allowed: \(tojson)") end)
| unique
'

# shellcheck disable=SC2016
readonly JQ_DIFF='
def canon: walk(if type == "object" then to_entries | sort_by(.key) | from_entries else . end);
($current.settings // [] | map(select(.inherited != true) | {key: .key, value: (.fieldValues // .values // .value)}) | from_entries) as $cur
| to_entries[]
| if (.key | in($cur) | not) then "  + \(.key): \(.value | canon | tojson)"
  elif ($cur[.key] | canon) != (.value | canon) then "  ~ \(.key): \($cur[.key] | canon | tojson) -> \(.value | canon | tojson)"
  else empty end
'

[[ -f "$config" ]] || die "config not found: $config"
[[ -f "$repos_file" ]] || die "repos file not found: $repos_file"

# load_yaml <file>: prints the file as one line of JSON, failing unless it is exactly one document
load_yaml() {
  local json
  json="$(yq -o=json -I0 'explode(.)' "$1")" || die "$1: not valid YAML"
  [[ "$json" != *$'\n'* ]] || die "$1: must be exactly one YAML document"
  local dupes
  if ! dupes="$(yq '.. | select(tag == "!!map") | ((keys | length) - (keys | unique | length)) | select(. > 0)' "$1")" || [[ -n "$dupes" ]]; then
    die "$1: duplicate keys are not allowed"
  fi
  printf '%s\n' "$json"
}

repos_json="$(load_yaml "$repos_file")"
config_json="$(load_yaml "$config")"
if ! sonar_repos="$(jq -c --arg owner "$OWNER" "$JQ_SONAR_REPOS" <<<"$repos_json" 2>&1)"; then
  die "$repos_file: ${sonar_repos#jq: error (at <stdin>:*): }"
fi
validation="$(jq -r --argjson sonar "$sonar_repos" "$JQ_VALIDATE" <<<"$config_json")" || die "$config: validation failed"
mapfile -t violations < <(grep . <<<"$validation" || true)
if ((${#violations[@]})); then
  for v in "${violations[@]}"; do echo "::error::$config: $v" >&2; done
  exit 1
fi

# Prints a response body without control characters, so an API message can't start a workflow command
show_body() {
  jq -c '.errors // .' <<<"$1" 2>/dev/null || tr -d '\000-\037\177' <<<"$1" | head -c 500
}

# request <out-var> <curl args...> <url>: runs curl and fails unless the status is 2xx.
# The body goes to a file because curl truncates it per retry, while stdout would concatenate every attempt.
request() {
  local -n out="$1"
  shift
  local status
  status="$(curl -q "${CURL_OPTS[@]}" -o "$tmp/body" "$@")" || return 1
  out="$(cat "$tmp/body")"
  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    echo "::error::HTTP $status from ${*: -1}: $(show_body "$out")" >&2
    return 1
  fi
}

# fetch <out-var> <component> <keys>: reads settings and fails unless the body is one JSON object
fetch() {
  local -n settings="$1"
  request settings -G --data-urlencode "component=$2" --data-urlencode "keys=$3" "$API/settings/values" || return 1
  if ! jq -se 'length == 1 and (.[0] | type == "object")' >/dev/null 2>&1 <<<"$settings"; then
    echo "::error::$2: settings response is not one JSON object" >&2
    return 1
  fi
}

# plan <desired> <current>: prints one line per key that differs
plan() {
  jq -r --argjson current "$2" "$JQ_DIFF" <<<"$1"
}

post() {
  local component="$1" key="$2" value="$3" body args=()
  case "$(jq -r 'if type == "string" then "scalar" elif .[0] | type == "object" then "fields" else "list" end' <<<"$value")" in
  scalar) args+=(--data-urlencode "value=$(jq -r . <<<"$value")") ;;
  list) while IFS= read -r v; do args+=(--data-urlencode "values=$v"); done < <(jq -r '.[]' <<<"$value") ;;
  fields) while IFS= read -r v; do args+=(--data-urlencode "fieldValues=$v"); done < <(jq -c '.[]' <<<"$value") ;;
  esac
  request body -X POST -H "@$auth_header" --data-urlencode "component=$component" \
    --data-urlencode "key=$key" "${args[@]}" "$API/settings/set"
}

failed=0
drifted=0
mapfile -t names < <(jq -r '.[]' <<<"$sonar_repos")
for name in "${names[@]}"; do
  component="${OWNER}_$name"
  desired="$(jq -c --arg n "$name" '(.defaults // {}) + (.repos[$n] // {})' <<<"$config_json")"
  [[ "$desired" != "{}" ]] || continue
  keys="$(jq -r 'keys | join(",")' <<<"$desired")"

  current=""
  if ! fetch current "$component" "$keys"; then
    echo "::error::$component: could not read settings" >&2
    failed=1
    continue
  fi
  if ! diff="$(plan "$desired" "$current")"; then
    echo "::error::$component: could not compare settings" >&2
    failed=1
    continue
  fi
  if [[ -z "$diff" ]]; then
    echo "$component: in sync"
    continue
  fi
  drifted=$((drifted + 1))
  echo "$component: differs"
  echo "$diff"
  [[ "$apply" == true ]] || continue

  while IFS= read -r key; do
    if ! post "$component" "$key" "$(jq -c --arg k "$key" '.[$k]' <<<"$desired")"; then
      echo "::error::$component: could not set $key" >&2
      failed=1
    fi
  done < <(sed -nE 's/^  [+~] ([^:]+): .*/\1/p' <<<"$diff")

  if fetch current "$component" "$keys" && after="$(plan "$desired" "$current")" && [[ -z "$after" ]]; then
    echo "$component: applied"
  else
    echo "::error::$component: settings still differ after apply" >&2
    failed=1
  fi
done

if ((drifted)); then
  echo "$drifted project(s) differ"
else
  echo "All ${#names[@]} project(s) in sync"
fi
exit "$failed"
