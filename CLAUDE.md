# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Purpose

This repository is a **GitHub Repository Operator** - a registry and orchestrator that manages GitHub repositories to standardize developer experience across projects. Currently syncs configuration to existing repositories; will eventually create and fully configure new repositories.

### Related Projects

- **[xfg](https://github.com/anthony-spruyt/xfg)**: The underlying tool used to sync configuration files to target repositories
- **[claude-config](https://github.com/anthony-spruyt/claude-config)**: Repository containing shared Claude configuration (`.claude/` directory contents)

### Goals

- Eliminate repetitive setup when creating new repositories
- Standardize configuration and developer experience across all repositories
- Centralize the distribution of new development experience features
- Reduce hours of manual configuration work

### Authentication

- **Phase 1**: Uses GitHub Personal Access Token (PAT) for repository access
- **Phase 2** (planned): Migrate to GitHub App for improved security and permissions

## Development Commands

```bash
# Run MegaLinter locally (Docker required)
./lint.sh

# Run config sync manually (requires GH_TOKEN environment variable)
GH_TOKEN=<your-token> npx @aspruyt/xfg --config ./src/config.yaml
```

Pre-commit hooks run automatically for linting (yamllint, prettier), security (gitleaks), and file hygiene (whitespace, line endings, merge conflicts, smart quotes).

## Architecture

### XFG Configuration System

The operator uses [xfg](https://github.com/anthony-spruyt/xfg) to sync files to target repositories.

**Configuration file**: `src/config.yaml`

- `repos` - List of target repositories with optional per-repo file overrides
- `files` - Default files to sync, each with:
  - `content` - Template path (prefixed with `@templates/`)
  - `createOnly` - If true, only creates file if it doesn't exist (won't overwrite)
  - `header` - Optional header comments
- `prOptions.merge: auto` - PRs are automatically merged when checks pass

**Templates directory**: `src/templates/`
Contains all template files that get distributed: devcontainer setup, GitHub workflows, linting configs, editor configs, etc.

### Renovate Configuration

Modular config in `.github/renovate/` is NOT synced to repos - other repos reference it directly via `github>anthony-spruyt/repo-operator//...` extends. Changes here affect all repos immediately.

- For repo-specific rules, use `matchRepositories: ["owner/repo"]` in `package-rules.json5`
- Don't use xfg overrides for Renovate array merging (YAML syntax limitation with `$arrayMerge`)

### CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yaml`) runs:

1. **lint** - MegaLinter validation (skipped for renovate/dependabot commits)
2. **sync-config** - Uses the [xfg GitHub Action](https://github.com/anthony-spruyt/xfg) via GitHub App (on push only, skipped if no `src/` changes)
3. **summary** - Aggregates results for branch protection

The sync-config job creates PRs in target repositories with the updated configuration files.

Additional workflows distributed to target repos include Trivy vulnerability scanning.
