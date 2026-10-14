#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  BASE="$REPO_ROOT/src/templates/.mega-linter-base.yml"
}

@test "shellcheck and shfmt lint .bats files on top of MegaLinter's default bash extensions" {
  local linter
  for linter in BASH_SHELLCHECK BASH_SHFMT; do
    run yq -o=json -I0 ".${linter}_FILE_EXTENSIONS" "$BASE"
    echo "$linter: $output"
    [ "$output" = '[".sh",".bash",".dash",".ksh",".bats"]' ]
  done
}
