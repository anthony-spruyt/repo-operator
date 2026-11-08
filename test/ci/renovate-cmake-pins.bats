#!/usr/bin/env bats
# shellcheck disable=SC2016

# Renovate has no CMake manager, so the annotated custom.regex managers read FetchContent and ExternalProject GIT_TAG pins.
# The matchStrings avoid lookahead, so RE2 (Renovate) and JavaScript regexes agree on them.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  ANNOTATED="$REPO_ROOT/.github/renovate/custom-managers/annotated.json5"
  # yq reads json5 as YAML flow style once the full-line comments are gone
  MANAGERS="$(sed '/^[[:space:]]*\/\//d' "$ANNOTATED" | yq -p yaml -o json -I0 '[.customManagers[] | select(.description[0] | test("CMake"))]')"
}

# Prints what the CMake managers capture from stdin, one object per matched dependency
captures() {
  node -e '
    const managers = JSON.parse(process.argv[1]);
    const text = require("fs").readFileSync(0, "utf8");
    const found = [];
    for (const manager of managers) {
      for (const matchString of manager.matchStrings) {
        for (const hit of text.matchAll(new RegExp(matchString, "g"))) found.push(hit.groups);
      }
    }
    console.log(JSON.stringify(found));
  ' "$MANAGERS" | jq -c 'sort_by(.depName) | map({depName, datasource, versioning, currentDigest, currentValue})'
}

@test "a sha-pinned GIT_TAG yields the tag in its comment as the version and the sha as the digest, in either annotation order" {
  run captures <<'EOF'
FetchContent_Declare(
    widget
    GIT_REPOSITORY https://github.com/example/widget.git
    # renovate: depName=example/widget datasource=github-tags
    GIT_TAG 0123456789abcdef0123456789abcdef01234567 # v1.2.3, prose after the tag stays out of the version
)
ExternalProject_Add(
    gadget
    # renovate: datasource=github-tags depName=example/gadget versioning=loose
    GIT_TAG fedcba9876543210fedcba9876543210fedcba98 # 2.0.1
)
EOF
  [ "$status" -eq 0 ]
  [ "$output" = '[{"depName":"example/gadget","datasource":"github-tags","versioning":"loose","currentDigest":"fedcba9876543210fedcba9876543210fedcba98","currentValue":"2.0.1"},{"depName":"example/widget","datasource":"github-tags","versioning":null,"currentDigest":"0123456789abcdef0123456789abcdef01234567","currentValue":"v1.2.3"}]' ]
}

@test "a tag-only GIT_TAG yields the tag with no digest" {
  run captures <<'EOF'
FetchContent_Declare(
    widget
    # renovate: depName=example/widget datasource=github-tags
    GIT_TAG v1.2.3
)
EOF
  [ "$status" -eq 0 ]
  [ "$output" = '[{"depName":"example/widget","datasource":"github-tags","versioning":null,"currentDigest":null,"currentValue":"v1.2.3"}]' ]
}

@test "a sha with no tag comment yields nothing, so a commit is never looked up as a version" {
  run captures <<'EOF'
FetchContent_Declare(
    widget
    # renovate: depName=example/widget datasource=github-tags
    GIT_TAG 0123456789abcdef0123456789abcdef01234567
)
EOF
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "a GIT_TAG without a renovate annotation yields nothing" {
  run captures <<'EOF'
FetchContent_Declare(
    widget
    GIT_REPOSITORY https://github.com/example/widget.git
    GIT_TAG 0123456789abcdef0123456789abcdef01234567 # v1.2.3
)
EOF
  [ "$status" -eq 0 ]
  [ "$output" = '[]' ]
}

@test "the CMake managers read CMakeLists.txt and .cmake files at any depth and nothing else" {
  run node -e '
    const patterns = JSON.parse(process.argv[1]).flatMap((manager) => manager.managerFilePatterns);
    const hits = (file) => patterns.some((pattern) => new RegExp(pattern.slice(1, -1)).test(file));
    const read = ["CMakeLists.txt", "tools/compat/CMakeLists.txt", "cmake/zydis.cmake", "top.cmake"].filter(hits);
    const skipped = ["docs/cmake.md", "CMakeLists.txt.bak", "cmake/zydis.cmake.in", "NotCMakeLists.txt", "src/main.cpp"].filter(hits);
    console.log(JSON.stringify({ patterns: patterns.length > 0, read, skipped }));
  ' "$MANAGERS"
  [ "$status" -eq 0 ]
  [ "$output" = '{"patterns":true,"read":["CMakeLists.txt","tools/compat/CMakeLists.txt","cmake/zydis.cmake","top.cmake"],"skipped":[]}' ]
}
