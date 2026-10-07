#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  STEP="${BATS_TEST_TMPDIR}/resolve.sh"
  yq -r '.jobs.discover-images.steps[] | select(.id == "discover") | .run' \
    "$REPO_ROOT/.github/workflows/_trivy-img.yaml" >"$STEP"
  export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
  : >"$GITHUB_OUTPUT"
  export GITHUB_REPOSITORY="anthony-spruyt/example"
  export GITHUB_REPOSITORY_OWNER="anthony-spruyt"
  STUB="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "$STUB"
  printf '#!/usr/bin/env bash\necho "$*" >"%s/gh-args"\nprintf "a\\nb\\n"\n' "$BATS_TEST_TMPDIR" >"$STUB/gh"
  chmod +x "$STUB/gh"
  export PATH="$STUB:$PATH"
}

resolve() {
  IMAGES_INPUT="$1" GH_TOKEN=token run bash -e "$STEP"
}

@test "declared images are scanned, sorted" {
  resolve '["web", "api"]'
  [ "$status" -eq 0 ]
  grep -qx 'images=\["api","web"\]' "$GITHUB_OUTPUT"
}

@test "declared images never call the GitHub API" {
  resolve '["web"]'
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/gh-args" ]
}

@test "fails on an empty input rather than scanning nothing" {
  resolve ''
  [ "$status" -ne 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/gh-args" ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "an empty declared list scans nothing" {
  resolve '[]'
  [ "$status" -eq 0 ]
  grep -qx 'images=\[\]' "$GITHUB_OUTPUT"
}

@test "duplicate names are scanned once" {
  resolve '["web","web"]'
  [ "$status" -eq 0 ]
  grep -qx 'images=\["web"\]' "$GITHUB_OUTPUT"
}

@test "nested package names are allowed" {
  resolve '["tools/web-ui"]'
  [ "$status" -eq 0 ]
  grep -qx 'images=\["tools/web-ui"\]' "$GITHUB_OUTPUT"
}

@test "rejects input that is not JSON" {
  resolve 'web'
  [ "$status" -ne 0 ]
  [ ! -s "$GITHUB_OUTPUT" ]
}

@test "rejects a JSON string instead of an array" {
  resolve '"web"'
  [ "$status" -ne 0 ]
}

@test "rejects uppercase names, which GHCR does not allow" {
  resolve '["SunGather"]'
  [ "$status" -ne 0 ]
}

@test "rejects names that could escape the image path" {
  for bad in '["../web"]' '["web:latest"]' '["web@sha256:00"]' '["a b"]' '["/web"]' '[""]' '[1]'; do
    : >"$GITHUB_OUTPUT"
    resolve "$bad"
    [ "$status" -ne 0 ] || {
      echo "accepted: $bad"
      return 1
    }
    [ ! -s "$GITHUB_OUTPUT" ]
  done
}

@test "rejects output injection through a newline" {
  resolve $'["web"]\nimages=["evil"]'
  [ "$status" -ne 0 ]
  run grep -c evil "$GITHUB_OUTPUT"
  [ "$output" = "0" ]
}
