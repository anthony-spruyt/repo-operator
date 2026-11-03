#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  TEMPLATES="$SRC/templates"
  FILES_FILE="$SRC/files.yaml"
  GROUPS_FILE="$SRC/groups.yaml"
  REPOS_FILE="$SRC/repos.yaml"
}

# parsed <file>: a JSON, JSON5 or YAML file as JSON; full-line // comments go first, yq reads the rest as YAML
parsed() {
  sed '/^[[:space:]]*\/\//d' "$1" | yq -p yaml -o json -I0
}

# overlays <synced file>: JSON array of {owner, content}, one per place that sets the file
# (files.yaml, every group, every conditional group, every repo), "@templates/" contents read from disk
overlays() {
  local entry template
  {
    yq -o=json -I0 ".files[\"$1\"] | select(kind == \"map\") | {\"owner\": \"base\", \"content\": .content}" "$FILES_FILE"
    yq -o=json -I0 ".groups | to_entries[] | .key as \$k | (.value.files[\"$1\"] | select(kind == \"map\")) | {\"owner\": \"group:\" + \$k, \"content\": .content}" "$GROUPS_FILE"
    yq -o=json -I0 ".conditionalGroups[] | ((.when.allOf // []) | join(\"+\")) as \$w | (.files[\"$1\"] | select(kind == \"map\")) | {\"owner\": \"when:\" + \$w, \"content\": .content}" "$GROUPS_FILE"
    yq -o=json -I0 ".repos[] | .git as \$g | (.files[\"$1\"] | select(kind == \"map\")) | {\"owner\": \"repo:\" + \$g, \"content\": .content}" "$REPOS_FILE"
  } | while IFS= read -r entry; do
    template="$(jq -r '.content | strings | select(startswith("@templates/")) | ltrimstr("@templates/")' <<<"$entry")"
    if [ -n "$template" ]; then
      jq -c --argjson content "$(parsed "$TEMPLATES/$template")" '.content = $content' <<<"$entry"
    else
      echo "$entry"
    fi
  done | jq -s 'map(select(.content != null))'
}

# synced_files <regex>: "<owner> <file>" for every synced file name matching the regex, from the same places as overlays
synced_files() {
  {
    yq -r ".files | keys | .[] | select(test(\"$1\")) | \"base \" + ." "$FILES_FILE"
    yq -r ".groups | to_entries[] | .key as \$k | ((.value.files // {}) | keys | .[] | select(test(\"$1\"))) | \"group:\" + \$k + \" \" + ." "$GROUPS_FILE"
    yq -r ".conditionalGroups[] | ((.when.allOf // []) | join(\"+\")) as \$w | ((.files // {}) | keys | .[] | select(test(\"$1\"))) | \"when:\" + \$w + \" \" + ." "$GROUPS_FILE"
    yq -r ".repos[] | .git as \$g | ((.files // {}) | keys | .[] | select(test(\"$1\"))) | \"repo:\" + \$g + \" \" + ." "$REPOS_FILE"
  }
}

# vscode_settings: JSON array of {owner, settings}, one per source of VS Code settings:
# every .vscode/settings.json overlay and every devcontainer's customizations.vscode.settings
vscode_settings() {
  {
    overlays .vscode/settings.json | jq -c '.[] | {owner, settings: .content}'
    overlays .devcontainer/devcontainer.json | jq -c '.[] | {owner, settings: .content.customizations.vscode.settings} | select(.settings != null)'
  } | jq -s '.'
}

# conditional_json <group> <file>: the content a conditional group requiring <group> gives a synced file, as JSON
conditional_json() {
  yq -o=json -I0 "[.conditionalGroups[] | select(.when.allOf | contains([\"$1\"])) | .files[\"$2\"].content | select(. != null)] | .[0]" "$GROUPS_FILE"
}

# tf_hook <hook id> <field>: a pre-commit-terraform hook of the terraform group
tf_hook() {
  yq -o=json -I0 '.groups.terraform.files[".pre-commit-config.yaml"].content.repos["$values"][] | select(.repo | test("pre-commit-terraform")) | .hooks[]' "$GROUPS_FILE" |
    jq -r "select(.id == \"$1\") | $2"
}

@test "a conditional group that sets ENABLE_LINTERS on the MegaLinter base appends, so the base allowlist survives" {
  run yq -o=json -I0 '[.conditionalGroups[] | .files[".mega-linter-base.yml"].content.ENABLE_LINTERS | select(. != null) | select((kind == "map" and .["$arrayMerge"] == "append") | not)] | length' "$GROUPS_FILE"
  [ "$output" = "0" ]
}

@test "the typescript group enables prettier for ts and js together with the style keys that activate it" {
  content="$(conditional_json typescript .mega-linter-base.yml)"
  [ "$content" != "null" ]
  for lang in TYPESCRIPT JAVASCRIPT; do
    run jq -r --arg l "$lang" '.ENABLE_LINTERS["$values"] | index($l + "_PRETTIER") != null' <<<"$content"
    [ "$output" = "true" ]
    run jq -r --arg l "$lang" '.[$l + "_DEFAULT_STYLE"]' <<<"$content"
    [ "$output" = "prettier" ]
  done
}

@test "the terraform group has MegaLinter run terraform fmt next to tflint" {
  content="$(conditional_json terraform .mega-linter-base.yml)"
  run jq -r '.ENABLE_LINTERS["$values"] | contains(["TERRAFORM_TFLINT", "TERRAFORM_TERRAFORM_FMT"])' <<<"$content"
  [ "$output" = "true" ]
}

@test "terraform_fmt covers every .tf and .tfvars file and terraform_tflint every .tf file, including the coder templates under cluster/" {
  for id in terraform_fmt terraform_tflint; do
    pattern="$(tf_hook "$id" .files)"
    [ -n "$pattern" ]
    grep -Eq "$pattern" <<<"infra/terraform/main.tf"
    grep -Eq "$pattern" <<<"cluster/apps/coder-system/coder-template-sync/app/templates/xfg/main.tf"
  done
  grep -Eq "$(tf_hook terraform_fmt .files)" <<<"infra/terraform/workspace-factory/variables.auto.tfvars"
}

@test "terraform_tflint reads the repo's .tflint.hcl, the config MegaLinter's tflint reads" {
  run tf_hook terraform_tflint '.args | index("--args=--config=__GIT_WORKING_DIR__/.tflint.hcl") != null'
  [ "$output" = "true" ]
}

@test "markdownlint is the only markdown formatter any pre-commit overlay or synced file brings, and it fixes in place" {
  hooks="$(overlays .pre-commit-config.yaml | jq -c '[.[].content.repos | (if type == "object" then .["$values"] else . end)[]]')"
  run jq -r '.[] | (.repo, .hooks[].id) | select(test("^md|mdformat|markdown|remark|prettier")) | select(. != "https://github.com/igorshubovych/markdownlint-cli" and . != "markdownlint")' <<<"$hooks"
  echo "$output"
  [ "$output" = "" ]
  run synced_files mdformat
  [ "$output" = "" ]
  run jq -r '.[].hooks[] | select(.id == "markdownlint") | [(.args | index("--fix") != null), has("exclude")] | @tsv' <<<"$hooks"
  [ "$output" = $'true\tfalse' ]
}

@test "the markdownlint ignore template skips every file name MegaLinter's base filter excludes" {
  filter="$(yq -r '.FILTER_REGEX_EXCLUDE' "$TEMPLATES/.mega-linter-base.yml")"
  names="$(sed -E 's/^\(//; s/\)$//; s/\$\|/\n/g; s/\$$//; s/\\\././g' <<<"$filter")"
  [ -n "$names" ]
  while IFS= read -r name; do
    [[ "$name" =~ ^[A-Za-z0-9_.-]+$ ]]
    grep -qxF "$name" "$TEMPLATES/.markdownlintignore"
  done <<<"$names"
}

@test "no overlay of the Claude settings adds a PostToolUse hook, where the edit-time formatter used to run" {
  run jq -r '[.[].content.hooks.PostToolUse | select(. != null)] | length' <<<"$(overlays .claude/settings.json)"
  [ "$output" = "0" ]
}

@test "prettier reaches a repo only through the typescript group: its extension, config files and default formatter" {
  extension_owners="$(overlays .devcontainer/devcontainer.json | jq -r '.[] | .owner as $o | (.content.customizations.vscode.extensions // [] | if type == "object" then .["$values"] else . end)[] | select(. == "esbenp.prettier-vscode") | $o' | sort -u)"
  formatter_owners="$(vscode_settings | jq -r '.[] | .owner as $o | .settings | .. | objects | select(.["editor.defaultFormatter"] == "esbenp.prettier-vscode") | $o' | sort -u)"
  [ "$extension_owners" = "group:typescript" ]
  [ "$formatter_owners" = "group:typescript" ]
  [ "$(synced_files prettier | sort)" = $'group:typescript .prettierignore\ngroup:typescript .prettierrc.yaml' ]
}

@test "VS Code formats on save only for a language whose editor formatter is a tool MegaLinter runs, never as a global default" {
  allowed=(
    # TYPESCRIPT_PRETTIER: the prettier extension reads .prettierrc.yaml, as MegaLinter's prettier does
    "[typescript]@group:typescript"
    # JAVASCRIPT_PRETTIER: same
    "[javascript]@group:typescript"
    # TERRAFORM_TERRAFORM_FMT: hashicorp.terraform formats with terraform fmt
    "[terraform]@group:terraform"
    # GO_GOLANGCI_LINT: golang.go formats with gofmt, which the synced .golangci.yml enables as a golangci-lint formatter
    "[go]@when:megalinter-flavor+go"
    # CPP_CLANG_FORMAT: cpptools formats with clang-format and .clang-format, which Chromance's .mega-linter.yml enables
    "[cpp]@repo:https://github.com/anthony-spruyt/Chromance.git"
  )
  allowed_json="$(printf '%s\n' "${allowed[@]}" | jq -R . | jq -s .)"
  run jq -r --argjson allowed "$allowed_json" '
    [.[] | .owner as $o | .settings | to_entries[]
      | if .key == "editor.formatOnSave" then (select(.value != false) | "global@" + $o)
        elif (.key | startswith("[")) and (.value | type == "object") then (select(.value["editor.formatOnSave"] != null and .value["editor.formatOnSave"] != false) | .key + "@" + $o)
        else empty end] as $found
    | ($found - $allowed | map("unexpected " + .)), ($allowed - $found | map("missing " + .)) | .[]' <<<"$(vscode_settings)"
  echo "$output"
  [ "$output" = "" ]
}

@test "the synced golangci config enables gofmt, the formatter golang.go runs on save" {
  run yq -r '.formatters.enable | contains(["gofmt"])' "$TEMPLATES/.golangci.yml"
  [ "$output" = "true" ]
}
