#!/usr/bin/env bash
# Deletes old Docker Hub tags with the GHCR cleanup's keep rules: per version (digest), skip the one tagged latest
# and those pushed within OLDER_THAN, keep the newest KEEP_N_TAGGED of the rest, delete every tag of the others.
set -euo pipefail

readonly API="https://hub.docker.com/v2"
readonly CURL_OPTS=(--proto "=https" --max-time 30 --retry 3 -sS -w "%{http_code}")
readonly NAME_RE='^[a-z0-9]+([._-][a-z0-9]+)*$'
readonly TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'

die() {
  echo "::error::$*" >&2
  exit 1
}

export LOGIN_USER="${USERNAME:-${NAMESPACE:-}}"
[[ "${NAMESPACE:-}" =~ $NAME_RE ]] || die "namespace is not a Docker Hub namespace"
[[ "$LOGIN_USER" =~ $NAME_RE ]] || die "username is not a Docker Hub username"
[[ -n "${DOCKERHUB_TOKEN:-}" ]] || die "the Docker Hub token is empty"
[[ "${KEEP_N_TAGGED:-}" =~ ^0*([1-9][0-9]{0,8})$ ]] || die "keep-n-tagged must be a whole number of at least 1"
keep="${BASH_REMATCH[1]}"
[[ "${DRY_RUN:-}" =~ ^(true|false)$ ]] || die "dry-run must be true or false"
if ! [[ "${OLDER_THAN:-}" =~ ^[[:space:]]*0*([1-9][0-9]{0,4})[[:space:]]*(second|minute|hour|day|week|month|year)s?[[:space:]]*$ ]]; then
  die "older-than must be a positive interval of at most 99999 units, such as '4 weeks' or '30 days'"
fi
# Unit lengths match human-interval, which the GHCR cleanup uses: a month is 30 days, a year 365
declare -A UNIT=([second]=1 [minute]=60 [hour]=3600 [day]=86400 [week]=604800 [month]=2592000 [year]=31536000)
cutoff=$(($(date -u +%s) - BASH_REMATCH[1] * UNIT[${BASH_REMATCH[2]}]))
IFS=, read -ra packages <<<"${PACKAGES:-}"
((${#packages[@]})) || die "no packages to clean"
for p in "${packages[@]}"; do
  [[ "$p" =~ $NAME_RE ]] || die "package name not allowed: $p"
done

tmp="$(umask 077 && mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# The token reaches jq and curl only through env and files: argv is readable by any process on the runner
jq -n '{identifier: env.LOGIN_USER, secret: env.DOCKERHUB_TOKEN}' >"$tmp/login"

# shellcheck disable=SC2016
readonly JQ_PLAN='
def pushed: (.tag_last_pushed // .last_updated // "") | sub("\\.[0-9]+Z$"; "Z") | try fromdate catch null;
group_by(.digest // "tag:\(.name)")
| map(select(all(.name != "latest")) | {tags: map(.name), pushed: (map(pushed) | max)})
| map(select(.pushed != null and .pushed < $cutoff))
| sort_by(-.pushed)
| .[$keep:][].tags[]
'

show_body() {
  jq -c '.message // .detail // .' "$tmp/body" 2>/dev/null || tr -d '\000-\037\177' <"$tmp/body" | head -c 500
}

# request <curl args...> <url>: the body lands in $tmp/body and the status in STATUS; fails unless it is 2xx
request() {
  STATUS="$(curl -q "${CURL_OPTS[@]}" -o "$tmp/body" "$@")" || {
    STATUS=""
    return 1
  }
  [[ "$STATUS" =~ ^2[0-9][0-9]$ ]]
}

http_error() {
  echo "::error::HTTP ${STATUS:-error} from $1: $(show_body)" >&2
}

login() {
  local token
  if ! request -X POST -H "Content-Type: application/json" --data-binary "@$tmp/login" "$API/auth/token"; then
    http_error "$API/auth/token"
    return 1
  fi
  token="$(jq -er '.access_token | select(type == "string" and length > 0)' "$tmp/body")" || return 1
  printf 'Authorization: Bearer %s\n' "$token" >"$tmp/auth"
}

# hub <curl args...> <url>: an authenticated request that logs in again once if the token, which lasts 10 minutes, expired
hub() {
  request -H "@$tmp/auth" "$@" && return 0
  [[ "$STATUS" == 401 ]] || return 1
  login && request -H "@$tmp/auth" "$@"
}

# list_tags <repo>: writes every tag to $tmp/tags.json; returns 2 when the repository doesn't exist
list_tags() {
  local url="$API/namespaces/$NAMESPACE/repositories/$1/tags?page_size=100" n=0
  rm -rf "$tmp/pages" && mkdir "$tmp/pages"
  while [[ -n "$url" ]]; do
    [[ "$url" == "$API/namespaces/$NAMESPACE/repositories/$1/tags?"* ]] || {
      echo "::error::$1: next page is not on the Hub API" >&2
      return 1
    }
    n=$((n + 1))
    if ! hub "$url"; then
      [[ "$n" == 1 && "$STATUS" == 404 ]] && return 2
      http_error "$url"
      return 1
    fi
    jq -e '.results | type == "array"' "$tmp/body" >/dev/null || {
      echo "::error::$1: page $n is not a tag list" >&2
      return 1
    }
    mv "$tmp/body" "$tmp/pages/$n.json"
    url="$(jq -r '.next // ""' "$tmp/pages/$n.json")"
  done
  jq -s 'map(.results[])' "$tmp/pages"/*.json >"$tmp/tags.json"
}

clean() {
  local repo="$NAMESPACE/$1" plan tag rc=0
  if ! login; then
    echo "::error::$repo: could not log in to Docker Hub" >&2
    return 1
  fi
  list_tags "$1" || rc=$?
  if ((rc == 2)); then
    echo "::notice::$repo: no such Docker Hub repository, skipping"
    return 0
  elif ((rc)); then
    echo "::error::$repo: could not list tags" >&2
    return 1
  fi
  plan="$(jq -r --argjson cutoff "$cutoff" --argjson keep "$keep" "$JQ_PLAN" "$tmp/tags.json")" || return 1
  if [[ -z "$plan" ]]; then
    echo "$repo: nothing to delete"
    return 0
  fi
  while IFS= read -r tag; do
    [[ "$tag" =~ $TAG_RE ]] || {
      echo "::error::$repo: tag name not allowed: $(tr -d '\000-\037\177' <<<"$tag" | head -c 200)" >&2
      return 1
    }
  done <<<"$plan"
  local failed=0 url
  while IFS= read -r tag; do
    url="$API/namespaces/$NAMESPACE/repositories/$1/tags/$tag"
    if [[ "$DRY_RUN" == true ]]; then
      echo "$repo: would delete $tag"
    elif hub -X DELETE "$url"; then
      echo "$repo: deleted $tag"
    elif [[ "$STATUS" == 404 ]]; then
      echo "$repo: $tag already gone"
    else
      http_error "$url"
      failed=1
    fi
  done <<<"$plan"
  return "$failed"
}

failed=0
for p in "${packages[@]}"; do
  clean "$p" || failed=1
done
exit "$failed"
