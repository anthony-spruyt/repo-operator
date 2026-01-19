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
GH_TOKEN=<your-token> ./src/sync-config.sh
```

Pre-commit hooks run automatically and include: yamllint, gitleaks, prettier, trailing-whitespace fixes.

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

### CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yaml`) runs:

1. **lint** - MegaLinter validation (skipped for renovate/dependabot commits)
2. **sync-config** - Runs xfg to sync templates to target repos (on push/dispatch only)
3. **summary** - Aggregates results for branch protection

The sync-config job creates PRs in target repositories with the updated configuration files.
