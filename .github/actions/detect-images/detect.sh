#!/usr/bin/env bash
# shellcheck disable=SC2016 # $vars in single quotes are jq's
# Writes the repo's image build matrix to GITHUB_OUTPUT: release-please packages whose path holds a
# Dockerfile or flavor.yaml, with settings from <path>/metadata.yaml. Run from the repo root. See docs/ci.md.
set -euo pipefail
shopt -s inherit_errexit

readonly CONFIG="release-please-config.json"
readonly NAME_RE='^[a-z0-9]+([._-][a-z0-9]+)*$'
readonly PATH_RE='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
readonly SHA_RE='^([0-9a-f]{40}|[0-9a-f]{64})$'
readonly NAMES_JQ='map(.name) | if length == 0 then "(none)" else join(", ") end'

mode="${MODE:-changed}"
image="${IMAGE:-}"
base="${BASE_SHA:-}"
repo_name="${REPO_NAME:-${GITHUB_REPOSITORY#*/}}"

die() {
  local message="$1" msg
  msg="${message//'%'/%25}"
  msg="${msg//$'\r'/%0D}"
  printf '::error::%s\n' "${msg//$'\n'/%0A}" >&2
  exit 1
}

# Paths are repo-relative; ".." could reach outside the checkout
safe_path() {
  local p="$1"
  if [[ "$p" =~ $PATH_RE && "/$p/" != */../* ]]; then
    return 0
  fi
  return 1
}

norm_path() {
  local p="$1"
  while [[ "$p" == ./* ]]; do p="${p#./}"; done
  while [[ "$p" == */ ]]; do p="${p%/}"; done
  printf '%s' "${p:-.}"
  return 0
}

validate() {
  [[ "$mode" =~ ^(changed|all)$ ]] || die "mode must be changed or all, got: $mode"
  [[ -z "$base" || "$base" =~ $SHA_RE ]] || die "Invalid base SHA"
  [[ -z "$image" || "$image" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "Invalid image name"
  return 0
}

readonly ENTRY_JQ='
def safe: type == "string" and test($path_re) and (("/" + . + "/") | contains("/../") | not);
def str_or_empty($k): .[$k] // "" | if type == "string" then . else error("\($k) must be a string") end;
. as $m
| ($m.build_context // "") as $bc
| if ($bc | type) != "string" or ($bc != "" and ($bc | safe | not)) then error("build_context must be a relative path inside the repo") else . end
| ($m.watch // []) as $w
| if ($w | type) != "array" or ($w | all(safe) | not) then error("watch must be a list of relative paths inside the repo") else . end
| ($m["free-disk"] // false) as $fd
| if ($fd | type) != "boolean" then error("free-disk must be true or false") else . end
| ($m["extra-tags"] // "") as $et
| if ($et | type) == "array" and ($et | all(type == "string")) then ($et | join("\n"))
  elif ($et | type) == "string" then $et
  else error("extra-tags must be a string or a list of strings") end
| . as $tags
| {
    name: $name,
    path: $path,
    context: (if $bc == "" then $path else $bc end),
    dockerfile: (if $path == "." then "Dockerfile" else "\($path)/Dockerfile" end),
    watch: $w,
    "prepare-command": ($m | str_or_empty("prepare-command")),
    "free-disk": $fd,
    "extra-tags": $tags,
    "test-command": ($m | str_or_empty("test-command"))
  }
'

image_entry() {
  local path="$1" name="$2" meta_file="$1/metadata.yaml" meta="{}" entry ctx
  if [[ "$path" == "." ]]; then
    meta_file="metadata.yaml"
  fi
  if [[ -f "$meta_file" ]]; then
    meta=$(yq -o=json -I0 '. // {}' "$meta_file") || die "$meta_file: invalid YAML"
    [[ "$(jq -r 'type' <<<"$meta")" == "object" ]] || die "$meta_file: must be a mapping"
  fi
  entry=$(jq -c --arg path "$path" --arg name "$name" --arg path_re "$PATH_RE" \
    "try ($ENTRY_JQ) catch {error: .}" <<<"$meta")
  if [[ "$(jq -r 'has("error")' <<<"$entry")" == "true" ]]; then
    die "$meta_file: $(jq -r '.error' <<<"$entry")"
  fi
  ctx=$(jq -r '.context' <<<"$entry")
  ctx=$(norm_path "$ctx")
  [[ -d "$ctx" ]] || die "$meta_file: build_context directory does not exist: $ctx"
  jq -c --arg ctx "$ctx" '.context = $ctx' <<<"$entry"
  return 0
}

list_images() {
  local packages=() entries=() line path component name entry
  if [[ ! -f "$CONFIG" ]]; then
    echo '{"packages":[],"images":[]}'
    return 0
  fi
  while IFS= read -r line; do
    path=$(norm_path "$(jq -r '.path' <<<"$line")")
    component=$(jq -r '.component' <<<"$line")
    safe_path "$path" || die "$CONFIG: invalid package path: $path"
    packages+=("$path")
    [[ -f "$path/Dockerfile" || -f "$path/flavor.yaml" ]] || continue
    if [[ -n "$component" ]]; then
      name="$component"
    elif [[ "$path" != "." ]]; then
      name="${path##*/}"
    else
      name="${repo_name,,}"
    fi
    [[ "$name" =~ $NAME_RE ]] || die "Invalid image name for package $path: $name"
    entry=$(image_entry "$path" "$name")
    entries+=("$entry")
  done < <(jq -c '.packages // {} | to_entries[] | {path: .key, component: (.value.component // "" | tostring)}' "$CONFIG")

  local listing dup
  listing=$(printf '%s\n' "${entries[@]}" | jq -cs --args '{packages: $ARGS.positional, images: .}' "${packages[@]}")
  dup=$(jq -r '.images | group_by(.name) | map(select(length > 1) | .[0].name) | first // empty' <<<"$listing")
  [[ -z "$dup" ]] || die "Duplicate image name: $dup"
  printf '%s\n' "$listing"
  return 0
}

changed_files() {
  local out="$1"
  if [[ -n "$base" ]]; then
    git cat-file -e "${base}^{commit}" 2>/dev/null ||
      die "Base commit $base is not in the clone; check out with fetch-depth: 0"
    git diff --name-only --no-renames -z "${base}...HEAD" >"$out" ||
      die "No merge base with $base; check out with fetch-depth: 0"
  else
    git rev-parse -q --verify 'HEAD~1^{commit}' >/dev/null ||
      die "HEAD~1 is not in the clone; check out with fetch-depth: 2 or more"
    git diff --name-only --no-renames -z HEAD~1 HEAD >"$out"
  fi
  return 0
}

# The longest matching package path owns a file, so a nested package's changes skip its parent
readonly SELECT_JQ='
def norm: sub("^(\\./)+"; "") | sub("/+$"; "") | if . == "" then "." else . end;
def under($p): . as $f | $p == "." or $f == $p or ($f | startswith($p + "/"));
def release_only: test("(^|/)CHANGELOG\\.md$") or . == ".release-please-manifest.json";
($files | map(select(release_only | not))) as $fs
| .packages as $pkgs
| [$fs[] as $f | $pkgs | map(select(. as $p | $f | under($p))) | max_by(if . == "." then -1 else length end) // empty] as $owners
| .images
| map(select(
    . as $img
    | any($owners[]; . == $img.path)
    or any($img.watch[] | norm; . as $w | any($fs[]; under($w)))
    or ($img.context != $img.path and any($fs[]; under($img.context)))
  ))
'

select_images() {
  local listing="$1" out="$2" names files diff
  if [[ -n "$image" ]]; then
    jq -c --arg n "$image" '.images | map(select(.name == $n))' <<<"$listing" >"$out"
    if [[ "$(jq 'length' "$out")" == "0" ]]; then
      names=$(jq -r ".images | $NAMES_JQ" <<<"$listing")
      die "Unknown image: $image. Images: $names"
    fi
  elif [[ "$mode" == "all" || "$(jq '.images | length' <<<"$listing")" == "0" ]]; then
    jq -c '.images' <<<"$listing" >"$out"
  else
    diff="$out.diff"
    changed_files "$diff"
    files=$(jq -Rs 'split("\u0000") | map(select(length > 0))' "$diff")
    jq -c --argjson files "$files" "$SELECT_JQ" <<<"$listing" >"$out"
  fi
  return 0
}

write_outputs() {
  local selected="$1" matrix has
  matrix=$(jq -c '{include: .}' "$selected")
  has=$(jq -r 'if length > 0 then "true" else "false" end' "$selected")
  echo "Images: $(jq -r "$NAMES_JQ" "$selected")"
  {
    echo "matrix=$matrix"
    echo "has-images=$has"
  } >>"$GITHUB_OUTPUT"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    {
      echo "### Images"
      echo
      jq -r 'if length == 0 then "No images to build." else .[] | "- `\(.name)` (`\(.path)`)" end' "$selected"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  return 0
}

main() {
  local listing
  validate
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' EXIT
  listing=$(list_images)
  select_images "$listing" "$work_dir/selected"
  write_outputs "$work_dir/selected"
  return 0
}

main
