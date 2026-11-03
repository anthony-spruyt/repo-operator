#!/usr/bin/env bash
# Prints the image a Dockerfile's first FROM line names, with its ARG defaults resolved.
# Usage: devcontainer-image.sh <Dockerfile>
set -euo pipefail

dockerfile="${1:-}"
if [[ -z "$dockerfile" || ! -r "$dockerfile" ]]; then
  echo "Usage: devcontainer-image.sh <Dockerfile> (readable file)" >&2
  exit 2
fi

declare -A args=()
image=""
while IFS= read -r line; do
  if [[ "$line" =~ ^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
    value="${BASH_REMATCH[2]}"
    value="${value%\"}"
    args["${BASH_REMATCH[1]}"]="${value#\"}"
  elif [[ "$line" =~ ^FROM[[:space:]]+(.*)$ ]]; then
    read -ra words <<<"${BASH_REMATCH[1]}"
    for word in "${words[@]}"; do
      [[ "$word" == --* ]] || {
        image="$word"
        break
      }
    done
    break
  fi
done <"$dockerfile"

if [[ -z "$image" ]]; then
  echo "No FROM line in $dockerfile" >&2
  exit 1
fi

var_re='^([^$]*)\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(.*)$'
resolved=""
rest="$image"
while [[ "$rest" =~ $var_re ]]; do
  name="${BASH_REMATCH[2]}"
  if [[ ! -v "args[$name]" ]]; then
    echo "FROM line of $dockerfile uses $name, which no ARG before it sets" >&2
    exit 1
  fi
  resolved+="${BASH_REMATCH[1]}${args[$name]}"
  rest="${BASH_REMATCH[3]}"
done
image="$resolved$rest"

if [[ "$image" == *'$'* ]]; then
  echo "FROM line of $dockerfile still has a variable after resolving: $image" >&2
  exit 1
fi

echo "$image"
