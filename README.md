# repo-operator

[![CI](https://github.com/anthony-spruyt/repo-operator/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/anthony-spruyt/repo-operator/actions/workflows/ci.yaml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A GitHub Repository Operator that manages and standardizes configuration across multiple repositories.

## What It Does

- Syncs standardized configuration files (linting, CI/CD, devcontainer, editor settings) to target repositories
- Includes security scanning templates (Trivy vulnerability scanner)
- Creates PRs automatically when templates are updated
- Auto-merges PRs when all checks pass
- Future: Create and fully configure new repositories

## How It Works

This operator uses [xfg](https://github.com/anthony-spruyt/xfg) to sync template files to target repositories.

1. Templates are defined in `src/templates/`
2. Target repositories and file mappings are configured in `src/config.yaml`
3. CI runs on push to main, creating PRs in target repos with updated configs

## Adding a Repository

Edit `src/config.yaml`:

```yaml
repos:
  - git: https://github.com/your-org/your-repo.git
    files:
      # Optional: disable or override specific files for this repo
      .github/workflows/dependabot-automerge.yaml: false
```

## Local Development

```bash
# Run linting locally (requires Docker)
./lint.sh

# Run config sync manually
GH_TOKEN=<your-token> npx @aspruyt/xfg --config ./src/config.yaml
```

## Related Projects

- [xfg](https://github.com/anthony-spruyt/xfg) - The sync engine
- [claude-config](https://github.com/anthony-spruyt/claude-config) - Shared Claude Code configuration
