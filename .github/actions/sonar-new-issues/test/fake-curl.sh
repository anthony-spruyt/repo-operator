#!/usr/bin/env bash
# Stands in for curl in the bats tests. Each FAKE_<ENDPOINT> variable holds space-separated
# "[code:]file" responses, served in order with the last one repeating.
set -euo pipefail

out=""
url=""
params=()
while [[ $# -gt 0 ]]; do
  case "$1" in
  -o)
    out="$2"
    shift
    ;;
  --data-urlencode)
    params+=("$2")
    shift
    ;;
  -H | --header)
    echo "header $2" >>"$FAKE_CALLS"
    shift
    ;;
  -w | --max-time | --retry | --proto)
    shift
    ;;
  https://*) url="$1" ;;
  *) ;;
  esac
  shift
done

echo "$url ${params[*]}" >>"$FAKE_CALLS"

case "${url#https://sonarcloud.io/api/}" in
project_pull_requests/list) name=PRS ;;
issues/search) name=ISSUES ;;
hotspots/search) name=HOTSPOTS ;;
measures/component) name=MEASURES ;;
*)
  echo "fake curl: unexpected URL $url" >&2
  exit 2
  ;;
esac

var="FAKE_${name}"
read -r -a responses <<<"${!var:-}"
if [[ ${#responses[@]} -eq 0 ]]; then
  echo "fake curl: $var is not set" >&2
  exit 2
fi

counter="${FAKE_CALLS}.${name}"
n=$(cat "$counter" 2>/dev/null || echo 0)
echo $((n + 1)) >"$counter"
if [[ $n -ge ${#responses[@]} ]]; then
  n=$((${#responses[@]} - 1))
fi
response="${responses[$n]}"

code=200
file="$response"
if [[ "$response" == *:* ]]; then
  code="${response%%:*}"
  file="${response#*:}"
fi

if [[ "$code" == "000" ]]; then
  echo "curl: (7) Failed to connect" >&2
  printf '000'
  exit 7
fi

cp "$file" "$out"
printf '%s' "$code"
