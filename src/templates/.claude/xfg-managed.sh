#!/bin/bash
# No ${...} here - xfg would substitute it on sync.
# Usage: xfg-managed.sh check <path> | hook (PreToolUse JSON on stdin) | staged
set -eu

list_url=$(printenv XFG_MANAGED_URL || echo https://raw.githubusercontent.com/anthony-spruyt/repo-operator/main/.github/xfg-managed.json)
ttl=$(printenv XFG_MANAGED_TTL || echo 900)
self_repo=anthony-spruyt/repo-operator
in_place="[[:space:]](-[a-zA-Z]*i|--in-place)"

repo_name() {
  local dir=$1
  git -C "$dir" remote get-url origin 2>/dev/null |
    sed -nE 's#^(https://|ssh://git@|git@)github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$#\2#p' |
    sed 's/\.git$//'
}

cached_list() {
  local common cache tmp
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)
  cache="$common/xfg-managed.json"
  if [[ ! -f "$cache" || $(($(date +%s) - $(stat -c %Y "$cache"))) -ge "$ttl" ]]; then
    tmp=$(mktemp "$common/xfg-managed.XXXXXX")
    if curl -fsSL --max-time 5 "$list_url" -o "$tmp" 2>/dev/null && jq -e 'type == "object"' "$tmp" >/dev/null 2>&1; then
      mv "$tmp" "$cache"
    else
      rm -f "$tmp"
    fi
  fi
  [[ -f "$cache" ]] && echo "$cache"
}

managed_files() {
  local repo list
  repo=$(repo_name "$1")
  [[ -n "$repo" ]] || return 0
  list=$(cached_list "$1") || return 0
  jq -r --arg r "$repo" '.[$r] // [] | .[]' "$list"
}

existing_dir() {
  local dir=$1
  while [[ ! -d "$dir" ]]; do dir=$(dirname "$dir"); done
  echo "$dir"
}

locate() {
  local abs root
  abs=$(realpath -m "$1")
  root=$(git -C "$(existing_dir "$(dirname "$abs")")" rev-parse --show-toplevel 2>/dev/null) || return 0
  printf '%s\t%s\n' "$root" "$(realpath -m --relative-to="$root" "$abs")"
}

is_managed() {
  local root=$1 rel=$2
  managed_files "$root" | grep -qxF -- "$rel"
}

explain() {
  local root=$1 rel=$2
  if [[ "$(repo_name "$root")" == "$self_repo" ]]; then
    printf '%s is synced here by XFG Apply. Edit its source in src/ instead (usually src/templates/%s, or src/*.yaml). Load the repo-operator skill before changing it.\n' "$rel" "$rel"
  else
    printf '%s is managed by %s: xfg overwrites it on every sync, so a change made here is lost. Change it in %s instead (usually src/templates/%s, or src/*.yaml). Load the repo-operator skill before changing it.\n' "$rel" "$self_repo" "$self_repo" "$rel"
  fi
}

any_managed() {
  local list
  list=$(cached_list "$1") || return 1
  jq -r '.[][]' "$list" | grep -qxF -- "$2"
}

# Prints ? for a target it cannot resolve: relative writes then match every repo's managed names.
cd_dir() {
  local cur=$1 prev=$2 args dir
  args=$(sed -E 's/[0-9&]*>+&?[[:space:]]*[^[:space:]]*//g; s/^[[:space:]]+//; s/[[:space:]]+$//; s/^(-[LPe@]+[[:space:]]+)*(--[[:space:]]+)?//' <<<"$3" | tr -d "\"')}")
  case "$args" in
  *[[:space:]]* | *'$'* | *'`'* | *[*?[]* | '~'[!/]*) echo '?' ;;
  '' | '~') printenv HOME || echo '?' ;;
  [~]/*) dir=$(printenv HOME) && realpath -m -- "$dir/$(cut -c3- <<<"$args")" || echo '?' ;;
  -) echo "$prev" ;;
  /*) realpath -m -- "$args" ;;
  *)
    if [[ "$cur" == '?' ]]; then echo '?'; else realpath -m -- "$cur/$args"; fi
    ;;
  esac
}

write_targets() {
  local seg=$1 first=$2 second=$3 words
  words=$(tr -s '[:space:]=' '\n' <<<"$seg" | tr -d "\"'()")
  if [[ $seg == *'>'* || $seg == *of=* ]]; then
    { grep -oE "(>|&>|of=)[[:space:]]*[\"']?[^[:space:]\"';)<>|&]+" <<<"$seg" || true; } |
      sed -E "s/^(>|&>|of=)[[:space:]]*[\"']?//"
  fi
  case "$first" in
  sed | perl) [[ $seg =~ $in_place ]] && echo "$words" ;;
  tee | rm | truncate | unlink | shred | mv) echo "$words" ;;
  cp | install | ln | rsync) echo "$words" | tail -n 1 ;;
  git) [[ "$second" == rm || "$second" == mv ]] && echo "$words" ;;
  *) ;;
  esac
  return 0
}

check_target() {
  local sroot=$1 cur=$2 word=$3 abs root rel
  case "$word" in
  -*) return 0 ;;
  /*) abs=$word ;;
  [~]/*) abs=$(printenv HOME)/$(cut -c3- <<<"$word") ;;
  *)
    if [[ "$cur" == '?' ]]; then
      rel=$(realpath -m --relative-to=/ -- "/$word")
      [[ -n "$sroot" ]] && any_managed "$sroot" "$rel" && {
        explain "$sroot" "$rel" >&2
        exit 2
      }
      return 0
    fi
    abs=$cur/$word
    ;;
  esac
  IFS=$'\t' read -r root rel < <(locate "$abs") || return 0
  if is_managed "$root" "$rel"; then
    explain "$root" "$rel" >&2
    exit 2
  fi
}

check_segment() {
  local sroot=$1 cur=$2 seg=$3 first=$4 second=$5 t
  case "$first" in
  sed | perl | tee | rm | truncate | unlink | shred | mv | cp | install | ln | rsync | git) ;;
  *) [[ $seg == *'>'* || $seg == *of=* ]] || return 0 ;;
  esac
  while IFS= read -r t; do
    [[ -z "$t" ]] || check_target "$sroot" "$cur" "$t"
  done < <(write_targets "$seg" "$first" "$second")
}

block_managed_writes() {
  local sroot=$1 cur=$2 cmd=$3 prev='?' stack='' segments seg first second rest pushes pops i t
  segments=$(sed -E "s/&&|\|\|/\n/g; s/>\|/>/g; s/[|;]/\n/g" <<<"$cmd" |
    awk '{
      o = gsub(/\(/, "("); c = gsub(/\)/, ")"); l = 0
      if (match($0, /^[ \t]*\(+/)) { s = substr($0, RSTART, RLENGTH); l = gsub(/\(/, "", s) }
      u = o - l
      print $0 "\037" (l + (u > c ? u - c : 0)) "\037" (c > u ? c - u : 0)
    }' |
    sed -E 's/^[[:space:](){]*//; s/^(then|do|else|!)[[:space:]]+//; s/^sudo[[:space:]]+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*//')
  while IFS=$'\037' read -r seg pushes pops; do
    for ((i = 0; i < pushes; i++)); do stack=$cur$'\t'$stack; done
    read -r first rest <<<"$seg" || true
    read -r second _ <<<"$rest" || true
    case "$first" in
    cd | pushd)
      t=$(cd_dir "$cur" "$prev" "$rest")
      prev=$cur
      cur=$t
      ;;
    popd)
      prev=$cur
      cur='?'
      ;;
    *) ;;
    esac
    check_segment "$sroot" "$cur" "$seg" "$first" "$second"
    for ((i = 0; i < pops; i++)); do
      [[ -z "$stack" ]] || IFS=$'\t' read -r cur stack <<<"$stack"
    done
  done <<<"$segments"
}

run_hook() {
  local input tool cwd path root rel
  input=$(cat)
  tool=$(jq -r '.tool_name // empty' <<<"$input")
  cwd=$(jq -r '.cwd // empty' <<<"$input")
  [[ -n "$cwd" ]] || cwd=$PWD
  case "$tool" in
  Edit | MultiEdit | Write | NotebookEdit)
    path=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' <<<"$input")
    [[ -n "$path" ]] || exit 0
    [[ "$path" == /* ]] || path="$cwd/$path"
    IFS=$'\t' read -r root rel < <(locate "$path") || exit 0
    if is_managed "$root" "$rel"; then
      explain "$root" "$rel" >&2
      exit 2
    fi
    ;;
  Bash)
    root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || root=
    block_managed_writes "$root" "$cwd" "$(jq -r '.tool_input.command // empty' <<<"$input")"
    ;;
  *) ;;
  esac
  exit 0
}

run_staged() {
  local root files rel failed=0
  root=$(git rev-parse --show-toplevel)
  files=$(managed_files "$root")
  [[ -n "$files" ]] || exit 0
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if grep -qxF -- "$rel" <<<"$files"; then
      explain "$root" "$rel" >&2
      failed=1
    fi
  done < <(git -C "$root" diff --cached --name-only --no-renames)
  exit "$failed"
}

case "$1" in
check)
  if IFS=$'\t' read -r root rel < <(locate "$2") && is_managed "$root" "$rel"; then
    echo yes
  else
    echo no
  fi
  ;;
hook) run_hook ;;
staged) run_staged ;;
*)
  echo "usage: xfg-managed.sh check <path> | hook | staged" >&2
  exit 64
  ;;
esac
