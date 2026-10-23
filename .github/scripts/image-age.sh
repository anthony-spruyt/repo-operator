#!/usr/bin/env bash
# Dates the third-party container images the fleet uses from their registries and publishes a Renovate preset
# (image-age.json) that holds back tags and rebuilds younger than 7 days. Subcommands: see usage().
set -euo pipefail

# renovate: depName=renovate datasource=npm
RENOVATE_VERSION="44.178.3"

MIN_AGE_SECONDS=$((7 * 86400))
KEEP_NEWEST=50
MAX_PAGES=20
STALE_SECONDS=$((36 * 3600))
MAX_BYTES=524288
DATA_BRANCH="renovate-data"
DATA_FILE="image-age.json"
API="https://api.github.com"
OUT_OF_SCOPE_HOSTS=("8gears.container-registry.com")
DOCKER_HUB_HOSTS=("docker.io" "index.docker.io" "registry-1.docker.io")
OWN_IMAGES_PREFIX="ghcr.io/anthony-spruyt/"

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

# http METHOD URL OUT [curl args...]: prints the status code, 000 when curl itself failed
http() {
  local method=$1 url=$2 out=$3 code
  shift 3
  local args=(-q -sS --proto '=https' --proto-redir '=https' --max-time 60 --retry 2)
  if [[ "$method" != GET ]]; then args+=(-X "$method"); fi
  code=$(curl "${args[@]}" "$@" -o "$out" -w '%{http_code}' "$url") || code=000
  printf '%s' "$code"
}

# gh_http METHOD URL OUT [curl args...]: the only call that carries the token, and only to api.github.com
gh_http() {
  local method=$1 url=$2 out=$3
  shift 3
  [[ "$url" == "$API/"* ]] || return 1
  http "$method" "$url" "$out" -H "@$AUTH_FILE" -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$@"
}

COSIGN_TAG='^sha256-[0-9a-f]+(\.(sig|att|sbom))?$'

# enough_rows ROWS: at least KEEP_NEWEST distinct tags whose build is old enough to use
enough_rows() {
  local cut=$(($(now) - MIN_AGE_SECONDS))
  awk -F'\t' -v cut="$cut" -v keep="$KEEP_NEWEST" -v cosign="$COSIGN_TAG" \
    '$3 <= cut && $1 !~ cosign && !seen[$1]++ { n++ } END { exit !(n >= keep) }' "$1"
}

fetch_ghcr() {
  local image=$1 raw=$2 path=${1#*/} url hdr body code page=0
  local owner=${path%%/*} name=${path#*/}
  url="$API/users/$owner/packages/container/${name//\//%2F}/versions?per_page=100"
  hdr=$(mktemp) body=$(mktemp)
  while :; do
    if ((++page > MAX_PAGES)); then
      say "::error::$image: more than $MAX_PAGES pages of tags needed"
      rm -f "$hdr" "$body"
      return 1
    fi
    code=$(gh_http GET "$url" "$body" -D "$hdr")
    if [[ "$code" != 200 ]]; then
      say "::error::$image: registry answered $code"
      rm -f "$hdr" "$body"
      return 1
    fi
    rows_ghcr <"$body" >>"$raw"
    if enough_rows "$raw"; then break; fi
    url=$(sed -n 's/^[Ll]ink:.*<\([^>]*\)>; *rel="next".*/\1/p' "$hdr" | tr -d '\r' | head -1)
    [[ -n "$url" ]] || break
    if [[ "$url" != "$API/"* ]]; then
      say "::error::$image: next page link leaves api.github.com"
      rm -f "$hdr" "$body"
      return 1
    fi
  done
  rm -f "$hdr" "$body"
}

fetch_quay() {
  local image=$1 raw=$2 path=${1#*/} body code page=0
  body=$(mktemp)
  while :; do
    if ((++page > MAX_PAGES)); then
      say "::error::$image: more than $MAX_PAGES pages of tags needed"
      rm -f "$body"
      return 1
    fi
    code=$(http GET "https://quay.io/api/v1/repository/$path/tag/?onlyActive=true&limit=100&page=$page" "$body")
    if [[ "$code" != 200 ]]; then
      say "::error::$image: registry answered $code"
      rm -f "$body"
      return 1
    fi
    rows_quay <"$body" >>"$raw"
    if enough_rows "$raw" || [[ "$(jq -r '.has_additional' "$body")" != true ]]; then break; fi
  done
  rm -f "$body"
}

# fetch_once IMAGE RAW URL ADAPTER [curl args...]: registries that answer with every tag in one call
fetch_once() {
  local image=$1 raw=$2 url=$3 adapter=$4 body code
  shift 4
  body=$(mktemp)
  code=$(http GET "$url" "$body" "$@")
  if [[ "$code" != 200 ]]; then
    say "::error::$image: registry answered $code"
    rm -f "$body"
    return 1
  fi
  "$adapter" <"$body" >>"$raw"
  rm -f "$body"
}

# fetch_rows IMAGE OUT: every tag of the image with its digest and push time, newest first, one row per tag
fetch_rows() {
  local image=$1 out=$2 host=${1%%/*} path=${1#*/} raw status=0
  raw=$(mktemp)
  case "$host" in
  ghcr.io) fetch_ghcr "$image" "$raw" || status=1 ;;
  quay.io) fetch_quay "$image" "$raw" || status=1 ;;
  mcr.microsoft.com) fetch_once "$image" "$raw" "https://mcr.microsoft.com/api/v1/catalog/$path/tags?reg=mar" rows_mcr || status=1 ;;
  gcr.io | registry.k8s.io) fetch_once "$image" "$raw" "https://$host/v2/$path/tags/list" rows_gcr -L || status=1 ;;
  *)
    say "::error::unsupported registry $host for $image"
    status=2
    ;;
  esac
  if ((status == 0)); then
    LC_ALL=C sort -s -t $'\t' -k3,3nr "$raw" | awk -F'\t' '!seen[$1]++' >"$out"
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

allowed_regex() {
  local tag escaped=()
  for tag in "$@"; do
    # shellcheck disable=SC2001
    escaped+=("$(sed 's#[][\\.+*?(){}|^$/]#\\&#g' <<<"$tag")")
  done
  if ((${#escaped[@]} == 0)); then
    printf '/^$/'
  else
    printf '/^(%s)$/' "$(IFS='|' && printf '%s' "${escaped[*]}")"
  fi
}

# image_rules IMAGE SELECTED NOW: the allowedVersions rule and the digest rule for one image
image_rules() {
  local image=$1 sel=$2 at=$3 tags map
  mapfile -t tags < <(cut -f1 "$sel")
  map=$(jq -Rsc 'split("\n") | map(select(. != "") | split("\t") | {(.[0]): .[1]}) | add // {}' "$sel" | jq -Sc .)
  jq -n --arg image "$image" --arg at "$(iso "$at")" --arg re "$(allowed_regex "${tags[@]}")" --arg map "$map" '
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
      matchJsonata: ["$exists(newDigest) and ($exists($lookup(\($map), newValue)) ? $lookup(\($map), newValue) != newDigest : true)"],
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
  local repo=$1 out=$2 log err status=0
  log=$(mktemp) err=$(mktemp)
  if ! RENOVATE_TOKEN="$GITHUB_TOKEN" LOG_FORMAT=json LOG_LEVEL=info \
    npx --yes "renovate@$RENOVATE_VERSION" --dry-run=extract --platform=github "$repo" >"$log" 2>"$err"; then
    tail -n 5 "$err"
    rm -f "$log" "$err"
    return 1
  fi
  if ! jq -Rse 'split("\n") | map(fromjson? // empty) | any(.[]; .msg == "Repository finished")' "$log" >/dev/null; then
    rm -f "$log" "$err"
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
    | select(.image != null)
    | select(.image as $i | ($i | split("/")[0]) as $h | ($h | contains(".")) and ($hubs | index($h) | not) and ($skipped | index($h) | not)
        and ($i | startswith($own) | not) and ($moved | index($i) | not))' "$log" >"$out" || status=1
  rm -f "$log" "$err"
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

# fetch_contents PATH OUT: the decoded content of a file in this repo's data branch or another repo; prints the status
fetch_contents() {
  local url=$1 out=$2 body code
  body=$(mktemp)
  code=$(gh_http GET "$url" "$body")
  if [[ "$code" == 200 ]]; then jq -r '.content' "$body" | base64 -d >"$out"; fi
  rm -f "$body"
  printf '%s' "$code"
}

# previous_by_image OUT: the rules of the last published data, keyed by image; an empty object on the first run
previous_by_image() {
  local raw code
  raw=$(mktemp)
  code=$(fetch_contents "$API/repos/$GITHUB_REPOSITORY/contents/$DATA_FILE?ref=$DATA_BRANCH" "$raw")
  case "$code" in
  200) ;;
  404) echo '{}' >"$raw" ;;
  *)
    say "::error::reading the previous $DATA_FILE answered $code"
    rm -f "$raw"
    return 1
    ;;
  esac
  jq '[(.packageRules // [])[] | select((.matchPackageNames // []) | length == 1)]
    | group_by(.matchPackageNames[0]) | map({key: .[0].matchPackageNames[0], value: .}) | from_entries' "$raw" >"$1"
  rm -f "$raw"
}

# warn_stale_pins IMAGE INVENTORY ROWS: a pinned digest the registry does not list for its tag never matches the data
warn_stale_pins() {
  local image=$1 inventory=$2 rows=$3 repo tag pinned listed
  while IFS=$'\t' read -r repo tag pinned; do
    listed=$(awk -F'\t' -v t="$tag" '$1 == t { print $2; exit }' "$rows")
    if [[ -n "$listed" && "$listed" != "$pinned" ]]; then
      say "::warning::$repo pins $image:$tag to $pinned, which is not the digest the registry lists for that tag"
    fi
  done < <(jq -r --arg i "$image" '.images[$i].pins[] | [.repo, .tag, .digest] | @tsv' "$inventory")
}

# dated_rules IMAGE INVENTORY SKIPS PREVIOUS WORKDIR: writes the rules for one image to WORKDIR/rules.json
dated_rules() {
  local image=$1 inventory=$2 skips=$3 previous=$4 work=$5 used skip status=0
  fetch_rows "$image" "$work/rows" || status=$?
  if ((status == 0)); then
    used=$(jq -r --arg i "$image" '.images[$i].tags | join(" ")' "$inventory")
    skip=$(jq -r --arg i "$image" '.[$i] // [] | join(" ")' <<<"$skips")
    select_rows "$work/rows" "$used" "$skip" >"$work/selected"
    warn_stale_pins "$image" "$inventory" "$work/rows"
    image_rules "$image" "$work/selected" "$(now)" >"$work/rules.json"
  elif ((status == 1)) && jq -e --arg i "$image" 'has($i)' "$previous" >/dev/null; then
    say "image-age: $image keeps the rules of the previous run"
    jq --arg i "$image" '.[$i]' "$previous" >"$work/rules.json"
  else
    disabling_rule "$image" "$(now)" | jq -s . >"$work/rules.json"
  fi
}

# override_guard INVENTORY: repo overrides load last, so a rule there that sets allowedVersions or enabled for a dated image wins
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
      | ("allowedVersions", "enabled") as $key
      | select($rule | has($key))
      | (($rule.matchPackageNames // []) + ($rule.matchDepNames // []))[] as $name
      | select($inv[0].images | has($name))
      | [$key, $name] | @tsv' <<<"$parsed" | sort -u | while IFS=$'\t' read -r key image; do
      say "::error::$repo renovate-overrides.json5 sets $key for $image; image-age owns $key for registry images (tag skips go in .github/renovate/image-age-skips.yaml)"
    done
  done < <(public_repos)
  rm -f "$raw"
}

cmd_render() {
  local in=$1 out=$2 work previous skips image by count
  mkdir -p "$out"
  REPORT="$out/report.txt"
  if [[ -f "$in/report.txt" ]]; then cp "$in/report.txt" "$REPORT"; else : >"$REPORT"; fi
  init_auth
  work=$(mktemp -d)
  previous="$work/previous.json"
  by="$work/by-image.json"
  previous_by_image "$previous" || return 1
  skips=$(yq -o json -I0 '. // {}' "$SKIPS_FILE")
  echo '{}' >"$by"
  while read -r image; do
    dated_rules "$image" "$in/inventory.json" "$skips" "$previous" "$work"
    jq --arg i "$image" --slurpfile r "$work/rules.json" '.[$i] = $r[0]' "$by" >"$work/by.tmp"
    mv "$work/by.tmp" "$by"
  done < <(jq -r '.images | keys[]' "$in/inventory.json")
  if [[ "$(jq '.failedRepos | length' "$in/inventory.json")" -gt 0 ]]; then
    jq --slurpfile inv "$in/inventory.json" --slurpfile prev "$previous" '. + ($prev[0] | with_entries(select(.key as $k | $inv[0].images | has($k) | not)))' "$by" >"$work/by.tmp"
    mv "$work/by.tmp" "$by"
  fi
  override_guard "$in/inventory.json"
  assemble_preset "$by" "$out/image-age.json" "$(now)"
  cp "${BASH_SOURCE[0]}" "$out/image-age.sh"
  chmod +x "$out/image-age.sh"
  count=$(jq '.packageRules | length' "$out/image-age.json")
  say "image-age: $count rules for $(jq length "$by") images"
  rm -rf "$work"
}

cmd_validate() {
  local file="$1/$DATA_FILE" size
  if ! jq -e . "$file" >/dev/null 2>&1; then
    say "::error::$DATA_FILE is not valid JSON"
    return 1
  fi
  size=$(wc -c <"$file")
  if ((size > MAX_BYTES)); then
    say "::error::$DATA_FILE is $size bytes, above the $MAX_BYTES byte limit"
    return 1
  fi
  if ! npx --yes --package "renovate@$RENOVATE_VERSION" -- renovate-config-validator --strict --no-global "$file"; then
    say "::error::the Renovate config validator rejected $DATA_FILE"
    return 1
  fi
}

# gh_json METHOD URL OUT [BODY_FILE]: prints the status of a GitHub API call with a JSON body
gh_json() {
  local method=$1 url=$2 out=$3 body=${4:-}
  if [[ -n "$body" ]]; then
    gh_http "$method" "$url" "$out" -H 'Content-Type: application/json' --data-binary "@$body"
  else
    gh_http "$method" "$url" "$out"
  fi
}

# ensure_data_branch: creates the data branch from main's head on the first run; prints nothing
ensure_data_branch() {
  local base="$API/repos/$GITHUB_REPOSITORY" out code sha
  out=$(mktemp)
  code=$(gh_json GET "$base/git/ref/heads/$DATA_BRANCH" "$out")
  case "$code" in
  200) rm -f "$out" ;;
  404)
    code=$(gh_json GET "$base/git/ref/heads/main" "$out")
    if [[ "$code" != 200 ]]; then
      say "::error::reading main answered $code"
      rm -f "$out"
      return 1
    fi
    sha=$(jq -r '.object.sha' "$out")
    jq -n --arg ref "refs/heads/$DATA_BRANCH" --arg sha "$sha" '{ref: $ref, sha: $sha}' >"$out"
    code=$(gh_json POST "$base/git/refs" "$out.resp" "$out")
    rm -f "$out" "$out.resp"
    if [[ "$code" != 201 ]]; then
      say "::error::creating the $DATA_BRANCH branch answered $code"
      return 1
    fi
    ;;
  *)
    say "::error::reading the $DATA_BRANCH branch answered $code"
    rm -f "$out"
    return 1
    ;;
  esac
}

# cmd_publish IN: one contents API write per run, so the data branch only holds commits GitHub signs
cmd_publish() {
  local in=$1 base="$API/repos/$GITHUB_REPOSITORY" out body code sha=""
  init_auth
  out=$(mktemp) body=$(mktemp)
  code=$(gh_json GET "$base/contents/$DATA_FILE?ref=$DATA_BRANCH" "$out")
  case "$code" in
  200) sha=$(jq -r '.sha' "$out") ;;
  404) ensure_data_branch || return 1 ;;
  *)
    say "::error::reading $DATA_FILE on $DATA_BRANCH answered $code"
    return 1
    ;;
  esac
  jq -n --arg branch "$DATA_BRANCH" --arg sha "$sha" --arg content "$(base64 -w0 "$in/$DATA_FILE")" \
    '{message: "chore(renovate): refresh image-age data", content: $content, branch: $branch} + (if $sha == "" then {} else {sha: $sha} end)' >"$body"
  code=$(gh_json PUT "$base/contents/$DATA_FILE" "$out" "$body")
  rm -f "$out" "$body"
  if [[ "$code" != 200 && "$code" != 201 ]]; then
    say "::error::writing $DATA_FILE to $DATA_BRANCH answered $code"
    return 1
  fi
  say "image-age: published $DATA_FILE to $DATA_BRANCH"
  if grep -q '^::error::' "$in/report.txt"; then
    say "::error::image-age data was published with errors, see the extract and render steps above"
    return 1
  fi
}

usage() {
  echo "usage: image-age.sh extract --out DIR | render --in DIR --out DIR | validate --in DIR | publish --in DIR" >&2
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
