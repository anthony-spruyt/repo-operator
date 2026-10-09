#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/check-xfg-config.sh"
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  CFG="${BATS_TEST_TMPDIR}/src"
  mkdir -p "$CFG"
  printf 'id: test\n' >"$CFG/base.yaml"
  printf 'repos:\n  - git: https://github.com/anthony-spruyt/xfg.git\n' >"$CFG/repos.yaml"
}

@test "passes on the repo's own src/ config" {
  run "$SCRIPT" "$REPO_ROOT/src"
  [ "$status" -eq 0 ]
}

@test "passes on a minimal config" {
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "fails when the config directory is missing" {
  run "$SCRIPT" "$CFG/nope"
  [ "$status" -ne 0 ]
}

@test "allows githubHosts listing only github.com" {
  printf 'githubHosts:\n  - github.com\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "rejects a githubHosts entry other than github.com" {
  printf 'githubHosts:\n  - github.com\n  - attacker.example\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"attacker.example"* ]]
}

@test "rejects githubHosts that is not a list" {
  printf 'githubHosts: attacker.example\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects githubHosts in a nested fragment" {
  mkdir -p "$CFG/more/deep"
  printf 'githubHosts: [attacker.example]\n' >"$CFG/more/deep/hosts.yml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects githubHosts with an uppercase .YAML extension" {
  printf 'githubHosts: [attacker.example]\n' >"$CFG/hosts.YAML"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects githubHosts reached through an alias" {
  printf 'x-hosts: &h [attacker.example]\ngithubHosts: *h\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects githubHosts in a second YAML document" {
  printf -- '---\ngithubHosts: [attacker.example]\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects duplicate keys" {
  printf 'id: other\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects a file that is not valid YAML" {
  printf 'repos: [\n' >"$CFG/broken.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects symlinks" {
  ln -s /etc/hostname "$CFG/link.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects a repo on another host" {
  printf '  - git: https://attacker.example/anthony-spruyt/x.git\n' >>"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"attacker.example"* ]]
}

@test "rejects a repo under another owner" {
  printf '  - git: https://github.com/someone-else/x.git\n' >>"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects one bad URL in a git list" {
  printf '  - git:\n      - https://github.com/anthony-spruyt/a.git\n      - https://attacker.example/b/c.git\n' >>"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects SSH, http and mixed-case host URLs" {
  for url in git@attacker.example:anthony-spruyt/x.git http://github.com/anthony-spruyt/x https://GitHub.com/anthony-spruyt/x; do
    printf 'repos:\n  - git: %s\n' "$url" >"$CFG/repos.yaml"
    run "$SCRIPT" "$CFG"
    [ "$status" -eq 1 ]
  done
}

@test "rejects a URL with a trailing second line" {
  printf 'repos:\n  - git: "https://github.com/anthony-spruyt/x\\nhttps://attacker.example/a/b"\n' >"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects a repo entry with no git URL" {
  printf '  - groups: [x]\n' >>"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "allows an upstream fork from another owner on github.com" {
  printf '    upstream: https://github.com/someone-else/x\n' >>"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "rejects upstream or source off github.com" {
  for key in upstream source; do
    printf 'repos:\n  - git: https://github.com/anthony-spruyt/x\n    %s: https://attacker.example/a/b\n' "$key" >"$CFG/repos.yaml"
    run "$SCRIPT" "$CFG"
    [ "$status" -eq 1 ]
  done
}

@test "ignores repos lists in dot-directory templates" {
  mkdir -p "$CFG/templates"
  printf 'repos:\n  - repo: https://github.com/pre-commit/pre-commit-hooks\n' >"$CFG/templates/.pre-commit-config.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "rejects an env var reference in YAML file content" {
  printf 'files:\n  a.txt:\n    content: "${XFG_GITHUB_APP_PRIVATE_KEY}"\n' >"$CFG/files.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"XFG_GITHUB_APP_PRIVATE_KEY"* ]]
}

@test "rejects an env var reference with a default in a template" {
  mkdir -p "$CFG/templates/.github"
  printf 'key: ${APP_KEY:-none}\n' >"$CFG/templates/.github/a.txt"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects an env var reference built from a YAML escape" {
  printf 'files:\n  a.txt:\n    content: "\\x24{XFG_GITHUB_APP_PRIVATE_KEY}"\n' >"$CFG/files.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects an env var reference built from a JSON escape" {
  mkdir -p "$CFG/templates"
  printf '{"a": "\\u0024{XFG_GITHUB_APP_PRIVATE_KEY}"}\n' >"$CFG/templates/a.json"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects an env var reference split by a line continuation" {
  printf 'files:\n  a.txt:\n    content: "$\\\n      {XFG_GITHUB_APP_PRIVATE_KEY}"\n' >"$CFG/files.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "allows escaped env syntax and xfg template variables" {
  mkdir -p "$CFG/templates"
  printf 'echo "$${HOME} ${xfg:repo.name} $$${PATH}"\n' >"$CFG/templates/a.sh"
  printf 'files:\n  a.txt:\n    content: "$${CI} ${xfg:repo.owner}"\n' >"$CFG/files.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "allows secrets sourced from the env Apply passes" {
  printf 'settings:\n  secrets:\n    DOCKERHUB_TOKEN:\n      env: DOCKERHUB_TOKEN\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "rejects a secret sourced from the App key env" {
  printf 'groups:\n  g:\n    settings:\n      secrets:\n        LEAK:\n          env: XFG_GITHUB_APP_PRIVATE_KEY\n' >"$CFG/groups.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *"XFG_GITHUB_APP_PRIVATE_KEY"* ]]
}

@test "rejects an AI key env other than OPENROUTER_API_KEY" {
  printf 'prOptions:\n  ai:\n    apiKeyEnv: XFG_GITHUB_APP_PRIVATE_KEY\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "rejects an AI base URL other than OpenRouter" {
  printf 'prOptions:\n  ai:\n    baseUrl: https://attacker.example/v1\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "allows the OpenRouter AI config" {
  printf 'prOptions:\n  ai:\n    provider: openai\n    baseUrl: https://openrouter.ai/api/v1\n    apiKeyEnv: OPENROUTER_API_KEY\n' >>"$CFG/base.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "rejects escapes that could build an env var reference in JSON5" {
  mkdir -p "$CFG/templates"
  printf '{a: "\\x24{XFG_GITHUB_APP_PRIVATE_KEY}"}\n' >"$CFG/templates/a.json5"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
}

@test "allows escaped backslashes in JSON5" {
  mkdir -p "$CFG/templates"
  printf '{a: "C:\\\\x"}\n' >"$CFG/templates/a.json5"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}

@test "rejects a file path with a .git segment" {
  for path in .git .git/config .git/hooks/pre-commit foo/.git/config ./.git/config .GIT/config foo/.Git; do
    printf 'files:\n  "%s":\n    content: x\n' "$path" >"$CFG/files.yaml"
    run "$SCRIPT" "$CFG"
    [ "$status" -eq 1 ]
    [[ "$output" == *".git segment"* ]]
  done
}

@test "rejects a .git file path in a group, conditional group or repo" {
  printf 'groups:\n  g:\n    files:\n      .git/config:\n        content: x\n' >"$CFG/groups.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *".git segment"* ]]
  printf 'conditionalGroups:\n  - when: {allOf: [g]}\n    files:\n      .git/config:\n        content: x\n' >"$CFG/groups.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *".git segment"* ]]
  rm "$CFG/groups.yaml"
  printf '    files:\n      .git/hooks/post-checkout:\n        content: x\n' >>"$CFG/repos.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 1 ]
  [[ "$output" == *".git segment"* ]]
}

@test "allows .github, .gitignore and .gitattributes file paths" {
  printf 'files:\n  .github/workflows/ci.yaml:\n    content: x\n  .gitignore:\n    content: x\n  sub/.gitattributes:\n    content: x\n  foo.git/a:\n    content: x\n' >"$CFG/files.yaml"
  run "$SCRIPT" "$CFG"
  [ "$status" -eq 0 ]
}
