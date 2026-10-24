#!/usr/bin/env bash
# Stands in for gh. FAKE_STATE holds what the repo contains:
#   contents/<ref, / as %2F>/<path>   files served by the contents API (404 when absent)
#   releases.json                     the releases list
#   tags                              one existing tag per line
#   runs/<tag, / as %2F>.json         the workflow runs of a tag
#   dispatch-fail                     tags whose dispatch fails
#   default_branch                    the default branch (main when absent)
#   repo-fail                         when present, the repository API call fails
#   releases-fail                     when present, listing the releases fails
# Every call is logged to FAKE_STATE/calls as "token=<GH_TOKEN> <args>"; dispatches also go to FAKE_STATE/dispatched.
set -euo pipefail

printf 'token=%s %s\n' "${GH_TOKEN:-}" "$*" >>"$FAKE_STATE/calls"

decode() {
  printf '%b' "${1//%/\\x}"
}

if [[ "$1" == "workflow" && "$2" == "run" ]]; then
  if [[ -f "$FAKE_STATE/dispatch-fail" ]] && grep -qxF "$5" "$FAKE_STATE/dispatch-fail"; then
    echo "gh: could not create a workflow dispatch event (HTTP 422)" >&2
    exit 1
  fi
  printf '%s %s\n' "$3" "$5" >>"$FAKE_STATE/dispatched"
  exit 0
fi

if [[ "$1" != "api" ]]; then
  echo "fake gh: unexpected call: $*" >&2
  exit 2
fi
shift
url=""
while (($#)); do
  case "$1" in
  -H) shift ;;
  --paginate) ;;
  *) url="$1" ;;
  esac
  shift
done

case "$url" in
repos/*/contents/*)
  rest="${url#*/contents/}"
  ref=$(decode "${rest#*\?ref=}")
  file="$FAKE_STATE/contents/${ref//\//%2F}/${rest%%\?ref=*}"
  if [[ ! -f "$file" ]]; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  cat "$file"
  ;;
repos/*/releases\?*)
  if [[ -f "$FAKE_STATE/releases-fail" ]]; then
    echo "gh: Server Error (HTTP 502)" >&2
    exit 1
  fi
  if [[ -f "$FAKE_STATE/releases.json" ]]; then cat "$FAKE_STATE/releases.json"; else echo '[]'; fi
  ;;
repos/*/git/matching-refs/tags/*)
  prefix="${url#*/matching-refs/tags/}"
  if [[ -f "$FAKE_STATE/tags" ]]; then
    jq -Rsc --arg p "$prefix" 'split("\n") | map(select(length > 0 and startswith($p)) | {ref: "refs/tags/\(.)"})' "$FAKE_STATE/tags"
  else
    echo '[]'
  fi
  ;;
repos/*/actions/workflows/*/runs\?*)
  branch=""
  query="${url#*\?}"
  for kv in ${query//&/ }; do
    if [[ "$kv" == branch=* ]]; then branch=$(decode "${kv#branch=}"); fi
  done
  file="$FAKE_STATE/runs/${branch//\//%2F}.json"
  if [[ -f "$file" ]]; then cat "$file"; else echo '{"workflow_runs":[]}'; fi
  ;;
repos/*/*)
  if [[ -f "$FAKE_STATE/repo-fail" ]]; then
    echo "gh: Server Error (HTTP 500)" >&2
    exit 1
  fi
  if [[ -f "$FAKE_STATE/default_branch" ]]; then branch=$(<"$FAKE_STATE/default_branch"); else branch=main; fi
  jq -nc --arg b "$branch" '{default_branch: $b}'
  ;;
*)
  echo "fake gh: unexpected url: $url" >&2
  exit 2
  ;;
esac
