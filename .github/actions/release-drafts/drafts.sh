#!/usr/bin/env bash
# shellcheck disable=SC2016 # $vars in single quotes are jq's
set -euo pipefail
shopt -s inherit_errexit

readonly PATH_RE='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._/@+-]*$'
readonly MANIFEST=".release-please-manifest.json"
readonly WORKFLOW_FILE_RE='^\.github/workflows/[A-Za-z0-9._-]+\.ya?ml$'

die() {
  local message="$1" msg
  msg="${message//'%'/%25}"
  msg="${msg//$'\r'/%0D}"
  printf '::error::%s\n' "${msg//$'\n'/%0A}" >&2
  exit 1
}

PACKAGES_JQ_FILE="$(dirname -- "${BASH_SOURCE[0]}")/../detect-images/packages.jq"
readonly PACKAGES_JQ_FILE
[[ -f "$PACKAGES_JQ_FILE" ]] || die "packages.jq not found beside the detect-images action"

# Paths go into API URLs and must stay repo-relative
safe_path() {
  local p="$1"
  if [[ "$p" =~ $PATH_RE && "/$p/" != */../* ]]; then
    return 0
  fi
  return 1
}

readonly NORM_JQ='def norm: sub("^(\\./)+"; "") | sub("/+$"; "") | if . == "" then "." else . end;'

# release-please's tag is [component + separator] [v] version; a null component is one it reads from a package file
readonly TAG_PARTS_JQ="$NORM_JQ"'
def str_or($d): if type == "string" and . != "" then . else $d end;
. as $c
| ($c.packages // {}) | to_entries
| map(
    (.key | norm) as $p
    | .value as $v
    | def opt($k): $v[$k] // $c[$k];
      def flag($k; $d): if $v | has($k) then $v[$k] elif $c | has($k) then $c[$k] else $d end == true;
    (opt("release-type") | str_or("node")) as $type
    | {
        key: $p,
        value: {
          v: (if flag("include-v-in-tag"; true) then "v" else "" end),
          separator: (opt("tag-separator") | str_or("-")),
          component: (
            (($v.component // opt("package-name") // "") | tostring) as $comp
            | if flag("include-component-in-tag"; true) | not then ""
              elif $comp != "" then $comp
              elif $type | IN("node", "dart", "helm", "rust", "sfdx") then null
              else "" end
          )
        }
      }
  )
| from_entries
'

readonly TAGS_JQ="$NORM_JQ"'
if ($manifest | type) != "object" then error("manifest must be an object") else . end
| ($manifest | to_entries | map({key: (.key | norm), value}) | from_entries) as $m
| map($parts[.path] as $t
    | select($t.component != null and ($m[.path] | type) == "string")
    | {
        path,
        version: $m[.path],
        tag: ((if $t.component == "" then "" else $t.component + $t.separator end) + $t.v + $m[.path])
      })
'

# True when the latest version is newer than this one; a prerelease sorts below its release
readonly NEWER_JQ='
def key: sub("\\+.*$"; "")
  | (capture("^(?<core>[0-9]+(\\.[0-9]+)*)(-(?<pre>.*))?$") // error("not a version"))
  | [(.core | split(".") | map(tonumber)), (if .pre == null then [1, ""] else [0, .pre] end)];
($latest | key) > ($version | key)
'

uri() {
  local value="$1"
  jq -rn --arg v "$value" '$v | @uri'
}

fetch() {
  local path="$1" ref="$2"
  gh api -H 'Accept: application/vnd.github.raw+json' "repos/${GH_REPO}/contents/${path}?ref=$(uri "$ref")"
}

is_image() {
  local path="$1" ref="$2" prefix=""
  if [[ "$path" != "." ]]; then
    prefix="$path/"
  fi
  fetch "${prefix}Dockerfile" "$ref" >/dev/null 2>&1 || fetch "${prefix}flavor.yaml" "$ref" >/dev/null 2>&1
}

package_for_tag() {
  local tag="$1" ref="$2" config manifest pkgs parts match path
  config=$(fetch release-please-config.json "$ref" 2>/dev/null) || return 1
  manifest=$(fetch "$MANIFEST" "$ref" 2>/dev/null) || return 1
  pkgs=$(jq -c -f "$PACKAGES_JQ_FILE" <<<"$config" 2>/dev/null) || return 1
  parts=$(jq -c "$TAG_PARTS_JQ" <<<"$config" 2>/dev/null) || return 1
  match=$(jq -c --argjson manifest "$manifest" --argjson parts "$parts" --arg tag "$tag" \
    "$TAGS_JQ | map(select(.tag == \$tag)) | first // empty" <<<"$pkgs" 2>/dev/null) || return 1
  [[ -n "$match" ]] || return 1
  path=$(jq -r '.path' <<<"$match")
  safe_path "$path" || return 1
  is_image "$path" "$ref" || return 1
  printf '%s\n' "$match"
  return 0
}

superseded() {
  local path="$1" version="$2" default manifest latest
  default=$(gh api "repos/${GH_REPO}" | jq -er '.default_branch') || die "Cannot read the default branch"
  manifest=$(fetch "$MANIFEST" "$default") || die "Cannot read $MANIFEST on $default"
  latest=$(jq -er --arg p "$path" "$NORM_JQ"'
    to_entries | map(select(.key | norm == $p)) | .[0].value | strings' <<<"$manifest") ||
    die "No version for $path in $MANIFEST on $default"
  jq -nr --arg latest "$latest" --arg version "$version" "$NEWER_JQ" || die "Cannot compare $version with $latest"
  return 0
}

synthesize() {
  local tag="${TAG:-}" pkg path version newer releases
  [[ "$tag" =~ $TAG_RE ]] || die "Invalid tag"
  pkg=$(package_for_tag "$tag" "$tag") || die "Tag $tag is not the release tag of an image package at that tag"
  path=$(jq -r '.path' <<<"$pkg")
  version=$(jq -r '.version' <<<"$pkg")
  newer=$(superseded "$path" "$version")
  releases=$(jq -nc --arg path "$path" --arg tag "$tag" --arg version "$version" --arg newer "$newer" '
    (if $path == "." then "" else "\($path)--" end) as $k
    | {
        paths_released: ([$path] | tojson),
        ($k + "tag_name"): $tag,
        ($k + "version"): $version,
        ($k + "superseded"): $newer
      }')
  {
    echo "release-created=true"
    echo "releases=$releases"
  } >>"$GITHUB_OUTPUT"
  echo "Running the release of $tag, built from the tag"
  return 0
}

# Tags the release-please step of this run just drafted; their own images job builds them
released_tags() {
  local releases="${RELEASES:-}"
  [[ -n "$releases" ]] || releases='{}'
  jq -c '[to_entries[] | select(.key | test("(^|--)tag_name$")) | .value | strings]' <<<"$releases" ||
    die "RELEASES must be the release-please outputs as JSON"
}

draft_tags() {
  local skip="$1"
  GH_TOKEN="$APP_TOKEN" gh api --paginate "repos/${GH_REPO}/releases?per_page=100" |
    jq -sc --argjson skip "$skip" \
      '[.[][] | select(.draft == true) | .tag_name | strings | select(. as $t | $skip | any(. == $t) | not)]'
}

tag_exists() {
  local tag="$1"
  gh api "repos/${GH_REPO}/git/matching-refs/tags/${tag}" | jq -e --arg r "refs/tags/${tag}" 'any(.[]; .ref == $r)' >/dev/null
}

# A dispatch runs the caller as it is at the tag, so only a caller with a recover job can build a tag-ref run
caller_recovers() {
  local path="$1" ref="$2"
  fetch "$path" "$ref" 2>/dev/null |
    yq -e '[.jobs[] | .uses // ""] | any_c(test("^anthony-spruyt/repo-operator/[.]github/workflows/_release-recover[.]yaml@"))' >/dev/null 2>&1
}

run_counts() {
  local file="$1" tag="$2"
  gh api --paginate "repos/${GH_REPO}/actions/workflows/${file}/runs?branch=$(uri "$tag")&per_page=100" |
    jq -sc '[.[].workflow_runs[]] | {
      active: [.[] | select(.status | IN("queued", "in_progress", "waiting", "requested", "pending"))] | length,
      failed: [.[] | select(.event == "workflow_dispatch" and (.conclusion | IN("failure", "timed_out", "startup_failure")))] | length
    }'
}

recover_one() {
  local tag="$1" path="$2" file="$3" counts
  if [[ ! "$tag" =~ $TAG_RE ]]; then
    echo "::notice::A draft with an invalid tag name was skipped"
    return 0
  fi
  if ! tag_exists "$tag"; then
    echo "::notice::Draft $tag: no tag, skipped"
    return 0
  fi
  if ! package_for_tag "$tag" "$tag" >/dev/null; then
    echo "::notice::Draft $tag: not the release tag of an image package, skipped"
    return 0
  fi
  if ! caller_recovers "$path" "$tag"; then
    echo "::notice::Draft $tag: its caller workflow does not recover drafts, skipped"
    return 0
  fi
  counts=$(run_counts "$file" "$tag")
  if [[ "$(jq -r '.active' <<<"$counts")" != "0" ]]; then
    echo "::notice::Draft $tag: a run is already queued or in progress, skipped"
    return 0
  fi
  if (($(jq -r '.failed' <<<"$counts") >= MAX_FAILURES)); then
    echo "::warning::Draft $tag: not retried, $(jq -r '.failed' <<<"$counts") dispatched runs failed (limit $MAX_FAILURES)"
    return 0
  fi
  if gh workflow run "$file" --ref "$tag"; then
    echo "Dispatched $file on $tag"
  else
    echo "::warning::Draft $tag: dispatching $file failed"
  fi
  return 0
}

recover() {
  local ref="${WORKFLOW_REF#"${GH_REPO}/"}" path skip drafts tag
  if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    echo "::notice::Tag-ref runs do not recover drafts"
    return 0
  fi
  path="${ref%%@*}"
  [[ "$path" =~ $WORKFLOW_FILE_RE ]] || die "Cannot tell the caller workflow from: ${WORKFLOW_REF:-}"
  [[ "${MAX_FAILURES:-3}" =~ ^[0-9]+$ ]] || die "max-failures must be a number"
  MAX_FAILURES="${MAX_FAILURES:-3}"
  [[ -n "${APP_TOKEN:-}" ]] || die "APP_TOKEN is required"
  skip=$(released_tags)
  drafts=$(draft_tags "$skip" | jq -r '.[]') || {
    echo "::warning::Could not list the draft releases"
    return 1
  }
  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    recover_one "$tag" "$path" "${path##*/}"
  done <<<"$drafts"
  return 0
}

main() {
  [[ -n "${GH_REPO:-}" ]] || die "GH_REPO is required"
  case "${MODE:-}" in
  recover) recover ;;
  synthesize) synthesize ;;
  *) die "mode must be recover or synthesize, got: ${MODE:-}" ;;
  esac
  return 0
}

main
