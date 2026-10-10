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
readonly VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._/@+-]*$'
readonly NAMES_JQ='map(.name) | if length == 0 then "(none)" else join(", ") end'

mode="${MODE:-changed}"
image="${IMAGE:-}"
base="${BASE_SHA:-}"
releases="${RELEASES:-}"
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
  [[ "$mode" =~ ^(changed|all|released)$ ]] || die "mode must be changed, all or released, got: $mode"
  [[ -z "$base" || "$base" =~ $SHA_RE ]] || die "Invalid base SHA"
  [[ -z "$image" || "$image" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || die "Invalid image name"
  if [[ "$mode" == "released" ]]; then
    [[ -z "$image" ]] || die "image does not apply to released mode"
    jq -e 'type == "object"' <<<"$releases" >/dev/null 2>&1 || die "releases must be the release-please outputs as JSON"
  fi
  return 0
}

readonly ENTRY_JQ='
def safe: type == "string" and test($path_re) and (("/" + . + "/") | contains("/../") | not);
def str_or_empty($k): .[$k] // "" | if type == "string" then . else error("\($k) must be a string") end;
. as $m
| ($m.build_context // "") as $bc
| if ($bc | type) != "string" or ($bc != "" and ($bc | safe | not)) then error("build_context must be a relative path inside the repo") else . end
| ($m.workdir // "") as $wd
| if ($wd | type) != "string" or ($wd != "" and ($wd | safe | not)) then error("workdir must be a relative path inside the repo") else . end
| ($m.watch // []) as $w
| if ($w | type) != "array" or ($w | all(safe) | not) then error("watch must be a list of relative paths inside the repo") else . end
| ($m["free-disk"] // false) as $fd
| if ($fd | type) != "boolean" then error("free-disk must be true or false") else . end
| ($m["extra-tags"] // "") as $et
| if ($et | type) == "array" and ($et | all(type == "string")) then ($et | join("\n"))
  elif ($et | type) == "string" then $et
  else error("extra-tags must be a string or a list of strings") end
| . as $tags
| ($m | str_or_empty("language")) as $lang
| if ["", "go", "node", "python", "none"] | index($lang) | not then error("language must be go, node, python or none") else . end
| {
    name: $name,
    path: $path,
    context: (if $bc == "" then $path else $bc end),
    dockerfile: (if $path == "." then "Dockerfile" else "\($path)/Dockerfile" end),
    watch: $w,
    "prepare-command": ($m | str_or_empty("prepare-command")),
    "free-disk": $fd,
    "extra-tags": $tags,
    "test-command": ($m | str_or_empty("test-command")),
    language: $lang,
    workdir: (if $wd == "" then $path else $wd end)
  }
'

image_entry() {
  local path="$1" name="$2" meta_file="$1/metadata.yaml" meta="{}" entry ctx workdir
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
  workdir=$(norm_path "$(jq -r '.workdir' <<<"$entry")")
  [[ -d "$workdir" ]] || die "$meta_file: workdir directory does not exist: $workdir"
  jq -c --arg ctx "$ctx" --arg workdir "$workdir" '.context = $ctx | .workdir = $workdir' <<<"$entry"
  return 0
}

# Version files mirror release-please's src/strategies/*.ts; other release types fall back to building.
# The docker tag gets a v only when include-v-in-tag is set true.
readonly PACKAGES_JQ='
def norm: sub("^(\\./)+"; "") | sub("/+$"; "") | if . == "" then "." else . end;
def list: if type == "array" then .[] | strings else empty end;
def str_or($d): if type == "string" and . != "" then . else $d end;
. as $c
| ($c.packages // {}) | to_entries
| map(
    (.key | norm) as $p
    | .value as $v
    | def opt($k): $v[$k] // $c[$k];
      def flag($k; $d): if $v | has($k) then $v[$k] elif $c | has($k) then $c[$k] else $d end == true;
      def add_path: (if $p == "." or startswith("/") then sub("^/+"; "") else "\($p)/\(.)" end) | sub("/+$"; "");
    (opt("release-type") | str_or("node")) as $type
    | (opt("version-file") | str_or("")) as $vf
    | {
        path: $p,
        docker_prefix: (if flag("include-v-in-tag"; false) then "v" else "" end),
        component: ($v.component // "" | tostring),
        exclude: [opt("exclude-paths") | list | sub("^/+"; "") | norm],
        changelog: (opt("changelog-path") | str_or("CHANGELOG.md") | add_path),
        version_files: (
          [opt("extra-files") | if type == "array" then .[] else empty end
            | if type == "object" and (.glob | not) then .path else . end | strings | add_path]
          + ({
              node: ["package.json", "package-lock.json", "npm-shrinkwrap.json", "samples/package.json"],
              python: ["setup.cfg", "setup.py", "pyproject.toml"],
              simple: [$vf | str_or("version.txt")],
              go: [$vf | select(. != "")]
            }[$type] // [] | map(add_path))
          + (if $type == "node" or $type == "python" then ["changelog.json"] else [] end)
        ),
        python: ($type == "python")
      }
  )
'

list_images() {
  local config="$1" label="$2" pkgs entries=() line path component name entry
  if [[ ! -f "$config" ]]; then
    echo '{"packages":[],"images":[]}'
    return 0
  fi
  pkgs=$(jq -c "$PACKAGES_JQ" "$config") || die "$label: invalid config"
  while IFS= read -r line; do
    path=$(jq -r '.path' <<<"$line")
    component=$(jq -r '.component' <<<"$line")
    safe_path "$path" || die "$label: invalid package path: $path"
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
  done < <(jq -c '.[]' <<<"$pkgs")

  local listing dup
  listing=$(printf '%s\n' "${entries[@]}" | jq -cs --argjson pkgs "$pkgs" '{packages: $pkgs, images: .}')
  dup=$(jq -r '.images | group_by(.name) | map(select(length > 1) | .[0].name) | first // empty' <<<"$listing")
  [[ -z "$dup" ]] || die "Duplicate image name: $dup"
  printf '%s\n' "$listing"
  return 0
}

require_base() {
  git cat-file -e "${base}^{commit}" 2>/dev/null ||
    die "Base commit $base is not in the clone; check out with fetch-depth: 0"
  return 0
}

base_listing() {
  local file="$work_dir/base-config.json"
  if git cat-file -e "${base}:$CONFIG" 2>/dev/null; then
    git show "${base}:$CONFIG" >"$file" || die "Cannot read $CONFIG at base commit $base"
  fi
  list_images "$file" "$CONFIG at base commit $base"
  return 0
}

changed_files() {
  local out="$1"
  if [[ -n "$base" ]]; then
    git diff --name-only --no-renames -z "${base}...HEAD" >"$out" ||
      die "No merge base with $base; check out with fetch-depth: 0"
  else
    git rev-parse -q --verify 'HEAD~1^{commit}' >/dev/null ||
      die "HEAD~1 is not in the clone; check out with fetch-depth: 2 or more"
    git diff --name-only --no-renames -z HEAD~1 HEAD >"$out"
  fi
  return 0
}

# Dependency bumps touch version files too, so they skip only in a release PR; the longest package path owns a file
readonly SELECT_JQ='
def norm: sub("^(\\./)+"; "") | sub("/+$"; "") | if . == "" then "." else . end;
def under($p): . as $f | $p == "." or $f == $p or ($f | startswith($p + "/"));
def rel($p): if $p == "." then . else .[($p | length) + 1:] end;
.packages as $pkgs
| ($diff | split("\u0000") | map(select(length > 0))) as $files
| ".release-please-manifest.json" as $manifest
| ([$pkgs[].changelog] + [$manifest]) as $always
| def release_always: . as $f | any($always[]; . == $f);
  def version_file: . as $f | any($pkgs[]; . as $pk
    | any($pk.version_files[]; . == $f)
    or ($pk.python and ($f | under($pk.path))
      and ($f | rel($pk.path) | test("^(src/)?[^/]+/__init__\\.py$|(^|/)version\\.py$"))));
  def owns($f): .path as $p | ($f | under($p)) and (any(.exclude[] as $x | $f | under($x); .) | not);
(($files | length) > 0 and any($files[]; . == $manifest) and all($files[]; release_always or version_file)) as $release_pr
| (if $release_pr then [] else $files | map(select(release_always | not)) end) as $fs
| [$fs[] as $f | $pkgs | map(select(owns($f)) | .path) | max_by(if . == "." then -1 else length end) // empty] as $owners
| .images
| map(select(
    . as $img
    | any($owners[]; . == $img.path)
    or any($img.watch[] | norm; . as $w | any($fs[]; under($w)))
    or ($img.context != $img.path and any($fs[]; under($img.context)))
  ))
'

# release-please-action sets <path>--<key> outputs, unprefixed for path "."
readonly RELEASED_JQ='
def norm: sub("^(\\./)+"; "") | sub("/+$"; "") | if . == "" then "." else . end;
def valid($tag; $version): ($tag | type) == "string" and ($version | type) == "string"
  and ($tag | test($tag_re)) and ($version | test($version_re)) and ($tag | endswith($version));
$rel[0] as $r
| ($r.paths_released // "[]" | if type == "string" then fromjson else . end) as $paths
| [$paths[] | strings | (if . == "." then "" else "\(.)--" end) as $k
    | {path: norm, tag: $r["\($k)tag_name"], version: $r["\($k)version"]}] as $released
| .packages as $pkgs
| .images
| map(
    . as $img
    | first($released[] | select(.path == $img.path)) as $rl
    | if valid($rl.tag; $rl.version) | not then error("Release of \($rl.path) has no valid tag_name and version") else . end
    | . + {
        version: $rl.version,
        "tag-name": $rl.tag,
        "tag-prefix": first($pkgs[] | select(.path == $img.path) | .docker_prefix)
      }
  )
'

released_images() {
  local listing="$1" out="$2" result
  printf '%s' "$releases" >"$out.releases"
  result=$(jq -c --slurpfile rel "$out.releases" --arg tag_re "$TAG_RE" --arg version_re "$VERSION_RE" \
    "try ($RELEASED_JQ) catch {error: .}" <<<"$listing")
  if [[ "$(jq -r 'type == "object" and has("error")' <<<"$result")" == "true" ]]; then
    die "$(jq -r '.error' <<<"$result")"
  fi
  printf '%s\n' "$result" >"$out"
  return 0
}

select_images() {
  local listing="$1" out="$2" names
  if [[ "$mode" == "released" ]]; then
    released_images "$listing" "$out"
  elif [[ -n "$image" ]]; then
    jq -c --arg n "$image" '.images | map(select(.name == $n))' <<<"$listing" >"$out"
    if [[ "$(jq 'length' "$out")" == "0" ]]; then
      names=$(jq -r ".images | $NAMES_JQ" <<<"$listing")
      die "Unknown image: $image. Images: $names"
    fi
  elif [[ "$mode" == "all" ]]; then
    jq -c '.images' <<<"$listing" >"$out"
  else
    changed_images "$listing" "$out"
  fi
  return 0
}

# A pull request could edit its own config to skip its build, so the base's config selects images too
changed_images() {
  local out="$2" diff="$2.diff" listings=("$1") base_list l
  if [[ -n "$base" ]]; then
    require_base
    base_list=$(base_listing)
    listings+=("$base_list")
  fi
  if [[ "$(printf '%s\n' "${listings[@]}" | jq -s 'map(.images | length) | add')" == "0" ]]; then
    echo '[]' >"$out"
    return 0
  fi
  changed_files "$diff"
  for l in "${listings[@]}"; do
    # --rawfile, not --argjson: one argument caps at 128 KB, so large diffs would fail
    jq -c --rawfile diff "$diff" "$SELECT_JQ" <<<"$l"
  done | jq -cs 'add | reduce .[] as $i ([]; if any(.[]; .name == $i.name) then . else . + [$i] end)' >"$out"
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
      jq -r 'if length == 0 then "No images to build." else .[] | "- `\(.name)` (`\(.path)`)\(if ."tag-name" then ", tag `\(."tag-name")`" else "" end)" end' "$selected"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
  return 0
}

main() {
  local listing
  validate
  work_dir=$(mktemp -d)
  trap 'rm -rf "$work_dir"' EXIT
  listing=$(list_images "$CONFIG" "$CONFIG")
  select_images "$listing" "$work_dir/selected"
  write_outputs "$work_dir/selected"
  return 0
}

main
