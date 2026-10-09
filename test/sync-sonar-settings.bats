#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/sync-sonar-settings.sh"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  WORK="${BATS_TEST_TMPDIR}"
  export STATE="$WORK/state" CURL_LOG="$WORK/curl.log"
  mkdir -p "$STATE" "$WORK/bin"
  : >"$CURL_LOG"
  write_fake_curl
  export PATH="$WORK/bin:$PATH"
  unset SONAR_TOKEN FAKE_GET_STATUS FAKE_GET_JUNK FAKE_JUNK_AFTER_POST FAKE_POST_STATUS FAKE_POST_NOOP FAKE_DEFAULT_EMPTY

  cat >"$WORK/repos.yaml" <<'EOF'
repos:
  - git: https://github.com/anthony-spruyt/alpha.git
    groups: [claude, sonar]
  - git: https://github.com/anthony-spruyt/beta.git
    groups: [sonar]
  - git: https://github.com/anthony-spruyt/gamma.git
    groups: [claude]
EOF
  cat >"$WORK/sonar.yaml" <<'EOF'
defaults:
  sonar.exclusions: [".claude/**"]
  sonar.issue.ignore.multicriteria:
    - ruleKey: "*:S8431"
      resourceKey: "**/*"
repos:
  beta:
    sonar.inclusions: ["src/**"]
EOF
  in_sync_state alpha
  in_sync_state beta '{"key":"sonar.inclusions","values":["src/**"]}'
}

# Fake curl: serves GETs from $STATE/<component>.json and applies POSTs to that file
write_fake_curl() {
  cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
method=GET url="" auth=no data=() out=""
[[ "${1:-}" == -q ]] || { echo "fake curl: -q must come first" >&2; exit 2; }
shift
while (($#)); do
  case "$1" in
  -X) method="$2"; shift 2 ;;
  -G | --get | -sS) shift ;;
  --proto | --max-time | --retry | -w) shift 2 ;;
  -o) out="$2"; shift 2 ;;
  -H)
    if [[ "$2" == @* ]] && grep -q '^Authorization: Bearer ' "${2#@}"; then auth=yes; fi
    shift 2
    ;;
  --data-urlencode) data+=("$2"); shift 2 ;;
  https://*) url="$1"; shift ;;
  *) echo "fake curl: unexpected argument: $1" >&2; exit 2 ;;
  esac
done
{
  printf '%s %s auth=%s\n' "$method" "$url" "$auth"
  for d in "${data[@]}"; do printf '  %s\n' "$d"; done
} >>"$CURL_LOG"
component="" key="" value="" values=() fields=()
for d in "${data[@]}"; do
  case "$d" in
  component=*) component="${d#component=}" ;;
  key=*) key="${d#key=}" ;;
  value=*) value="${d#value=}" ;;
  values=*) values+=("${d#values=}") ;;
  fieldValues=*) fields+=("${d#fieldValues=}") ;;
  esac
done
file="$STATE/$component.json"
[[ -n "$out" ]] || { echo "fake curl: -o is required" >&2; exit 2; }
exec 3>&1 >"$out"
# Prints the status the way -w '%{http_code}' does, on stdout rather than into the -o file
status() { printf '%s' "$1" >&3; }
if [[ "$method" == GET && -n "${FAKE_JUNK_AFTER_POST:-}" && -f "$STATE/.posted" ]]; then
  printf '{"errors":[]}{"settings":[]}'
  status 200
elif [[ "$method" == GET && "$url" == https://sonarcloud.io/api/settings/values ]]; then
  if [[ -n "${FAKE_GET_STATUS:-}" ]]; then
    printf '{"errors":[{"msg":"boom"}]}'
    status "$FAKE_GET_STATUS"
  elif [[ -n "${FAKE_GET_JUNK:-}" && "$component" == "${FAKE_GET_JUNK}" ]]; then
    printf '{"errors":[]}{"settings":[]}'
    status 200
  elif [[ -f "$file" ]]; then
    cat "$file"
    status 200
  elif [[ -n "${FAKE_DEFAULT_EMPTY:-}" ]]; then
    printf '{"settings":[]}'
    status 200
  else
    printf '{"errors":[{"msg":"Component key not found"}]}'
    status 404
  fi
elif [[ "$method" == POST && "$url" == https://sonarcloud.io/api/settings/set ]]; then
  touch "$STATE/.posted"
  if [[ -n "${FAKE_POST_STATUS:-}" ]]; then
    printf '{"errors":[{"msg":"rejected"}]}'
    status "$FAKE_POST_STATUS"
    exit 0
  fi
  if [[ -z "${FAKE_POST_NOOP:-}" ]]; then
    if ((${#fields[@]})); then
      entry=$(printf '%s\n' "${fields[@]}" | jq -sc --arg k "$key" '{key: $k, fieldValues: .}')
    elif ((${#values[@]})); then
      entry=$(printf '%s\n' "${values[@]}" | jq -Rsc --arg k "$key" '{key: $k, values: (split("\n") | .[:-1])}')
    else
      entry=$(jq -nc --arg k "$key" --arg v "$value" '{key: $k, value: $v}')
    fi
    jq -c --argjson e "$entry" '.settings = ([.settings[] | select(.key != $e.key)] + [$e])' "$file" >"$file.new"
    mv "$file.new" "$file"
  fi
  status 204
else
  echo "fake curl: unexpected request $method $url" >&2
  exit 2
fi
FAKE
  chmod +x "$WORK/bin/curl"
}

# in_sync_state <repo> [extra setting JSON...]: project already matches the defaults
in_sync_state() {
  local repo="$1"
  shift
  local extra
  extra=$(printf '%s\n' "$@" | jq -sc '.')
  jq -nc --argjson extra "$extra" '{settings: ([
    {key: "sonar.autoscan.enabled", value: "true"},
    {key: "sonar.exclusions", values: [".claude/**"]},
    {key: "sonar.issue.ignore.multicriteria", fieldValues: [{resourceKey: "**/*", ruleKey: "*:S8431"}]}
  ] + $extra)}' >"$STATE/anthony-spruyt_$repo.json"
}

run_sync() {
  run "$SCRIPT" --config "$WORK/sonar.yaml" --repos "$WORK/repos.yaml" "$@"
}

posts() {
  grep -c '^POST ' "$CURL_LOG" || true
}

@test "dry-run reports every project in sync and posts nothing" {
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"anthony-spruyt_alpha: in sync"* ]]
  [[ "$output" == *"anthony-spruyt_beta: in sync"* ]]
  [ "$(posts)" -eq 0 ]
}

@test "manages only repos in the sonar group" {
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" != *gamma* ]]
  ! grep -q gamma "$CURL_LOG"
}

@test "dry-run shows drift without a token and posts nothing" {
  jq -c '.settings |= map(select(.key != "sonar.exclusions"))' "$STATE/anthony-spruyt_alpha.json" >"$WORK/a" && mv "$WORK/a" "$STATE/anthony-spruyt_alpha.json"
  in_sync_state beta '{"key":"sonar.inclusions","values":["old/**"]}'
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *'+ sonar.exclusions: [".claude/**"]'* ]]
  [[ "$output" == *'~ sonar.inclusions: ["old/**"] -> ["src/**"]'* ]]
  [[ "$output" == *"2 project(s) differ"* ]]
  [ "$(posts)" -eq 0 ]
}

@test "dry-run never sends the token, even when it is set" {
  export SONAR_TOKEN="dummy-token-value"
  run_sync
  [ "$status" -eq 0 ]
  ! grep -q 'auth=yes' "$CURL_LOG"
}

@test "per-repo values replace the default for that key and keep the other defaults" {
  printf '  alpha:\n    sonar.exclusions: ["vendor/**"]\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *'~ sonar.exclusions: [".claude/**"] -> ["vendor/**"]'* ]]
  [[ "$output" != *"sonar.issue.ignore.multicriteria:"* ]]
}

@test "treats an inherited value as unset" {
  jq -c '.settings |= map(if .key == "sonar.exclusions" then . + {inherited: true} else . end)' "$STATE/anthony-spruyt_alpha.json" >"$WORK/a" && mv "$WORK/a" "$STATE/anthony-spruyt_alpha.json"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *'+ sonar.exclusions: [".claude/**"]'* ]]
}

@test "detects a reordered multi-criteria set as drift" {
  printf '  alpha:\n    sonar.issue.ignore.multicriteria:\n      - {ruleKey: "a", resourceKey: "1"}\n      - {ruleKey: "b", resourceKey: "2"}\n' >>"$WORK/sonar.yaml"
  in_sync_state alpha
  jq -c '.settings |= map(if .key == "sonar.issue.ignore.multicriteria" then .fieldValues = [{resourceKey: "2", ruleKey: "b"}, {resourceKey: "1", ruleKey: "a"}] else . end)' "$STATE/anthony-spruyt_alpha.json" >"$WORK/a" && mv "$WORK/a" "$STATE/anthony-spruyt_alpha.json"
  run_sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"~ sonar.issue.ignore.multicriteria"* ]]
}

@test "apply refuses to run without SONAR_TOKEN" {
  run_sync --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"SONAR_TOKEN"* ]]
  [ "$(posts)" -eq 0 ]
}

@test "apply rejects a token with a newline and does not print it" {
  export SONAR_TOKEN=$'abc\nX-Evil: 1'
  run_sync --apply
  [ "$status" -eq 1 ]
  [[ "$output" != *"X-Evil"* ]]
  [ "$(posts)" -eq 0 ]
}

@test "apply posts only the keys that differ, with the token, and never prints it" {
  export SONAR_TOKEN="dummy-token-value"
  in_sync_state beta '{"key":"sonar.inclusions","values":["old/**"]}'
  jq -c '.settings |= map(select(.key != "sonar.issue.ignore.multicriteria"))' "$STATE/anthony-spruyt_alpha.json" >"$WORK/a" && mv "$WORK/a" "$STATE/anthony-spruyt_alpha.json"
  run_sync --apply
  [ "$status" -eq 0 ]
  [ "$(posts)" -eq 2 ]
  ! grep -q '^POST .* auth=no' "$CURL_LOG"
  ! grep -q '^GET .* auth=yes' "$CURL_LOG"
  grep -qxF '  component=anthony-spruyt_alpha' "$CURL_LOG"
  grep -qxF '  key=sonar.issue.ignore.multicriteria' "$CURL_LOG"
  grep -qxF '  fieldValues={"ruleKey":"*:S8431","resourceKey":"**/*"}' "$CURL_LOG"
  grep -qxF '  values=src/**' "$CURL_LOG"
  ! grep -qx '  key=sonar.exclusions' "$CURL_LOG"
  [[ "$output" != *"dummy-token-value"* ]]
  ! grep -q 'dummy-token-value' "$CURL_LOG"
}

@test "apply sends one values field per list entry" {
  export SONAR_TOKEN="dummy-token-value"
  printf '  alpha:\n    sonar.exclusions: ["a/**", "b/**"]\n' >>"$WORK/sonar.yaml"
  run_sync --apply
  [ "$status" -eq 0 ]
  grep -qxF '  values=a/**' "$CURL_LOG"
  grep -qxF '  values=b/**' "$CURL_LOG"
}

@test "apply sends a scalar as value" {
  export SONAR_TOKEN="dummy-token-value"
  printf '  alpha:\n    sonar.python.version: "3.12"\n' >>"$WORK/sonar.yaml"
  run_sync --apply
  [ "$status" -eq 0 ]
  grep -qxF '  value=3.12' "$CURL_LOG"
}

@test "apply is idempotent: a second run posts nothing" {
  export SONAR_TOKEN="dummy-token-value"
  in_sync_state beta
  run_sync --apply
  [ "$status" -eq 0 ]
  [ "$(posts)" -eq 1 ]
  : >"$CURL_LOG"
  run_sync --apply
  [ "$status" -eq 0 ]
  [ "$(posts)" -eq 0 ]
  [[ "$output" == *"anthony-spruyt_beta: in sync"* ]]
}

@test "apply fails when a setting does not stick" {
  export SONAR_TOKEN="dummy-token-value"
  export FAKE_POST_NOOP=1
  in_sync_state beta
  run_sync --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"anthony-spruyt_beta"* ]]
}

@test "apply fails loudly on an API error from set" {
  export SONAR_TOKEN="dummy-token-value"
  export FAKE_POST_STATUS=400
  in_sync_state beta
  run_sync --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 400"* ]]
  [[ "$output" == *"rejected"* ]]
}

@test "fails loudly when a project does not exist" {
  rm "$STATE/anthony-spruyt_beta.json"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"anthony-spruyt_beta"* ]]
  [[ "$output" == *"HTTP 404"* ]]
}

@test "fails loudly on a server error from values, naming the endpoint" {
  export FAKE_GET_STATUS=503
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"HTTP 503 from https://sonarcloud.io/api/settings/values"* ]]
}

@test "fails on a read that is not one JSON document and still checks the other projects" {
  export FAKE_GET_JUNK=anthony-spruyt_alpha
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"anthony-spruyt_alpha"* ]]
  [[ "$output" == *"anthony-spruyt_beta: in sync"* ]]
}

@test "apply fails when the read after it is not one JSON document" {
  export SONAR_TOKEN="dummy-token-value" FAKE_JUNK_AFTER_POST=1
  in_sync_state beta
  run_sync --apply
  [ "$status" -eq 1 ]
  [[ "$output" != *"anthony-spruyt_beta: applied"* ]]
}

@test "rejects a repos file with more than one YAML document" {
  printf -- '---\nrepos:\n  - git: https://github.com/anthony-spruyt/gamma.git\n    groups: [sonar]\n' >>"$WORK/repos.yaml"
  printf '  alpha:\n    "sonar.x&key=evil": ["x"]\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"one YAML document"* ]]
  ! grep -q '^GET' "$CURL_LOG"
}

@test "rejects a config file with more than one YAML document" {
  export SONAR_TOKEN="dummy-token-value"
  printf -- '---\ndefaults:\n  sonar.exclusions: ["x"]\n' >>"$WORK/sonar.yaml"
  run_sync --apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"one YAML document"* ]]
  ! grep -q '^GET' "$CURL_LOG"
}

@test "fails when config names a repo outside the sonar group" {
  printf '  gamma:\n    sonar.exclusions: ["x"]\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"gamma"* ]]
  [ "$(posts)" -eq 0 ]
}

@test "rejects a setting key that is not a plain sonar.* key" {
  printf '  alpha:\n    "sonar.x&key=sonar.evil": ["x"]\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"setting key not allowed"* ]]
  ! grep -q '^GET' "$CURL_LOG"
}

@test "rejects a value that is not a string, list of strings or list of string maps" {
  printf '  alpha:\n    sonar.exclusions: 3\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"sonar.exclusions"* ]]
}

@test "rejects an unknown top-level config key" {
  printf 'host: https://attacker.example\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"host"* ]]
}

@test "rejects a sonar repo URL outside github.com/anthony-spruyt" {
  printf '  - git: https://github.com/someone-else/delta.git\n    groups: [sonar]\n' >>"$WORK/repos.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"someone-else"* ]]
  ! grep -q '^GET' "$CURL_LOG"
}

@test "passes values with URL metacharacters through as a single encoded field" {
  export SONAR_TOKEN="dummy-token-value"
  printf '  alpha:\n    sonar.exclusions: ["a&key=sonar.evil&component=other"]\n' >>"$WORK/sonar.yaml"
  run_sync --apply
  [ "$status" -eq 0 ]
  grep -qxF '  values=a&key=sonar.evil&component=other' "$CURL_LOG"
  [ "$(grep -c '^  component=' "$CURL_LOG")" -ge 1 ]
  ! grep -qxF '  component=other' "$CURL_LOG"
}

@test "rejects an unknown option" {
  run_sync --bogus
  [ "$status" -eq 2 ]
}

@test "plans the repo's own config against empty projects" {
  export FAKE_DEFAULT_EMPTY=1
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"anthony-spruyt_repo-operator"* ]]
  [[ "$output" == *'+ sonar.exclusions: [".claude/**"]'* ]]
  [ "$(posts)" -eq 0 ]
}

@test "rejects duplicate keys in the config" {
  printf '  alpha:\n    sonar.exclusions: ["x"]\n    sonar.exclusions: ["y"]\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate keys"* ]]
}

@test "rejects an empty string value" {
  printf '  alpha:\n    sonar.python.version: ""\n' >>"$WORK/sonar.yaml"
  run_sync
  [ "$status" -eq 1 ]
  [[ "$output" == *"sonar.python.version"* ]]
}

@test "matches the sonar group exactly, not as a substring" {
  printf '  - git: https://github.com/anthony-spruyt/delta.git\n    groups: "nosonar"\n' >>"$WORK/repos.yaml"
  run_sync
  [[ "$output" != *delta* ]]
}
