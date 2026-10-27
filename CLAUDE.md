# CLAUDE.md

## Project Purpose

Registry and orchestrator that uses [xfg](https://github.com/anthony-spruyt/xfg) to sync shared config to GitHub repos, and to create missing ones, so every repo has the same developer experience.

## Authentication

- **CI sync**: XFG Apply uses the `repo-operator` GitHub App (`APP_CLIENT_ID` / `APP_PRIVATE_KEY`), whose key lives only in the `production` and `plan-main` environments. XFG Plan on `main` uses the same key from `plan-main` (deployment branch `main`, no reviewer), because GitHub hides merge settings and ruleset `bypass_actors` from read-only tokens. PR previews (XFG Plan (preview)) and Lint
  Canary use a read-only Plan App (`PLAN_APP_CLIENT_ID` / `PLAN_APP_PRIVATE_KEY`) and never see a write key; the preview plan is partial.
- **Local/manual runs**: Use the fine-grained PAT in `GH_TOKEN` (from `~/.secrets/.env.common`). It is kept on purpose: `gh` needs a user identity for issues and PRs, so it is not being migrated to the app.
- **Secrets sync** (`xfg secrets sync`): CI only, via the xfg action with GitHub App auth. The PAT has no secrets access.

## Development Commands

```bash
# Run MegaLinter locally with auto-fixes (Docker/podman required)
./lint.sh

# Run MegaLinter locally without fixes (--ci is for CI workflows, not local runs)
APPLY_FIXES=none ./lint.sh

# Run or skip some linters (ENABLE_LINTERS, DISABLE_LINTERS, ENABLE_DISABLE_LINTERS_PRIORITY pass through when set)
DISABLE_LINTERS=SPELL_LYCHEE ENABLE_DISABLE_LINTERS_PRIORITY=DISABLE ./lint.sh
```

Pre-commit hooks run automatically on commit.

## Architecture

### XFG Configuration System

Load the `repo-operator` skill (source `src/templates/.claude/skills/repo-operator/SKILL.md`) before changing `src/`. Repo specifics:

- `.prettierrc.yaml` uses `requirePragma` overrides to skip md/json/yaml because prettier only reads `.prettierignore` from the cwd (subdirectory runs ignore it). `*.json` needs `parser: json5` since the `json` parser ignores `requirePragma`. mdformat owns markdown.
- MegaLinter excludes live in `.mega-linter-base.yml` as `ADDITIONAL_EXCLUDED_DIRECTORIES`, which adds to MegaLinter's defaults (`.git`, `node_modules`, ...). Repos add more via the same key, listed in `CONFIG_PROPERTIES_TO_APPEND`. Setting `EXCLUDED_DIRECTORIES` in a repo replaces MegaLinter's defaults, not the base list.
- Trivy scanners are set by `scan.scanners` in `trivy-mega-linter.yaml`; `.mega-linter-base.yml` only strips MegaLinter's default `--scanners vuln,misconfig` so the config file wins. Vulnerabilities are scanned by the daily Trivy workflow instead.
- `prOptions.ai` in `base.yaml` asks LiteLLM first (host from the `LITELLM_HOST` secret, never written in the repo; XFG Apply builds `LITELLM_BASE_URL` as `https://<host>/v1` and allows `<host>:443` in harden-runner, and leaves both out when the secret is empty) and falls back to OpenRouter when LiteLLM or any of its env vars is missing, empty or fails; the guard pins both. `prOptions.ai.prompt`
  keeps sync commits to `chore`/`ci`/`build`/`docs`/`style`. Image repos hide those types from release-please, so a sync never cuts a release; a `feat` sync would bump the minor version.
- **PR approval gate** (design in [#581](https://github.com/anthony-spruyt/repo-operator/issues/581)). Each rule lives in one place:
  - `pr-rules` (`protected-main-branch`): one approval from someone who is neither the PR author nor the latest pusher; a real commit dismisses it, an "Update branch" keeps it. No CODEOWNERS.
  - `.mergify.yml` merge protections: `approval` (one approval on every PR, including repos without `pr-rules`), `outsider` (an author outside the trusted bot and owner list needs `anthony-spruyt`) and `gate-files` (`.github/`, `.mergify.yml`, root `renovate.json`, `renovate-overrides.json5` and `release-please-config.json`, `metadata.yaml` at any depth, and the repo's `gateFilesExtra` need
    `anthony-spruyt` unless the PR is pure Renovate or wholly the owner's). Mergify is in `pr-rules` `bypass_actors` (mode `exempt`) and enforces these protections.
  - `pr-reviews`: a ruleset on `main` (group `dismiss-stale-approvals`) that dismisses approvals when new commits are pushed, for the repos in that group.
  - Approvals on Renovate PRs reset when new commits are pushed: a `.mergify.yml` pull request rule dismisses them, including in repos without `pr-rules`.
  - Mergify never approves a PR. Release PRs are ordinary PRs that merge once a collaborator approves them.
  - "Pure" means the bot opened the PR and every commit has that bot's author login and `<id>+<login>@users.noreply.github.com` email, committer `noreply@github.com` and a valid signature. Only GitHub's web-flow key signs that combination; a commit signed with any other key carries its signer's committer email.
  - "Wholly the owner's" means `anthony-spruyt` opened the PR and every commit is verified with an owner author email and an owner or `noreply@github.com` committer email. The conditions match verified emails; GitHub verifies a signature only for its committer email's account, so agent commits (`spruyt-labs-bot`, app bots) do not qualify.
  - Only the release bot creates and moves tags, and only in `release-please` repos; other repos take no tags.
  - megalinter-refresh PRs commit unsigned through `git push`, so they need a normal approval until they commit through the API.
  - `gateFilesExtra` is a template var prepended to the gate-files regex, with its own trailing `|`: repo-operator adds `src/` (the config the next Apply syncs), `test/ci/` (the guard tests) and `lint.sh`. A repo may add paths its image prepare and test commands use, as container-images and traefik-api-key-auth do; leave it empty where `src/` is application code.
- The `main` XFG Plan runs `src/` before the owner reads it with the write key, so it runs behind harden-runner in the [switch's](docs/ci.md#harden-runner) mode and `.github/scripts/check-xfg-config.sh`, which fails on any non-`github.com` `githubHosts`, repo URL outside `github.com/anthony-spruyt/`, `${VAR}` env reference, `files` path with a `.git` segment, secret source env outside the allowed set (the LiteLLM gateway names
  only in the xfg `integration`/`integration-main` environments), AI endpoint, key env or header env outside the pinned LiteLLM and OpenRouter set, or AI provider with neither `baseUrl` nor `baseUrlEnv` (including `ai: true`).

### Adding a New Repository

xfg [lifecycle](https://github.com/anthony-spruyt/xfg/blob/main/docs/configuration/lifecycle.md) creates a missing repo on sync: empty by default, a fork with `upstream`, or a full mirror of another repo with `source`.

- **Splitting a subfolder out with its history is not a lifecycle mode.** Create the repo empty in the GitHub UI (nothing ticked), push the filtered history (`git filter-repo --subdirectory-filter <dir>`), and only then add it to `repos.yaml`. Once synced, rulesets require signed commits and PRs, so rewritten history can no longer be pushed.

After the repo exists:

1. **Accept the `spruyt-labs-bot` collaborator invite** as the bot. xfg sends it on sync (`settings.collaborators` in `settings.yaml`), but GitHub needs the bot to accept it. `collaborators.deleteOrphaned` is on, so anyone added by hand gets removed.
2. **Enable the repo in the Mergify portal** (dashboard.mergify.com) - installing the GitHub App is not enough. Without it, the `Mergify Merge Protections` required check never runs and every PR is blocked.

### Renovate Configuration

Modular config in `.github/renovate/` is NOT synced to repos - other repos reference it directly via `github>anthony-spruyt/repo-operator//...` extends. Changes here affect all repos immediately.

- For repo-specific rules, use `matchRepositories: ["owner/repo"]` in `package-rules.json5`
- Don't use xfg overrides for Renovate array merging (YAML syntax limitation with `$arrayMerge`)
- **Layout, the same in every repo**: the `renovate` group syncs a root `renovate.json` on every Apply (the shared presets, `forkProcessing: "enabled"`, then `local>${xfg:repo.fullName}//renovate-overrides.json5` last) and seeds a root `renovate-overrides.json5` once with `createOnly`. Edit the override file in the target repo, not here. Don't add per-repo Renovate entries to `repos.yaml`.
- **Why root `renovate.json`**: with the app on all repositories, Renovate skips a fork unless `forkProcessing` is enabled in the default config file, `renovate.json`, and nowhere else. Renovate reads only the first config file it finds and never merges two, so nothing else may sit beside it.
- **xfg-managed files**: `xfg-managed.json5` is generated from `src/`. It stops target repos from bumping files that xfg manages there without `createOnly`. After any `src/` change, run `.github/scripts/gen-xfg-managed-renovate.sh src > .github/renovate/xfg-managed.json5` and `.github/scripts/gen-xfg-managed-renovate.sh --map src > .github/xfg-managed.json`. Guard Tests fail if either drifts.

### CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/ci.yaml`) runs:

1. **lint** - MegaLinter validation (skipped on `workflow_dispatch`). **repo** then calls `.github/workflows/ci-repo.yaml`, this repo's own jobs: **guard-test** (`repo / Guard Tests`) runs `bats -r test/`. Code tests: one `test/<name>.bats` per script in `.github/scripts/`, per action and per synced script. Guard tests, which keep CI and config wired, sit in `test/ci/` and are gate files. Fixtures
   and helpers go in `test/fixtures/<name>/`. See `docs/ci.md` for the `ci.yaml` / `ci-repo.yaml` split.
2. **xfg-preview** - Dry-run sync via the [xfg GitHub Action](https://github.com/anthony-spruyt/xfg) with the read-only Plan App, on dispatch from non-`main` refs and on PRs that have the `xfg/plan` label or change `ci.yaml`, `check-xfg-config.sh` or `xfg-preview-needed.sh`; never on merge queue PRs. The config guard runs on every PR. Any other label skips every job. Partial: merge settings and
   ruleset `bypass_actors` show as changes because the Plan App can't read them.
3. **xfg-plan** - Full dry-run on `main` push and dispatch, with the write App's key from the `plan-main` environment; fails rather than plan partially if that key is missing. harden-runner runs in the [switch's](docs/ci.md#harden-runner) mode with an allowlist of GitHub and npm, and the config guard runs first (as in xfg-preview and xfg-apply). This is the plan to read before approving Apply. Skips when `src/` is unchanged since `LAST_XFG_DEPLOY_SHA` (a repo
   variable).
4. **xfg-apply** - Real sync. **Push/dispatch only (never PRs)**, always gated by the `production` environment and its required reviewer; no workflow input skips it. The Apply-side secrets live in that environment (`GHCR_READ_TOKEN` is also a repo secret, because the `github-trivy` sync writes it back for the Trivy scan). Records `LAST_XFG_DEPLOY_SHA` after applying. harden-runner runs in the
   [switch's](docs/ci.md#harden-runner) mode with an allowlist of GitHub, npm, OpenRouter and the LiteLLM host. AI commit messages use LiteLLM, with OpenRouter as the fallback.
5. **summary** - Aggregates results for branch protection

The xfg-apply job pushes the updated configuration directly to target repos (`prOptions.merge: direct`). Commits by `repo-operator[bot]` are skipped to prevent sync→commit→sync loops.

`lint-canary.yaml` is called by `ci.yaml` and runs on PRs that touch a lint pin or lint template, never on merge queue PRs: it renders the planned files with `xfg sync --dry-run --render-dir`, overlays them on each affected repo's `main` and runs `./lint.sh --ci` there. `summary` judges it, so a failure blocks the merge. See `docs/ci.md`.

`sonar-settings.yaml` owns SonarQube Cloud project settings for the `sonar` group, from `.github/sonar-settings.yaml`. It plans on PRs that touch its paths (public GET, no token) and applies on `main` push, weekly and dispatch with `SONAR_TOKEN` from the `sonar` environment. It is not a required check, because its paths filter would leave it pending on other PRs. See the README.

The `sonar` job in `ci.yaml` (`sonar / New Issues`) fails a PR when SonarQube Cloud reports any open issue or hotspot to review on its head commit. It calls `_sonar-new-issues.yaml` at the same commit, uses no token, and `summary` judges it. The `sonar` group adds the same job to the synced `ci.yaml` and appends it to `summary.needs`. See `docs/ci.md`.
