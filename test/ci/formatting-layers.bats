#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  SRC="$REPO_ROOT/src"
  TEMPLATES="$SRC/templates"
  GROUPS_FILE="$SRC/groups.yaml"
}

# group_json <group> <file> <jq expr>: the group's content for a synced file, as JSON
group_json() {
  yq -o=json -I0 ".groups[\"$1\"].files[\"$2\"].content" "$GROUPS_FILE" | jq -r "$3"
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

@test "the terraform hooks cover every .tf file, including the coder templates under cluster/" {
  for id in terraform_fmt terraform_tflint; do
    pattern="$(tf_hook "$id" .files)"
    [ -n "$pattern" ]
    grep -Eq "$pattern" <<<"infra/terraform/main.tf"
    grep -Eq "$pattern" <<<"cluster/apps/coder-system/coder-template-sync/app/templates/xfg/main.tf"
  done
}

@test "terraform_tflint reads the repo's .tflint.hcl, the config MegaLinter's tflint reads" {
  run tf_hook terraform_tflint '.args | index("--args=--config=__GIT_WORKING_DIR__/.tflint.hcl") != null'
  [ "$output" = "true" ]
}

@test "markdown has one formatter, markdownlint fixing in pre-commit, and mdformat is not synced anywhere" {
  run grep -rli mdformat "$SRC"
  [ "$status" -eq 1 ]
  run yq -o=json -I0 '.repos[] | select(.repo | test("markdownlint-cli")) | .hooks[] | select(.id == "markdownlint")' "$TEMPLATES/.pre-commit-config.yaml"
  [ "$(jq -r '.args | index("--fix") != null' <<<"$output")" = "true" ]
  [ "$(jq -r 'has("exclude")' <<<"$output")" = "false" ]
}

@test "the markdownlint ignore template skips every markdown file MegaLinter's base filter skips" {
  filter="$(yq -r '.FILTER_REGEX_EXCLUDE' "$TEMPLATES/.mega-linter-base.yml")"
  for name in CLAUDE.md CHANGELOG.md; do
    grep -Eq "$filter" <<<"$name"
    grep -qxF "$name" "$TEMPLATES/.markdownlintignore"
  done
}

@test "no hook of the claude settings template runs a formatter after an edit" {
  run jq -r '[.hooks.PostToolUse[]?.hooks[]?.command | select(test("mdformat|prettier"))] | length' "$TEMPLATES/.claude/settings.json"
  [ "$output" = "0" ]
}

@test "the prettier extension, its config and its ignore file sync only to the typescript group" {
  run grep -c 'esbenp.prettier-vscode' "$TEMPLATES/.devcontainer/devcontainer.json5"
  [ "$output" = "0" ]
  run yq -o=json -I0 '.files | keys' "$SRC/files.yaml"
  [ "$(jq -r 'any(. == ".prettierrc.yaml" or . == ".prettierignore")' <<<"$output")" = "false" ]
  run group_json typescript .devcontainer/devcontainer.json '.customizations.vscode.extensions["$values"] | index("esbenp.prettier-vscode") != null'
  [ "$output" = "true" ]
  for file in .prettierrc.yaml .prettierignore; do
    run yq -r ".groups.typescript.files | has(\"$file\")" "$GROUPS_FILE"
    [ "$output" = "true" ]
  done
}

@test "VS Code formats on save only in languages whose formatter MegaLinter runs, and not in yaml" {
  run jq -r '."editor.formatOnSave", ."yaml.format.enable"' "$TEMPLATES/.vscode/settings.json"
  [ "$output" = $'false\nfalse' ]
  for lang in typescript javascript; do
    run group_json typescript .vscode/settings.json ".[\"[$lang]\"] | [.\"editor.defaultFormatter\", .\"editor.formatOnSave\"] | join(\" \")"
    [ "$output" = "esbenp.prettier-vscode true" ]
  done
  run group_json terraform .vscode/settings.json '.["[terraform]"]["editor.formatOnSave"]'
  [ "$output" = "true" ]
}
