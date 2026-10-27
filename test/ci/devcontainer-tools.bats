#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  TEMPLATE="$REPO_ROOT/src/templates/.devcontainer/devcontainer.json5"
  REPOS="$REPO_ROOT/src/repos.yaml"
  CI_REPO="$REPO_ROOT/.github/workflows/ci-repo.yaml"
  OPERATOR_GIT="https://github.com/anthony-spruyt/repo-operator.git"
  ACTIONLINT="ghcr.io/devcontainers-extra/features/actionlint"
  NPM_PACKAGE="ghcr.io/devcontainers-extra/features/npm-package"
  JQ_LIKES="ghcr.io/eitsupi/devcontainer-features/jq-likes"
}

# template_json <jq expr>: the base template once its full-line comments are gone; yq reads the JSON5 as YAML flow style
template_json() {
  sed '/^[[:space:]]*\/\//d' "$TEMPLATE" | yq -p yaml -o json -I0 | jq -r "$1"
}

# operator_devcontainer <yq expr>: repo-operator's devcontainer.json overlay in repos.yaml, comments kept
operator_devcontainer() {
  yq ".repos[] | select(.git == \"$OPERATOR_GIT\") | .files[\".devcontainer/devcontainer.json\"].content | $1" "$REPOS"
}

# ci_pin <step name> <env var>
ci_pin() {
  yq -r ".jobs.guard-test.steps[] | select(.name == \"$1\") | .env.$2" "$CI_REPO"
}

# pin_annotation <file> <feature id>: the line directly above the feature's version line
pin_annotation() {
  awk -v feat="\"$2\"" '
    index($0, feat) { in_feat = 1; next }
    in_feat && /[vV]ersion"?[[:space:]]*:/ { print prev; exit }
    { prev = $0 }' "$1"
}

dep_name() {
  grep -oE 'depName=[^[:space:]]+' <<<"$1"
}

ci_annotation() {
  grep -B1 -F "$1: \"" "$CI_REPO" | head -1
}

@test "the base template's actionlint version is the ACTIONLINT_VERSION CI pins" {
  want="$(ci_pin "Install actionlint" ACTIONLINT_VERSION)"
  run template_json ".features[\"$ACTIONLINT\"].version"
  [ -n "$want" ]
  [ "${output#v}" = "${want#v}" ]
}

@test "the actionlint feature version is annotated for the same dependency as the CI pin" {
  run pin_annotation "$TEMPLATE" "$ACTIONLINT"
  [[ "$output" =~ ^[[:space:]]*//[[:space:]]renovate:[[:space:]] ]]
  [ -n "$(dep_name "$output")" ]
  [ "$(dep_name "$output")" = "$(dep_name "$(ci_annotation ACTIONLINT_VERSION)")" ]
}

@test "repo-operator's jsonata feature version is the JSONATA_VERSION CI pins" {
  want="$(ci_pin "Install jsonata" JSONATA_VERSION)"
  run operator_devcontainer ".features[\"$NPM_PACKAGE\"] | .package + \" \" + .version"
  [ -n "$want" ]
  [ "$output" = "jsonata $want" ]
}

@test "the jsonata feature version is annotated for the same dependency as the CI pin" {
  operator_devcontainer ".features" >"$BATS_TEST_TMPDIR/features.yaml"
  run pin_annotation "$BATS_TEST_TMPDIR/features.yaml" "$NPM_PACKAGE"
  [[ "$output" =~ ^[[:space:]]*#[[:space:]]renovate:[[:space:]] ]]
  [ -n "$(dep_name "$output")" ]
  [ "$(dep_name "$output")" = "$(dep_name "$(ci_annotation JSONATA_VERSION)")" ]
}

@test "every version in the base template's features is annotated for Renovate" {
  run awk '
    /^[[:space:]]*"[A-Za-z]*[vV]ersion"[[:space:]]*:/ {
      n++
      if (prev !~ /^[[:space:]]*\/\/ renovate: /) { print "unannotated: " $0; bad = 1 }
    }
    { prev = $0 }
    END { exit (bad || n == 0) }' "$TEMPLATE"
  [ "$status" -eq 0 ]
}

@test "the base template installs yq, jq and gojq, and actionlint" {
  run template_json "[.features | keys[] | select(. == \"$JQ_LIKES\" or . == \"$ACTIONLINT\")] | length"
  [ "$output" = "2" ]
  run template_json ".features[\"$JQ_LIKES\"] | keys | join(\",\")"
  [ "$output" = "gojqVersion,jqVersion,yqVersion" ]
}

@test "jsonata and NODE_PATH are repo-operator's only, so no other repo can require undeclared global packages" {
  run template_json '[.features, .containerEnv] | tostring'
  [[ "$output" != *"npm-package"* ]]
  [[ "$output" != *"NODE_PATH"* ]]
  run operator_devcontainer '.containerEnv.NODE_PATH'
  [[ "$output" == */lib/node_modules ]]
  run yq "[.repos[] | select(.git != \"$OPERATOR_GIT\") | .files[\".devcontainer/devcontainer.json\"].content | select(. != null) | (.features // {}) | keys | .[] | select(. == \"$NPM_PACKAGE\")] | length" "$REPOS"
  [ "$output" = "0" ]
}

@test "the jq-likes block lives in the base template only" {
  run yq "[.repos[] | .files[\".devcontainer/devcontainer.json\"].content | select(. != null) | (.features // {}) | keys | .[] | select(. == \"$JQ_LIKES\")] | length" "$REPOS"
  [ "$output" = "0" ]
}
