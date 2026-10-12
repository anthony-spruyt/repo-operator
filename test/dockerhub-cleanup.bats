#!/usr/bin/env bats
# shellcheck disable=SC2016

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../.github/actions/dockerhub-cleanup/cleanup.sh"
  WORK="${BATS_TEST_TMPDIR}"
  export STATE="$WORK/state" CURL_LOG="$WORK/curl.log"
  mkdir -p "$STATE" "$WORK/bin"
  : >"$CURL_LOG"
  write_fake_curl
  write_jq_guard
  export PATH="$WORK/bin:$PATH"
  export NAMESPACE=aspruyt USERNAME="" DOCKERHUB_TOKEN=s3cret-pat PACKAGES=app OLDER_THAN="4 weeks" KEEP_N_TAGGED=2 DRY_RUN=false
  unset FAKE_PAGE_SIZE FAKE_AUTH_STATUS FAKE_LIST_STATUS FAKE_PAGE2_STATUS FAKE_DELETE_STATUS FAKE_NEXT FAKE_TOKEN_USES
}

# tags <repo> <name:digest:days-ago>...: writes the repo's tags as the Hub API lists them, newest push first
tags() {
  local repo="$1" spec name digest days now
  shift
  now="$(date -u +%s)"
  for spec in "$@"; do
    IFS=: read -r name digest days <<<"$spec"
    jq -cn --arg n "$name" --arg d "$digest" --arg t "$(date -u -d "@$((now - days * 86400 - 60))" +%Y-%m-%dT%H:%M:%S.123456Z)" \
      '{name: $n, digest: (if $d == "" then null else "sha256:\($d)" end), tag_last_pushed: $t, last_updated: $t}'
  done | jq -s 'sort_by(.tag_last_pushed) | reverse' >"$STATE/$repo.json"
}

# jq that refuses the token in its arguments, where any process on the runner could read it
write_jq_guard() {
  local real
  real="$(command -v jq)"
  cat >"$WORK/bin/jq" <<GUARD
#!/usr/bin/env bash
for a in "\$@"; do
  [[ "\$a" != *s3cret-pat* ]] || { echo "jq guard: the token is in argv" >&2; exit 2; }
done
exec "$real" "\$@"
GUARD
  chmod +x "$WORK/bin/jq"
}

remaining() {
  jq -r '[.[].name] | sort | join(" ")' "$STATE/$1.json"
}

# Fake curl: serves the tag list from $STATE/<repo>.json in pages and applies DELETEs to it
write_fake_curl() {
  cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
for a in "$@"; do
  [[ "$a" != *s3cret-pat* ]] || { echo "fake curl: the token is in argv" >&2; exit 2; }
done
method=GET url="" auth="" body="" out="" ctype=no
[[ "${1:-}" == -q ]] || { echo "fake curl: -q must come first" >&2; exit 2; }
shift
while (($#)); do
  case "$1" in
  -X) method="$2"; shift 2 ;;
  -sS) shift ;;
  --proto | --max-time | --retry | -w) shift 2 ;;
  -o) out="$2"; shift 2 ;;
  -H)
    if [[ "$2" == @* ]]; then
      auth="$(sed -n 's/^Authorization: Bearer //p' "${2#@}")"
    elif [[ "$2" == "Content-Type: application/json" ]]; then
      ctype=yes
    else
      echo "fake curl: unexpected header: $2" >&2; exit 2
    fi
    shift 2
    ;;
  --data-binary)
    [[ "$2" == @* ]] || { echo "fake curl: the body must come from a file" >&2; exit 2; }
    body="$(cat "${2#@}")"; method=POST; shift 2
    ;;
  https://*) url="$1"; shift ;;
  *) echo "fake curl: unexpected argument: $1" >&2; exit 2 ;;
  esac
done
printf '%s %s auth=%s\n' "$method" "$url" "${auth:-none}" >>"$CURL_LOG"
[[ -n "$out" ]] || { echo "fake curl: -o is required" >&2; exit 2; }
exec 3>&1 >"$out"
status() { printf '%s' "$1" >&3; }
api=https://hub.docker.com/v2
if [[ "$method" == POST && "$url" == "$api/auth/token" ]]; then
  [[ "$ctype" == yes ]] || { echo "fake curl: no JSON content type" >&2; exit 2; }
  n=$(grep -c '^POST ' "$CURL_LOG")
  if [[ -n "${FAKE_AUTH_STATUS:-}" ]]; then
    printf '{"message":"bad credentials"}'
    status "$FAKE_AUTH_STATUS"
  elif jq -e --arg u "${USERNAME:-$NAMESPACE}" '. == {identifier: $u, secret: ("s3cret" + "-pat")}' >/dev/null <<<"$body"; then
    printf '{"access_token":"jwt-%s"}' "$n"
    status 200
  else
    printf '{"message":"unexpected body"}'
    status 401
  fi
  exit 0
fi
[[ "$auth" == jwt-* ]] || { printf '{"message":"no token"}'; status 401; exit 0; }
if [[ -n "${FAKE_TOKEN_USES:-}" ]] && (($(grep -c " auth=$auth\$" "$CURL_LOG") > FAKE_TOKEN_USES)); then
  printf '{"message":"token expired"}'
  status 401
  exit 0
fi
re="^$api/namespaces/$NAMESPACE/repositories/([^/?]+)/tags(/([^/?]+))?(\?(.*))?$"
[[ "$url" =~ $re ]] || { echo "fake curl: unexpected URL: $url" >&2; exit 2; }
repo="${BASH_REMATCH[1]}" tag="${BASH_REMATCH[3]}" query="${BASH_REMATCH[5]}"
file="$STATE/$repo.json"
if [[ "$method" == GET && -z "$tag" ]]; then
  if [[ -n "${FAKE_LIST_STATUS:-}" && "$repo" == "${FAKE_LIST_STATUS%%=*}" ]]; then
    printf '{"message":"boom"}'
    status "${FAKE_LIST_STATUS#*=}"
  elif [[ -n "${FAKE_PAGE2_STATUS:-}" && "$query" == *page=2* ]]; then
    printf '{"message":"object not found"}'
    status "$FAKE_PAGE2_STATUS"
  elif [[ ! -f "$file" ]]; then
    printf '{"message":"object not found"}'
    status 404
  else
    [[ "$query" == *page_size=100* ]] || { echo "fake curl: no page_size=100" >&2; exit 2; }
    page=1
    [[ "$query" =~ (^|&)page=([0-9]+) ]] && page="${BASH_REMATCH[2]}"
    size="${FAKE_PAGE_SIZE:-100}"
    jq -c --argjson p "$page" --argjson s "$size" --arg next "${FAKE_NEXT:-$api/namespaces/$NAMESPACE/repositories/$repo/tags?page_size=100&page=$((page + 1))}" \
      '{count: length, next: (if length > $p * $s then $next else null end), results: .[($p - 1) * $s:$p * $s]}' "$file"
    status 200
  fi
elif [[ "$method" == DELETE && -n "$tag" ]]; then
  if [[ -n "${FAKE_DELETE_STATUS:-}" && "$tag" == "${FAKE_DELETE_STATUS%%=*}" ]]; then
    printf '{"message":"nope"}'
    status "${FAKE_DELETE_STATUS#*=}"
  elif [[ -f "$file" ]] && jq -e --arg t "$tag" 'any(.name == $t)' "$file" >/dev/null; then
    jq --arg t "$tag" 'map(select(.name != $t))' "$file" >"$file.new" && mv "$file.new" "$file"
    status 204
  else
    printf '{"message":"tag not found"}'
    status 404
  fi
else
  echo "fake curl: unexpected request: $method $url" >&2; exit 2
fi
FAKE
  chmod +x "$WORK/bin/curl"
}

@test "deletes every tag of the versions past the newest keep-n-tagged old ones, and keeps latest and young versions" {
  tags app latest:d1:1 1.5:d1:1 1.5.0:d1:1 1.0.0:d6:10 1.4.0:d2:40 1.3.0:d3:50 1.2.0:d4:60 1.2:d4:60 1.1.0:d5:70
  run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "1.0.0 1.3.0 1.4.0 1.5 1.5.0 latest" ]
}

@test "a version's age is its newest tag push" {
  tags app latest:d1:1 1.4.0:d2:40 1.3.0:d3:50 1.2.0:d4:60 1.2:d4:5 1.1.0:d5:70
  KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "1.2 1.2.0 1.4.0 latest" ]
}

@test "the version tagged latest is kept even when it is old" {
  tags app latest:d1:90 2.0.0:d1:90 1.0.0:d2:100 0.9.0:d3:110
  KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "1.0.0 2.0.0 latest" ]
}

@test "a tag with no digest counts as its own version" {
  tags app latest:d1:1 a::40 b::50 c::60
  KEEP_N_TAGGED=1 run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "a latest" ]
}

@test "older-than counts a month as 30 days, like the GHCR cleanup" {
  tags app latest:d1:1 a:d2:59 b:d3:61 c:d4:62
  OLDER_THAN="2 months" KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "a b latest" ]
}

@test "reads every page of tags" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42 d:d5:43 e:d6:44
  FAKE_PAGE_SIZE=2 KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "a latest" ]
  [ "$(grep -c '^GET ' "$CURL_LOG")" = "3" ]
}

@test "lists hundreds of large tags without passing them as one argument" {
  local now old
  now="$(date -u +%s)"
  old="$(date -u -d "@$((now - 60 * 86400))" +%Y-%m-%dT%H:%M:%S.123456Z)"
  jq -n --arg t "$old" --arg pad "$(printf '%01000d' 0)" \
    '[{name: "latest", digest: "sha256:new", tag_last_pushed: $t, last_updated: $t}]
     + [range(400) | {name: "v\(.)", digest: "sha256:d\(.)", tag_last_pushed: $t, last_updated: $t, images: [{digest: $pad}]}]' >"$STATE/app.json"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(jq length "$STATE/app.json")" = "3" ]
}

@test "a 404 after the first page fails instead of skipping the package" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42
  FAKE_PAGE_SIZE=2 FAKE_PAGE2_STATUS=404 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" != *"::notice::"* ]]
  [[ "$output" == *"::error::HTTP 404"* ]]
  [ "$(remaining app)" = "a b c latest" ]
}

@test "logs in again when the Hub token expires mid-package" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42 d:d5:43
  KEEP_N_TAGGED=1 FAKE_TOKEN_USES=2 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "a latest" ]
  [ "$(grep -c '^POST ' "$CURL_LOG")" = "2" ]
}

@test "refuses a next page outside the Hub API" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42
  FAKE_PAGE_SIZE=2 FAKE_NEXT=https://evil.example/v2/x run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"app: next page is not on the Hub API"* ]]
  [ "$(remaining app)" = "a b c latest" ]
}

@test "a dry run lists what it would delete and deletes nothing" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42
  DRY_RUN=true KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"aspruyt/app: would delete b"* ]]
  [[ "$output" == *"aspruyt/app: would delete c"* ]]
  [ "$(remaining app)" = "a b c latest" ]
  run ! grep -q '^DELETE ' "$CURL_LOG"
}

@test "cleans every package with one login" {
  tags app latest:d1:1 a:d2:40 b:d3:41
  tags tool latest:d1:1 x:d2:40 y:d3:41
  PACKAGES="app,tool" KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(remaining app)" = "a latest" ]
  [ "$(remaining tool)" = "latest x" ]
  [ "$(grep -c '^POST https://hub.docker.com/v2/auth/token ' "$CURL_LOG")" = "1" ]
  grep -q '^DELETE .*/repositories/tool/tags/y auth=jwt-1$' "$CURL_LOG"
}

@test "a token Hub still rejects after a fresh login stops the package without a login per tag" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42 d:d5:43
  tags tool latest:d1:1 x:d2:40 y:d3:41
  PACKAGES="app,tool" KEEP_N_TAGGED=1 FAKE_DELETE_STATUS=b=401 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::aspruyt/app: Docker Hub rejected the token"* ]]
  [ "$(grep -c '^POST ' "$CURL_LOG")" -le 3 ]
}

@test "logs in as dockerhub-username when it is set" {
  tags app latest:d1:1
  USERNAME=someone run "$SCRIPT"
  [ "$status" -eq 0 ]
}

@test "skips a package with no Docker Hub repository" {
  tags tool latest:d1:1 x:d2:40 y:d3:41
  PACKAGES="app,tool" KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::aspruyt/app: no such Docker Hub repository, skipping"* ]]
  [ "$(remaining tool)" = "latest x" ]
}

@test "a failed listing fails the run but still cleans the other packages" {
  tags app latest:d1:1 a:d2:40 b:d3:41
  tags tool latest:d1:1 x:d2:40 y:d3:41
  PACKAGES="app,tool" KEEP_N_TAGGED=1 FAKE_LIST_STATUS=app=500 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::HTTP 500"* ]]
  [ "$(remaining app)" = "a b latest" ]
  [ "$(remaining tool)" = "latest x" ]
}

@test "a failed delete fails the run but still deletes the other tags" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42
  KEEP_N_TAGGED=1 FAKE_DELETE_STATUS=b=403 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::HTTP 403"* ]]
  [ "$(remaining app)" = "a b latest" ]
}

@test "a 404 on delete fails the run, so a delete that never lands can't pass" {
  tags app latest:d1:1 a:d2:40 b:d3:41 c:d4:42
  KEEP_N_TAGGED=1 FAKE_DELETE_STATUS=b=404 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::HTTP 404"* ]]
  [ "$(remaining app)" = "a b latest" ]
}

@test "a tag with an empty digest counts as its own version" {
  local t
  t="$(date -u -d "@$(($(date -u +%s) - 50 * 86400))" +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg t "$t" '[{name: "latest", digest: "", tag_last_pushed: $t}, {name: "a", digest: "", tag_last_pushed: $t}, {name: "b", digest: "", tag_last_pushed: $t}]' >"$STATE/app.json"
  KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(jq length "$STATE/app.json")" = "2" ]
  [ "$(jq -r 'any(.name == "latest")' "$STATE/app.json")" = "true" ]
}

@test "a failed login fails the run without listing anything" {
  tags app latest:d1:1 a:d2:40 b:d3:41
  KEEP_N_TAGGED=1 FAKE_AUTH_STATUS=401 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::HTTP 401"* ]]
  [[ "$output" != *s3cret-pat* ]]
  run ! grep -q '^GET ' "$CURL_LOG"
}

@test "refuses a tag name the registry never produces, and still deletes the other tags" {
  tags app latest:d1:1 a:d2:40 '..%2Fx:d3:41' b:d4:42
  KEEP_N_TAGGED=1 run "$SCRIPT"
  echo "$output"
  [ "$status" -eq 1 ]
  [[ "$output" == *"aspruyt/app: tag name not allowed"* ]]
  [ "$(remaining app)" = "..%2Fx a latest" ]
  run ! grep -q '%2F' "$CURL_LOG"
}

@test "refuses bad inputs before calling the API" {
  local bad
  for bad in "NAMESPACE=Bad/ns" "NAMESPACE=" "USERNAME=a;b" "PACKAGES=" "PACKAGES=app,../x" "PACKAGES=app,*" "KEEP_N_TAGGED=0" "KEEP_N_TAGGED=x" "OLDER_THAN=0 days" "OLDER_THAN=soon" "DRY_RUN=maybe"; do
    run env "$bad" "$SCRIPT"
    echo "$bad: $output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"::error::"* ]]
  done
  DOCKERHUB_TOKEN="" run "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::the Docker Hub token is empty"* ]]
  NAMESPACE=Bad run "$SCRIPT"
  [[ "$output" == "::error::namespace is not a Docker Hub namespace" ]]
  USERNAME=Bad run "$SCRIPT"
  [[ "$output" == "::error::username is not a Docker Hub username" ]]
  [ ! -s "$CURL_LOG" ]
}

@test "the action passes each input to the script under the name it reads" {
  local action="${BATS_TEST_DIRNAME}/../.github/actions/dockerhub-cleanup/action.yaml"
  run yq -o=json -I0 '[.runs.using, (.runs.steps | length), .runs.steps[0].shell, .runs.steps[0].run, .runs.steps[0].env]' "$action"
  [ "$output" = '["composite",1,"bash","\"$CLEANUP_SCRIPT\"",{"NAMESPACE":"${{ inputs.namespace }}","USERNAME":"${{ inputs.username }}","DOCKERHUB_TOKEN":"${{ inputs.token }}","PACKAGES":"${{ inputs.packages }}","OLDER_THAN":"${{ inputs.older-than }}","KEEP_N_TAGGED":"${{ inputs.keep-n-tagged }}","DRY_RUN":"${{ inputs.dry-run }}","CLEANUP_SCRIPT":"${{ github.action_path }}/cleanup.sh"}]' ]
  run yq -o=json -I0 '.inputs | to_entries | map(select(.value.required == true) | .key)' "$action"
  [ "$output" = '["namespace","token","packages"]' ]
}
