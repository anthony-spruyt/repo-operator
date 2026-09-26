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
GH_TOKEN=<your-token> npx @aspruyt/xfg sync --config ./src
```

## Renovate Configuration

Modular Renovate config in `.github/renovate/` is **not** synced via xfg — target repos reference it directly:

```json5
{ "extends": ["github>anthony-spruyt/repo-operator//.github/renovate/..."] }
```

For repo-specific Renovate rules, use `matchRepositories` in `.github/renovate/package-rules.json5`.

## SonarQube Cloud Configuration

Rule exclusions live in SonarQube Cloud project settings, **not** in Git. Automatic analysis only honours a fixed set of properties in `.sonarcloud.properties` — `sonar.issue.ignore.multicriteria` is not among them and is silently ignored there.

`docker:S8431` ("Use either the version tag or the digest") is excluded on every project, because Renovate pins images with both a tag and a digest by design. Re-apply after recreating a project:

```bash
curl -X POST https://sonarcloud.io/api/settings/set \
  --header "Authorization: Bearer $SONAR_TOKEN" \
  --data-urlencode "key=sonar.issue.ignore.multicriteria" \
  --data-urlencode "component=anthony-spruyt_<repo>" \
  --data-urlencode 'fieldValues={"ruleKey":"*:S8431","resourceKey":"**/*"}'
```

Custom quality profiles would be the tidier fix, but assigning one requires a paid plan.

## Credentials

Every credential that can act on the managed repos. Keep this current when adding an app, token, or bypass actor.

### GitHub Apps and bots

| Actor                            | ID      | Credential                                                                                         | Can do                                           | Bypass                                                      |
| -------------------------------- | ------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------- |
| `repo-operator[bot]`             | 2758555 | `APP_*`, repo-operator only                                                                        | Files, settings, rulesets, secrets on every repo | `pr-rules` `always` (direct-push sync)                      |
| `repo-operator-release-bot[bot]` | 4745999 | One app for every release-please repo; `RELEASE_PLEASE_APP_*` synced by the `release-please` group | Opens release PRs, creates tags and releases     | `tag-rules` `always` where a release moves a tag (xfg `vN`) |
| `container-images-garbo[bot]`    | 3215096 | `GARBO_*`, container-images only                                                                   | Deletes old releases and tags                    | `tag-rules` `always` on container-images                    |
| `renovate[bot]`                  | 2740    | Mend-hosted                                                                                        | Opens PRs                                        | none                                                        |
| `mergify[bot]`                   | 10562   | Mergify-hosted                                                                                     | Merges PRs, queue branches                       | `pr-rules` `exempt`                                         |

`pr-rules` only exists on `protected-main-branch` repos. Mergify merge protections trust PRs authored by `repo-operator-release-bot[bot]` (`release-please`, `megalinter-refresh`); that is an author match, not a ruleset bypass.

### Tokens

| Token                       | Type                                                           | Where                    | Can do                                                           |
| --------------------------- | -------------------------------------------------------------- | ------------------------ | ---------------------------------------------------------------- |
| `GHCR_READ_TOKEN`           | Classic PAT, `read:packages` only                              | Synced to `github-trivy` | Read every package; the list API rejects app tokens              |
| `GH_TOKEN` (local)          | Fine-grained PAT                                               | `~/.secrets/.env.common` | `gh` and local dry-runs; no secrets or packages access           |
| `CONTAINER_RETENTION_TOKEN` | PAT                                                            | container-images only    | Deletes old versions of packages in `release-please-config.json` |
| xfg test creds              | `TEST_*`, `GH_PAT_ORG`, `GITLAB_TOKEN`, `AZURE_DEVOPS_EXT_PAT` | xfg only                 | Integration tests against test orgs                              |

The local PAT stays on purpose: `gh` needs a user identity.

### Rotating a synced secret

Secrets in `settings.secrets` (`groups.yaml`) are copied from repo-operator's own secrets by `xfg secrets sync` in CI. To rotate one: update the secret in repo-operator, run the `CI` workflow by hand (`workflow_dispatch` always syncs), and approve the `production` gate.

## Related Projects

- [xfg](https://github.com/anthony-spruyt/xfg) — The sync engine
- [claude-config](https://github.com/anthony-spruyt/claude-config) — Shared Claude Code configuration
