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

- **CI sync**: Uses a GitHub App (`APP_CLIENT_ID` var / `APP_PRIVATE_KEY` secret)
- **Local/manual runs**: Use a Personal Access Token via `GH_TOKEN`
- **Phase 2** (planned): Migrate remaining PAT usage to the GitHub App

## Development Commands

```bash
# Run MegaLinter locally with auto-fixes (Docker/podman required)
./lint.sh

# Run MegaLinter in CI mode (no fixes, skips bot-authored commits)
./lint.sh --ci

# Run config sync manually (requires GH_TOKEN environment variable)
GH_TOKEN=<your-token> npx @aspruyt/xfg sync --config ./src

# Dry-run config sync (validates config and shows planned changes without applying)
npx --safe-chain-skip-minimum-package-age @aspruyt/xfg sync --config ./src --dry-run
```

**When to dry-run**: After any change to `src/` files (groups, repos, settings, files). Catches issues like xfg deduplicating rules by type, incorrect array merging, or missing file references before pushing to CI.

Pre-commit hooks run automatically for linting (yamllint, prettier), security (gitleaks), and file hygiene (whitespace, line endings, merge conflicts, smart quotes).

## Architecture

### XFG Configuration System

The operator uses [xfg](https://github.com/anthony-spruyt/xfg) to sync files to target repositories.

**Configuration directory**: `src/` (multi-file directory-based config)

- `base.yaml` - Core config: `id`, `deleteOrphaned`, `prOptions`
- `files.yaml` - Default files to sync to all repos
- `groups.yaml` - Group definitions and conditional groups
- `repos.yaml` - Target repositories with optional per-repo overrides
- `settings.yaml` - Global settings: labels, repo defaults, rulesets, code scanning
- File content uses `@templates/` references (resolved relative to fragment file)
- `prOptions.merge: direct` - Changes are pushed directly

**Templates directory**: `src/templates/` Contains all template files that get distributed: devcontainer setup, GitHub workflows, linting configs, editor configs, etc.

**Key xfg mechanics**:

- `createOnly: true` - file is **seeded once** and never overwritten on later syncs (use for files repos customize, e.g. `.gitignore`, `.mega-linter.yml`, `renovate-overrides.json5`). Default (omitted) overwrites on every sync.
- `$arrayMerge: append` + `$values: [...]` - appends to an array (e.g. pre-commit `repos`, devcontainer `extensions`) instead of replacing it. Required because plain YAML keys replace.
- **Groups** (`groups.yaml`) - named bundles of files/settings; can `extends` other groups. Repos opt in via the `groups:` list in `repos.yaml`.
- **conditionalGroups** (`groups.yaml`) - apply files/settings based on which groups a repo has, via `allOf` / `anyOf` / `noneOf` predicates. Used for cross-cutting rules (e.g. status-check rulesets that differ when `mergify` is present).

### Renovate Configuration

Modular config in `.github/renovate/` is NOT synced to repos - other repos reference it directly via `github>anthony-spruyt/repo-operator//...` extends. Changes here affect all repos immediately.

- For repo-specific rules, use `matchRepositories: ["owner/repo"]` in `package-rules.json5`
- Don't use xfg overrides for Renovate array merging (YAML syntax limitation with `$arrayMerge`)
- **Per-repo overrides**: instead of xfg array merges, repos use a `createOnly` `.github/renovate-overrides.json5` (seeded empty) and the synced `.github/renovate.json5` appends a `local>anthony-spruyt/<repo>//.github/renovate-overrides.json5` to its `extends`. Edit the override file in the target repo, not here.

### CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yaml`) runs:

1. **lint** - MegaLinter validation (skipped on `workflow_dispatch`; bot commits skipped inside `lint.sh --ci`)
2. **xfg-plan** - Dry-run sync via the [xfg GitHub Action](https://github.com/anthony-spruyt/xfg) (GitHub App auth). Runs on PRs, push, and dispatch. Skips when `src/` is unchanged since `LAST_XFG_DEPLOY_SHA` (a repo variable).
3. **xfg-apply** - Real sync. **Push/dispatch only (never PRs)**, gated by the `production` environment approval (bypassable via the `skip_approval` dispatch input). Records `LAST_XFG_DEPLOY_SHA` after applying.
4. **summary** - Aggregates results for branch protection

The xfg-apply job pushes the updated configuration directly to target repos (`prOptions.merge: direct`). Commits by `repo-operator[bot]` are skipped to prevent sync→commit→sync loops.

Additional workflows distributed to target repos include Trivy vulnerability scanning.
