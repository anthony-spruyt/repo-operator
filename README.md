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
   - **XFG Plan (preview)** — partial dry-run on PRs, using the read-only Plan App
   - **XFG Plan** — full dry-run on `main`, the plan to read before approving Apply
   - **XFG Apply** — pushes changes to target repos (requires production environment approval)
   - **Summary** — aggregates results for branch protection

XFG Apply authenticates as the `repo-operator` GitHub App, whose key (`APP_PRIVATE_KEY`) is a secret in the `production` and `plan-main` environments. XFG Plan on `main` uses it from `plan-main` (branch `main` only, no reviewer), since GitHub hides merge settings and ruleset `bypass_actors` from read-only tokens. PR previews and Lint Canary use a read-only Plan App (`PLAN_APP_*`).

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

With `github-ci` (but not `image`, which keeps `ci.yaml` managed), the first sync seeds `.github/workflows/ci.yaml` without comments. Add `# main` after each `uses: anthony-spruyt/repo-operator/...@<sha>` there, so Renovate keeps the pin current (see [docs/ci.md](docs/ci.md)).

## Local Development

```bash
# Run linting locally (requires Docker)
./lint.sh

# Dry-run config sync (validates and shows planned changes)
npx @aspruyt/xfg sync --config ./src --dry-run

# Run config sync manually (requires GitHub App credentials or GH_TOKEN)
GH_TOKEN=<your-token> npx @aspruyt/xfg sync --config ./src
```

## Shared CI

Reusable workflows (`_lint`, `_summary`, `_trivy-*`, `_go-test`, `_python-uv-test`, `_build-image`, `_release-please`, `_rebuild-release`, `_container-retention`, `_sonar-new-issues`) and composite actions (`build-image`, `publish-release`, `sonar-new-issues`, `trivy-scan`) that other repos call. See [docs/ci.md](docs/ci.md).

Every `megalinter` repo gets its MegaLinter image pin inside its managed `lint.sh`. The pins live in this repo, so Renovate bumps each one once here instead of in every repo. See [Lint image pin](docs/ci.md#lint-image-pin).

Image repos join `go-image` or `python-image`. Those groups sync the CI and release callers, the language flavor pin and the lint config (`.golangci.yml`, `ruff-base.toml`) as managed files. See [Managed image repos](docs/ci.md#managed-image-repos).

## Renovate Configuration

Modular Renovate config in `.github/renovate/` is **not** synced via xfg — target repos reference it directly:

```json5
{ "extends": ["github>anthony-spruyt/repo-operator//.github/renovate/..."] }
```

For repo-specific Renovate rules, use `matchRepositories` in `.github/renovate/package-rules.json5`.

Target repos don't bump the files xfg manages for them. `.github/renovate/xfg-managed.json5` disables Renovate on every file that xfg manages in a repo without `createOnly`. Without it, Renovate's bump would be reverted by the next sync. Renovate bumps those pins here in `src/` instead, and they reach the target repos at the next XFG Apply. `createOnly` files stay with their repo. Vulnerability
alerts override `enabled: false`, so a security fix can still open a PR in a target repo. Land the same fix in `src/` too, or the next sync reverts it. The preset is generated from `src/`, so regenerate it after any change there:

```bash
.github/scripts/gen-xfg-managed-renovate.sh src > .github/renovate/xfg-managed.json5
```

Guard Tests fail when the committed preset doesn't match `src/`.

Every repo in the `renovate` group gets the same two files at its root:

| File                       | Owner         | Sync                                                                                                                                     |
| -------------------------- | ------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `renovate.json`            | repo-operator | Overwritten on every Apply: the shared presets above, `forkProcessing: "enabled"`, and `local>owner/repo//renovate-overrides.json5` last |
| `renovate-overrides.json5` | the repo      | Seeded once (`createOnly`), then never touched. Put repo-specific rules here                                                             |

`forkProcessing` sits in the root `renovate.json` because the Renovate app is installed on all repositories, and in that mode it skips a fork unless its default config file, `renovate.json`, enables forks. Renovate uses only the first config file it finds and never merges two, so no repo keeps a `.github/renovate.json5` beside it.

## SonarQube Cloud Configuration

Rule exclusions and path filters live in SonarQube Cloud project settings, not in the repos. Automatic analysis only honours a fixed set of properties in `.sonarcloud.properties`, and it silently ignores `sonar.issue.ignore.multicriteria`. Custom quality profiles would be the tidier fix, but assigning one requires a paid plan.

The `SonarQube Cloud Settings` workflow (`.github/workflows/sonar-settings.yaml`) owns these settings for every repo in the `sonar` group. Change them in `.github/sonar-settings.yaml`, never in the SonarQube Cloud UI, because the next run reverts UI edits.

- `defaults` apply to every project: `*:S8431` ("Use either the version tag or the digest") is ignored, because Renovate pins images with both a tag and a digest by design. `.claude/**` is kept out of analysis and duplication checks.
- `repos.<name>` sets extra keys for one project. A key listed there replaces that key's default.
- Keys the file does not list are left as they are in SonarQube Cloud. Removing a key from the file does not revert it; reset it in the SonarQube Cloud UI.

The workflow plans on PRs that touch the config, the script or `src/repos.yaml`. It reads public settings, so no token is needed. It applies on push to `main`, every Monday, and on manual dispatch, with `SONAR_TOKEN` from the `sonar` environment (`main` only). A recreated project is fixed by the next run.

Create the SonarQube Cloud project before adding a repo to the `sonar` group, or the workflow fails on the missing project. To plan locally:

```bash
.github/scripts/sync-sonar-settings.sh
```

The `SonarCloud` workflow (`.github/workflows/sonar-new-issues.yaml`) fails a PR when SonarQube Cloud reports any new open issue or hotspot to review on it, which the free plan's quality gate lets through. It reads the public API, so no token is needed. See [`sonar-new-issues`](docs/ci.md#sonar-new-issues).

## Credentials

Every credential that can act on the managed repos. Keep this current when adding an app, token, or bypass actor.

### GitHub Apps and bots

| Actor                            | ID      | Credential                                                                                         | Can do                                           | Bypass                                                      |
| -------------------------------- | ------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------ | ----------------------------------------------------------- |
| `repo-operator[bot]`             | 2758555 | `APP_*`, repo-operator `production` and `plan-main` (`main` only) environments                     | Files, settings, rulesets, secrets on every repo | `pr-rules` `always` (direct-push sync)                      |
| Plan App                         | n/a     | `PLAN_APP_*`, repo-operator only                                                                   | Read-only metadata for `xfg` dry-runs            | none                                                        |
| `repo-operator-release-bot[bot]` | 4745999 | One app for every release-please repo; `RELEASE_PLEASE_APP_*` synced by the `release-please` group | Opens release PRs, creates tags and releases     | `tag-rules` `always` on `release-please` repos              |
| `container-images-garbo[bot]`    | 3215096 | `GARBO_*`, container-images only                                                                   | Deletes old releases and tags                    | `tag-rules` `always` on container-images                    |
| `mergify[bot]`                   | 10562   | Mergify-hosted                                                                                     | Merges PRs, queue branches                       | `pr-rules` `exempt`                                         |

`tag-rules` blocks creating, updating and deleting any tag in every repo, so only its bypass actors can tag: the release bot in `release-please` repos (including xfg's floating `vN` tag) and garbo on container-images. Repos outside `release-please` take no tags.

`pr-rules` only exists on `protected-main-branch` repos. Mergify approves a pure `repo-operator-release-bot[bot]` release-please PR in the Monday window with its own review, which counts towards `pr-rules`' one approval; that is a review, not a ruleset bypass.

### Tokens

| Token              | Type                                                           | Where                                           | Can do                                                 |
| ------------------ | -------------------------------------------------------------- | ----------------------------------------------- | ------------------------------------------------------ |
| `GHCR_READ_TOKEN`  | Classic PAT, `read:packages` only                              | Synced to `github-trivy`                        | Read every package; the list API rejects app tokens    |
| `SONAR_TOKEN`      | SonarQube Cloud token                                          | repo-operator `sonar` environment (`main` only) | Set project settings (`sonar-settings.yaml`)           |
| `GH_TOKEN` (local) | Fine-grained PAT                                               | `~/.secrets/.env.common`                        | `gh` and local dry-runs; no secrets or packages access |
| xfg test creds     | `TEST_*`, `GH_PAT_ORG`, `GITLAB_TOKEN`, `AZURE_DEVOPS_EXT_PAT` | xfg only                                        | Integration tests against test orgs                    |

The local PAT stays on purpose: `gh` needs a user identity.

### Rotating a synced secret

Secrets in `settings.secrets` (`groups.yaml`) are copied from repo-operator's own secrets by `xfg secrets sync` in CI. To rotate one: update the secret in the repo-operator `production` environment, run the `CI` workflow by hand (`workflow_dispatch` always syncs), and approve the `production` gate.

## Related Projects

- [xfg](https://github.com/anthony-spruyt/xfg) — The sync engine
- [claude-config](https://github.com/anthony-spruyt/claude-config) — Shared Claude Code configuration
