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
  if [[ "$method" != GET ]]; then args+=(-X "$method"); fi
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
  local cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v cut="$cut" -v cosign="$COSIGN_TAG" '$3 <= cut && $1 !~ cosign && !seen[$1]++ { n++ } END { print n + 0 }' "$1"
}

# missing_tags ROWS USED: the tags in use (space-separated) that ROWS do not list, one per line
missing_tags() {
  awk -F'\t' -v used="$2" '
    { listed[$1] = 1 }
    END { n = split(used, u, " "); for (i = 1; i <= n; i++) if (!(u[i] in listed)) print u[i] }
  ' "$1"
}

# enough_rows ROWS USED: KEEP_NEWEST old tags are listed and so is every tag in use
enough_rows() {
  [[ "$(old_count "$1")" -ge "$KEEP_NEWEST" && -z "$(missing_tags "$1" "$2")" ]]
}

# page_cap IMAGE RAW: at the page cap, the listing is complete enough once KEEP_NEWEST old tags are in
page_cap() {
  if [[ "$(old_count "$2")" -ge "$KEEP_NEWEST" ]]; then return 0; fi
  say "::error::$1: more than $MAX_PAGES pages of tags needed"
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
  if [[ "$2" == 200 ]]; then return 0; fi
  say "::error::$1: registry answered $2"
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
  local hdr body status=0
  hdr=$(mktemp) body=$(mktemp)
  ghcr_pages "$1" "$2" "$3" "$hdr" "$body" || status=1
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
  local body status=0
  body=$(mktemp)
  quay_pages "$1" "$2" "$3" "$body" || status=1
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
  : >"$2"
  awk -F'\t' -v OFS='\t' -v out="$2" '
    NF != 3 || $3 !~ /^[0-9]+$/ { bad_time = 1; next }
    length($1) > 128 || $1 !~ /^[A-Za-z0-9_][A-Za-z0-9_.-]*$/ || length($2) != 71 || $2 !~ /^sha256:[0-9a-f]+$/ { dropped++; next }
    { print > out }
    END { printf "%d %d\n", bad_time, dropped }
  ' "$1"
}

# fetch_rows IMAGE OUT [USED]: every tag of the image with its digest and push time, newest first, one row per tag.
# USED are the tags in use (space-separated); paging goes on until they are listed. Exit 1: the registry could not be read, 2: no adapter.
fetch_rows() {
  local image=$1 out=$2 used=${3:-} host=${1%%/*} path=${1#*/} raw rows stats bad_time dropped tag status=0
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
      while read -r tag; do
        say "::warning::$image: tag $tag in use was not listed by the registry"
      done < <(missing_tags "$out" "$used")
    fi
    rm -f "$rows"
  fi
  rm -f "$raw"
  return "$status"
}

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# select_rows ROWS USED SKIPS: the tags (and digests) Renovate may use, newest first. USED and SKIPS are space-separated tags.
select_rows() {
  local cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v OFS='\t' -v cut="$cut" -v keep="$KEEP_NEWEST" -v cosign="$COSIGN_TAG" -v used="$2" -v skip="$3" '
    BEGIN {
      n = split(used, u, " "); for (i = 1; i <= n; i++) U[u[i]] = 1
      n = split(skip, s, " "); for (i = 1; i <= n; i++) S[s[i]] = 1
    }
    $3 > cut || $1 ~ cosign || ($1 in S) { next }
    { eligible++ }
    eligible <= keep || ($1 in U) { print $1, $2 }
  ' "$1"
}

# trim_rows ROWS USED: the rows worth storing: every build younger than 7 days, the newest KEEP_NEWEST older ones and the tags in use
trim_rows() {
  local cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v OFS='\t' -v cut="$cut" -v keep="$KEEP_NEWEST" -v cosign="$COSIGN_TAG" -v used="$2" '
    BEGIN { n = split(used, u, " "); for (i = 1; i <= n; i++) U[u[i]] = 1 }
    $1 ~ cosign { next }
    $3 > cut { print; next }
    { old++ }
    old <= keep || ($1 in U) { print }
  ' "$1"
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

# image_rules IMAGE SELECTED NOW: the allowedVersions rule and the digest rule for one image; fails when no tag is selected
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

# disabling_rule IMAGE NOW: holds back every update of an image that could not be dated
disabling_rule() {
  jq -n --arg image "$1" --arg at "$(iso "$2")" '{
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

# assemble_preset BY_IMAGE OUT NOW: BY_IMAGE maps each image to its rules; adds the catch-all and the stale guard
assemble_preset() {
  local excluded
  excluded=$({
    printf '!%s/**\n' "${DOCKER_HUB_HOSTS[@]}" "${OUT_OF_SCOPE_HOSTS[@]}"
    printf '!%s**\n' "$OWN_IMAGES_PREFIX"
    moved_images | jq -r '.[] | "!" + .'
  } | jq -Rn '[inputs]')
  jq -S -n --slurpfile by "$1" --argjson excluded "$excluded" --argjson at "$3" --arg when "$(iso "$3")" --argjson stale "$STALE_SECONDS" '
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
      }' >"$2"
}

repo_slug() { sed -E 's#^https://github\.com/##; s#\.git$##' <<<"$1"; }

# public_repos: owner/name of every repo that takes the shared Renovate config
public_repos() {
  yq '.repos[] | select(.files.inherit != false) | .git' "$REPOS_FILE" | while read -r url; do repo_slug "$url"; done
}

# extract_repo REPO OUT: one JSON object per third-party registry image reference found in REPO
extract_repo() {
  local repo=$1 out=$2 log err all name status=0
  log=$(mktemp) err=$(mktemp) all=$(mktemp)
  if ! RENOVATE_TOKEN="$GITHUB_TOKEN" LOG_FORMAT=json LOG_LEVEL=info \
    npx --yes "renovate@$RENOVATE_VERSION" --dry-run=extract --platform=github "$repo" >"$log" 2>"$err"; then
    tail -n 5 "$err"
    rm -f "$log" "$err" "$all"
    return 1
  fi
  if ! jq -Rse 'split("\n") | map(fromjson? // empty) | any(.[]; .msg == "Extracted dependencies" and (.packageFiles | type) == "object")' "$log" >/dev/null; then
    rm -f "$log" "$err" "$all"
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
  rm -f "$log" "$err" "$all"
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
    if extract_repo "$repo" "$tmp"; then
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
  local name
  while IFS= read -r name; do
    say "::error::dropped the image name $name from $3"
  done < <(jq -r --arg re "$IMAGE_RE" '.images | keys[] | select(test($re) | not) | @json' "$1")
  jq -c --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --arg repo "$REPO_RE" '
    .images |= (to_entries | map(select(.key | test($re))
      | .value.tags |= map(select(type == "string" and test($tag)))
      | .value.pins |= map(select((.repo | type == "string" and test($repo)) and (.tag | type == "string" and test($tag)) and (.digest | type == "string" and test($dig)))))
      | from_entries)' "$1" >"$2"
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

# previous_data OUT: the data of the last published run, checked as fresh data is. The empty shape on the first run.
previous_data() {
  local raw code inv
  raw=$(mktemp) inv=$(mktemp)
  code=$(fetch_contents "$API/repos/$DATA_REPO/contents/$STATE_FILE?ref=$DATA_BRANCH" "$raw")
  case "$code" in
  200)
    if ! jq -e '(.rows | type) == "object" and (.inventory.images | type) == "object"' "$raw" >/dev/null 2>&1; then
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
  done < <(jq -r --arg re "$IMAGE_RE" '.rows | keys[] | select(test($re) | not) | @json' "$raw")
  while IFS=$'\t' read -r image dropped; do
    say "::error::dropped $dropped rows of $image from the previous data"
  done < <(jq -r --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" "$ROW_OK"'
    .rows | to_entries[] | select(.key | test($re))
    | [.key, ((.value | length) - (.value | map(select(row_ok)) | length))] | select(.[1] > 0) | @tsv' "$raw")
  jq '.inventory' "$raw" >"$inv.in"
  clean_inventory "$inv.in" "$inv" "the previous data"
  jq -c --arg re "$IMAGE_RE" --arg tag "$TAG_RE" --arg dig "$DIGEST_RE" --slurpfile inv "$inv" "$ROW_OK"'
    {inventory: $inv[0], rows: (.rows | to_entries | map(select(.key | test($re)) | .value |= map(select(row_ok))) | from_entries)}' "$raw" >"$1"
  rm -f "$raw" "$inv" "$inv.in"
}

# stored_rows IMAGE PREVIOUS OUT: the stored rows of an image as tab-separated rows, newest first
stored_rows() {
  jq -r --arg i "$1" '.rows[$i] // [] | .[] | [.tag, .digest, .pushedAt] | @tsv' "$2" | LC_ALL=C sort -s -t $'\t' -k3,3nr >"$3"
}

# dated_rules IMAGE INVENTORY SKIPS PREVIOUS WORKDIR: writes the rules for one image to WORKDIR/rules.json and the rows to keep to WORKDIR/stored
dated_rules() {
  local image=$1 inventory=$2 skips=$3 previous=$4 work=$5 used skip status=0
  used=$(jq -r --arg i "$image" '.images[$i].tags | join(" ")' "$inventory")
  skip=$(jq -r --arg i "$image" '.[$i] // [] | join(" ")' <<<"$skips")
  rm -f "$work/rows"
  : >"$work/stored"
  fetch_rows "$image" "$work/rows" "$used" || status=$?
  if ((status == 1)); then
    stored_rows "$image" "$previous" "$work/rows"
    if [[ -s "$work/rows" ]]; then
      say "image-age: $image keeps its stored rows"
      status=0
    fi
  fi
  if ((status != 0)); then
    disabling_rule "$image" "$(now)" | jq -s . >"$work/rules.json"
    return 0
  fi
  trim_rows "$work/rows" "$used" >"$work/stored"
  select_rows "$work/rows" "$used" "$skip" >"$work/selected"
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

cmd_render() {
  local in=$1 out=$2 work previous skips image count
  mkdir -p "$out"
  REPORT="$out/report.txt"
  if [[ -f "$in/report.txt" ]]; then cp "$in/report.txt" "$REPORT"; else : >"$REPORT"; fi
  init_auth
  work=$(mktemp -d)
  previous="$work/previous.json"
  previous_data "$previous" || return 1
  clean_inventory "$in/inventory.json" "$work/inventory.json" "the inventory"
  if [[ "$(jq '.failedRepos | length' "$work/inventory.json")" -gt 0 ]]; then
    jq -c --slurpfile prev "$previous" '.images = ($prev[0].inventory.images + .images)' "$work/inventory.json" >"$work/merged.json"
    mv "$work/merged.json" "$work/inventory.json"
  fi
  skips=$(yq -o json -I0 '. // {}' "$SKIPS_FILE")
  echo '{}' >"$work/by-image.json"
  echo '{}' >"$work/stored.json"
  while read -r image; do
    dated_rules "$image" "$work/inventory.json" "$skips" "$previous" "$work"
    jq --arg i "$image" --slurpfile r "$work/rules.json" '.[$i] = $r[0]' "$work/by-image.json" >"$work/tmp.json"
    mv "$work/tmp.json" "$work/by-image.json"
    if [[ -s "$work/stored" ]]; then
      jq --arg i "$image" --slurpfile s <(jq -Rn '[inputs | split("\t") | {tag: .[0], digest: .[1], pushedAt: (.[2] | tonumber)}]' "$work/stored") \
        '.[$i] = $s[0]' "$work/stored.json" >"$work/tmp.json"
      mv "$work/tmp.json" "$work/stored.json"
    fi
  done < <(jq -r '.images | keys[]' "$work/inventory.json")
  override_guard "$work/inventory.json"
  assemble_preset "$work/by-image.json" "$out/$DATA_FILE" "$(now)"
  jq -S -n --arg at "$(iso "$(now)")" --slurpfile inv "$work/inventory.json" --slurpfile rows "$work/stored.json" \
    '{generatedAt: $at, inventory: $inv[0], rows: $rows[0]}' >"$out/$STATE_FILE"
  count=$(jq '.packageRules | length' "$out/$DATA_FILE")
  say "image-age: $count rules for $(jq length "$work/by-image.json") images"
  rm -rf "$work"
}

sha256_of() { sha256sum <"$1" | cut -d' ' -f1; }

cmd_hashes() {
  printf 'preset=%s\ndata=%s\n' "$(sha256_of "$1/$DATA_FILE")" "$(sha256_of "$1/$STATE_FILE")"
}

# preset_problems FILE: one line per way FILE differs from the shape that render writes
preset_problems() {
  local pre suf
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
    end' "$1"
}

cmd_validate() {
  local dir=$1 file="$1/$DATA_FILE" state="$1/$STATE_FILE" size problem bad=0
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
  fi
  if ((bad != 0)); then return 1; fi
  if ! npx --yes --package "renovate@$RENOVATE_VERSION" -- renovate-config-validator --strict --no-global "$file"; then
    say "::error::the Renovate config validator rejected $DATA_FILE"
    return 1
  fi
}

# check_hash FILE EXPECTED: the artifact file is the one render hashed
check_hash() {
  if [[ "$(sha256_of "$1")" == "$2" ]]; then return 0; fi
  say "::error::$(basename "$1") does not match the hash that render reported"
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
