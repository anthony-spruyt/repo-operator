#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  SCRIPT="$REPO_ROOT/.github/scripts/image-age.sh"
  FX="$REPO_ROOT/test/fixtures/image-age"
  WORK="$BATS_TEST_TMPDIR"
  NOW=1792713600
  mkdir -p "$WORK/bin" "$WORK/renovate"
  cp "$FX/fake-curl.sh" "$WORK/bin/curl"
  cp "$FX/fake-npx.sh" "$WORK/bin/npx"
  chmod +x "$WORK/bin/curl" "$WORK/bin/npx"
  export PATH="$WORK/bin:$PATH" TMPDIR="$WORK"
  export FAKE_ROUTES="$WORK/routes" FAKE_LOG="$WORK/curl.log" FAKE_NPX_LOG="$WORK/npx.log" FAKE_NPX_DIR="$WORK/renovate"
  : >"$FAKE_ROUTES"
  : >"$FAKE_LOG"
  : >"$FAKE_NPX_LOG"
  export IMAGE_AGE_NOW="$NOW" GITHUB_TOKEN=dummy-token-value GITHUB_REPOSITORY=anthony-spruyt/repo-operator
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

# ghcr_page <count> <tag prefix> <created_at>: a versions page of <count> single-tag versions
ghcr_page() {
  jq -n --argjson n "$1" --arg p "$2" --arg t "$3" \
    '[range(0; $n) | {name: "sha256:\(.)", created_at: $t, metadata: {container: {tags: ["\($p)\(.)"]}}}]'
}
old_ghcr_page() { ghcr_page "$1" "$2" 2026-09-01T00:00:00Z; }
young_ghcr_page() { ghcr_page "$1" "$2" 2026-10-22T00:00:00Z; }

GHCR=https://api.github.com
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

@test "fetch_rows stops at the first ghcr page that already holds 50 old tags" {
  old_ghcr_page 60 t >"$WORK/p1.json"
  route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100" 200 "$WORK/p1.json" "$NEXT"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 1 ]
  [ "$(wc -l <"$WORK/rows")" -eq 60 ]
}

@test "fetch_rows counts only tags that are old enough, not cosign signatures" {
  local sigs=() i
  for i in $(seq 1 60); do sigs+=("$(printf 'sha256-%064d.sig' "$i")"); done
  jq -n '[$ARGS.positional | to_entries[] | {name: "sha256:\(.key)", created_at: "2026-09-01T00:00:00Z", metadata: {container: {tags: [.value]}}}]' \
    --args "${sigs[@]}" >"$WORK/p1.json"
  route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100" 200 "$WORK/p1.json" "$NEXT"
  old_ghcr_page 60 t >"$WORK/p2.json"
  route GET "$GHCR/user/1/packages/container/widget/versions?per_page=100&page=2" 200 "$WORK/p2.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 2 ]
}

@test "fetch_rows keeps the newest build of a tag that shows up twice" {
  jq -n '[{name: "sha256:old", created_at: "2026-08-01T00:00:00Z", metadata: {container: {tags: ["1.0"]}}},
          {name: "sha256:new", created_at: "2026-09-01T00:00:00Z", metadata: {container: {tags: ["1.0", "1"]}}}]' >"$WORK/p1.json"
  route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100" 200 "$WORK/p1.json"
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -eq 0 ]
  [ "$(cat "$WORK/rows")" = "$(printf '1.0\tsha256:new\t1788220800\n1\tsha256:new\t1788220800')" ]
}

@test "fetch_rows never sends the token to a next link outside api.github.com" {
  young_ghcr_page 3 t >"$WORK/p1.json"
  route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100" 200 "$WORK/p1.json" 'Link: <https://registry.example.com/next>; rel="next"'
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"ghcr.io/acme/widget"* ]]
  [ "$(wc -l <"$FAKE_LOG")" -eq 1 ]
}

@test "fetch_rows gives up with an error after 20 pages when the tags stay too young" {
  young_ghcr_page 3 t >"$WORK/young.json"
  for n in $(seq 1 25); do
    route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$n" 200 "$WORK/young.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=$((n + 1))>; rel=\"next\""
  done
  route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100" 200 "$WORK/young.json" "Link: <$GHCR/users/acme/packages/container/widget/versions?per_page=100&page=1>; rel=\"next\""
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"ghcr.io/acme/widget"*"20 pages"* ]]
  [ "$(wc -l <"$FAKE_LOG")" -eq 20 ]
}

@test "fetch_rows reports the registry status when a page fails" {
  route GET "$GHCR/users/acme/packages/container/widget/versions?per_page=100" 403
  run fn fetch_rows ghcr.io/acme/widget "$WORK/rows"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"ghcr.io/acme/widget"*"403"* ]]
}

@test "fetch_rows pages quay by page number without a token" {
  jq '.has_additional = true' "$FX/quay-tags.json" >"$WORK/q1.json"
  jq -n '{tags: [range(0; 60) | {name: "v\(.)", start_ts: 1700000000, end_ts: null, manifest_digest: "sha256:\(.)"}], has_additional: false}' >"$WORK/q2.json"
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

@test "allowed_regex escapes every regex character in a tag" {
  run fn allowed_regex 1.2.3 'v1.0.0+b' 'a-b' '2.0_x' 'x(1)|[y]'
  [ "$status" -eq 0 ]
  [ "$output" = '/^(1\.2\.3|v1\.0\.0\+b|a-b|2\.0_x|x\(1\)\|\[y\])$/' ]
}

@test "allowed_regex with no tags matches nothing" {
  run fn allowed_regex
  [ "$output" = '/^$/' ]
}

@test "image_rules gives one allowedVersions rule and one digest rule per image" {
  printf 'v0.15.1\t%s\nv0.14.0\t%s\n' "$(digest c)" "$(digest e)" >"$WORK/sel"
  run fn image_rules quay.io/acme/widget "$WORK/sel" "$NOW"
  [ "$status" -eq 0 ]
  [ "$(jq length <<<"$output")" -eq 2 ]
  jq -e '.[0] | .matchDatasources == ["docker"] and .matchPackageNames == ["quay.io/acme/widget"]
    and .allowedVersions == "/^(v0\\.15\\.1|v0\\.14\\.0)$/"
    and (.description | contains("quay.io/acme/widget") and contains("2026-10-23T00:00:00Z"))
    and (has("enabled") | not)' <<<"$output"
  map="{\"v0.14.0\":\"$(digest e)\",\"v0.15.1\":\"$(digest c)\"}"
  expr="\$exists(newDigest) and (\$exists(\$lookup($map, newValue)) ? \$lookup($map, newValue) != newDigest : true)"
  jq -e --arg expr "$expr" '.[1] | .matchDatasources == ["docker"] and .matchPackageNames == ["quay.io/acme/widget"]
    and .matchUpdateTypes == ["major", "minor", "patch", "digest"] and .enabled == false and .matchJsonata == [$expr]
    and (.description | contains("quay.io/acme/widget") and contains("2026-10-23T00:00:00Z"))' <<<"$output"
}

# jsonata_true <expression> <json input>: the Renovate matchJsonata verdict for one set of fields
jsonata_true() {
  node -e '
    const jsonata = require("jsonata");
    jsonata(process.argv[1]).evaluate(JSON.parse(process.argv[2])).then((r) => console.log(r === true ? "true" : "false"));
  ' "$1" "$2"
}

digest_rule_expr() {
  printf 'v0.15.1\t%s\nv0.14.0\t%s\n' "$(digest c)" "$(digest e)" >"$WORK/sel"
  fn image_rules quay.io/acme/widget "$WORK/sel" "$NOW" | jq -r '.[1].matchJsonata[0]'
}

@test "the digest rule holds back a young or unknown build and lets a dated one through" {
  node -e 'require("jsonata")' 2>/dev/null || skip "the jsonata package is not installed"
  expr=$(digest_rule_expr)
  [ "$(jsonata_true "$expr" '{"depName":"quay.io/acme/widget","currentValue":"v0.15.1"}')" = false ]
  [ "$(jsonata_true "$expr" '{"newValue":"v0.16.0"}')" = false ]
  [ "$(jsonata_true "$expr" "{\"newValue\":\"v0.15.1\",\"newDigest\":\"$(digest c)\"}")" = false ]
  [ "$(jsonata_true "$expr" "{\"newValue\":\"v0.15.1\",\"newDigest\":\"$(digest f)\"}")" = true ]
  [ "$(jsonata_true "$expr" "{\"newValue\":\"v0.16.0\",\"newDigest\":\"$(digest f)\"}")" = true ]
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
  node -e 'require("jsonata")' 2>/dev/null || skip "the jsonata package is not installed"
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

@test "extract runs the pinned Renovate once per public repo with the token, JSON logs and no write access" {
  use_renovate_logs
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_NPX_LOG")" = "$(printf '%s\n' \
    '--yes renovate@44.178.3 --dry-run=extract --platform=github anthony-spruyt/blog | token=set format=json' \
    '--yes renovate@44.178.3 --dry-run=extract --platform=github anthony-spruyt/SunGather | token=set format=json' \
    '--yes renovate@44.178.3 --dry-run=extract --platform=github anthony-spruyt/spruyt-labs | token=set format=json')" ]
  run grep -q dummy-token-value <<<"$output"
  [ "$status" -ne 0 ]
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

@test "extract treats a log that never reached the end of the run as a failure" {
  use_renovate_logs
  head -1 "$FX/renovate-blog.log" >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
}

@test "extract treats a log it cannot read as a failure, not as an empty repo" {
  use_renovate_logs
  printf '%s\n' '{"msg":"Extracted dependencies","packageFiles":"odd"}' '{"msg":"Repository finished"}' >"$FAKE_NPX_DIR/anthony-spruyt__blog.log"
  run fn main extract --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(jq -c '.failedRepos' "$WORK/out/inventory.json")" = '["anthony-spruyt/blog"]' ]
  [[ "$output" == *"::error::"*"anthony-spruyt/blog"* ]]
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

PREV="$GHCR/repos/anthony-spruyt/repo-operator/contents/image-age.json?ref=renovate-data"

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

# contents_body <file>: the contents API answer for a file
contents_body() { jq -n --arg c "$(base64 -w0 "$1")" '{sha: "abc123", encoding: "base64", content: $c}'; }

@test "render dates each image at its registry and writes the preset, the report and the script" {
  widget_inventory "$(digest c)"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  jq -e '.packageRules[0].allowedVersions == "/^(v0\\.15\\.1|v0\\.14\\.0)$/" and (.packageRules | length) == 4' "$WORK/out/image-age.json"
  [ -f "$WORK/out/report.txt" ]
  [ -x "$WORK/out/image-age.sh" ]
  [[ "$output" != *"::"* ]]
  grep -q 'quay.io.* auth=no' "$FAKE_LOG"
  grep -q 'contents/image-age.json?ref=renovate-data auth=yes' "$FAKE_LOG"
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

@test "render warns when a repo pins a digest the registry does not list for that tag" {
  widget_inventory "$(digest f)"
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::warning::anthony-spruyt/blog pins quay.io/acme/widget:v0.15.1"* ]]
  grep -q '^::warning::' "$WORK/out/report.txt"
}

@test "render keeps an image's previous rules and reports an error when its registry fails" {
  widget_inventory "$(digest c)"
  by_image quay.io/acme/widget
  fn assemble_preset "$WORK/by-image.json" "$WORK/previous.json" $((NOW - 3600))
  contents_body "$WORK/previous.json" >"$WORK/previous-contents.json"
  route GET "$PREV" 200 "$WORK/previous-contents.json"
  route_quay 500
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::quay.io/acme/widget: registry answered 500"* ]]
  [ "$(jq -c '[.packageRules[] | select(.matchPackageNames == ["quay.io/acme/widget"])]' "$WORK/out/image-age.json")" = "$(jq -c '[.packageRules[] | select(.matchPackageNames == ["quay.io/acme/widget"])]' "$WORK/previous.json")" ]
  grep -q '^::error::quay.io/acme/widget' "$WORK/out/report.txt"
}

@test "render holds back an image whose registry fails when there are no previous rules" {
  widget_inventory "$(digest c)"
  route_quay 500
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [[ "$output" == *"::error::quay.io/acme/widget: registry answered 500"* ]]
  jq -e '.packageRules[0] | .enabled == false and .matchPackageNames == ["quay.io/acme/widget"] and (has("allowedVersions") | not) and (has("matchUpdateTypes") | not)' "$WORK/out/image-age.json"
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

@test "render carries over the previous rules of images it could not list only when a repo failed to extract" {
  by_image ghcr.io/acme/gone
  fn assemble_preset "$WORK/by-image.json" "$WORK/previous.json" $((NOW - 3600))
  contents_body "$WORK/previous.json" >"$WORK/previous-contents.json"
  route GET "$PREV" 200 "$WORK/previous-contents.json"
  route_rest

  inventory '{"failedRepos":["anthony-spruyt/SunGather"],"images":{}}'
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  jq -e '[.packageRules[] | select(.matchPackageNames == ["ghcr.io/acme/gone"])] | length == 2' "$WORK/out/image-age.json"
  jq -e '.packageRules[-2].matchPackageNames | index("!ghcr.io/acme/gone") != null' "$WORK/out/image-age.json"

  inventory '{"failedRepos":[],"images":{}}'
  run fn main render --in "$WORK/in" --out "$WORK/out2"
  [ "$status" -eq 0 ]
  jq -e '[.packageRules[] | select(.matchPackageNames == ["ghcr.io/acme/gone"])] | length == 0' "$WORK/out2/image-age.json"
}

@test "render stops without a preset when the previous data cannot be read" {
  widget_inventory "$(digest c)"
  route GET "$PREV" 500
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"500"* ]]
  [ ! -e "$WORK/out/image-age.json" ]
}

@test "render flags overrides that set allowedVersions or enabled for a registry image it dates" {
  inventory '{"failedRepos":[],"images":{"quay.io/acme/widget":{"tags":["v0.15.1"],"pins":[]},"ghcr.io/acme/litellm":{"tags":["v1"],"pins":[]}}}'
  cat >"$WORK/overrides.json5" <<'JSON5'
{
  packageRules: [
    // a mistyped upstream tag
    { matchPackageNames: ["quay.io/acme/widget"], allowedVersions: "!/^v?1\\.0$/" },
    { matchDepNames: ["ghcr.io/acme/litellm"], enabled: false },
    { matchPackageNames: ["docker.io/other/thing"], allowedVersions: "<2" },
    { matchPackageNames: ["quay.io/acme/widget"], schedule: ["at any time"] }
  ]
}
JSON5
  contents_body "$WORK/overrides.json5" >"$WORK/overrides-contents.json"
  route GET "$GHCR/repos/anthony-spruyt/spruyt-labs/contents/renovate-overrides.json5" 200 "$WORK/overrides-contents.json"
  route_quay 200 "$FX/quay-tags.json"
  route GET "$GHCR/users/acme/packages/container/litellm/versions?per_page=100" 200 "$FX/ghcr-versions.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^::error::anthony-spruyt/spruyt-labs renovate-overrides.json5' <<<"$output")" -eq 2 ]
  [[ "$output" == *"::error::anthony-spruyt/spruyt-labs renovate-overrides.json5 sets allowedVersions for quay.io/acme/widget"* ]]
  [[ "$output" == *"::error::anthony-spruyt/spruyt-labs renovate-overrides.json5 sets enabled for ghcr.io/acme/litellm"* ]]
  [ -f "$WORK/out/image-age.json" ]
}

@test "render reports overrides it cannot read" {
  widget_inventory "$(digest c)"
  route GET "$GHCR/repos/anthony-spruyt/blog/contents/renovate-overrides.json5" 500
  route_quay 200 "$FX/quay-tags.json"
  route_rest
  run fn main render --in "$WORK/in" --out "$WORK/out"
  [[ "$output" == *"::error::anthony-spruyt/blog renovate-overrides.json5 answered 500"* ]]
}

# preset_in: a rendered artifact directory
preset_in() {
  mkdir -p "$WORK/art"
  printf '{"packageRules":[]}\n' >"$WORK/art/image-age.json"
  : >"$WORK/art/report.txt"
}

@test "validate runs the pinned Renovate validator on the preset" {
  preset_in
  run fn main validate --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_NPX_LOG")" = "--yes --package renovate@44.178.3 -- renovate-config-validator --strict --no-global $WORK/art/image-age.json | token= format=" ]
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

@test "the copy of the script in the artifact validates from a directory outside the checkout" {
  preset_in
  cp "$SCRIPT" "$WORK/art/image-age.sh"
  run bash "$WORK/art/image-age.sh" validate --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_NPX_LOG")" = "--yes --package renovate@44.178.3 -- renovate-config-validator --strict --no-global $WORK/art/image-age.json | token= format=" ]
}

DATA="$GHCR/repos/anthony-spruyt/repo-operator"

@test "publish updates image-age.json on the data branch with one contents call that carries no author or committer" {
  preset_in
  printf '{"sha":"abc123"}\n' >"$WORK/sha.json"
  route GET "$DATA/contents/image-age.json?ref=renovate-data" 200 "$WORK/sha.json"
  route PUT "$DATA/contents/image-age.json" 200
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(cat "$FAKE_LOG")" = "$(printf 'GET %s/contents/image-age.json?ref=renovate-data auth=yes\nPUT %s/contents/image-age.json auth=yes' "$DATA" "$DATA")" ]
  jq -e '.branch == "renovate-data" and .sha == "abc123" and (.message | length) > 0 and (has("author") | not) and (has("committer") | not)' "$FAKE_LOG.body.2"
  [ "$(jq -r .content "$FAKE_LOG.body.2" | base64 -d)" = "$(cat "$WORK/art/image-age.json")" ]
}

@test "publish creates the data branch from main on the first run and then writes the file" {
  preset_in
  printf '{"object":{"sha":"mainsha"}}\n' >"$WORK/main-ref.json"
  route GET "$DATA/contents/image-age.json?ref=renovate-data" 404
  route GET "$DATA/git/ref/heads/renovate-data" 404
  route GET "$DATA/git/ref/heads/main" 200 "$WORK/main-ref.json"
  route POST "$DATA/git/refs" 201
  route PUT "$DATA/contents/image-age.json" 201
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(cut -d' ' -f1,2 "$FAKE_LOG" | sed "s#$DATA##" | paste -sd'|')" = "GET /contents/image-age.json?ref=renovate-data|GET /git/ref/heads/renovate-data|GET /git/ref/heads/main|POST /git/refs|PUT /contents/image-age.json" ]
  jq -e '.ref == "refs/heads/renovate-data" and .sha == "mainsha"' "$FAKE_LOG.body.4"
  jq -e '.branch == "renovate-data" and (has("sha") | not)' "$FAKE_LOG.body.5"
}

@test "publish writes the file when the data branch exists without it" {
  preset_in
  route GET "$DATA/contents/image-age.json?ref=renovate-data" 404
  route GET "$DATA/git/ref/heads/renovate-data" 200
  route PUT "$DATA/contents/image-age.json" 201
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$FAKE_LOG")" -eq 3 ]
  run grep -q POST "$FAKE_LOG"
  [ "$status" -ne 0 ]
}

@test "publish reports a refused write" {
  preset_in
  route GET "$DATA/contents/image-age.json?ref=renovate-data" 200 "$WORK/sha.json"
  printf '{"sha":"abc123"}\n' >"$WORK/sha.json"
  route PUT "$DATA/contents/image-age.json" 409
  run fn main publish --in "$WORK/art"
  [ "$status" -ne 0 ]
  [[ "$output" == *"::error::"*"409"* ]]
}

@test "publish fails after writing when the report holds an error" {
  preset_in
  printf '::error::quay.io/acme/widget: registry answered 500\n' >"$WORK/art/report.txt"
  printf '{"sha":"abc123"}\n' >"$WORK/sha.json"
  route GET "$DATA/contents/image-age.json?ref=renovate-data" 200 "$WORK/sha.json"
  route PUT "$DATA/contents/image-age.json" 200
  run fn main publish --in "$WORK/art"
  [ "$status" -eq 1 ]
  grep -q '^PUT ' "$FAKE_LOG"
  [[ "$output" == *"::error::"*"published"* ]]
}

@test "the script commits only through the contents API" {
  run grep -Eq 'git push|git/commits|git/trees|git/blobs|git commit' "$SCRIPT"
  [ "$status" -ne 0 ]
}
