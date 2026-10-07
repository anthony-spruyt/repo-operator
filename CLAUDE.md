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

- **CI sync**: XFG Apply uses the `repo-operator` GitHub App (`APP_CLIENT_ID` / `APP_PRIVATE_KEY`), whose key lives only in the `production` and `plan-main` environments. XFG Plan on `main` uses the same key from `plan-main` (deployment branch `main`, no reviewer), because GitHub hides merge settings and ruleset `bypass_actors` from read-only tokens. PR previews (XFG Plan (preview)) and Lint
  Canary use a read-only Plan App (`PLAN_APP_CLIENT_ID` / `PLAN_APP_PRIVATE_KEY`) and never see a write key; the preview plan is partial.
- **Local/manual runs**: Use the fine-grained PAT in `GH_TOKEN` (from `~/.secrets/.env.common`). It is kept on purpose: `gh` needs a user identity for issues and PRs, so it is not being migrated to the app.
- **Secrets sync** (`xfg secrets sync`): CI only, via the xfg action with GitHub App auth. The PAT has no secrets access.

## Development Commands

```bash
# Run MegaLinter locally with auto-fixes (Docker/podman required)
./lint.sh

# Run MegaLinter in CI mode (no fixes)
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
- `.prettierrc.yaml` uses `requirePragma` overrides to skip md/json/yaml because prettier only reads `.prettierignore` from the cwd (subdirectory runs ignore it). `*.json` needs `parser: json5` since the `json` parser ignores `requirePragma`. mdformat owns markdown.
- MegaLinter excludes live in `.mega-linter-base.yml` as `ADDITIONAL_EXCLUDED_DIRECTORIES`, which adds to MegaLinter's defaults (`.git`, `node_modules`, ...). Repos add more via the same key, listed in `CONFIG_PROPERTIES_TO_APPEND`. Setting `EXCLUDED_DIRECTORIES` in a repo replaces MegaLinter's defaults, not the base list.
- Trivy scanners are set by `scan.scanners` in `trivy-mega-linter.yaml`; `.mega-linter-base.yml` only strips MegaLinter's default `--scanners vuln,misconfig` so the config file wins. Vulnerabilities are scanned by the daily Trivy workflow instead.
- `prOptions.ai.prompt` in `base.yaml` keeps sync commits to `chore`/`ci`/`build`/`docs`/`style`. Image repos hide those types from release-please, so a sync never cuts a release; a `feat` sync would bump the minor version.
- `template: true` + `vars` - substitutes `${xfg:name}` (and built-ins like `${xfg:repo.fullName}`) in a file. Unknown variables fail the sync. `lint.sh` takes its `megalinterImage` pin from the `megalinter-flavor` conditional groups keyed on the language groups or a per-repo override in `repos.yaml`, which is where Renovate bumps the pins; the image groups set `language` for the managed
  CI/release callers. Shell templates holding `${xfg:...}` use a `.tmpl` extension so this repo's shellcheck skips them. See `docs/ci.md`.
- `.mergify.yml` merge protections need an `anthony-spruyt` approval on every PR except Renovate's, the release bot's and the owner's own (any approval). A change under `.github/` or to `.mergify.yml` always needs the owner, so a bot approval (for example `skynet-rw[bot]`) never merges one. `revert-approved` trusts only `skynet-rw[bot]`, the platform's revert agent. In repo-operator its `src/`
  changes are gated by the owner reading the Plan before approving XFG Apply, not by Mergify. The `main` XFG Plan runs that unreviewed `src/` with the write key, so it runs behind a harden-runner egress block and `.github/scripts/check-xfg-config.sh`, which fails on any non-`github.com` `githubHosts`, repo URL outside `github.com/anthony-spruyt/`, or `${VAR}` env reference. Mergify is an `exempt`
  `pr-rules` bypass actor, so these protections are the real gate.
- The `request owner review` rule in `.mergify.yml` skips bots by exact login. An `author~=\[bot\]$` regex would also skip `skynet-rw[bot]` agent PRs, the ones it exists for.
- Comments in a template are **not** synced - xfg emits generated YAML with only the `header:` lines from `groups.yaml`. Explain non-obvious template config here instead.

### Adding a New Repository

xfg [lifecycle](https://github.com/anthony-spruyt/xfg/blob/main/docs/configuration/lifecycle.md) creates a missing repo on sync: empty by default, a fork with `upstream`, or a full mirror of another repo with `source`.

- **Splitting a subfolder out with its history is not a lifecycle mode.** Create the repo empty in the GitHub UI (nothing ticked), push the filtered history (`git filter-repo --subdirectory-filter <dir>`), and only then add it to `repos.yaml`. Once synced, rulesets require signed commits and PRs, so rewritten history can no longer be pushed.
- **CI cannot create repos on this personal account.** A GitHub App installation token cannot create user-owned repos; that needs a user access token (interactive login). CI uses the `repo-operator` app's installation token, so create fails with `403 Rate Limit Exceeded` after long retries ([xfg#1070](https://github.com/anthony-spruyt/xfg/issues/1070)). Org-owned repos do work with an installation
  token. Create the repo in the GitHub UI first, then let CI manage it. Do not use the local `GH_TOKEN` PAT for this - it belongs to `spruyt-labs-bot`, so the bot would own the repo.

After the repo exists:

1. **Accept the `spruyt-labs-bot` collaborator invite** as the bot. xfg sends it on sync (`settings.collaborators` in `settings.yaml`), but GitHub needs the bot to accept it. `collaborators.deleteOrphaned` is on, so anyone added by hand gets removed.
2. **Enable the repo in the Mergify portal** (dashboard.mergify.com) - installing the GitHub App is not enough. Without it, the `Mergify Merge Protections` required check never runs and every PR is blocked.

### Renovate Configuration

Modular config in `.github/renovate/` is NOT synced to repos - other repos reference it directly via `github>anthony-spruyt/repo-operator//...` extends. Changes here affect all repos immediately.

- For repo-specific rules, use `matchRepositories: ["owner/repo"]` in `package-rules.json5`
- Don't use xfg overrides for Renovate array merging (YAML syntax limitation with `$arrayMerge`)
- **Per-repo overrides**: instead of xfg array merges, repos use a `createOnly` `.github/renovate-overrides.json5` (seeded empty) and the synced `.github/renovate.json5` appends a `local>anthony-spruyt/<repo>//.github/renovate-overrides.json5` to its `extends`. Edit the override file in the target repo, not here.

### CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yaml`) runs:

1. **lint** - MegaLinter validation (skipped on `workflow_dispatch`). **guard-test** runs the bats tests for `.github/scripts/check-xfg-config.sh`.
2. **xfg-preview** - Dry-run sync via the [xfg GitHub Action](https://github.com/anthony-spruyt/xfg) with the read-only Plan App, on PRs and dispatch from non-`main` refs. Partial: merge settings and ruleset `bypass_actors` show as changes because the Plan App can't read them.
3. **xfg-plan** - Full dry-run on `main` push and dispatch, with the write App's key from the `plan-main` environment; fails rather than plan partially if that key is missing. Egress is blocked to GitHub and npm, and the config guard runs first (as in xfg-preview and xfg-apply), because agent reverts can merge `src/` with no review. This is the plan to read before approving Apply. Skips when
   `src/` is unchanged since `LAST_XFG_DEPLOY_SHA` (a repo variable).
4. **xfg-apply** - Real sync. **Push/dispatch only (never PRs)**, always gated by the `production` environment and its required reviewer; no workflow input skips it. The Apply-side secrets live in that environment (`GHCR_READ_TOKEN` is also a repo secret, because the `github-trivy` sync writes it back for the Trivy scan). Records `LAST_XFG_DEPLOY_SHA` after applying. Egress is blocked to GitHub,
   npm and OpenRouter (AI commit messages).
5. **summary** - Aggregates results for branch protection

The xfg-apply job pushes the updated configuration directly to target repos (`prOptions.merge: direct`). Commits by `repo-operator[bot]` are skipped to prevent sync→commit→sync loops.

`lint-canary.yaml` runs on PRs that touch a lint pin or lint template: it renders the planned files with `xfg sync --dry-run --render-dir`, overlays them on each affected repo's `main` and runs `./lint.sh --ci` there. It is not a required check. See `docs/ci.md`.

Additional workflows distributed to target repos include Trivy vulnerability scanning.
