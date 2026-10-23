#!/usr/bin/env bash
# Dates the third-party container images the fleet uses from their registries and publishes a Renovate preset
# (image-age.json) that holds back tags and rebuilds younger than 7 days. Subcommands: see usage().
set -euo pipefail

# renovate: depName=renovate datasource=npm
RENOVATE_VERSION="44.164.7"

MIN_AGE_SECONDS=$((7 * 86400))
KEEP_NEWEST=50
MAX_PAGES=20
STALE_SECONDS=$((36 * 3600))
MAX_BYTES=524288
MAX_DATA_BYTES=2097152
DIAGNOSIS_LOG_LINES=15
DIAGNOSIS_ERR_LINES=10
DATA_REPO="anthony-spruyt/renovate-data"
DATA_BRANCH="main"
DATA_FILE="image-age.json"
STATE_FILE="image-age-data.json"
API="https://api.github.com"
OUT_OF_SCOPE_HOSTS=("8gears.container-registry.com")
DOCKER_HUB_HOSTS=("docker.io" "index.docker.io" "registry-1.docker.io")
OWN_IMAGES_PREFIX="ghcr.io/anthony-spruyt/"

IMAGE_RE='^[a-z0-9]+([.-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$'
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
DIGEST_RE='^sha256:[0-9a-f]{64}$'
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
MANIFEST_ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPOS_FILE="${IMAGE_AGE_REPOS_FILE:-$ROOT/src/repos.yaml}"
SKIPS_FILE="${IMAGE_AGE_SKIPS_FILE:-$ROOT/.github/renovate/image-age-skips.yaml}"
RULES_FILE="${IMAGE_AGE_RULES_FILE:-$ROOT/.github/renovate/package-rules.json5}"

rows_ghcr() {
  jq -r '.[] | .name as $d | (.created_at | fromdateiso8601) as $t | (.metadata.container.tags // [])[] | [., $d, $t] | @tsv'
}

rows_quay() {
  jq -r '.tags[] | select(.end_ts == null) | [.name, .manifest_digest, .start_ts] | @tsv'
}

rows_mcr() {
  jq -r '[.[] | [.name, .digest, (.lastModifiedDate | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601)]]
    | sort_by(-.[2]) | .[] | @tsv'
}

rows_gcr() {
  jq -r '[.manifest | to_entries[] | select((.value.tag | length) > 0) | .key as $d
      | ((.value.timeUploadedMs | tonumber) / 1000 | floor) as $t | .value.tag[] | [., $d, $t]]
    | sort_by(-.[2]) | .[] | @tsv'
}

AUTH_FILE=""
REPORT=""

# Workflow command lines (::error::, ::warning::) go to the log and to the report that publish checks last.
say() {
  printf '%s\n' "$*"
  if [[ -n "$REPORT" ]]; then printf '%s\n' "$*" >>"$REPORT"; fi
}

now() { printf '%s' "${IMAGE_AGE_NOW:-$(date +%s)}"; }

init_auth() {
  AUTH_FILE=$(mktemp)
  chmod 600 "$AUTH_FILE"
  printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" >"$AUTH_FILE"
  trap 'rm -f "$AUTH_FILE"' EXIT
}

# http METHOD URL OUT [curl args...]: prints the HTTP status, 000 when the request itself failed
http() {
  local method=$1 url=$2 out=$3 code err rc=0
  shift 3
  local args=(-q -sS --fail --globoff --proto '=https' --proto-redir '=https' --max-time 60 --retry 2)
  case "$method" in
  GET) ;;
  HEAD) args+=(--head) ;;
  *) args+=(-X "$method") ;;
  esac
  err=$(mktemp)
  code=$(curl "${args[@]}" "$@" -o "$out" -w '%{http_code}' "$url" 2>"$err") || rc=$?
  # Exit 22 is an HTTP error, whose status curl has already printed
  if ((rc != 0 && rc != 22)); then
    code=000
    cat "$err" >&2
  fi
  rm -f "$err"
  printf '%s' "$code"
}

# gh_http METHOD URL OUT [curl args...]: a GitHub API call with the token, for api.github.com URLs only
gh_http() {
  local method=$1 url=$2 out=$3
  shift 3
  [[ "$url" == "$API/"* ]] || return 1
  http "$method" "$url" "$out" -H "@$AUTH_FILE" -H "Accept: ${GH_ACCEPT:-application/vnd.github+json}" -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

COSIGN_TAG='^sha256-[0-9a-f]+([.](sig|att|sbom))?$'

# old_count ROWS: the distinct tags whose build is at least 7 days old, cosign tags aside
old_count() {
  local rows=$1 cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v cut="$cut" -v cosign="$COSIGN_TAG" '$3 <= cut && $1 !~ cosign && !seen[$1]++ { n++ } END { print n + 0 }' "$rows"
}

# missing_tags ROWS USED: the tags in use (space-separated) that ROWS do not list, one per line
missing_tags() {
  local rows=$1 used=$2
  awk -F'\t' -v used="$used" '
    { listed[$1] = 1 }
    END { n = split(used, u, " "); for (i = 1; i <= n; i++) if (!(u[i] in listed)) print u[i] }
  ' "$rows"
}

# enough_rows ROWS USED: KEEP_NEWEST old tags are listed and so is every tag in use
enough_rows() {
  local rows=$1 used=$2
  [[ "$(old_count "$rows")" -ge "$KEEP_NEWEST" && -z "$(missing_tags "$rows" "$used")" ]]
}

# page_cap IMAGE RAW: at the page cap the listing counts as complete once one tag is at least 7 days old
page_cap() {
  local image=$1 raw=$2
  if [[ "$(old_count "$raw")" -ge 1 ]]; then return 0; fi
  say "::error::$image: no tag at least 7 days old in the first $MAX_PAGES pages"
  return 1
}

# page_rows IMAGE ADAPTER BODY RAW: appends the rows of one registry answer; an answer the adapter cannot read fails the image
page_rows() {
  local image=$1 adapter=$2 body=$3 raw=$4 chunk
  chunk=$(mktemp)
  if ! "$adapter" <"$body" >"$chunk" 2>/dev/null; then
    say "::error::$image: the registry answer could not be read"
    rm -f "$chunk"
    return 1
  fi
  cat "$chunk" >>"$raw"
  rm -f "$chunk"
}

# answer_ok IMAGE CODE: a registry answered 200
answer_ok() {
  local image=$1 code=$2
  if [[ "$code" == 200 ]]; then return 0; fi
  say "::error::$image: registry answered $code"
  return 1
}

ghcr_pages() {
  local image=$1 raw=$2 used=$3 hdr=$4 body=$5 path=${1#*/} url code page=0
  local owner=${path%%/*} name=${path#*/}
  url="$API/users/$owner/packages/container/${name//\//%2F}/versions?per_page=100"
  while :; do
    if ((++page > MAX_PAGES)); then
      page_cap "$image" "$raw" && return 0
      return 1
    fi
    code=$(gh_http GET "$url" "$body" -D "$hdr")
    answer_ok "$image" "$code" || return 1
    page_rows "$image" rows_ghcr "$body" "$raw" || return 1
    if enough_rows "$raw" "$used"; then return 0; fi
    url=$(sed -n 's/^[Ll]ink:.*<\([^>]*\)>; *rel="next".*/\1/p' "$hdr" | tr -d '\r' | head -1)
    [[ -n "$url" ]] || return 0
    if [[ "$url" != "$API/"* ]]; then
      say "::error::$image: next page link leaves api.github.com"
      return 1
    fi
  done
}

fetch_ghcr() {
  local image=$1 raw=$2 used=$3 hdr body status=0
  hdr=$(mktemp) body=$(mktemp)
  ghcr_pages "$image" "$raw" "$used" "$hdr" "$body" || status=1
  rm -f "$hdr" "$body"
  return "$status"
}

quay_pages() {
  local image=$1 raw=$2 used=$3 body=$4 path=${1#*/} code page=0
  while :; do
    if ((++page > MAX_PAGES)); then
      page_cap "$image" "$raw" && return 0
      return 1
    fi
    code=$(http GET "https://quay.io/api/v1/repository/$path/tag/?onlyActive=true&limit=100&page=$page" "$body")
    answer_ok "$image" "$code" || return 1
    page_rows "$image" rows_quay "$body" "$raw" || return 1
    if enough_rows "$raw" "$used" || [[ "$(jq -r '.has_additional' "$body")" != true ]]; then return 0; fi
  done
}

fetch_quay() {
  local image=$1 raw=$2 used=$3 body status=0
  body=$(mktemp)
  quay_pages "$image" "$raw" "$used" "$body" || status=1
  rm -f "$body"
  return "$status"
}

# fetch_once IMAGE RAW URL ADAPTER [curl args...]: registries that answer with every tag in one call
fetch_once() {
  local image=$1 raw=$2 url=$3 adapter=$4 body code status=0
  shift 4
  body=$(mktemp)
  code=$(http GET "$url" "$body" "$@")
  if answer_ok "$image" "$code"; then page_rows "$image" "$adapter" "$body" "$raw" || status=1; else status=1; fi
  rm -f "$body"
  return "$status"
}

# clean_rows IN OUT: copies the well-formed rows to OUT. Prints "<1 if a push time is not a number> <rows dropped for a malformed tag or digest>"
clean_rows() {
  local in=$1 out=$2
  : >"$out"
  awk -F'\t' -v OFS='\t' -v out="$out" '
    NF != 3 || $3 !~ /^[0-9]+$/ { bad_time = 1; next }
    length($1) > 128 || $1 !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ || length($2) != 71 || $2 !~ /^sha256:[0-9a-f]+$/ { dropped++; next }
    { print > out }
    END { printf "%d %d\n", bad_time, dropped }
  ' "$in"
}

# fetch_rows IMAGE OUT [USED]: every tag of the image with its digest and push time, newest first, one row per tag.
# USED are the tags in use (space-separated); paging goes on until they are listed. Exit 1: the registry could not be read, 2: no adapter.
fetch_rows() {
  local image=$1 out=$2 used=${3:-} host=${1%%/*} path=${1#*/} raw rows stats bad_time dropped status=0
  raw=$(mktemp)
  case "$host" in
  ghcr.io) fetch_ghcr "$image" "$raw" "$used" || status=1 ;;
  quay.io) fetch_quay "$image" "$raw" "$used" || status=1 ;;
  mcr.microsoft.com) fetch_once "$image" "$raw" "https://mcr.microsoft.com/api/v1/catalog/$path/tags?reg=mar" rows_mcr || status=1 ;;
  gcr.io | registry.k8s.io) fetch_once "$image" "$raw" "https://$host/v2/$path/tags/list" rows_gcr -L || status=1 ;;
  *)
    say "::error::unsupported registry $host for $image"
    status=2
    ;;
  esac
  if ((status == 0)); then
    rows=$(mktemp)
    stats=$(clean_rows "$raw" "$rows")
    read -r bad_time dropped <<<"$stats"
    if [[ "$bad_time" != 0 ]]; then
      say "::error::$image: a row of the registry listing has no usable push time"
      status=1
    elif [[ ! -s "$rows" ]]; then
      say "::error::$image: the registry listed no tags"
      status=1
    else
      if [[ "$dropped" != 0 ]]; then say "::warning::$image: dropped $dropped rows with a malformed tag or digest"; fi
      LC_ALL=C sort -s -t $'\t' -k3,3nr "$rows" | awk -F'\t' '!seen[$1]++' >"$out"
    fi
    rm -f "$rows"
  fi
  rm -f "$raw"
  return "$status"
}

# pull_auth URL OUT: writes a curl header file with the anonymous pull token that URL hands out. Prints why on failure.
pull_auth() {
  local url=$1 out=$2 body code token
  body=$(mktemp)
  code=$(http GET "$url" "$body")
  token=$(jq -r '.token | strings' "$body" 2>/dev/null) || token=""
  rm -f "$body"
  if [[ "$code" != 200 ]]; then
    echo "the pull token request answered $code"
    return 1
  fi
  if [[ ! "$token" =~ ^[A-Za-z0-9._~+/=-]+$ ]]; then
    echo "the registry gave no usable pull token"
    return 1
  fi
  printf 'Authorization: Bearer %s\n' "$token" >"$out"
}

# head_manifest IMAGE TAG OUT: writes the digest that the registry serves for the tag now to OUT, from a HEAD on its manifest. Prints why on failure.
head_manifest() {
  local image=$1 tag=$2 out=$3 host=${1%%/*} path=${1#*/} token_url="" hdr auth code digest why
  local args=(-H "Accept: $MANIFEST_ACCEPT")
  case "$host" in
  ghcr.io) token_url="https://ghcr.io/token?scope=repository:$path:pull&service=ghcr.io" ;;
  quay.io) token_url="https://quay.io/v2/auth?service=quay.io&scope=repository:$path:pull" ;;
  gcr.io)
    token_url="https://gcr.io/v2/token?scope=repository:$path:pull&service=gcr.io"
    args+=(-L)
    ;;
  registry.k8s.io) args+=(-L) ;;
  mcr.microsoft.com) ;;
  *)
    echo "there is no adapter for the registry $host"
    return 1
    ;;
  esac
  hdr=$(mktemp) auth=$(mktemp)
  if [[ -n "$token_url" ]]; then
    if ! why=$(pull_auth "$token_url" "$auth"); then
      rm -f "$hdr" "$auth"
      echo "$why"
      return 1
    fi
    args+=(-H "@$auth")
  fi
  code=$(http HEAD "https://$host/v2/$path/manifests/$tag" /dev/null -D "$hdr" "${args[@]}")
  digest=$(sed -n 's/^docker-content-digest:[[:space:]]*//Ip' "$hdr" | tr -d '\r' | tail -1)
  rm -f "$hdr" "$auth"
  if [[ "$code" != 2?? ]]; then
    echo "the registry answered $code"
    return 1
  fi
  if [[ ! "$digest" =~ $DIGEST_RE ]]; then
    echo "the registry sent no digest"
    return 1
  fi
  printf '%s\n' "$digest" >"$out"
}

# manifest_digest IMAGE TAG OUT: head_manifest, with a ::warning:: when the registry gives no digest. OUT is empty then.
manifest_digest() {
  local image=$1 tag=$2 out=$3 why
  : >"$out"
  if why=$(head_manifest "$image" "$tag" "$out"); then return 0; fi
  : >"$out"
  say "::warning::$image: could not read the digest of tag $tag ($why)"
  return 1
}

iso() {
  local epoch=$1
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# stored_unlisted IMAGE PREVIOUS [TAG]: the tag, digest and first-seen time (epoch seconds, never later than now) of the entries of the previous data for IMAGE, or just TAG, tab-separated
stored_unlisted() {
  local image=$1 previous=$2 tag=${3:-}
  jq -r --arg i "$image" --arg t "$tag" --argjson now "$(now)" '
    (.unlisted[$i] // {}) | to_entries[] | select($t == "" or .key == $t)
    | [.key, .value.digest, ([(.value.firstSeen | fromdateiso8601), $now] | min)] | @tsv' "$previous"
}

# listed_at IMAGE TAG DIGEST PREVIOUS: when the previous rows list the tag at the digest, the time the registry made it (epoch seconds, never later than now)
listed_at() {
  local image=$1 tag=$2 digest=$3 previous=$4
  jq -r --arg i "$image" --arg t "$tag" --arg d "$digest" --argjson now "$(now)" '
    [.rows[$i][]? | select(.tag == $t and .digest == $d) | .pushedAt] | max // empty | [., $now] | min' "$previous"
}

# resolve_unlisted IMAGE ROWS USED PREVIOUS OUT: for each tag in use that ROWS lack, the digest the registry serves now and when it was first seen:
# the stored entry's time for that digest, else the push time of that tag and digest in the previous rows, else now.
# OUT gets "tag digest seen current" per tag; current is 1 when the registry gave the digest in this run, 0 for an entry kept from PREVIOUS.
resolve_unlisted() {
  local image=$1 rows=$2 used=$3 previous=$4 out=$5 tag got now_at got_digest stored_digest stored_at seen
  : >"$out"
  got=$(mktemp)
  now_at=$(now)
  while read -r tag; do
    IFS=$'\t' read -r _ stored_digest stored_at <<<"$(stored_unlisted "$image" "$previous" "$tag")"
    if manifest_digest "$image" "$tag" "$got"; then
      got_digest=$(<"$got")
      seen=$stored_at
      if [[ "$got_digest" != "$stored_digest" ]]; then
        seen=$(listed_at "$image" "$tag" "$got_digest" "$previous")
        seen=${seen:-$now_at}
      fi
      printf '%s\t%s\t%s\t1\n' "$tag" "$got_digest" "$seen" >>"$out"
      if ((seen > now_at - MIN_AGE_SECONDS)); then
        say "::notice::$image: tag $tag is not among the builds the registry lists; its digest is admitted after 7 days of being seen (first seen $(iso "$seen"))"
      fi
    elif [[ -n "$stored_digest" ]]; then
      printf '%s\t%s\t%s\t0\n' "$tag" "$stored_digest" "$stored_at" >>"$out"
    fi
  done < <(missing_tags "$rows" "$used")
  rm -f "$got"
}

# carry_unlisted IMAGE USED PREVIOUS OUT: for an image that could not be listed, the stored entries of the tags in use, written to OUT as resolve_unlisted writes the ones it kept
carry_unlisted() {
  local image=$1 used=$2 previous=$3 out=$4
  stored_unlisted "$image" "$previous" | awk -F'\t' -v OFS='\t' -v used="$used" '
    BEGIN { n = split(used, u, " "); for (i = 1; i <= n; i++) U[u[i]] = 1 }
    $1 in U { print $1, $2, $3, 0 }
  ' >"$out"
}

# select_rows ROWS USED SKIPS: the tags (and digests) Renovate may use, newest first. USED and SKIPS are space-separated tags.
select_rows() {
  local rows=$1 used=$2 skips=$3 cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v OFS='\t' -v cut="$cut" -v keep="$KEEP_NEWEST" -v cosign="$COSIGN_TAG" -v used="$used" -v skip="$skips" '
    BEGIN {
      n = split(used, u, " "); for (i = 1; i <= n; i++) U[u[i]] = 1
      n = split(skip, s, " "); for (i = 1; i <= n; i++) S[s[i]] = 1
    }
    $3 !~ /^-?[0-9]+$/ { next }
    $3 > cut || $1 ~ cosign || ($1 in S) { next }
    { eligible++ }
    eligible <= keep || ($1 in U) { print $1, $2 }
  ' "$rows"
}

# trim_rows ROWS USED: the rows worth storing: every build younger than 7 days, the newest KEEP_NEWEST older ones and the tags in use
trim_rows() {
  local rows=$1 used=$2 cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v OFS='\t' -v cut="$cut" -v keep="$KEEP_NEWEST" -v cosign="$COSIGN_TAG" -v used="$used" '
    BEGIN { n = split(used, u, " "); for (i = 1; i <= n; i++) U[u[i]] = 1 }
    $1 ~ cosign { next }
    $3 > cut { print; next }
    { old++ }
    old <= keep || ($1 in U) { print }
  ' "$rows"
}

# allowed_regex TAG...: a Renovate regex that matches exactly these tags; fails when there are none
allowed_regex() {
  local tag escaped=()
  (($# > 0)) || return 1
  for tag in "$@"; do
    # shellcheck disable=SC2001
    escaped+=("$(sed 's#[][\\.+*?(){}|^$/]#\\&#g' <<<"$tag")")
  done
  printf '/^(%s)$/' "$(IFS='|' && printf '%s' "${escaped[*]}")"
}

# image_rules IMAGE SELECTED AT: the allowedVersions rule and the digest rule for one image; fails when no tag is selected
image_rules() {
  local image=$1 sel=$2 at=$3 tags map re
  [[ -s "$sel" ]] || return 1
  mapfile -t tags < <(cut -f1 "$sel")
  re=$(allowed_regex "${tags[@]}")
  map=$(jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}' "$sel" | jq -Sc .)
  jq -n --arg image "$image" --arg at "$(iso "$at")" --arg re "$re" --arg map "$map" '
    [{
      description: "image-age: \($image) tags built at least 7 days ago, dated \($at)",
      matchDatasources: ["docker"],
      matchPackageNames: [$image],
      allowedVersions: $re
    },
    {
      description: "image-age: \($image) rebuilds younger than 7 days wait, dated \($at)",
      matchDatasources: ["docker"],
      matchPackageNames: [$image],
      matchUpdateTypes: ["major", "minor", "patch", "digest"],
      matchJsonata: ["($m := \($map); $exists(newDigest) and ($exists($lookup($m, newValue)) ? $lookup($m, newValue) != newDigest : true))"],
      enabled: false
    }]'
}

# disabling_rule IMAGE AT: holds back every update of an image that could not be dated
disabling_rule() {
  local image=$1 at=$2
  jq -n --arg image "$image" --arg at "$(iso "$at")" '{
    description: "image-age: \($image) could not be dated, updates held back, \($at)",
    matchDatasources: ["docker"],
    matchPackageNames: [$image],
    enabled: false
  }'
}

# moved_images: the old names of the images Renovate moves to Docker Hub, as a JSON array
moved_images() {
  sed '/^[[:space:]]*\/\//d' "$RULES_FILE" |
    yq -p yaml -o json -I0 '[.packageRules[] | select(has("replacementName")) | .matchPackageNames[]]'
}

# assemble_preset BY_IMAGE OUT AT: BY_IMAGE maps each image to its rules; adds the catch-all and the stale guard
assemble_preset() {
  local by_image=$1 out=$2 at=$3 excluded
  excluded=$({
    printf '!%s/**\n' "${DOCKER_HUB_HOSTS[@]}" "${OUT_OF_SCOPE_HOSTS[@]}"
    printf '!%s**\n' "$OWN_IMAGES_PREFIX"
    moved_images | jq -r '.[] | "!" + .'
  } | jq -Rn '[inputs]')
  jq -S -n --slurpfile by "$by_image" --argjson excluded "$excluded" --argjson at "$at" --arg when "$(iso "$at")" --argjson stale "$STALE_SECONDS" '
    "/^[^/]+\\.[^/]+\\//" as $host
    | ["major", "minor", "patch", "digest"] as $types
    | {
        "$schema": "https://docs.renovatebot.com/renovate-schema.json",
        packageRules: (
          [$by[0] | to_entries | sort_by(.key)[] | .value[]]
          + [{
              description: "image-age: registry image not yet dated, picked up on its next run, \($when)",
              matchDatasources: ["docker"],
              matchPackageNames: ([$host] + $excluded + ($by[0] | keys | map("!" + .))),
              enabled: false
            },
            {
              description: "image-age: data older than 36h, see the image-age workflow in repo-operator, generated \($when)",
              matchDatasources: ["docker"],
              matchPackageNames: ([$host] + $excluded),
              matchUpdateTypes: $types,
              matchJsonata: ["$toMillis($now()) > \(($at + $stale) * 1000)"],
              enabled: false
            }]
        )
      }' >"$out"
}

repo_slug() {
  local url=$1
  sed -E 's#^https://github\.com/##; s#\.git$##' <<<"$url"
}

# public_repos: owner/name of every repo that takes the shared Renovate config
public_repos() {
  yq '.repos[] | select(.files.inherit != false) | .git' "$REPOS_FILE" | while read -r url; do repo_slug "$url"; done
}

# diagnose REPO LOG ERR: the first warning and error lines of Renovate's log (msg, errorMessage, err.message), the result of its run and the end of its stderr, for the job log and the report
# Each line starts with a label, so nothing in Renovate's output can start a workflow command; CR and LF become spaces.
diagnose() {
  local repo=$1 log=$2 err=$3 line
  say "Renovate output for $repo (warnings and errors of its log, the result of its run, end of its stderr):"
  while IFS= read -r line; do
    say "  $line"
  done < <(jq -Rnr --argjson max "$DIAGNOSIS_LOG_LINES" '
    def clean: tostring | gsub("[\r\n]+"; " ");
    [inputs | fromjson? | select(type == "object")] as $lines
    | ($lines | map(select((.level | type) == "number" and .level >= 40)) | .[:$max][]
        | "log: " + ([.msg // "no message", (.errorMessage | strings), (.err | objects | .message | strings)] | map(clean) | join(": "))),
      ($lines[] | select(.msg == "Repository finished" and (.result | type) == "string") | "result: " + (.result | clean))' "$log")
  while IFS= read -r line; do
    say "  stderr: $line"
  done < <(tail -n "$DIAGNOSIS_ERR_LINES" "$err" | tr '\r' ' ')
  return 0
}

# extract_repo REPO OUT LOGS: one JSON object per third-party registry image reference found in REPO; Renovate's log and stderr stay in LOGS
extract_repo() {
  local repo=$1 out=$2 logs=$3 log err all name status=0
  log="$logs/${repo//\//__}.log" err="$logs/${repo//\//__}.err"
  all=$(mktemp)
  # Setting both username and git author keeps Renovate from asking GitHub who the token belongs to
  if ! RENOVATE_TOKEN="$GITHUB_TOKEN" LOG_FORMAT=json LOG_LEVEL=info RENOVATE_X_IGNORE_RE2=true \
    RENOVATE_USERNAME="github-actions[bot]" RENOVATE_GIT_AUTHOR="github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>" \
    npm_config_omit=optional npx --yes "renovate@$RENOVATE_VERSION" --dry-run=extract --platform=github "$repo" >"$log" 2>"$err"; then
    diagnose "$repo" "$log" "$err"
    rm -f "$all"
    return 1
  fi
  if ! jq -Rse 'split("\n") | map(fromjson? // empty) | any(.[]; .msg == "Extracted dependencies" and (.packageFiles | type) == "object")' "$log" >/dev/null; then
    diagnose "$repo" "$log" "$err"
    rm -f "$all"
    return 1
  fi
  jq -Rsc --arg repo "$repo" --argjson moved "$(moved_images)" \
    --argjson hubs "$(printf '%s\n' "${DOCKER_HUB_HOSTS[@]}" | jq -R . | jq -sc .)" \
    --argjson skipped "$(printf '%s\n' "${OUT_OF_SCOPE_HOSTS[@]}" | jq -R . | jq -sc .)" \
    --arg own "$OWN_IMAGES_PREFIX" '
    split("\n") | map(fromjson? // empty)
    | map(select(.msg == "Extracted dependencies") | .packageFiles | [.[][] | .deps[]]) | add // []
    | .[] | select(.datasource == "docker" and .skipReason == null)
    | {image: (.packageName // .depName), tag: .currentValue, digest: .currentDigest, repo: $repo}
    | select(.image | type == "string")
    | select(.image as $i | ($i | split("/")[0]) as $h | ($h | contains(".")) and ($hubs | index($h) | not) and ($skipped | index($h) | not)
        and ($i | startswith($own) | not) and ($moved | index($i) | not))' "$log" >"$all" || status=1
  if ((status == 0)); then
    while IFS= read -r name; do
      say "::error::dropped the image name $name found in $repo: not a valid image reference"
    done < <(jq -r --arg re "$IMAGE_RE" 'select(.image | test($re) | not) | .image | @json' "$all")
    jq -c --arg re "$IMAGE_RE" 'select(.image | test($re))' "$all" >"$out" || status=1
  fi
  if ((status != 0)); then diagnose "$repo" "$log" "$err"; fi
  rm -f "$all"
  return "$status"
}

cmd_extract() {
  local out=$1 repo refs failed=() tmp
  mkdir -p "$out"
  REPORT="$out/report.txt"
  : >"$REPORT"
  refs=$(mktemp)
  while read -r repo; do
    tmp=$(mktemp)
    if extract_repo "$repo" "$tmp" "$out"; then
      cat "$tmp" >>"$refs"
    else
      say "::error::extracting the images of $repo failed, its previous rules stay"
      failed+=("$repo")
    fi
    rm -f "$tmp"
  done < <(public_repos)
  jq -s --argjson failed "$(printf '%s\n' "${failed[@]}" | jq -R 'select(. != "")' | jq -sc 'sort')" '
    {
      failedRepos: $failed,
      images: (group_by(.image) | map({key: .[0].image, value: {
        tags: ([.[].tag | select(. != null)] | unique),
        pins: ([.[] | select(.tag != null and .digest != null) | {repo, tag, digest}] | unique)
      }}) | from_entries)
    }' "$refs" >"$out/inventory.json"
  rm -f "$refs"
}

# clean_inventory FILE OUT WHERE: FILE's inventory without the image names, tags and pins that are malformed; each dropped name is reported
clean_inventory() {
  local file=$1 out=$2 where=$3 name
  while IFS= read -r name; do
    say "::error::dropped the image name $name from $where"
  done < <(jq -r --arg re "$IMAGE_RE" '.images | keys[] | select(test($re) | not) | @json' "$file")
  jq -c --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --arg repo "$REPO_RE" '
    .images |= (to_entries | map(select(.key | test($re))
      | .value.tags |= map(select(type == "string" and test($tag)))
      | .value.pins |= map(select((.repo | type == "string" and test($repo)) and (.tag | type == "string" and test($tag)) and (.digest | type == "string" and test($dig)))))
      | from_entries)' "$file" >"$out"
}

# fetch_contents URL OUT: the raw content of a file through the contents API; prints the HTTP status
fetch_contents() {
  local code
  code=$(GH_ACCEPT=application/vnd.github.raw+json gh_http GET "$1" "$2")
  printf '%s' "$code"
}

# shellcheck disable=SC2016
ROW_OK='def row_ok: (.tag | type == "string" and test($tag)) and (.digest | type == "string" and test($dig))
  and (.pushedAt | type == "number" and . >= 0 and . == floor);'

# shellcheck disable=SC2016
UNLISTED_OK='def entries: if type == "object" then to_entries else [] end;
  def time_ok: type == "string" and test($iso) and (try (fromdateiso8601 | true) catch false);
  def entry_ok: (.key | test($tag)) and (.value | type == "object") and (.value.digest | type == "string" and test($dig))
    and (.value.firstSeen | time_ok);'

# previous_data OUT: the data of the last published run, checked as fresh data is. The empty shape on the first run.
previous_data() {
  local out=$1 raw code inv
  raw=$(mktemp) inv=$(mktemp)
  code=$(fetch_contents "$API/repos/$DATA_REPO/contents/$STATE_FILE?ref=$DATA_BRANCH" "$raw")
  case "$code" in
  200)
    if ! jq -e '(.rows | type) == "object" and (.inventory.images | type) == "object" and ((.unlisted // {}) | type) == "object"' "$raw" >/dev/null 2>&1; then
      say "::error::the stored $STATE_FILE is not data that render writes"
      rm -f "$raw" "$inv"
      return 1
    fi
    ;;
  404) echo '{"inventory":{"failedRepos":[],"images":{}},"rows":{}}' >"$raw" ;;
  *)
    say "::error::reading the stored $STATE_FILE answered $code"
    rm -f "$raw" "$inv"
    return 1
    ;;
  esac
  local name image dropped
  while IFS= read -r name; do
    say "::error::dropped the image name $name from the previous data"
  done < <(jq -r --arg re "$IMAGE_RE" '[.rows, (.unlisted // {})] | map(keys) | add | unique[] | select(test($re) | not) | @json' "$raw")
  while IFS=$'\t' read -r image dropped; do
    say "::error::dropped $dropped rows of $image from the previous data"
  done < <(jq -r --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" "$ROW_OK"'
    .rows | to_entries[] | select(.key | test($re))
    | [.key, ((.value | length) - (.value | map(select(row_ok)) | length))] | select(.[1] > 0) | @tsv' "$raw")
  while IFS=$'\t' read -r image dropped; do
    say "::error::dropped $dropped unlisted entries of $image from the previous data"
  done < <(jq -r --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --arg iso "$ISO_RE" "$UNLISTED_OK"'
    (.unlisted // {}) | to_entries[] | select(.key | test($re))
    | [.key, ((if (.value | type) == "object" then (.value | length) else 1 end) - (.value | entries | map(select(entry_ok)) | length))] | select(.[1] > 0) | @tsv' "$raw")
  jq '.inventory' "$raw" >"$inv.in"
  clean_inventory "$inv.in" "$inv" "the previous data"
  jq -c --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --arg iso "$ISO_RE" --slurpfile inv "$inv" "$ROW_OK $UNLISTED_OK"'
    {generatedAt: (.generatedAt | if time_ok then . else null end), inventory: $inv[0], rows: (.rows | to_entries | map(select(.key | test($re)) | .value |= map(select(row_ok))) | from_entries),
     unlisted: ((.unlisted // {}) | to_entries | map(select(.key | test($re)) | .value |= (entries | map(select(entry_ok)) | from_entries)) | map(select(.value | length > 0)) | from_entries)}' "$raw" >"$out"
  rm -f "$raw" "$inv" "$inv.in"
}

# stored_rows IMAGE PREVIOUS OUT: the stored rows of an image as tab-separated rows, newest first
stored_rows() {
  local image=$1 previous=$2 out=$3
  jq -r --arg i "$image" '.rows[$i] // [] | .[] | [.tag, .digest, .pushedAt] | @tsv' "$previous" | LC_ALL=C sort -s -t $'\t' -k3,3nr >"$out"
}

# dated_rules IMAGE INVENTORY SKIPS PREVIOUS WORKDIR: writes the rules for one image to WORKDIR/rules.json, the rows to keep to WORKDIR/stored and the unlisted tags to WORKDIR/unlisted
dated_rules() {
  local image=$1 inventory=$2 skips=$3 previous=$4 work=$5 used skip status=0
  used=$(jq -r --arg i "$image" '.images[$i].tags | join(" ")' "$inventory")
  skip=$(jq -r --arg i "$image" '.[$i] // [] | join(" ")' <<<"$skips")
  rm -f "$work/rows"
  : >"$work/stored"
  : >"$work/unlisted"
  fetch_rows "$image" "$work/rows" "$used" || status=$?
  if ((status == 1)); then
    stored_rows "$image" "$previous" "$work/rows"
    if [[ -s "$work/rows" ]]; then
      say "image-age: $image keeps its stored rows"
      status=0
    fi
  fi
  if ((status != 0)); then
    carry_unlisted "$image" "$used" "$previous" "$work/unlisted"
    disabling_rule "$image" "$(now)" | jq -s . >"$work/rules.json"
    return 0
  fi
  resolve_unlisted "$image" "$work/rows" "$used" "$previous" "$work/unlisted"
  trim_rows "$work/rows" "$used" >"$work/stored"
  select_rows "$work/rows" "$used" "$skip" >"$work/selected"
  awk -F'\t' -v OFS='\t' '$4 == 1 { print $1, $2, $3 }' "$work/unlisted" >"$work/seen"
  select_rows "$work/seen" "$used" "$skip" >>"$work/selected"
  if [[ -s "$work/selected" ]]; then
    image_rules "$image" "$work/selected" "$(now)" >"$work/rules.json"
  else
    say "image-age: $image has no tag at least 7 days old, updates held back"
    disabling_rule "$image" "$(now)" | jq -s . >"$work/rules.json"
  fi
}

# override_guard INVENTORY: a repo rule in renovate-overrides.json5 that enables a dated image or sets allowedVersions for it is reported
override_guard() {
  local inventory=$1 repo code raw parsed
  raw=$(mktemp)
  while read -r repo; do
    code=$(fetch_contents "$API/repos/$repo/contents/renovate-overrides.json5" "$raw")
    case "$code" in
    404) continue ;;
    200) ;;
    *)
      say "::error::$repo renovate-overrides.json5 answered $code"
      continue
      ;;
    esac
    if ! parsed=$(sed -e '/^[[:space:]]*\/\//d' -e 's#[[:space:]]//[[:space:]].*$##' "$raw" | yq -p yaml -o json -I0 '.' 2>/dev/null); then
      say "::error::$repo renovate-overrides.json5 could not be read"
      continue
    fi
    jq -r --slurpfile inv "$inventory" '
      (.packageRules // [])[]
      | select((.matchDatasources // ["docker"]) | index("docker"))
      | . as $rule
      | (($rule.matchPackageNames // []) + ($rule.matchDepNames // []))[] as $name
      | select($name | type == "string")
      | select($inv[0].images | has($name))
      | (if $rule.enabled == true then ["error", "enabled: true", $name] else empty end),
        (if $rule | has("allowedVersions") then ["warning", "allowedVersions", $name] else empty end)
      | @tsv' <<<"$parsed" | sort -u | while IFS=$'\t' read -r level what image; do
      say "::$level::$repo renovate-overrides.json5 sets $what for $image; tag skips for registry images go in .github/renovate/image-age-skips.yaml"
    done
  done < <(public_repos)
  rm -f "$raw"
}

# clock_ok PREVIOUS: the time is not earlier than the last published run; prints why when it is
clock_ok() {
  local previous=$1 last
  last=$(jq -r '(.generatedAt // empty) | fromdateiso8601' "$previous")
  if [[ -n "$last" ]] && (($(now) < last)); then
    say "::error::the clock reads $(iso "$(now)"), earlier than the last published run at $(iso "$last")"
    return 1
  fi
}

cmd_render() {
  local in=$1 out=$2 work previous skips image count
  mkdir -p "$out"
  REPORT="$out/report.txt"
  if [[ -f "$in/report.txt" ]]; then cp "$in/report.txt" "$REPORT"; else : >"$REPORT"; fi
  init_auth
  work=$(mktemp -d)
  previous="$work/previous.json"
  previous_data "$previous" || return 1
  clock_ok "$previous" || return 1
  clean_inventory "$in/inventory.json" "$work/inventory.json" "the inventory"
  if [[ "$(jq '.failedRepos | length' "$work/inventory.json")" -gt 0 ]]; then
    jq -c --slurpfile prev "$previous" '.images = ($prev[0].inventory.images + .images)' "$work/inventory.json" >"$work/merged.json"
    mv "$work/merged.json" "$work/inventory.json"
  fi
  skips=$(yq -o json -I0 '. // {}' "$SKIPS_FILE")
  echo '{}' >"$work/by-image.json"
  echo '{}' >"$work/stored.json"
  echo '{}' >"$work/unlisted.json"
  while read -r image; do
    dated_rules "$image" "$work/inventory.json" "$skips" "$previous" "$work"
    jq --arg i "$image" --slurpfile r "$work/rules.json" '.[$i] = $r[0]' "$work/by-image.json" >"$work/tmp.json"
    mv "$work/tmp.json" "$work/by-image.json"
    if [[ -s "$work/stored" ]]; then
      jq --arg i "$image" --slurpfile s <(jq -Rn '[inputs | split("\t") | {tag: .[0], digest: .[1], pushedAt: (.[2] | tonumber)}]' "$work/stored") \
        '.[$i] = $s[0]' "$work/stored.json" >"$work/tmp.json"
      mv "$work/tmp.json" "$work/stored.json"
    fi
    if [[ -s "$work/unlisted" ]]; then
      jq --arg i "$image" --slurpfile u <(jq -Rn '[inputs | split("\t") | {key: .[0], value: {digest: .[1], firstSeen: (.[2] | tonumber | todate)}}] | from_entries' "$work/unlisted") \
        '.[$i] = $u[0]' "$work/unlisted.json" >"$work/tmp.json"
      mv "$work/tmp.json" "$work/unlisted.json"
    fi
  done < <(jq -r '.images | keys[]' "$work/inventory.json")
  override_guard "$work/inventory.json"
  assemble_preset "$work/by-image.json" "$out/$DATA_FILE" "$(now)"
  jq -S -n --arg at "$(iso "$(now)")" --slurpfile inv "$work/inventory.json" --slurpfile rows "$work/stored.json" --slurpfile unlisted "$work/unlisted.json" \
    '{generatedAt: $at, inventory: $inv[0], rows: $rows[0], unlisted: $unlisted[0]}' >"$out/$STATE_FILE"
  count=$(jq '.packageRules | length' "$out/$DATA_FILE")
  say "image-age: $count rules for $(jq length "$work/by-image.json") images"
  rm -rf "$work"
}

sha256_of() {
  local file=$1
  sha256sum <"$file" | cut -d' ' -f1
}

cmd_hashes() {
  local dir=$1
  printf 'preset=%s\ndata=%s\n' "$(sha256_of "$dir/$DATA_FILE")" "$(sha256_of "$dir/$STATE_FILE")"
}

# preset_problems FILE: one line per way FILE differs from the shape that render writes
preset_problems() {
  local file=$1 pre suf
  # shellcheck disable=SC2016
  pre='($m := '
  # shellcheck disable=SC2016
  suf='; $exists(newDigest) and ($exists($lookup($m, newValue)) ? $lookup($m, newValue) != newDigest : true))'
  jq -r --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --arg pre "$pre" --arg suf "$suf" \
    --arg av '^/\^\(([A-Za-z0-9_.\\-]+)(\|[A-Za-z0-9_.\\-]+)*\)\$/$' --arg stale '^\$toMillis\(\$now\(\)\) > [0-9]+$' '
    def types: ["major", "minor", "patch", "digest"];
    def host: "/^[^/]+\\.[^/]+\\//";
    def within($allowed): (keys - $allowed) == [];
    def excl_ok: .matchPackageNames[1:] | all(type == "string" and test("^![A-Za-z0-9._*:/-]+$"));
    def digest_expr_ok:
      . as $e
      | type == "string" and ($e | startswith($pre)) and ($e | endswith($suf))
        and (try ($e[($pre | length):(($e | length) - ($suf | length))] | fromjson
            | type == "object" and all(to_entries[]; (.key | test($tag)) and (.value | test($dig))) and ($pre + tojson + $suf == $e)) catch false);
    def kind:
      if (.matchPackageNames | type) != "array" or (.matchPackageNames | length) == 0 then "unknown"
      elif .matchPackageNames[0] == host then (if has("matchUpdateTypes") then "stale" else "catchall" end)
      elif (.matchPackageNames | length) == 1 and (.matchPackageNames[0] | type == "string" and test($re)) then
        (if has("allowedVersions") then "allow" elif has("matchJsonata") then "digest" else "hold" end)
      else "unknown" end;
    def valid:
      type == "object" and (.description | type) == "string" and .matchDatasources == ["docker"]
      and (kind as $k
        | if $k == "allow" then
            within(["description", "matchDatasources", "matchPackageNames", "allowedVersions"]) and (.allowedVersions | type == "string" and test($av))
          elif $k == "digest" then
            within(["description", "matchDatasources", "matchPackageNames", "matchUpdateTypes", "matchJsonata", "enabled"])
            and .matchUpdateTypes == types and .enabled == false and (.matchJsonata | type == "array" and length == 1 and (.[0] | digest_expr_ok))
          elif $k == "hold" then
            within(["description", "matchDatasources", "matchPackageNames", "enabled"]) and .enabled == false
          elif $k == "catchall" then
            within(["description", "matchDatasources", "matchPackageNames", "enabled"]) and .enabled == false and excl_ok
          elif $k == "stale" then
            within(["description", "matchDatasources", "matchPackageNames", "matchUpdateTypes", "matchJsonata", "enabled"])
            and .matchUpdateTypes == types and .enabled == false and excl_ok
            and (.matchJsonata | type == "array" and length == 1 and (.[0] | type == "string" and test($stale)))
          else false end);
    if type != "object" then "the preset is not a JSON object"
    elif (keys - ["$schema", "packageRules"]) != [] then "the preset has keys other than $schema and packageRules"
    elif (.packageRules | type) != "array" then "packageRules is not an array"
    else
      .packageRules as $rules
      | ($rules | to_entries[] | select(.value | valid | not) | "rule \(.key) is not a rule that render writes"),
        (if ([$rules[] | select(type == "object" and valid and kind == "catchall")] | length) != 1 then "the catch-all rule is missing or repeated" else empty end),
        (if ([$rules[] | select(type == "object" and valid and kind == "stale")] | length) != 1 then "the stale guard is missing or repeated" else empty end),
        ([$rules[] | select(type == "object" and valid and (kind == "allow" or kind == "digest" or kind == "hold"))] | group_by(.matchPackageNames[0])[]
          | select((map(kind) | sort) as $k | $k != ["allow", "digest"] and $k != ["hold"])
          | "the rules of \(.[0].matchPackageNames[0] | @json) are not one allowedVersions rule and one digest rule, or one hold rule")
    end' "$file"
}

cmd_validate() {
  local dir=$1 file state size problem bad=0
  file="$dir/$DATA_FILE" state="$dir/$STATE_FILE"
  if ! jq -e . "$file" >/dev/null 2>&1; then
    say "::error::$DATA_FILE is not valid JSON"
    return 1
  fi
  size=$(wc -c <"$file")
  if ((size > MAX_BYTES)); then
    say "::error::$DATA_FILE is $size bytes, above the $MAX_BYTES byte limit"
    return 1
  fi
  while IFS= read -r problem; do
    say "::error::$DATA_FILE: $problem"
    bad=1
  done < <(preset_problems "$file")
  if [[ ! -f "$state" ]] || ! jq -e 'type == "object" and (.generatedAt | type) == "string" and (.inventory.images | type) == "object" and (.rows | type) == "object"' "$state" >/dev/null 2>&1; then
    say "::error::$STATE_FILE is missing or is not an object with generatedAt, inventory and rows"
    bad=1
  elif (($(wc -c <"$state") > MAX_DATA_BYTES)); then
    say "::error::$STATE_FILE is above the $MAX_DATA_BYTES byte limit"
    bad=1
  elif ! jq -e --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --arg iso "$ISO_RE" "$UNLISTED_OK"'
      (if has("unlisted") then .unlisted else {} end) | type == "object" and all(to_entries[]; (.key | test($re)) and (.value | type == "object") and all(.value | entries[]; entry_ok))' "$state" >/dev/null 2>&1; then
    say "::error::$STATE_FILE: unlisted is not a map of image to tag to a digest and a first-seen time"
    bad=1
  fi
  if ((bad != 0)); then return 1; fi
  if ! npm_config_omit=optional RENOVATE_X_IGNORE_RE2=true npx --yes --package "renovate@$RENOVATE_VERSION" -- renovate-config-validator --strict --no-global "$file"; then
    say "::error::the Renovate config validator rejected $DATA_FILE"
    return 1
  fi
}

# check_hash FILE EXPECTED: the artifact file is the one render hashed
check_hash() {
  local file=$1 expected=$2
  if [[ "$(sha256_of "$file")" == "$expected" ]]; then return 0; fi
  say "::error::$(basename "$file") does not match the hash that render reported"
  return 1
}

# put_file DIR NAME: writes DIR/NAME to the data repo with one contents API call, which GitHub signs
put_file() {
  local dir=$1 name=$2 url="$API/repos/$DATA_REPO/contents/$2" out body code sha=""
  out=$(mktemp) body=$(mktemp)
  code=$(gh_http GET "$url?ref=$DATA_BRANCH" "$out")
  case "$code" in
  200) sha=$(jq -r '.sha' "$out") ;;
  404) ;;
  *)
    say "::error::reading $name in $DATA_REPO answered $code"
    rm -f "$out" "$body"
    return 1
    ;;
  esac
  base64 -w0 "$dir/$name" | jq -Rs --arg m "chore(renovate): refresh $name" --arg s "$sha" --arg b "$DATA_BRANCH" \
    '{message: $m, content: ., branch: $b} + (if $s == "" then {} else {sha: $s} end)' >"$body"
  code=$(gh_http PUT "$url" "$out" -H 'Content-Type: application/json' --data-binary "@$body")
  rm -f "$out" "$body"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    say "::error::writing $name to $DATA_REPO answered $code"
    return 1
  fi
}

cmd_publish() {
  local in=$1
  if [[ -z "${PRESET_SHA256:-}" || -z "${DATA_SHA256:-}" ]]; then
    say "::error::the hashes that render reports are missing"
    return 1
  fi
  check_hash "$in/$DATA_FILE" "$PRESET_SHA256" || return 1
  check_hash "$in/$STATE_FILE" "$DATA_SHA256" || return 1
  init_auth
  put_file "$in" "$STATE_FILE" || return 1
  put_file "$in" "$DATA_FILE" || return 1
  say "image-age: published $DATA_FILE and $STATE_FILE to $DATA_REPO"
  if grep -q '^::error::' "$in/report.txt"; then
    say "::error::image-age data was published with errors, see the extract and render steps above"
    return 1
  fi
}

usage() {
  echo "usage: image-age.sh extract --out DIR | render --in DIR --out DIR | hashes --in DIR | validate --in DIR | publish --in DIR" >&2
  exit 2
}

main() {
  local cmd=${1:-} in="" out=""
  shift || usage
  while (($#)); do
    case "$1" in
    --in) in=${2:?} && shift 2 ;;
    --out) out=${2:?} && shift 2 ;;
    *) usage ;;
    esac
  done
  case "$cmd" in
  extract)
    [[ -n "$out" ]] || usage
    cmd_extract "$out"
    ;;
  render)
    [[ -n "$in" && -n "$out" ]] || usage
    cmd_render "$in" "$out"
    ;;
  hashes)
    [[ -n "$in" ]] || usage
    cmd_hashes "$in"
    ;;
  validate)
    [[ -n "$in" ]] || usage
    cmd_validate "$in"
    ;;
  publish)
    [[ -n "$in" ]] || usage
    cmd_publish "$in"
    ;;
  *) usage ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
