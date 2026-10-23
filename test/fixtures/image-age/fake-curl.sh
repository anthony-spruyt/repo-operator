#!/usr/bin/env bash
# Stands in for curl in the bats tests. Each line of $FAKE_ROUTES is
# "METHOD<TAB>URL<TAB>STATUS<TAB>BODY_FILE<TAB>HEADER" ("-" for an empty field); the first line that matches serves the request.
# With -L a Location header is followed through the routes. Requests land in $FAKE_LOG, request bodies in $FAKE_LOG.body.N.
set -euo pipefail

[[ "${1:-}" == -q ]] || {
  echo "fake curl: -q must come first" >&2
  exit 2
}
shift

method=GET url="" out="" hdr="" data="" follow=no auth=no
while (($#)); do
  case "$1" in
  -X) method="$2" && shift 2 ;;
  -o) out="$2" && shift 2 ;;
  -D) hdr="$2" && shift 2 ;;
  -L) follow=yes && shift ;;
  -sS) shift ;;
  --proto | --proto-redir | --max-time | --retry | -w) shift 2 ;;
  --data-binary) data="${2#@}" && shift 2 ;;
  -H)
    if [[ "$2" == @* ]] && grep -q '^Authorization: ' "${2#@}"; then auth=yes; fi
    shift 2
    ;;
  https://*) url="$1" && shift ;;
  *)
    echo "fake curl: unexpected argument: $1" >&2
    exit 2
    ;;
  esac
done

n=$(($(wc -l <"$FAKE_LOG" 2>/dev/null || echo 0) + 1))
printf '%s %s auth=%s\n' "$method" "$url" "$auth" >>"$FAKE_LOG"
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
  if [[ -n "$hdr" ]]; then
    printf 'HTTP/2 %s\r\n' "$status" >>"$hdr"
    [[ -z "$header" ]] || printf '%s\r\n' "$header" >>"$hdr"
    printf '\r\n' >>"$hdr"
  fi
  if [[ "$follow" == yes && "$status" == 30? && "$header" == Location:* ]]; then
    url="${header#Location: }"
    method=GET
    printf 'GET %s auth=no\n' "$url" >>"$FAKE_LOG"
    continue
  fi
  if [[ -n "$out" ]]; then
    if [[ -n "$body" ]]; then cat "$body" >"$out"; else : >"$out"; fi
  elif [[ -n "$body" ]]; then
    cat "$body"
  fi
  printf '%s' "$status"
  exit 0
done
