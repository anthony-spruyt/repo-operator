#!/bin/bash
set -euo pipefail

# This file is automatically updated - do not modify directly

# Make all shell scripts executable (runs from repo root via postCreateCommand)
find . -type f -name '*.sh' -exec chmod +x {} +

# Change to script directory for package.json access
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Install and setup safe-chain FIRST before any other npm installs
echo "Installing safe-chain..."
npm install -g "@aikidosec/safe-chain@$(node -p "require('./package.json').dependencies['@aikidosec/safe-chain']")"

echo "Setting up safe-chain..."
safe-chain setup    # Shell aliases for interactive terminals
safe-chain setup-ci # Executable shims for scripts/CI

# Add safe-chain shims to PATH for all subsequent commands
# This ensures pre-commit and other tools use protected pip/npm
export PATH="$HOME/.safe-chain/shims:$PATH"

echo "Installing pre-commit hooks..."
pre-commit install --install-hooks

echo "Installing Claude Code CLI..."
curl -fsSL https://claude.ai/install.sh | bash

echo ""
echo "Running setup verification..."
"$SCRIPT_DIR/verify-setup.sh"
