# repo-operator

[![CI](https://github.com/anthony-spruyt/repo-operator/actions/workflows/ci.yaml/badge.svg?branch=main)](https://github.com/anthony-spruyt/repo-operator/actions/workflows/ci.yaml) [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A GitHub Repository Operator that manages and standardizes configuration across multiple repositories using [xfg](https://github.com/anthony-spruyt/xfg).

## What It Does

- Syncs standardized configuration files (linting, CI/CD, devcontainer, editor settings, security scanning) to target repositories
- Manages GitHub repository settings: labels, branch rulesets, code scanning configuration
- Uses a group system for composable, reusable configuration (e.g. `docker`, `python`, `megalinter`, `mergify`)
- Distributes modular Renovate configuration that target repos extend via `github>` references

## How It Works

1. Configuration lives in `src/` as multiple YAML files (see [Configuration](#configuration))
2. Template files in `src/templates/` are synced to target repos
3. CI runs a **plan/apply** pipeline on push to main:
   - **Lint** — MegaLinter validation
   - **XFG Plan** — dry-run showing planned changes (runs on PRs too)
   - **XFG Apply** — pushes changes to target repos (requires production environment approval)
   - **Summary** — aggregates results for branch protection

Authentication uses a GitHub App (`APP_CLIENT_ID` / `APP_PRIVATE_KEY`).

## Configuration

Config is split across multiple files in `src/`:

| File            | Purpose                                                                          |
| --------------- | -------------------------------------------------------------------------------- |
| `base.yaml`     | Core config: `id`, `deleteOrphaned`, `prOptions`                                 |
| `files.yaml`    | Default files synced to all repos                                                |
| `groups.yaml`   | Reusable groups (e.g. `docker`, `megalinter`, `renovate`) and conditional groups |
| `repos.yaml`    | Target repositories with group assignments and per-repo overrides                |
| `settings.yaml` | Global settings: labels, repo defaults, rulesets, code scanning                  |

Template files referenced via `@templates/` paths live in `src/templates/`.

## Adding a Repository

Edit `src/repos.yaml`:

```yaml
repos:
  - git: https://github.com/your-org/your-repo.git
    groups:
      - github-ci
      - github-trivy
      - megalinter
      - mergify
      - renovate
    files:
      # Optional: override or extend files for this repo
      .devcontainer/devcontainer.json:
        content:
          customizations:
            vscode:
              extensions:
                $arrayMerge: append
                $values:
                  - "some.extension"
```

## Local Development

```bash
# Run linting locally (requires Docker)
./lint.sh

# Dry-run config sync (validates and shows planned changes)
npx @aspruyt/xfg sync --config ./src --dry-run

# Run config sync manually (requires GitHub App credentials or GH_TOKEN)
GH_TOKEN=<your-token> npx @aspruyt/xfg --config ./src
```

## Renovate Configuration

Modular Renovate config in `.github/renovate/` is **not** synced via xfg — target repos reference it directly:

```json5
{ "extends": ["github>anthony-spruyt/repo-operator//.github/renovate/..."] }
```

For repo-specific Renovate rules, use `matchRepositories` in `.github/renovate/package-rules.json5`.

## Related Projects

- [xfg](https://github.com/anthony-spruyt/xfg) — The sync engine
- [claude-config](https://github.com/anthony-spruyt/claude-config) — Shared Claude Code configuration
