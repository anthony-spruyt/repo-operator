#!/usr/bin/env bash
set -uo pipefail

# This file is automatically updated - do not modify directly

# Devcontainer setup verification tests

PASSED=0
FAILED=0

pass() {
  echo "✓ $1"
  PASSED=$((PASSED + 1))
}

fail() {
  echo "✗ $1"
  FAILED=$((FAILED + 1))
}

echo "Running devcontainer verification tests..."
echo ""

# 1. Docker-in-Docker
if docker run --rm hello-world &>/dev/null; then
  pass "Docker-in-Docker is working"
else
  fail "Docker-in-Docker is not working"
fi

# 2. Pre-commit hooks installed
if pre-commit run --all-files &>/dev/null; then
  pass "Pre-commit hooks pass"
else
  fail "Pre-commit hooks failed"
fi

# 3. Safe-chain blocks malicious packages
SAFE_NPM="$HOME/.safe-chain/shims/npm"
if [[ -x "$SAFE_NPM" ]]; then
  TEMP_DIR=$(mktemp -d)
  SAFE_OUTPUT=$(cd "$TEMP_DIR" && "$SAFE_NPM" install safe-chain-test 2>&1 || true)
  rm -rf "$TEMP_DIR"
  if echo "$SAFE_OUTPUT" | grep -qi "safe-chain"; then
    pass "Safe-chain is blocking malicious packages"
  else
    fail "Safe-chain is not blocking (check output: $SAFE_OUTPUT)"
  fi
else
  fail "Safe-chain shims not found at $SAFE_NPM"
fi

# 4. GitHub CLI available
if command -v gh &>/dev/null; then
  pass "GitHub CLI is installed"
else
  fail "GitHub CLI is not installed"
fi

# 5. SSH agent forwarding
# shellcheck disable=SC2157 # xfg template syntax $${} appears as literal to shellcheck
if [[ -n "${SSH_AUTH_SOCK:-}" ]] && ssh-add -l &>/dev/null 2>&1; then
  pass "SSH agent has keys loaded"
else
  fail "SSH agent not available or no keys loaded"
fi

# 6. Claude Code CLI available
if command -v claude &>/dev/null; then
  pass "Claude Code CLI is installed"
else
  fail "Claude Code CLI is not installed"
fi

echo ""
echo "Results: $PASSED passed, $FAILED failed"

if [[ $FAILED -eq 0 ]]; then
  exit 0
else
  exit 1
fi
