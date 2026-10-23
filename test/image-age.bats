#!/usr/bin/env bats
# shellcheck disable=SC2016

load fixtures/image-age/jsonata

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="$REPO_ROOT/.github/scripts/image-age.sh"
  FX="$REPO_ROOT/test/fixtures/image-age"
  WORK="$BATS_TEST_TMPDIR"
  NOW=1792713600
  RENOVATE_PIN=$(sed -n 's/^RENOVATE_VERSION="\(.*\)"$/\1/p' "$SCRIPT")
  mkdir -p "$WORK/bin" "$WORK/renovate"
  cp "$FX/fake-curl.sh" "$WORK/bin/curl"
  cp "$FX/fake-npx.sh" "$WORK/bin/npx"
  chmod +x "$WORK/bin/curl" "$WORK/bin/npx"
  export PATH="$WORK/bin:$PATH" TMPDIR="$WORK"
  export FAKE_ROUTES="$WORK/routes" FAKE_LOG="$WORK/curl.log" FAKE_NPX_LOG="$WORK/npx.log" FAKE_NPX_DIR="$WORK/renovate"
  : >"$FAKE_ROUTES"
  : >"$FAKE_LOG"
  : >"$FAKE_NPX_LOG"
  export IMAGE_AGE_NOW="$NOW" GITHUB_TOKEN=dummy-token-value
  export IMAGE_AGE_REPOS_FILE="$FX/repos.yaml" IMAGE_AGE_SKIPS_FILE="$WORK/skips.yaml" IMAGE_AGE_RULES_FILE="$WORK/rules.json5"
  : >"$IMAGE_AGE_SKIPS_FILE"
  cat >"$IMAGE_AGE_RULES_FILE" <<'EOF'
{
  packageRules: [
    // moves
    { description: "a", matchDatasources: ["docker"], matchPackageNames: ["ghcr.io/static-web-server/static-web-server"], replacementName: "joseluisq/static-web-server" },
    { description: "b", matchDatasources: ["docker"], matchPackageNames: ["ghcr.io/astral-sh/uv"], replacementName: "astral/uv" },
    { description: "c", matchDatasources: ["docker"], matchPackageNames: ["ghcr.io/felddy/foundryvtt"], replacementName: "felddy/foundryvtt" },
    { description: "d", matchDatasources: ["docker"], matchPackageNames: ["public.ecr.aws/docker/library/eclipse-mosquitto"], replacementName: "eclipse-mosquitto" },
    { description: "e", matchPackageNames: ["renovate"], minimumReleaseAge: "0 days" }
  ]
}
EOF
}

# fn <function> [args]: runs a function of the script the way main would, with the script's shell options
fn() { bash -c 'source "$1" && init_auth && shift && "$@"' _ "$SCRIPT" "$@"; }

# digest <char>: a well-formed digest made of one hex digit
digest() { printf 'sha256:%064d' 0 | tr 0 "$1"; }

# route <METHOD> <URL> <STATUS> [BODY_FILE] [HEADER]
route() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:--}" "${5:--}" >>"$FAKE_ROUTES"; }

@test "the script pins the Renovate version that the annotation lets Renovate bump" {
  [ "$RENOVATE_PIN" = 44.164.7 ]
  grep -B1 '^RENOVATE_VERSION=' "$SCRIPT" | grep -q '^# renovate: depName=renovate datasource=npm$'
}

@test "ghcr rows hold every tag of every tagged version with its digest and push time, and skip untagged versions" {
  run fn rows_ghcr <"$FX/ghcr-versions.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    "sha-a49bd8f	$(digest a)	1792684829" \
    "latest	$(digest a)	1792684829" \
    "main	$(digest a)	1792684829" \
    "2.96.1	$(digest c)	1792684450" \
    "2.96	$(digest c)	1792684450" \
    "2.94.2	$(digest e)	1791797697" \
    "sha256-$(printf '%064d' 0 | tr 0 9).sig	$(digest f)	1791797698")" ]
}

@test "quay rows keep the active build of a tag, not the builds it replaced" {
  run fn rows_quay <"$FX/quay-tags.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    "latest	$(digest a)	1792557174" \
    "v0.15.1	$(digest c)	1791000000" \
    "v0.14.0	$(digest e)	1789000000")" ]
}

@test "mcr rows come out newest first from unordered input, with the fractional seconds and offset dropped" {
  run fn rows_mcr <"$FX/mcr-tags.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    "1.8.0	$(digest a)	1792610379" \
    "1.7.2	$(digest b)	1790848800" \
    "1.7.0	$(digest c)	1788220801")" ]
}

@test "gcr rows turn timeUploadedMs into seconds and skip untagged manifests" {
  run fn rows_gcr <"$FX/gcr-tags.json"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n' \
    "v8.2.0	$(digest a)	1792600000" \
    "latest	$(digest a)	1792600000" \
    "v8.1.0	$(digest b)	1790000000")" ]
}

@test "the row adapters exit non-zero on a body of the wrong shape" {
  run fn rows_ghcr <<<'{"message":"Bad credentials"}'
  [ "$status" -ne 0 ]
  run fn rows_quay <<<'{"message":"x"}'
  [ "$status" -ne 0 ]
  run fn rows_mcr <<<'{"message":"x"}'
  [ "$status" -ne 0 ]
  run fn rows_gcr <<<'{"message":"x"}'
  [ "$status" -ne 0 ]
  run fn rows_ghcr <<<'not json'
  [ "$status" -ne 0 ]
}

# ghcr_page <count> <tag prefix> <created_at>: a versions page of <count> single-tag versions
ghcr_page() {
  jq -n --argjson n "$1" --arg p "$2" --arg t "$3" \
    '[range(0; $n) | {name: "sha256:\(("0" * 64 + tostring)[-64:])", created_at: $t, metadata: {container: {tags: ["\($p)\(.)"]}}}]'
}
old_ghcr_page() { ghcr_page "$1" "$2" 2026-09-01T00:00:00Z; }
young_ghcr_page() { ghcr_page "$1" "$2" 2026-10-22T00:00:00Z; }

GHCR=https://api.github.com
WIDGET_VERSIONS="$GHCR/users/acme/packages/container/widget/versions?per_page=100"
NEXT='Link: <https://api.github.com/user/1/packages/container/widget/versions?per_page=100&page=2>; rel="next", <https://api.github.com/user/1/packages/container/widget/versions?per_page=100&page=9>; rel="last"'

@test "fetch_rows pages ghcr with the token until 50 tags are at least 7 days old, encoding a nested package name" {
  route GET "$GHCR/users/acme/packages/container/charts%2Fwidget/versions?per_page=100" 200 "$FX/ghcr-versions.json" "$NEXT"
  old_ghcr_page 60 t >"$WORK/p2.json"
  route GET "$GHCR/user/1/packages/container/widget/versions?per_page=100&page=2" 200 "$WORK/p2.json" "$NEXT"
  run fn fetch_rows ghcr.io/acme/charts/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 2 ]
  [ "$(grep -c 'auth=yes' "$FAKE_LOG")" -eq 2 ]
  [ "$(wc -l <"$WORK/rows")" -eq 67 ]
  [ "$(head -1 "$WORK/rows" | cut -f1)" = sha-a49bd8f ]
  [ "$(cut -f3 "$WORK/rows" | sort -rn | head -1)" = 1792684829 ]
  [ "$(cut -f3 "$WORK/rows")" = "$(cut -f3 "$WORK/rows" | sort -rn)" ]
}

@test "fetch_rows stops at the first ghcr page that holds 50 old tags and every tag in use" {
  old_ghcr_page 60 t >"$WORK/p1.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/p1.json" "$NEXT"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows" "t3 t7"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 1 ]
  [ "$(wc -l <"$WORK/rows")" -eq 60 ]
  [[ "$output" != *"::"* ]]
}

@test "fetch_rows keeps paging until a tag in use has been seen" {
  old_ghcr_page 60 t >"$WORK/p1.json"
  jq -n '[{name: "sha256:\("1" * 64)", created_at: "2026-08-01T00:00:00Z", metadata: {container: {tags: ["fleet-tag"]}}}]' >"$WORK/p2.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/p1.json" "$NEXT"
  route GET "$GHCR/user/1/packages/container/widget/versions?per_page=100&page=2" 200 "$WORK/p2.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows" "t3 fleet-tag"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 2 ]
  grep -q '^fleet-tag	' "$WORK/rows"
  [[ "$output" != *"::"* ]]
}

@test "fetch_rows warns about a tag in use that the registry never lists and still succeeds" {
  old_ghcr_page 60 t >"$WORK/p1.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/p1.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows" "ghost t1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::ghcr.io/acme/widget: tag ghost in use was not listed by the registry"* ]]
  [[ "$output" != *"t1 in use"* ]]
}

@test "fetch_rows stops at 20 pages with a warning when only a tag in use is still missing" {
  old_ghcr_page 60 t >"$WORK/old.json"
  for n in $(seq 1 25); do
    route GET "$GHCR/user/1/packages/container/widget/versions?per_page=100&page=$n" 200 "$WORK/old.json" "Link: <$GHCR/user/1/packages/container/widget/versions?per_page=100&page=$((n + 1))>; rel=\"next\""
  done
  route GET "$WIDGET_VERSIONS" 200 "$WORK/old.json" "Link: <$GHCR/user/1/packages/container/widget/versions?per_page=100&page=1>; rel=\"next\""
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows" "ghost"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 20 ]
  [[ "$output" == *"::warning::ghcr.io/acme/widget: tag ghost in use was not listed by the registry"* ]]
}

@test "fetch_rows counts only tags that are old enough, not cosign signatures" {
  local sigs=() i
  for i in $(seq 1 60); do sigs+=("$(printf 'sha256-%064d.sig' "$i")"); done
  jq -n '[$ARGS.positional | to_entries[] | {name: "sha256:\(("0" * 64 + (.key | tostring))[-64:])", created_at: "2026-09-01T00:00:00Z", metadata: {container: {tags: [.value]}}}]' \
    --args "${sigs[@]}" >"$WORK/p1.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/p1.json" "$NEXT"
  old_ghcr_page 60 t >"$WORK/p2.json"
  route GET "$GHCR/user/1/packages/container/widget/versions?per_page=100&page=2" 200 "$WORK/p2.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 2 ]
}

@test "fetch_rows keeps the newest build of a tag that shows up twice" {
  jq -n --arg o "$(digest 1)" --arg n "$(digest 2)" '[{name: $o, created_at: "2026-08-01T00:00:00Z", metadata: {container: {tags: ["1.0"]}}},
          {name: $n, created_at: "2026-09-01T00:00:00Z", metadata: {container: {tags: ["1.0", "1"]}}}]' >"$WORK/p1.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/p1.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/rows")" = "$(printf '1.0\t%s\t1788220800\n1\t%s\t1788220800' "$(digest 2)" "$(digest 2)")" ]
}

@test "fetch_rows never sends the token to a next link outside api.github.com" {
  young_ghcr_page 3 t >"$WORK/p1.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/p1.json" 'Link: <https://registry.example.com/next>; rel="next"'
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"ghcr.io/acme/widget"* ]]
  [ "$(wc -l <"$FAKE_LOG")" -eq 1 ]
}

@test "fetch_rows finishes at 20 pages with the old tags it has, even when there are fewer than 50" {
  old_ghcr_page 3 t >"$WORK/old.json"
  jq -n '[range(100) | {name: "sha256:\(("0" * 64 + tostring)[-64:])", created_at: "2026-09-01T00:00:00Z", metadata: {container: {tags: []}}}]' >"$WORK/untagged.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/old.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=2>; rel=\"next\""
  for n in $(seq 2 25); do
    route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$n" 200 "$WORK/untagged.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$((n + 1))>; rel=\"next\""
  done
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows" "t1 t2"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 20 ]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 0 ]
  [ "$(wc -l <"$WORK/rows")" -eq 3 ]
}

@test "fetch_rows still warns at the cap about a tag in use that the short listing lacks" {
  old_ghcr_page 3 t >"$WORK/old.json"
  for n in $(seq 1 25); do
    route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$n" 200 "$WORK/old.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$((n + 1))>; rel=\"next\""
  done
  route GET "$WIDGET_VERSIONS" 200 "$WORK/old.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=1>; rel=\"next\""
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows" "ghost"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::ghcr.io/acme/widget: tag ghost in use was not listed by the registry"* ]]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 0 ]
}

@test "fetch_rows gives up with an error at 20 pages when no tag is old enough" {
  young_ghcr_page 3 t >"$WORK/young.json"
  for n in $(seq 1 25); do
    route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$n" 200 "$WORK/young.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$((n + 1))>; rel=\"next\""
  done
  route GET "$WIDGET_VERSIONS" 200 "$WORK/young.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=1>; rel=\"next\""
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"ghcr.io/acme/widget"*"20 pages"* ]]
  [ "$(wc -l <"$FAKE_LOG")" -eq 20 ]
}

@test "fetch_rows reports the registry status when a page fails, keeping the status of an HTTP error" {
  route GET "$WIDGET_VERSIONS" 403
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::ghcr.io/acme/widget: registry answered 403"* ]]
}

@test "fetch_rows reports a registry that cannot be reached" {
  route GET "$WIDGET_VERSIONS" 000
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::ghcr.io/acme/widget: registry answered 000"* ]]
}

@test "fetch_rows fails on a body the adapter cannot read, instead of reading it as no tags" {
  printf 'not json' >"$WORK/bad.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/bad.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::ghcr.io/acme/widget:"* ]]
}

@test "fetch_rows fails when the registry lists no tags" {
  echo '[]' >"$WORK/empty.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/empty.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::ghcr.io/acme/widget: the registry listed no tags"* ]]
}

@test "fetch_rows fails on a push time that is not a number" {
  jq '.tags[0].start_ts = null' "$FX/quay-tags.json" >"$WORK/q.json"
  route GET "https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=1" 200 "$WORK/q.json"
  run fn fetch_rows quay.io/acme/widget "$WORK/rows"
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::quay.io/acme/widget:"*"push time"* ]]
  jq '.[0].created_at = "yesterday"' "$FX/ghcr-versions.json" >"$WORK/g.json"
  route GET "$WIDGET_VERSIONS" 200 "$WORK/g.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 1 ]
}

@test "fetch_rows drops rows with a malformed tag or digest and warns" {
  jq '.tags[1].name = "bad tag" | .tags[1].end_ts = null | .tags[2].manifest_digest = "sha256:xyz"' "$FX/quay-tags.json" >"$WORK/q.json"
  route GET "https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=1" 200 "$WORK/q.json"
  run fn fetch_rows quay.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$WORK/rows" | paste -sd' ')" = "latest v0.14.0" ]
  [[ "$output" == *"::warning::quay.io/acme/widget: dropped 2 rows"* ]]
}

@test "fetch_rows pages quay by page number without a token" {
  jq '.has_additional = true' "$FX/quay-tags.json" >"$WORK/q1.json"
  jq -n '{tags: [range(0; 60) | {name: "v\(.)", start_ts: 1700000000, end_ts: null, manifest_digest: "sha256:\(("0" * 64 + tostring)[-64:])"}], has_additional: false}' >"$WORK/q2.json"
  route GET "https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=1" 200 "$WORK/q1.json"
  route GET "https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=2" 200 "$WORK/q2.json"
  run fn fetch_rows quay.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_LOG")" = "$(printf 'GET https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=1 auth=no\nGET https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=2 auth=no')" ]
  [ "$(wc -l <"$WORK/rows")" -eq 63 ]
}

@test "fetch_rows reads the mcr catalog in one call, newest first" {
  route GET "https://mcr.microsoft.com/api/v1/catalog/dotnet/aspnet/tags?reg=mar" 200 "$FX/mcr-tags.json"
  run fn fetch_rows mcr.microsoft.com/dotnet/aspnet "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$WORK/rows" | paste -sd' ')" = "1.8.0 1.7.2 1.7.0" ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 1 ]
}

@test "fetch_rows reads gcr.io tag lists in one call" {
  route GET "https://gcr.io/v2/distroless/static/tags/list" 200 "$FX/gcr-tags.json"
  run fn fetch_rows gcr.io/distroless/static "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$WORK/rows" | paste -sd' ')" = "v8.2.0 latest v8.1.0" ]
}

@test "fetch_rows follows the registry.k8s.io redirect without a token" {
  route GET "https://registry.k8s.io/v2/sig-storage/csi-snapshotter/tags/list" 307 "" "Location: https://europe-docker.pkg.dev/v2/k8s-artifacts-prod/images/sig-storage/csi-snapshotter/tags/list?rid=1"
  route GET "https://europe-docker.pkg.dev/v2/k8s-artifacts-prod/images/sig-storage/csi-snapshotter/tags/list?rid=1" 200 "$FX/gcr-tags.json"
  run fn fetch_rows registry.k8s.io/sig-storage/csi-snapshotter "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cut -f1 "$WORK/rows" | paste -sd' ')" = "v8.2.0 latest v8.1.0" ]
  run grep -q 'auth=yes' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "fetch_rows rejects a registry it has no adapter for" {
  run fn fetch_rows registry.example.com/acme/widget "$WORK/rows"
  [ "$status" -eq 2 ]
  [ "$output" = "::error::unsupported registry registry.example.com for registry.example.com/acme/widget" ]
  [ ! -s "$FAKE_LOG" ]
}

@test "select_rows keeps the newest 50 builds that are at least 7 days old, plus fleet tags, minus skips and cosign tags" {
  {
    printf 'young\tsha256:y\t%s\n' $((NOW - 86400))
    printf 'almost\tsha256:a\t%s\n' $((NOW - 604799))
    printf 'edge\tsha256:e\t%s\n' $((NOW - 604800))
    printf 'sha256-%064d.sig\tsha256:s\t%s\n' 7 $((NOW - 700000))
    printf 'skipped\tsha256:k\t%s\n' $((NOW - 700000))
    for i in $(seq 1 60); do printf 'o%s\tsha256:o%s\t%s\n' "$i" "$i" $((NOW - 800000 - i)); done
    printf 'fleet\tsha256:f\t%s\n' $((NOW - 900000))
  } >"$WORK/rows"
  run fn select_rows "$WORK/rows" "fleet young" "skipped"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 51 ]
  [ "$(head -1 <<<"$output")" = "$(printf 'edge\tsha256:e')" ]
  [ "$(tail -1 <<<"$output")" = "$(printf 'fleet\tsha256:f')" ]
  selected=$output
  grep -q '^o49	' <<<"$selected"
  run grep -q '^o50	' <<<"$selected"
  [ "$status" -ne 0 ]
  run grep -Eq '^(young|almost|skipped|sha256-)' <<<"$selected"
  [ "$status" -ne 0 ]
}

@test "trim_rows keeps the young rows, the newest 50 old ones and the tags in use, and drops cosign tags" {
  {
    printf 'young\t%s\t%s\n' "$(digest 1)" $((NOW - 86400))
    printf 'sha256-%064d.sig\t%s\t%s\n' 7 "$(digest 2)" $((NOW - 700000))
    for i in $(seq 1 60); do printf 'o%s\t%s\t%s\n' "$i" "$(digest 3)" $((NOW - 800000 - i)); done
    printf 'fleet\t%s\t%s\n' "$(digest 4)" $((NOW - 900000))
  } >"$WORK/rows"
  run fn trim_rows "$WORK/rows" "fleet"
  [ "$status" -eq 0 ]
  [ "$(wc -l <<<"$output")" -eq 52 ]
  [ "$(head -1 <<<"$output")" = "$(printf 'young\t%s\t%s' "$(digest 1)" $((NOW - 86400)))" ]
  grep -q '^fleet	' <<<"$output"
  run grep -Eq '^(o51|sha256-)' <<<"$output"
  [ "$status" -ne 0 ]
}

@test "allowed_regex escapes every regex character in a tag" {
  run fn allowed_regex 1.2.3 'v1.0.0+b' 'a-b' '2.0_x' 'x(1)|[y]'
  [ "$status" -eq 0 ]
  [ "$output" = '/^(1\.2\.3|v1\.0\.0\+b|a-b|2\.0_x|x\(1\)\|\[y\])$/' ]
}

@test "allowed_regex with no tags fails and prints nothing, so /^\$/ is never written" {
  run fn allowed_regex
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ "$(grep -c '/\^\$/' "$SCRIPT")" -eq 0 ]
}

@test "image_rules gives one allowedVersions rule and one digest rule per image, binding the digest map once" {
  printf 'v0.15.1\t%s\nv0.14.0\t%s\n' "$(digest c)" "$(digest e)" >"$WORK/sel"
  run fn image_rules quay.io/acme/widget "$WORK/sel" "$NOW"
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 2 ]
  jq -e '.[0] | .matchDatasources == ["docker"] and .matchPackageNames == ["quay.io/acme/widget"]
    and .allowedVersions == "/^(v0\\.15\\.1|v0\\.14\\.0)$/"
    and (.description | contains("quay.io/acme/widget") and contains("2026-10-23T00:00:00Z"))
    and (has("enabled") | not)' <<<"$output"
  map="{\"v0.14.0\":\"$(digest e)\",\"v0.15.1\":\"$(digest c)\"}"
  expr="(\$m := $map; \$exists(newDigest) and (\$exists(\$lookup(\$m, newValue)) ? \$lookup(\$m, newValue) != newDigest : true))"
  jq -e --arg expr "$expr" '.[1] | .matchDatasources == ["docker"] and .matchPackageNames == ["quay.io/acme/widget"]
    and .matchUpdateTypes == ["major", "minor", "patch", "digest"] and .enabled == false and .matchJsonata == [$expr]
    and (.description | contains("quay.io/acme/widget") and contains("2026-10-23T00:00:00Z"))' <<<"$output"
}

@test "image_rules refuses an image with no allowed tag" {
  : >"$WORK/sel"
  run fn image_rules quay.io/acme/widget "$WORK/sel" "$NOW"
  [ "$status" -ne 0 ]
}

digest_rule_expr() {
  printf 'v0.15.1\t%s\nv0.14.0\t%s\n' "$(digest c)" "$(digest e)" >"$WORK/sel"
  fn image_rules quay.io/acme/widget "$WORK/sel" "$NOW" | jq -r '.[1].matchJsonata[0]'
}

@test "the digest rule holds back a young or unknown build and lets a dated one through" {
  need_jsonata
  expr=$(digest_rule_expr)
  [ "$(jsonata_true "$expr" '{"depName":"quay.io/acme/widget","currentValue":"v0.15.1"}')" = false ]
  [ "$(jsonata_true "$expr" '{"newValue":"v0.16.0"}')" = false ]
  [ "$(jsonata_true "$expr" "{\"newValue\":\"v0.15.1\",\"newDigest\":\"$(digest c)\"}")" = false ]
  [ "$(jsonata_true "$expr" "{\"newValue\":\"v0.15.1\",\"newDigest\":\"$(digest f)\"}")" = true ]
  [ "$(jsonata_true "$expr" "{\"newValue\":\"v0.16.0\",\"newDigest\":\"$(digest f)\"}")" = true ]
}

@test "a missing jsonata package fails the JSONata tests under CI and skips them elsewhere" {
  printf '#!/usr/bin/env bats\nload "%s"\n@test "needs jsonata" { need_jsonata; }\n' "$FX/jsonata" >"$WORK/probe.bats"
  CI=1 JSONATA_REQUIRE=jsonata-is-not-installed run bats "$WORK/probe.bats"
  [ "$status" -ne 0 ]
  [[ "$output" == *"the jsonata package is not installed"* ]]
  env -u CI JSONATA_REQUIRE=jsonata-is-not-installed bats "$WORK/probe.bats" | grep -q '# skip'
}

# by_image <image>...: a by-image rules file holding the rules of one dated tag per image
by_image() {
  local img json='{}'
  printf 'v1\t%s\n' "$(digest a)" >"$WORK/sel"
  for img in "$@"; do
    json=$(jq --arg i "$img" --argjson r "$(fn image_rules "$img" "$WORK/sel" "$NOW")" '.[$i] = $r' <<<"$json")
  done
  printf '%s\n' "$json" >"$WORK/by-image.json"
}

@test "assemble_preset appends the catch-all and stale guard after the per-image rules, sorted by image" {
  by_image quay.io/zed/last ghcr.io/acme/first
  run fn assemble_preset "$WORK/by-image.json" "$WORK/preset.json" "$NOW"
  [ "$status" -eq 0 ]
  jq -e '."$schema" != null and (.packageRules | length) == 6' "$WORK/preset.json"
  [ "$(jq -S . "$WORK/preset.json")" = "$(cat "$WORK/preset.json")" ]
  [ "$(jq -r '.packageRules[0:4][].matchPackageNames[0]' "$WORK/preset.json" | paste -sd' ')" = "ghcr.io/acme/first ghcr.io/acme/first quay.io/zed/last quay.io/zed/last" ]
  jq -e '.packageRules | all(has("description"))' "$WORK/preset.json"
}

@test "assemble_preset catch-all disables unknown registry images but not known, own, moved or Docker Hub ones" {
  by_image ghcr.io/acme/first
  fn assemble_preset "$WORK/by-image.json" "$WORK/preset.json" "$NOW"
  jq -e '.packageRules[2] | .enabled == false and .matchDatasources == ["docker"] and (has("matchUpdateTypes") | not)
    and (has("matchJsonata") | not) and (.description | contains("not yet dated"))
    and .matchPackageNames[0] == "/^[^/]+\\.[^/]+\\//"' "$WORK/preset.json"
  [ "$(jq -r '.packageRules[2].matchPackageNames[1:][]' "$WORK/preset.json" | sort | paste -sd' ')" = "$(printf '%s\n' \
    '!docker.io/**' '!index.docker.io/**' '!registry-1.docker.io/**' '!ghcr.io/anthony-spruyt/**' '!8gears.container-registry.com/**' \
    '!ghcr.io/static-web-server/static-web-server' '!ghcr.io/astral-sh/uv' '!ghcr.io/felddy/foundryvtt' \
    '!public.ecr.aws/docker/library/eclipse-mosquitto' '!ghcr.io/acme/first' | sort | paste -sd' ')" ]
}

@test "assemble_preset stale guard trips 36 hours after generation and still covers the known images" {
  by_image ghcr.io/acme/first
  fn assemble_preset "$WORK/by-image.json" "$WORK/preset.json" "$NOW"
  jq -e --arg expr "\$toMillis(\$now()) > $(((NOW + 36 * 3600) * 1000))" '.packageRules[3]
    | .enabled == false and .matchDatasources == ["docker"] and .matchUpdateTypes == ["major", "minor", "patch", "digest"]
    and .matchJsonata == [$expr] and (.description | contains("older than 36h"))
    and (.matchPackageNames | index("!ghcr.io/acme/first") | not)
    and (.matchPackageNames | index("!docker.io/**") != null) and (.matchPackageNames | index("!ghcr.io/astral-sh/uv") != null)' "$WORK/preset.json"
}

@test "the stale guard expression is false before its cutoff and true after it" {
  need_jsonata
  by_image ghcr.io/acme/first
  fn assemble_preset "$WORK/by-image.json" "$WORK/future.json" 4102444800
  fn assemble_preset "$WORK/by-image.json" "$WORK/past.json" 0
  [ "$(jsonata_true "$(jq -r '.packageRules[3].matchJsonata[0]' "$WORK/future.json")" '{}')" = false ]
  [ "$(jsonata_true "$(jq -r '.packageRules[3].matchJsonata[0]' "$WORK/past.json")" '{}')" = true ]
}

use_renovate_logs() {
  cp "$FX/renovate-blog.log" "$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  cp "$FX/renovate-sungather.log" "$FAKE_NPX_DIR/anthony-spruyt__SunGather.log"
  cp "$FX/renovate-spruyt-labs.log" "$FAKE_NPX_DIR/anthony-spruyt__spruyt-labs.log"
}

@test "extract lists the third-party registry images of every public repo, without own, moved, out-of-scope or Docker Hub images" {
  use_renovate_logs
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.images | keys[]' "$WORK/out/inventory.json" | paste -sd' ')" = "gcr.io/distroless/static ghcr.io/berriai/litellm-non_root ghcr.io/coder/envbuilder ghcr.io/czlonkowski/n8n-mcp ghcr.io/gohugoio/hugo ghcr.io/victoriametrics/mcp-victoriametrics mcr.microsoft.com/presidio-analyzer quay.io/ceph/ceph registry.k8s.io/sig-storage/csi-snapshotter" ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = "[]" ]
}

@test "extract records the tags in use and the pinned digests once per repo" {
  use_renovate_logs
  fn main extract --out "$WORK/out"
  jq -e '.images["ghcr.io/czlonkowski/n8n-mcp"] == {tags: ["2.95.0"], pins: [{repo: "anthony-spruyt/spruyt-labs", tag: "2.95.0", digest: "sha256:41f03f45896081afbb109ef8b158839bfe01c180dba5409c4f346ca668afeb1c"}]}
    and .images["ghcr.io/gohugoio/hugo"].pins[0].repo == "anthony-spruyt/blog"
    and .images["registry.k8s.io/sig-storage/csi-snapshotter"] == {tags: ["v8.7.0"], pins: []}
    and (.images["quay.io/ceph/ceph"].pins | length) == 1' "$WORK/out/inventory.json"
}

@test "extract runs the pinned Renovate once per public repo with the token, the Actions bot identity and JSON logs, and never prints the token" {
  use_renovate_logs
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  bot='user=github-actions[bot] author=github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>'
  [ "$(cat "$FAKE_NPX_LOG")" = "$(printf '%s\n' \
    "--yes renovate@$RENOVATE_PIN --dry-run=extract --platform=github anthony-spruyt/blog | token=set format=json $bot" \
    "--yes renovate@$RENOVATE_PIN --dry-run=extract --platform=github anthony-spruyt/SunGather | token=set format=json $bot" \
    "--yes renovate@$RENOVATE_PIN --dry-run=extract --platform=github anthony-spruyt/spruyt-labs | token=set format=json $bot")" ]
  [[ "$output" != *dummy-token-value* ]]
}

@test "extract keeps the Renovate log and stderr of every repo in the out dir, named after the repo" {
  use_renovate_logs
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  for name in blog SunGather spruyt-labs; do
    [ -s "$WORK/out/anthony-spruyt__$name.log" ]
    [ -s "$WORK/out/anthony-spruyt__$name.err" ]
  done
  cmp "$WORK/out/anthony-spruyt__blog.log" "$FX/renovate-blog.log"
  grep -q '^npm warn deprecated' "$WORK/out/anthony-spruyt__blog.err"
}

@test "extract reports a repo that fails and carries on with the rest" {
  use_renovate_logs
  rm "$FAKE_NPX_DIR/anthony-spruyt__SunGather.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::"*"anthony-spruyt/SunGather"* ]]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/SunGather"]' ]
  jq -e '.images["ghcr.io/gohugoio/hugo"] != null' "$WORK/out/inventory.json"
  grep -q '^::error::.*anthony-spruyt/SunGather' "$WORK/out/report.txt"
}

@test "extract shows why a repo failed in the job log and the report: the warning and error lines of the Renovate log with Renovate's own error text, and the end of its stderr" {
  use_renovate_logs
  cp "$FX/renovate-auth-failure.log" "$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  echo 1 >"$FAKE_NPX_DIR/anthony-spruyt__blog.status"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  for text in 'github.com token 401 unauthorized' 'Initialization error: Authentication failure' 'npm warn deprecated fake@1.0.0'; do
    [[ "$output" == *"$text"* ]]
    grep -qF "$text" "$WORK/out/report.txt"
  done
  [[ "$output" != *'Renovate started'* && "$output" != *'log level'* && "$output" != *'non-zero code'* ]]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
}

@test "extract shows the result Renovate gives for a run that exits 0 without extracting" {
  use_renovate_logs
  cp "$FX/renovate-bad-credentials.log" "$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  for text in 'Bad credentials - aborting' 'result: bad-credentials'; do
    [[ "$output" == *"$text"* ]]
    grep -qF "$text" "$WORK/out/report.txt"
  done
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
}

@test "extract shows the same diagnosis for a run that exits 0 without extracting" {
  use_renovate_logs
  cp "$FX/renovate-aborted.log" "$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'Repository has been aborted'*'Repository not found'* ]]
  grep -q 'Repository has been aborted' "$WORK/out/report.txt"
  [ "$(grep -c 'Repository has been aborted' <<<"$output")" -eq 1 ]
}

@test "extract diagnosis holds the first 15 error lines of the log and the last 10 lines of stderr" {
  use_renovate_logs
  for i in $(seq 1 20); do printf '{"level":50,"msg":"failure %02d"}\n' "$i"; done >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  for i in $(seq 1 12); do echo "stderr line $i"; done >"$FAKE_NPX_DIR/anthony-spruyt__blog.err"
  echo 1 >"$FAKE_NPX_DIR/anthony-spruyt__blog.status"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'failure [0-9]' <<<"$output")" -eq 15 ]
  [[ "$output" == *'failure 15'* && "$output" != *'failure 16'* ]]
  [ "$(grep -c 'stderr line' <<<"$output")" -eq 10 ]
  [[ "$output" == *'stderr line 12'* && "$output" != *'stderr line 2'$'\n'* ]]
  [ "$(grep -c 'stderr line' "$WORK/out/report.txt")" -eq 10 ]
}

@test "extract diagnosis skips lines of the log that are not JSON or have no numeric level, and tolerates an err that is not an object" {
  use_renovate_logs
  printf '%s\n' 'plain text, level 50' '42' '{"level":"50","msg":"string level"}' '{"level":50,"msg":"string err","err":"boom"}' '{"level":50,"err":{"message":"no msg"}}' '{"level":40,"msg":"object error message","errorMessage":{"a":1}}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  echo 1 >"$FAKE_NPX_DIR/anthony-spruyt__blog.status"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'string err'* && "$output" == *'no msg'* && "$output" == *'object error message'* ]]
  [[ "$output" != *'string level'* && "$output" != *'plain text'* ]]
}

@test "extract diagnosis cannot start a workflow command from the log or stderr" {
  use_renovate_logs
  printf '%s\n' '{"level":50,"msg":"::error::from msg","err":{"message":"line one\n::error::from err"}}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  printf '%s\n' '::error::from stderr' '  ::warning::indented stderr' >"$FAKE_NPX_DIR/anthony-spruyt__blog.err"
  echo 1 >"$FAKE_NPX_DIR/anthony-spruyt__blog.status"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'from msg'*'from err'*'from stderr'*'indented stderr'* ]]
  [ "$(grep -c '^[[:space:]]*::' <<<"$output")" -eq 1 ]
  [ "$(grep -c '^[[:space:]]*::' "$WORK/out/report.txt")" -eq 1 ]
}

@test "extract diagnosis turns a carriage return in the log or stderr into a space, so nothing after it starts a workflow command" {
  use_renovate_logs
  printf '%s\n' '{"level":50,"msg":"a\r::error::x","errorMessage":"b\r::error::y","err":{"message":"c\r::error::z"}}' '{"level":30,"msg":"Repository finished","result":"d\r::error::w"}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  printf 'e\r::error::v\n' >"$FAKE_NPX_DIR/anthony-spruyt__blog.err"
  echo 1 >"$FAKE_NPX_DIR/anthony-spruyt__blog.status"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^  log: a ' <<<"$output")" -eq 1 ]
  [[ "$output" == *'log: a ::error::x: b ::error::y: c ::error::z'* ]]
  [[ "$output" == *'result: d ::error::w'* ]]
  [[ "$output" == *'stderr: e ::error::v'* ]]
  for text in "$output" "$(cat "$WORK/out/report.txt")"; do
    [[ "$text" != *$'\r'* ]]
    [ "$(tr '\r' '\n' <<<"$text" | grep -c '^[[:space:]]*::')" -eq 1 ]
  done
}

@test "extract treats a log that never reached the end of the run as a failure" {
  use_renovate_logs
  head -1 "$FX/renovate-blog.log" >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
}

@test "extract treats a run that finished without extracting anything as a failure" {
  use_renovate_logs
  cp "$FX/renovate-aborted.log" "$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
  [[ "$output" == *"::error::"*"anthony-spruyt/blog"* ]]
}

@test "extract shows the same diagnosis when the extracted dependencies of a run cannot be read" {
  use_renovate_logs
  printf '%s\n' '{"level":50,"msg":"odd run"}' '{"level":30,"msg":"Extracted dependencies","packageFiles":{"dockerfile":"odd"}}' '{"level":30,"msg":"Repository finished"}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  echo 'stderr after odd run' >"$FAKE_NPX_DIR/anthony-spruyt__blog.err"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
  for text in 'Renovate output for anthony-spruyt/blog' 'log: odd run' 'stderr: stderr after odd run'; do
    [[ "$output" == *"$text"* ]]
    grep -qF "$text" "$WORK/out/report.txt"
  done
}

@test "extract treats a log it cannot read as a failure, not as an empty repo" {
  use_renovate_logs
  printf '%s\n' '{"msg":"Extracted dependencies","packageFiles":"odd"}' '{"msg":"Repository finished"}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
  [[ "$output" == *"::error::"*"anthony-spruyt/blog"* ]]
}

@test "extract drops an image name that is not a valid reference and reports it without letting it start a workflow command" {
  use_renovate_logs
  jq -nc '{msg: "Extracted dependencies", packageFiles: {dockerfile: [{deps: [
      {depName: "quay.io/Bad/Name", packageName: "quay.io/Bad/Name", datasource: "docker", currentValue: "1"},
      {depName: "quay.io/ok/name\n::error::injected", packageName: "quay.io/ok/name\n::error::injected", datasource: "docker", currentValue: "1"},
      {depName: "quay.io/ok/widget", packageName: "quay.io/ok/widget", datasource: "docker", currentValue: "1"}]}]}}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  echo '{"msg":"Repository finished"}' >>"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'::error::dropped the image name "quay.io/Bad/Name"'*"anthony-spruyt/blog"* ]]
  [[ "$output" == *'dropped the image name "quay.io/ok/name\n::error::injected"'* ]]
  [ "$(grep -c '^::error::' <<<"$output")" -eq 2 ]
  [ "$(jq -r '.images | keys[]' "$WORK/out/inventory.json" | grep -c 'quay.io/ok/widget')" -eq 1 ]
  [ "$(jq -r '.images | keys[]' "$WORK/out/inventory.json" | grep -c -i 'bad\|injected')" -eq 0 ]
}

@test "the script dispatches its subcommands and rejects anything else" {
  use_renovate_logs
  run "$SCRIPT" extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ -s "$WORK/out/inventory.json" ]
  run "$SCRIPT" extract
  [ "$status" -eq 2 ]
  run "$SCRIPT" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *usage* ]]
}

PREV="$GHCR/repos/anthony-spruyt/renovate-data/contents/image-age-data.json?ref=main"

# inventory <json>: the extract artifact render reads
inventory() {
  mkdir -p "$WORK/in"
  printf '%s\n' "$1" >"$WORK/in/inventory.json"
  : >"$WORK/in/report.txt"
}

# widget_inventory <digest>: one quay image used at v0.15.1 and pinned to <digest>
widget_inventory() {
  inventory "{\"failedRepos\":[],\"images\":{\"quay.io/acme/widget\":{\"tags\":[\"v0.15.1\"],\"pins\":[{\"repo\":\"anthony-spruyt/blog\",\"tag\":\"v0.15.1\",\"digest\":\"$1\"}]}}}"
}

route_quay() { route GET "https://quay.io/api/v1/repository/acme/widget/tag/?onlyActive=true&limit=100&page=1" "$@"; }

# route_rest: no previous data and no overrides in any repo (first matching route wins, so add specific ones before)
route_rest() {
  route GET "$PREV" 404
  for r in blog SunGather spruyt-labs; do route GET "$GHCR/repos/anthony-spruyt/$r/contents/renovate-overrides.json5" 404; done
}

# previous_data <image> [rows json]: the image-age-data.json of an earlier run, served by the data repo
previous_data() {
  local rows=${2:-"[{\"tag\":\"v0.15.1\",\"digest\":\"$(digest c)\",\"pushedAt\":1791000000},{\"tag\":\"v0.14.0\",\"digest\":\"$(digest e)\",\"pushedAt\":1789000000}]"}
  jq -n --arg i "$1" --argjson rows "$rows" '{generatedAt: "2026-10-22T18:00:00Z",
    inventory: {failedRepos: [], images: {($i): {tags: ["v0.15.1"], pins: []}}}, rows: {($i): $rows}}' >"$WORK/previous-data.json"
  route GET "$PREV" 200 "$WORK/previous-data.json"
}

widget_rules() { jq -c '[.packageRules[] | select(.matchPackageNames == ["quay.io/acme/widget"])]' "$1"; }

@test "render dates each image at its registry and writes the preset, the data and the report, but no script" {
  widget_inventory "$(digest c)"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  jq -e '.packageRules[0].allowedVersions == "/^(v0\\.15\\.1|v0\\.14\\.0)$/" and (.packageRules | length) == 4' "$WORK/out/image-age.json"
  jq -e --arg c "$(digest c)" '.generatedAt == "2026-10-23T00:00:00Z"
    and .rows["quay.io/acme/widget"] == [
      {tag: "latest", digest: "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", pushedAt: 1792557174},
      {tag: "v0.15.1", digest: $c, pushedAt: 1791000000},
      {tag: "v0.14.0", digest: "sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", pushedAt: 1789000000}]
    and .inventory.images["quay.io/acme/widget"].tags == ["v0.15.1"]' "$WORK/out/image-age-data.json"
  [ -f "$WORK/out/report.txt" ]
  [ ! -e "$WORK/out/image-age.sh" ]
  [[ "$output" != *"::"* ]]
  grep -q 'quay.io.* auth=no' "$FAKE_LOG"
  grep -q 'contents/image-age-data.json?ref=main auth=yes raw=yes' "$FAKE_LOG"
}

@test "render leaves out tags and digests that are younger than 7 days and the skipped tags" {
  widget_inventory "$(digest c)"
  printf 'quay.io/acme/widget:\n  - v0.14.0\n' >"$IMAGE_AGE_SKIPS_FILE"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  fn main render --in "$WORK/in" --out "$WORK/out"
  jq -e --arg d "$(digest c)" '.packageRules[0].allowedVersions == "/^(v0\\.15\\.1)$/"
    and (.packageRules[1].matchJsonata[0] | contains("\"v0.15.1\":\"" + $d + "\"") and (contains("latest") | not) and (contains("v0.14.0") | not))' "$WORK/out/image-age.json"
}

@test "render holds an image back, not behind an empty allowedVersions, when none of its tags is old enough or allowed" {
  widget_inventory "$(digest c)"
  printf 'quay.io/acme/widget:\n  - v0.15.1\n  - v0.14.0\n' >"$IMAGE_AGE_SKIPS_FILE"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  jq -e '.packageRules[0] | .enabled == false and .matchPackageNames == ["quay.io/acme/widget"] and (has("allowedVersions") | not)' "$WORK/out/image-age.json"
  [ "$(grep -c '/^\$/' "$WORK/out/image-age.json")" -eq 0 ]
}

@test "render says nothing about a pinned digest that the registry does not list for its tag" {
  widget_inventory "$(digest f)"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" != *"::"* ]]
  [ "$(grep -c '::' "$WORK/out/report.txt")" -eq 0 ]
}

@test "render keeps the stored rows of an image when its registry fails and renders the rules from them" {
  widget_inventory "$(digest c)"
  previous_data quay.io/acme/widget
  route_quay 500
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::quay.io/acme/widget: registry answered 500"* ]]
  jq -e --arg c "$(digest c)" --arg e "$(digest e)" '.packageRules[0].allowedVersions == "/^(v0\\.15\\.1|v0\\.14\\.0)$/"
    and (.packageRules[1].matchJsonata[0] | contains("\"v0.14.0\":\"" + $e + "\",\"v0.15.1\":\"" + $c + "\""))' "$WORK/out/image-age.json"
  [ "$(jq -c '.rows["quay.io/acme/widget"] | map(.tag)' "$WORK/out/image-age-data.json")" = '["v0.15.1","v0.14.0"]' ]
  grep -q '^::error::quay.io/acme/widget' "$WORK/out/report.txt"
}

@test "render re-renders stored rows against the clock, so a row that has grown old enough becomes allowed" {
  widget_inventory "$(digest c)"
  previous_data quay.io/acme/widget "[{\"tag\":\"v0.15.1\",\"digest\":\"$(digest c)\",\"pushedAt\":$((NOW - 3 * 86400))},{\"tag\":\"v0.14.0\",\"digest\":\"$(digest e)\",\"pushedAt\":$((NOW - 9 * 86400))}]"
  route_quay 500
  route_rest
  fn main render --in "$WORK/in" --out "$WORK/out"
  jq -e '.packageRules[0].allowedVersions == "/^(v0\\.14\\.0)$/"' "$WORK/out/image-age.json"
}

@test "render treats a registry answer with no tags, or one it cannot read, as a failure that keeps the stored rows" {
  widget_inventory "$(digest c)"
  previous_data quay.io/acme/widget
  echo '{"tags":[],"has_additional":false}' >"$WORK/none.json"
  route_quay 200 "$WORK/none.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::quay.io/acme/widget: the registry listed no tags"* ]]
  jq -e '.packageRules[0].allowedVersions == "/^(v0\\.15\\.1|v0\\.14\\.0)$/"' "$WORK/out/image-age.json"
}

@test "render holds back an image whose registry fails or answers with nothing usable when there are no stored rows" {
  widget_inventory "$(digest c)"
  : >"$FAKE_ROUTES"
  route_quay 500
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::quay.io/acme/widget: registry answered 500"* ]]
  jq -e '.packageRules[0] | .enabled == false and .matchPackageNames == ["quay.io/acme/widget"] and (has("allowedVersions") | not) and (has("matchUpdateTypes") | not)' "$WORK/out/image-age.json"

  : >"$FAKE_ROUTES"
  printf '<html>' >"$WORK/html"
  route_quay 200 "$WORK/html"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::quay.io/acme/widget:"* ]]
  jq -e '.packageRules[0] | .enabled == false and (has("allowedVersions") | not)' "$WORK/out2/image-age.json"
  [ "$(grep -c '/^\$/' "$WORK/out2/image-age.json")" -eq 0 ]
  [ "$(jq '.rows["quay.io/acme/widget"] // [] | length' "$WORK/out2/image-age-data.json")" -eq 0 ]
}

@test "render holds back an image from a registry it cannot read and asks no one for its tags" {
  inventory '{"failedRepos":[],"images":{"registry.example.com/acme/widget":{"tags":["1"],"pins":[]}}}'
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::unsupported registry registry.example.com for registry.example.com/acme/widget"* ]]
  jq -e '.packageRules[0] | .enabled == false and .matchPackageNames == ["registry.example.com/acme/widget"]' "$WORK/out/image-age.json"
  run grep -q registry.example.com "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "render re-validates the stored data: bad image names and bad rows are dropped with an error" {
  widget_inventory "$(digest c)"
  jq -n --arg c "$(digest c)" '{generatedAt: "2026-10-22T18:00:00Z", inventory: {failedRepos: [], images: {}},
    rows: {"quay.io/acme/widget": [{tag: "v0.15.1", digest: $c, pushedAt: 1791000000},
                                    {tag: "bad tag", digest: $c, pushedAt: 1791000000},
                                    {tag: "v0.13.0", digest: "sha256:short", pushedAt: 1791000000},
                                    {tag: "v0.12.0", digest: $c, pushedAt: "yesterday"}],
           "evil.example/a b": [{tag: "1", digest: $c, pushedAt: 1}],
           "quay.io/x\n::error::pwned": [{tag: "1", digest: $c, pushedAt: 1}]}}' >"$WORK/previous-data.json"
  route GET "$PREV" 200 "$WORK/previous-data.json"
  route_quay 500
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  jq -e '.packageRules[0].allowedVersions == "/^(v0\\.15\\.1)$/"' "$WORK/out/image-age.json"
  [[ "$output" == *'::error::dropped the image name "evil.example/a b" from the previous data'* ]]
  [[ "$output" == *'::error::dropped the image name "quay.io/x\n::error::pwned" from the previous data'* ]]
  [[ "$output" == *"::error::dropped 3 rows of quay.io/acme/widget from the previous data"* ]]
  [ "$(grep -c '^::error::pwned' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.rows | keys | join(" ")' "$WORK/out/image-age-data.json")" = "quay.io/acme/widget" ]
}

@test "render drops invalid image names from the inventory and reports them without starting a workflow command" {
  inventory '{"failedRepos":[],"images":{"Bad Name":{"tags":["1"],"pins":[]},"quay.io/x\n::error::pwned":{"tags":["1"],"pins":[]},"quay.io/acme/widget":{"tags":["v0.15.1","bad tag"],"pins":[]}}}'
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *'::error::dropped the image name "Bad Name" from the inventory'* ]]
  [[ "$output" == *'::error::dropped the image name "quay.io/x\n::error::pwned" from the inventory'* ]]
  [ "$(grep -c '^::error::pwned' <<<"$output")" -eq 0 ]
  [ "$(jq -r '.inventory.images | keys | join(" ")' "$WORK/out/image-age-data.json")" = "quay.io/acme/widget" ]
  [ "$(jq -c '.inventory.images["quay.io/acme/widget"].tags' "$WORK/out/image-age-data.json")" = '["v0.15.1"]' ]
}

@test "render carries over the stored rows of images it could not list only when a repo failed to extract" {
  previous_data ghcr.io/acme/gone "[{\"tag\":\"v1\",\"digest\":\"$(digest a)\",\"pushedAt\":1791000000}]"
  route GET "$GHCR/users/acme/packages/container/gone/versions?per_page=100" 500
  route_rest

  inventory '{"failedRepos":["anthony-spruyt/SunGather"],"images":{}}'
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  jq -e '[.packageRules[] | select(.matchPackageNames == ["ghcr.io/acme/gone"])] | length == 2' "$WORK/out/image-age.json"
  jq -e '.packageRules[-2].matchPackageNames | index("!ghcr.io/acme/gone") != null' "$WORK/out/image-age.json"
  jq -e '.inventory.images["ghcr.io/acme/gone"].tags == ["v0.15.1"] and .inventory.failedRepos == ["anthony-spruyt/SunGather"]' "$WORK/out/image-age-data.json"

  inventory '{"failedRepos":[],"images":{}}'
  run fn main render --in "$WORK/in" --out "$WORK/out2"
  [ "$status" -eq 0 ]
  jq -e '[.packageRules[] | select(.matchPackageNames == ["ghcr.io/acme/gone"])] | length == 0' "$WORK/out2/image-age.json"
}

@test "render treats an absent data file as a first run and stops when the data repo cannot be read" {
  widget_inventory "$(digest c)"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]

  : >"$FAKE_ROUTES"
  route GET "$PREV" 500
  run fn main render --in "$WORK/in" --out "$WORK/out2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"500"* ]]
  [ ! -e "$WORK/out2/image-age.json" ]
}

@test "render stops when the stored data is not a JSON object" {
  widget_inventory "$(digest c)"
  printf 'not json' >"$WORK/previous-data.json"
  route GET "$PREV" 200 "$WORK/previous-data.json"
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
  [ ! -e "$WORK/out/image-age.json" ]
}

overrides_in() {
  inventory '{"failedRepos":[],"images":{"quay.io/acme/widget":{"tags":["v0.15.1"],"pins":[]},"ghcr.io/acme/litellm":{"tags":["v1"],"pins":[]}}}'
  cat >"$WORK/overrides.json5"
  route GET "$GHCR/repos/anthony-spruyt/spruyt-labs/contents/renovate-overrides.json5" 200 "$WORK/overrides.json5"
  route_quay 200 "$FX/quay-tags.json"
  route GET "$GHCR/users/acme/packages/container/litellm/versions?per_page=100" 200 "$FX/ghcr-versions.json"
  route_rest
}

@test "render reports an override that turns a dated image back on as an error and an allowedVersions override as a warning" {
  overrides_in <<'JSON5'
{
  packageRules: [
    // a mistyped upstream tag
    { matchPackageNames: ["quay.io/acme/widget"], allowedVersions: "!/^v?1\\.0$/" },
    { matchDepNames: ["ghcr.io/acme/litellm"], enabled: true },
    { matchPackageNames: ["docker.io/other/thing"], allowedVersions: "<2" },
    { matchPackageNames: ["quay.io/acme/widget"], schedule: ["at any time"] }
  ]
}
JSON5
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^::error::anthony-spruyt/spruyt-labs renovate-overrides.json5' <<<"$output")" -eq 1 ]
  [ "$(grep -c '^::warning::anthony-spruyt/spruyt-labs renovate-overrides.json5' <<<"$output")" -eq 1 ]
  [[ "$output" == *"::error::anthony-spruyt/spruyt-labs renovate-overrides.json5 sets enabled: true for ghcr.io/acme/litellm"* ]]
  [[ "$output" == *"::warning::anthony-spruyt/spruyt-labs renovate-overrides.json5 sets allowedVersions for quay.io/acme/widget"* ]]
  [ -f "$WORK/out/image-age.json" ]
}

@test "render ignores an override that turns a dated image off" {
  overrides_in <<'JSON5'
{
  packageRules: [
    { matchDepNames: ["ghcr.io/acme/litellm"], enabled: false }
  ]
}
JSON5
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" != *"renovate-overrides.json5"* ]]
}

@test "render reports overrides it cannot read" {
  widget_inventory "$(digest c)"
  route GET "$GHCR/repos/anthony-spruyt/blog/contents/renovate-overrides.json5" 500
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [[ "$output" == *"::error::anthony-spruyt/blog renovate-overrides.json5 answered 500"* ]]
}

@test "hashes prints the sha256 of the preset and of the data file" {
  mkdir -p "$WORK/art"
  printf '{"a":1}\n' >"$WORK/art/image-age.json"
  printf '{"b":2}\n' >"$WORK/art/image-age-data.json"
  run fn main hashes --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'preset=%s\ndata=%s' "$(sha256sum <"$WORK/art/image-age.json" | cut -d' ' -f1)" "$(sha256sum <"$WORK/art/image-age-data.json" | cut -d' ' -f1)")" ]
}

# preset_in: a rendered artifact directory with a preset of the shape render writes
preset_in() {
  mkdir -p "$WORK/art"
  by_image quay.io/acme/widget
  fn assemble_preset "$WORK/by-image.json" "$WORK/art/image-age.json" "$NOW"
  cp "$WORK/art/image-age.json" "$WORK/good.json"
  jq -n '{generatedAt: "2026-10-23T00:00:00Z", inventory: {failedRepos: [], images: {}}, rows: {}}' >"$WORK/art/image-age-data.json"
  : >"$WORK/art/report.txt"
}

@test "validate runs the pinned Renovate validator on the preset" {
  preset_in
  run fn main validate --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_NPX_LOG")" = "--yes --package renovate@$RENOVATE_PIN -- renovate-config-validator --strict --no-global $WORK/art/image-age.json | token= format= user= author=" ]
}

@test "validate stops when the validator rejects the preset" {
  preset_in
  FAKE_VALIDATOR_STATUS=1 run fn main validate --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"image-age.json"* ]]
}

@test "validate stops above 512 KB without running the validator" {
  preset_in
  head -c 524289 /dev/zero | tr '\0' ' ' >>"$WORK/art/image-age.json"
  run fn main validate --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"524"* ]]
  [ ! -s "$FAKE_NPX_LOG" ]
}

@test "validate stops on a preset that is not JSON" {
  preset_in
  echo '{' >"$WORK/art/image-age.json"
  run fn main validate --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"* ]]
}

@test "validate accepts a preset made of the rules render writes, for dated and held-back images" {
  preset_in
  by_image quay.io/acme/widget ghcr.io/acme/other
  jq --argjson d "$(fn disabling_rule quay.io/acme/held "$NOW" | jq -s .)" '. + {"quay.io/acme/held": $d}' "$WORK/by-image.json" >"$WORK/by.tmp"
  fn assemble_preset "$WORK/by.tmp" "$WORK/art/image-age.json" "$NOW"
  run fn main validate --in "$WORK/art"
  [ "$status" -eq 0 ]
}

@test "validate rejects a preset that strays from the shape render writes, without running the validator" {
  preset_in
  local filter
  while IFS= read -r filter; do
    jq "$filter" "$WORK/good.json" >"$WORK/art/image-age.json"
    run fn main validate --in "$WORK/art" </dev/null
    if [ "$status" -eq 0 ]; then
      echo "accepted: $filter" >&2
      false
    fi
    [[ "$output" == *"::error::"* ]]
  done <<'EOF'
.packageRules[0].matchDatasources = ["docker", "npm"]
.packageRules[0].extends = ["config:base"]
.packageRules[0].matchUpdateTypes = ["major"]
.packageRules[0].enabled = false
.packageRules[1].enabled = true
.packageRules[1].matchUpdateTypes = ["major"]
.packageRules[0].allowedVersions = "/^$/"
.packageRules[0].allowedVersions = "/.*/"
.packageRules[0].allowedVersions = "/^(a)$/ || true"
.packageRules[1].matchJsonata = ["true"]
.packageRules[1].matchJsonata[0] += " or true"
.packageRules[1].matchJsonata += ["true"]
.packageRules[2].matchDatasources = ["npm"]
.packageRules[2].enabled = true
.packageRules[3].matchJsonata = ["1 = 1"]
.packageRules[3].enabled = true
del(.packageRules[3])
del(.packageRules[2])
del(.packageRules[1])
.packageRules += [.packageRules[0]]
.packageRules += [.packageRules[1]]
.packageRules += [.packageRules[2]]
.packageRules[0].matchPackageNames = ["quay.io/acme/wid get"]
.packageRules[0].matchPackageNames = ["quay.io/acme/widget", "ghcr.io/other/thing"]
.packageRules += [{description: "x", matchDatasources: ["docker"], matchPackageNames: ["ghcr.io/evil/thing"], enabled: true}]
.packageRules += [{matchDatasources: ["docker"], matchPackageNames: ["ghcr.io/evil/thing"], enabled: false}]
.postUpgradeTasks = {}
.packageRules = {}
.packageRules[0].description = 1
EOF
  [ ! -s "$FAKE_NPX_LOG" ]
}

@test "validate stops on a data file that is not a JSON object with generatedAt, inventory and rows" {
  preset_in
  echo '[]' >"$WORK/art/image-age-data.json"
  run fn main validate --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"image-age-data.json"* ]]
  rm "$WORK/art/image-age-data.json"
  run fn main validate --in "$WORK/art"
  [ "$status" -ne 0 ]
}

# publish_env: the hashes that render hands to publish
publish_env() {
  PRESET_SHA256=$(sha256sum <"$WORK/art/image-age.json" | cut -d' ' -f1)
  DATA_SHA256=$(sha256sum <"$WORK/art/image-age-data.json" | cut -d' ' -f1)
  export PRESET_SHA256 DATA_SHA256
}

DATA="$GHCR/repos/anthony-spruyt/renovate-data"

@test "publish writes both files to main of the data repo, one contents call each, with no author or committer" {
  preset_in
  publish_env
  printf '{"sha":"abc123"}\n' >"$WORK/sha-data.json"
  printf '{"sha":"def456"}\n' >"$WORK/sha-preset.json"
  route GET "$DATA/contents/image-age-data.json?ref=main" 200 "$WORK/sha-data.json"
  route PUT "$DATA/contents/image-age-data.json" 200
  route GET "$DATA/contents/image-age.json?ref=main" 200 "$WORK/sha-preset.json"
  route PUT "$DATA/contents/image-age.json" 200
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_LOG")" = "$(printf 'GET %s/contents/image-age-data.json?ref=main auth=yes\nPUT %s/contents/image-age-data.json auth=yes\nGET %s/contents/image-age.json?ref=main auth=yes\nPUT %s/contents/image-age.json auth=yes' "$DATA" "$DATA" "$DATA" "$DATA")" ]
  jq -e '.branch == "main" and .sha == "abc123" and (.message | length) > 0 and (has("author") | not) and (has("committer") | not)' "$FAKE_LOG.body.2"
  jq -e '.branch == "main" and .sha == "def456" and (has("author") | not) and (has("committer") | not)' "$FAKE_LOG.body.4"
  [ "$(jq -r .content "$FAKE_LOG.body.2" | base64 -d)" = "$(cat "$WORK/art/image-age-data.json")" ]
  [ "$(jq -r .content "$FAKE_LOG.body.4" | base64 -d)" = "$(cat "$WORK/art/image-age.json")" ]
}

@test "publish creates a file that is not in the data repo yet, without a sha" {
  preset_in
  publish_env
  route GET "$DATA/contents/image-age-data.json?ref=main" 404
  route PUT "$DATA/contents/image-age-data.json" 201
  route GET "$DATA/contents/image-age.json?ref=main" 404
  route PUT "$DATA/contents/image-age.json" 201
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 0 ]
  jq -e '.branch == "main" and (has("sha") | not)' "$FAKE_LOG.body.2"
  jq -e '.branch == "main" and (has("sha") | not)' "$FAKE_LOG.body.4"
  run grep -q 'git/refs' "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "publish sends a file above 128 KiB through jq's standard input, not its argument list" {
  preset_in
  jq -n '{generatedAt: "2026-10-23T00:00:00Z", inventory: {failedRepos: [], images: {}}, rows: {}, filler: ([range(0; 6000) | "0123456789abcdef0123456789abcdef"] | join(","))}' >"$WORK/art/image-age-data.json"
  [ "$(wc -c <"$WORK/art/image-age-data.json")" -gt 196608 ]
  publish_env
  route GET "$DATA/contents/image-age-data.json?ref=main" 404
  route PUT "$DATA/contents/image-age-data.json" 201
  route GET "$DATA/contents/image-age.json?ref=main" 404
  route PUT "$DATA/contents/image-age.json" 201
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(jq -r .content "$FAKE_LOG.body.2" | base64 -d | sha256sum)" = "$(sha256sum <"$WORK/art/image-age-data.json")" ]
}

@test "publish refuses an artifact whose files do not hash to what render reported, before any API call" {
  preset_in
  publish_env
  printf '{"packageRules":[{"enabled":false}]}\n' >"$WORK/art/image-age.json"
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"image-age.json"* ]]
  [ ! -s "$FAKE_LOG" ]

  preset_in
  publish_env
  printf '{}\n' >"$WORK/art/image-age-data.json"
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"image-age-data.json"* ]]
  [ ! -s "$FAKE_LOG" ]
}

@test "publish refuses to run without the hashes from render" {
  preset_in
  publish_env
  unset PRESET_SHA256
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_LOG" ]
  publish_env
  unset DATA_SHA256
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [ ! -s "$FAKE_LOG" ]
}

@test "publish reports a refused write and an unreadable file" {
  preset_in
  publish_env
  printf '{"sha":"abc123"}\n' >"$WORK/sha.json"
  route GET "$DATA/contents/image-age-data.json?ref=main" 200 "$WORK/sha.json"
  route PUT "$DATA/contents/image-age-data.json" 409
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"409"* ]]

  : >"$FAKE_ROUTES"
  route GET "$DATA/contents/image-age-data.json?ref=main" 500
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"500"* ]]
}

@test "publish fails after writing when the report holds an error" {
  preset_in
  publish_env
  printf '::error::quay.io/acme/widget: registry answered 500\n' >"$WORK/art/report.txt"
  printf '{"sha":"abc123"}\n' >"$WORK/sha.json"
  route GET "$DATA/contents/image-age-data.json?ref=main" 200 "$WORK/sha.json"
  route PUT "$DATA/contents/image-age-data.json" 200
  route GET "$DATA/contents/image-age.json?ref=main" 200 "$WORK/sha.json"
  route PUT "$DATA/contents/image-age.json" 200
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 1 ]
  [ "$(grep -c '^PUT ' "$FAKE_LOG")" -eq 2 ]
  [[ "$output" == *"::error::"*"published"* ]]
}

@test "the script writes only through the contents API and runs no other copy of itself" {
  run grep -Eq 'git push|git/commits|git/trees|git/blobs|git/refs|git commit' "$SCRIPT"
  [ "$status" -ne 0 ]
  run grep -Eq 'cp "\$\{BASH_SOURCE' "$SCRIPT"
  [ "$status" -ne 0 ]
}

@test "the script runs curl in one place, which fails on HTTP errors and keeps square brackets in URLs literal" {
  [ "$(grep -c '^[^#]*[$(]curl ' "$SCRIPT")" -eq 1 ]
  grep -q "^  local args=(-q -sS --fail --globoff " "$SCRIPT"
}
