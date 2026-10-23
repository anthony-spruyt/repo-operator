#!/usr/bin/env bash
# Stands in for curl in the bats tests. Each line of $FAKE_ROUTES is
# "METHOD<TAB>URL<TAB>STATUS<TAB>BODY_FILE<TAB>HEADER" ("-" for an empty field); the first line that matches serves the request.
# With -L a Location header is followed through the routes. Requests land in $FAKE_LOG, request bodies in $FAKE_LOG.body.N.
# A bearer token other than $GITHUB_TOKEN logs as auth=pull; the manifest Accept types log as accept=. --head answers with headers only.
# Like curl --fail, a status of 400 or more prints the status, writes no body and exits 22; the status 000 exits 28 as a dead connection does.
set -euo pipefail

[[ "${1:-}" == -q ]] || {
  echo "fake curl: -q must come first" >&2
  exit 2
}
shift

method=GET url="" out="" hdr="" data="" follow=no auth=no raw=no fail=no globoff=no accept="" token=""
while (($#)); do
  case "$1" in
  -X) method="$2" && shift 2 ;;
  -o) out="$2" && shift 2 ;;
  -D) hdr="$2" && shift 2 ;;
  -L) follow=yes && shift ;;
  --head) method=HEAD && shift ;;
  -sS) shift ;;
  --fail) fail=yes && shift ;;
  --globoff) globoff=yes && shift ;;
  --proto | --proto-redir | --max-time | --retry | -w) shift 2 ;;
  --data-binary) data="${2#@}" && shift 2 ;;
  -H)
    if [[ "$2" == @* ]]; then
      token=$(sed -n 's/^Authorization: Bearer //p' "${2#@}")
      [[ -z "$token" ]] || auth=$([[ "$token" == "${GITHUB_TOKEN:-}" ]] && echo yes || echo pull)
    fi
    if [[ "$2" == 'Accept: application/vnd.github.raw+json' ]]; then raw=yes; fi
    if [[ "$2" == 'Accept: application/vnd.oci.image.index.v1+json'* ]]; then accept="${2#Accept: }"; fi
    shift 2
    ;;
  https://*) url="$1" && shift ;;
  *)
    echo "fake curl: unexpected argument: $1" >&2
    exit 2
    ;;
  esac
done

if [[ "$fail" != yes || "$globoff" != yes ]]; then
  echo "fake curl: --fail and --globoff are required on every request" >&2
  exit 2
fi

n=$(($(wc -l <"$FAKE_LOG" 2>/dev/null || echo 0) + 1))
printf '%s %s auth=%s%s%s\n' "$method" "$url" "$auth" "$([[ "$raw" == yes ]] && echo ' raw=yes')" "${accept:+ accept=$accept}" >>"$FAKE_LOG"
if [[ -n "$data" ]]; then cp "$data" "$FAKE_LOG.body.$n"; fi

[[ -z "$hdr" ]] || : >"$hdr"
while :; do
  route=$(awk -F'\t' -v m="$method" -v u="$url" '$1 == m && $2 == u { print; exit }' "$FAKE_ROUTES")
  if [[ -z "$route" ]]; then
    echo "fake curl: unexpected request $method $url" >&2
    exit 2
  fi
  IFS=$'\t' read -r _ _ status body header <<<"$route"
  [[ "$body" != - ]] || body=""
  [[ "$header" != - ]] || header=""
  if [[ "$status" == 000 ]]; then
    printf '000'
    exit 28
  fi
  if [[ -n "$hdr" ]]; then
    printf 'HTTP/2 %s\r\n' "$status" >>"$hdr"
    [[ -z "$header" ]] || printf '%s\r\n' "$header" >>"$hdr"
    printf '\r\n' >>"$hdr"
  fi
  if [[ "$follow" == yes && "$status" == 30? && "$header" == Location:* ]]; then
    url="${header#Location: }"
    [[ "$method" == HEAD ]] || method=GET
    printf '%s %s auth=no\n' "$method" "$url" >>"$FAKE_LOG"
    continue
  fi
  if ((status >= 400)); then
    printf '%s' "$status"
    exit 22
  fi
  if [[ "$method" == HEAD ]]; then
    :
  elif [[ -n "$out" ]]; then
    if [[ -n "$body" ]]; then cat "$body" >"$out"; else : >"$out"; fi
  elif [[ -n "$body" ]]; then
    cat "$body"
  fi
  printf '%s' "$status"
  exit 0
done
