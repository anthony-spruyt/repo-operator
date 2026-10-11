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

CI lives in two files. `.github/workflows/ci.yaml` is the standard workflow (`lint`, then a `repo` job that calls `ci-repo.yaml`, then `image`, then `summary`), the same in every repo apart from per-repo xfg overlays. `.github/workflows/ci-repo.yaml` belongs to the repo and holds its own jobs. `github-ci` writes `ci.yaml` on every sync, so don't edit it in the repo; change the template or a
per-repo overlay in repo-operator. It seeds only `ci-repo.yaml`, once and without comments. Add `# main` after each `uses: anthony-spruyt/repo-operator/...@<sha>` in `ci-repo.yaml` when you add jobs, so Renovate keeps the pins current. Only repo-operator keeps its own `ci.yaml`, through a `createOnly` override (see [Standard ci.yaml and ci-repo.yaml](docs/ci.md#standard-ciyaml-and-ci-repoyaml)).

`github-ci` also syncs `.github/workflows/pr-title.yaml`, whose `PR Title` check fails a PR whose title doesn't follow Conventional Commits, since the squash commit on `main` takes the PR title. It is a required check wherever the `pr-rules` ruleset applies (see [PR title check](docs/ci.md#pr-title-check)).

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

Reusable workflows (`_lint`, `_summary`, `_trivy-*`, `_go-test`, `_python-uv-test`, `_images`, `_build-image`, `_release-please`, `_container-retention`, `_sonar-new-issues`) and composite actions (`build-image`, `publish-release`, `detect-images`, `sonar-new-issues`, `trivy-scan`) that other repos call. See [docs/ci.md](docs/ci.md).

Every repo's `ci.yaml` has an `image` job that builds each release-please package with a `Dockerfile` or `flavor.yaml` (a MegaLinter flavor, whose Dockerfile is generated) whose files changed, and the release callers publish each released package as its own image. See [Images](docs/ci.md#images).

Every `megalinter` repo gets its MegaLinter image pin inside its managed `lint.sh`. The pins live in this repo, so Renovate bumps each one once here instead of in every repo. See [Lint image pin](docs/ci.md#lint-image-pin).

Image repos join `go-image` or `python-image`, or `image` when their images use more than one language or a language the shared workflows don't test, such as .NET. Those groups sync the CI and release callers as managed files, and `go-image` and `python-image` also sync the language flavor pin and the lint config (`.golangci.yml`, `ruff-base.toml`). Every image publishes to GHCR and to Docker Hub
as `aspruyt/<image>`, with the `DOCKERHUB_TOKEN` secret that `image` syncs into the `release` environment. See [Managed image repos](docs/ci.md#managed-image-repos).

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

SonarQube Cloud's GitHub integration creates the project automatically when the repo is created. If the `Apply` on the merge push fails with a 404 because the project did not exist yet, re-run it once the project appears. To plan locally:

```bash
.github/scripts/sync-sonar-settings.sh
```

The `sonar` group adds a `sonar` job to the synced `ci.yaml` (`sonar / New Issues`, judged by `summary / Check Results`) that fails a PR when SonarQube Cloud reports any new open issue or hotspot to review on it, which the free plan's quality gate lets through. It reads the public API, so no token is needed. See [`sonar-new-issues`](docs/ci.md#sonar-new-issues) and
[Standard `ci.yaml`](docs/ci.md#standard-ciyaml-and-ci-repoyaml).

## Credentials

Keep this table current when adding a secret.

| Secret                 | Where it lives                                                                                                                                                                                         |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `APP_PRIVATE_KEY`      | repo-operator `production` and `plan-main` environments (`main` only), one copy each: rotate both. Client ID `APP_CLIENT_ID` is a repo variable                                                        |
| `PLAN_APP_PRIVATE_KEY` | repo-operator repo-level secret; XFG Plan (preview) and Lint Canary. Client ID `PLAN_APP_CLIENT_ID` is a repo variable                                                                                 |
| `RELEASE_PLEASE_APP_*` | Synced by the `release-please` group into each repo's `release` environment (`main` only; xfg's also `v*` tags)                                                                                        |
| `GHCR_READ_TOKEN`      | Synced to `github-trivy`; a classic PAT with `read:packages`, because the list API rejects app tokens                                                                                                  |
| `DOCKERHUB_TOKEN`      | Synced by `dockerhub`, which `image` extends, into `release` only                                                                                                                                      |
| `SONAR_TOKEN`          | repo-operator `sonar` environment (`main` only), for `sonar-settings.yaml`                                                                                                                             |
| `OPENROUTER_API_KEY`   | repo-operator `production` environment; XFG Apply AI commit messages, the fallback after LiteLLM                                                                                                       |
| `LITELLM_API_KEY`      | repo-operator `production` environment; XFG Apply AI commit messages through LiteLLM; also synced into xfg's `integration` and `integration-main` environments                                         |
| `CF_ACCESS_CLIENT_*`   | repo-operator `production` environment (`CF_ACCESS_CLIENT_ID` and `CF_ACCESS_CLIENT_SECRET`); the access headers for LiteLLM; also synced into xfg's `integration` and `integration-main` environments |
| `LITELLM_HOST`         | repo-operator `production` environment secret; the LiteLLM bare lowercase hostname, kept out of the repo; also synced into xfg's `integration` and `integration-main` environments                     |

### Rotating a synced secret

Secrets in `settings.secrets` and `settings.environments.<name>.secrets` (`groups.yaml`) are copied from repo-operator's own secrets by `xfg secrets sync` in CI. To rotate one: update the secret in the repo-operator `production` environment, run the `CI` workflow by hand (`workflow_dispatch` always syncs), and approve the `production` gate.

## Related Projects

- [xfg](https://github.com/anthony-spruyt/xfg) — The sync engine
- [claude-config](https://github.com/anthony-spruyt/claude-config) — Shared Claude Code configuration
