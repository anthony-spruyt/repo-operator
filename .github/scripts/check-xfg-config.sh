#!/usr/bin/env bash
# Checks that xfg config targets only github.com hosts, anthony-spruyt repos and the pinned AI endpoint, and holds no env references.
# Runs before every xfg step in ci.yaml. Usage: check-xfg-config.sh [dir]
set -euo pipefail

config_dir="${1:-src}"

# Must match the env passed to the Apply Secrets Sync step in .github/workflows/ci.yaml
readonly ALLOWED_SECRET_ENV='["RELEASE_PLEASE_APP_CLIENT_ID","RELEASE_PLEASE_APP_PRIVATE_KEY","GHCR_READ_TOKEN","DOCKERHUB_TOKEN"]'
readonly ALLOWED_AI_KEY_ENV="OPENROUTER_API_KEY"
readonly ALLOWED_AI_BASE_URL="https://openrouter.ai/api/v1"

# Mirrors xfg's env interpolation (config/env.ts): $${...} is an escape, ${VAR...} reads process.env.
readonly JQ_ENV_REF='def env_refs: gsub("\\$\\$\\{(?!xfg:)[^}]+\\}"; "") | [match("\\$\\{[A-Za-z_][A-Za-z0-9_.]*(:[?-][^}]*)?\\}"; "g").string] | .[];'

# shellcheck disable=SC2016
readonly JQ_CONFIG='
def bad($m): "\($f): \($m)";
def github_url: type == "string" and test("\\Ahttps://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\\z");
def owned_url: type == "string" and test("\\Ahttps://github\\.com/anthony-spruyt/[A-Za-z0-9_.-]+\\z");
(.. | objects | select(has("githubHosts")) | .githubHosts
  | if type != "array" then bad("githubHosts must be a list")
    else .[] | select(. != "github.com") | bad("githubHosts entry not allowed: \(tojson)") end),
(if type == "object" and has("repos") then
  .repos | if type != "array" then bad("repos must be a list") else
    .[] | if type != "object" or (has("git") | not) then bad("repo entry has no git URL: \(tojson)") else
      ((.git | if type == "array" then .[] else . end) | select(owned_url | not)
        | bad("repo git URL not allowed: \(tojson)")),
      (to_entries[] | select(.key == "upstream" or .key == "source") | select(.value | github_url | not)
        | bad("repo \(.key) URL not allowed: \(.value | tojson)"))
    end
  end
else empty end),
(paths(type == "string") as $p
  | select(($p | length) >= 3 and $p[-1] == "env" and $p[-3] == "secrets")
  | getpath($p) | select(IN($secret_env[]) | not)
  | bad("secret source env not allowed: \(tojson)")),
(.. | objects | select(has("files")) | .files | objects | keys[]
  | select(test("(\\A|[/\\\\])\\.git([/\\\\]|\\z)"; "i"))
  | bad("file path has a .git segment: \(tojson)")),
(.. | objects | select(has("apiKeyEnv")) | .apiKeyEnv | select(. != $ai_key_env)
  | bad("prOptions.ai.apiKeyEnv not allowed: \(tojson)")),
(.. | objects | select(has("ai")) | .ai | objects | select(has("baseUrl")) | .baseUrl
  | select(. != $ai_base_url) | bad("prOptions.ai.baseUrl not allowed: \(tojson)"))
'

violations=()

report() {
  while IFS= read -r line; do
    [[ -n "$line" ]] && violations+=("$line")
  done
}

if [[ ! -d "$config_dir" ]]; then
  echo "::error::xfg config directory not found: $config_dir" >&2
  exit 1
fi

# xfg follows symlinks, so config files must be regular files
while IFS= read -r -d '' link; do
  violations+=("$link: symlinks are not allowed")
done < <(find "$config_dir" -type l -print0)

# The files xfg loads as config: every .yaml/.yml, skipping dot-prefixed files and directories
while IFS= read -r -d '' file; do
  if ! json="$(yq -o=json -I0 'explode(.)' "$file" 2>&1)"; then
    violations+=("$file: not valid YAML")
    continue
  fi
  if [[ "$(printf '%s\n' "$json" | grep -c .)" -gt 1 ]]; then
    violations+=("$file: multiple YAML documents are not allowed")
  fi
  if ! dupes="$(yq '.. | select(tag == "!!map") | ((keys | length) - (keys | unique | length)) | select(. > 0)' "$file")" || [[ -n "$dupes" ]]; then
    violations+=("$file: duplicate keys are not allowed")
  fi
  report < <(printf '%s\n' "$json" | jq -r --arg f "$file" \
    --argjson secret_env "$ALLOWED_SECRET_ENV" \
    --arg ai_key_env "$ALLOWED_AI_KEY_ENV" \
    --arg ai_base_url "$ALLOWED_AI_BASE_URL" "$JQ_CONFIG")
done < <(find "$config_dir" -mindepth 1 -name '.*' -prune -o -type f \( -iname '*.yaml' -o -iname '*.yml' \) -print0)

# xfg interpolates ${VAR} from its environment into file content, and any file under the config dir
# can be content, so every file is checked, raw and decoded.
while IFS= read -r -d '' file; do
  report < <(perl -0777 -ne 's/\$\$\{(?!xfg:)[^}]+\}//g; print "$ARGV: env var reference not allowed: $1\n" while /(\$\{[A-Za-z_][A-Za-z0-9_.]*(?::[?-][^}]*)?\})/g' "$file")
  decoded=""
  case "${file,,}" in
  *.yaml | *.yml)
    decoded="$(yq -o=json -I0 'explode(.)' "$file" 2>/dev/null)" || violations+=("$file: not valid YAML")
    ;;
  *.json)
    decoded="$(jq -c . "$file" 2>/dev/null)" || violations+=("$file: not valid JSON")
    ;;
  *.json5)
    # No JSON5 decoder here, so escapes that can spell a reference are rejected
    if perl -0777 -ne 's/\\\\//g; exit(/\\(?:[\$\{\r\nxuU]|\xe2\x80[\xa8\xa9])/ ? 0 : 1)' "$file"; then
      violations+=("$file: escape sequences for \$, { or line continuations are not allowed in JSON5")
    fi
    ;;
  *) ;;
  esac
  if [[ -n "$decoded" ]]; then
    report < <(printf '%s\n' "$decoded" | jq -r --arg f "$file" \
      "$JQ_ENV_REF"' (.. | strings), (.. | objects | keys[]) | env_refs | "\($f): env var reference not allowed: \(.)"')
  fi
done < <(find "$config_dir" -type f -print0)

if [[ "${#violations[@]}" -gt 0 ]]; then
  mapfile -t unique < <(printf '%s\n' "${violations[@]}" | sort -u)
  for v in "${unique[@]}"; do
    echo "::error::$v" >&2
  done
  echo "xfg config guard: ${#unique[@]} violation(s); refusing to run xfg with an App key" >&2
  exit 1
fi

echo "xfg config guard: OK"
