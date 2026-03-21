# Spruyt-Labs Full Migration to Repo-Operator

## Context

spruyt-labs is a GitOps homelab repository (Talos Linux, FluxCD, Terraform) that predates repo-operator. It was the original repo whose patterns were extracted into repo-operator's shared templates and configs. However, spruyt-labs itself was never fully migrated — it currently only uses the `private-repo` group with `files: inherit: false` and `rulesets: inherit: false`, meaning it receives no synced files or standard configuration from repo-operator.

## Goal

Enable all standard groups for spruyt-labs (devcontainer, github-ci, github-trivy, renovate, pre-commit, megalinter, private-repo) with xfg content overrides for repo-specific needs. No new groups will be created — spruyt-labs is the only infrastructure repo, so repo-specific differences are handled via overrides rather than reusable groups.

## Changes in repo-operator

### 1. Replace spruyt-labs entry in `src/config.yaml`

Replace the current minimal entry with full group membership and content overrides:

```yaml
- git: https://github.com/anthony-spruyt/spruyt-labs.git
  groups:
    - devcontainer
    - github-ci
    - github-trivy
    - renovate
    - pre-commit
    - megalinter
    - private-repo
  prOptions:
    merge: manual
  files:
    # Devcontainer - extra features, mounts, extensions
    .devcontainer/devcontainer.json:
      content:
        features:
          "ghcr.io/devcontainers-extra/features/sops": {}
          "ghcr.io/eitsupi/devcontainer-features/jq-likes":
            yqVersion: "latest"
          "ghcr.io/devcontainers/features/terraform": {}
          "ghcr.io/devcontainers-extra/features/renovate-cli": {}
        mounts:
          $arrayMerge: append
          values:
            - "source=${localEnv:HOME}/.secrets/.terraform.d,target=/home/vscode/.terraform.d,type=bind,readonly"
            - "source=${localEnv:HOME}/.secrets,target=/home/vscode/.secrets,type=bind,readonly"
            - "source=${localEnv:HOME}/.secrets/talosconfig,target=/home/vscode/.secrets/talosconfig,type=bind"
        customizations:
          vscode:
            extensions:
              $arrayMerge: append
              values:
                - "task.vscode-task"
                - "tim-koehler.helm-intellisense"
                - "hashicorp.terraform"
                - "github.vscode-github-actions"
        portsAttributes:
          "3333":
            label: "Capacitor"
            onAutoForward: "openBrowser"

    # VSCode - repo-specific search excludes + formatters
    .vscode/settings.json:
      createOnly: false
      content:
        "search.exclude":
          "**/*.secret.*": true
          "**/temp/**": true
        "editor.defaultFormatter": "esbenp.prettier-vscode"
        "[terraform]":
          "editor.defaultFormatter": "hashicorp.terraform"

    # Yamllint - extra ignores (string replaces template value)
    .yamllint.yml:
      content:
        ignore: |
          *.sops.*
          talos/
          clusterconfig/
          legacy/
          .taskfiles/talos/scripts/

    # Trivy - add skip-dirs
    trivy.yaml:
      content:
        scan:
          skip-dirs:
            - talos/clusterconfig

    # Pre-commit - add sops + terraform hooks
    .pre-commit-config.yaml:
      content:
        repos:
          $arrayMerge: append
          values:
            - repo: https://github.com/k8s-at-home/sops-pre-commit
              rev: v2.1.1
              hooks:
                - id: forbid-secrets
            - repo: https://github.com/antonbabenko/pre-commit-terraform
              rev: v1.105.0
              hooks:
                - id: terraform_fmt
                  files: ^infra/terraform/
                - id: terraform_tflint
                  files: ^infra/terraform/

    # Renovate - add ignorePaths
    .github/renovate.json5:
      content:
        ignorePaths:
          - "talos/helmfile"

    # Not needed for this repo
    .eslintrc.json: false
    .hadolint.yaml: false
    .pylintrc: false

  settings:
    repo:
      allowAutoMerge: false
    rulesets:
      inherit: false
    labels:
      alert:
        color: "#e11d48"
        description: "Auto-created alert triage issue"
      "renovate/github-actions":
        color: "#ededed"
        description: ""
      "renovate/helm":
        color: "#ededed"
        description: ""
      "renovate/image":
        color: "#ededed"
        description: ""
      "renovate/talos":
        color: "#ededed"
        description: ""
      "renovate/terraform":
        color: "#ededed"
        description: ""
      "renovate/taskfile":
        color: "#ededed"
        description: ""
      sre:
        color: "#7c3aed"
        description: "SRE investigation or triage"
```

Key xfg merge semantics:

- `features` and `portsAttributes` are objects — new keys merge alongside template's existing keys
- `mounts` uses `$arrayMerge: append` with `values` syntax to append to the template's mount list without affecting sibling fields
- `extensions` uses `$arrayMerge: append` with `values` syntax to target the array specifically
- `repos` in pre-commit uses `$arrayMerge: append` with `values` syntax to add hooks after template's hooks
- `ignore` in yamllint is a string — replaces template value entirely (intended, we want the full ignore list)
- `ignorePaths` in renovate is an object merge adding the field to the template

No `protected-main-branch` group — spruyt-labs uses trunk-based development. This also means no `.github/CODEOWNERS` is synced.

`prOptions.merge: manual` is set for the initial migration so the large first xfg sync PR can be reviewed carefully. This can be changed to `merge: auto` after the migration is stable.

The `megalinter` group also syncs `lint.sh` (always updated) and `lint-config.sh` (createOnly). spruyt-labs does not have these files, so they will be created. If spruyt-labs has a task-based lint equivalent, it should be noted in the cleanup issues.

### 2. Add calver automerge disable to `.github/renovate/automerge.json5` (global)

Add to the packageRules array:

```json5
{
  description: "Disable automerge for calver packages (date-based versions are not true semver patches)",
  matchCurrentVersion: "/^20\\d{2}\\./",
  automerge: false,
}
```

This is a universal problem identified in spruyt-labs — calver packages masquerade as semver patches but represent potentially breaking date-based releases. Applies to all repos.

### 3. Add openclaw automerge disable to `.github/renovate/package-rules.json5` (scoped)

Add to the packageRules array:

```json5
{
  description: "Disable automerge for openclaw",
  matchRepositories: ["anthony-spruyt/spruyt-labs"],
  matchPackagePatterns: ["^(ghcr\\.io/)?openclaw"],
  automerge: false,
}
```

## Changes needed in spruyt-labs (tracked via GitHub issues)

These changes must be made in the spruyt-labs repository itself. Each should be tracked as a GitHub issue referencing this spec.

### Issue 1: Create `setup-devcontainer.sh`

The template's `post-create.sh` calls `setup-devcontainer.sh` after handling safe-chain, pre-commit, and claude-cli. spruyt-labs needs to create this file with its task-based tool installs:

```bash
#!/bin/bash
set -euo pipefail

# Install taskfile runner
curl -sSfL https://taskfile.dev/install.sh \
    | sudo sh -s -- -b /usr/local/bin

# Add safe-chain shims to PATH for task-based installs
export PATH="$HOME/.safe-chain/shims:$PATH"

# Install infrastructure tools via taskfiles
task install:kubectl-cli
task install:kustomize-cli
task install:helm-cli
task install:helmfile-cli
task install:helm-plugins
task install:cilium-cli
task install:hubble-cli
task install:talosctl-cli
task install:talhelper-cli
task install:flux-cli
task install:flux-capacitor
task install:age-cli
task install:velero-cli
task install:cnpg-plugin
task install:falcoctl-cli
```

Note: safe-chain, pre-commit init, and claude-cli install are handled by the template's `post-create.sh` and should be removed from spruyt-labs' setup.

### Issue 2: Update `.mega-linter.yml` to extend base config

The megalinter group syncs `.mega-linter-base.yml` (managed) and `.mega-linter.yml` (createOnly). Since spruyt-labs already has `.mega-linter.yml`, it won't be overwritten. It needs manual update to:

```yaml
EXTENDS: .mega-linter-base.yml
ENABLE_LINTERS:
  - TERRAFORM_TFLINT
FILTER_REGEX_EXCLUDE: '.*sops.*|.*/mcp\.json$|cluster/apps/openclaw/openclaw/app/workspace/|\.taskfiles/talos/scripts/'
REPOSITORY_SECRETLINT_ARGUMENTS:
  - "--secretlintignore"
  - ".secretlintignore"
EXCLUDED_DIRECTORIES:
  - .git
  - .output
  - clusterconfig
  - legacy
  - plans
  - talos
IGNORE_GITIGNORED_FILES: true
```

The base config provides: ACTION_ACTIONLINT, BASH_SHELLCHECK, BASH_SHFMT, JSON_JSONLINT, MARKDOWN_MARKDOWNLINT, REPOSITORY_GITLEAKS, REPOSITORY_SECRETLINT, REPOSITORY_TRIVY, SPELL_LYCHEE, YAML_YAMLLINT. spruyt-labs only needs to add TERRAFORM_TFLINT.

### Issue 3: Consolidate CI workflows into single `ci.yaml`

Replace the 5 standalone workflows with a single `ci.yaml` orchestrator:

- `lint.yaml` — replace with the shared reusable MegaLinter workflow from repo-operator
- `kubeconform.yaml` — convert to a local reusable workflow callable via `workflow_call`
- `kyverno-test.yaml` — convert to a local reusable workflow callable via `workflow_call`
- `terraform-validate.yaml` — convert to a local reusable workflow callable via `workflow_call`
- `flux-differ.yaml` — convert to a local reusable workflow callable via `workflow_call`

Add a `summary` job that aggregates all results for any future branch protection. The K8s/Terraform-specific reusable workflows live in spruyt-labs itself (not repo-operator) since they are repo-specific.

Delete the old standalone workflow files after migration.

### Issue 4: Delete orphaned `.github/renovate/` modular configs

Once spruyt-labs adopts the template `renovate.json5` (which extends `github>anthony-spruyt/repo-operator//.github/renovate/...`), the local `.github/renovate/` directory with its 8 modular config files becomes orphaned:

- `disabledDatasources.json5`
- `customManagers.json5`
- `groups.json5`
- `kubernetes.json5`
- `terraform.json5`
- `regex-managers.json5`
- `customDatasources.json5`
- `automerge.json5`

These should be deleted. The equivalent configs already exist in repo-operator's shared `.github/renovate/` directory.

### Issue 5: Migrate task-based lint to `lint.sh`

spruyt-labs has `task dev-env:lint` which calls `.taskfiles/dev-env/scripts/run-mega-linter.sh`. The template's `lint.sh` (synced by the megalinter group) supersedes this with a better implementation:

- Uses the custom MegaLinter image (`ghcr.io/anthony-spruyt/megalinter-container-images:latest`) instead of `oxsecurity/megalinter:v9`
- Supports `--ci` mode for GitHub Actions
- Configurable via `lint-config.sh`
- Handles bot commit skipping

Migration:

- Update `task dev-env:lint` to call `./lint.sh` instead of the custom script
- Delete `.taskfiles/dev-env/scripts/run-mega-linter.sh`
- The CI workflow (Issue 3) should call `./lint.sh --ci`

### Issue 6: Clean up replaced config files

After the first xfg sync lands, review and clean up any files that are now redundant or conflicting:

- Old `post-create.sh` content (safe-chain, pre-commit, claude-cli installs now handled by template)
- Old `devcontainer.json` inline `initializeCommand` (replaced by template's `initialize.sh`)
- Any other configs that the template now manages

## Files not affected by migration

These spruyt-labs-specific files are not managed by xfg and remain untouched:

- `.sops.yaml`, `.gitattributes` — SOPS encryption config
- `.tflint.hcl`, `.jscpd.json` — repo-specific linter configs
- `.mcp.json` — Claude MCP server config
- `Taskfile.yml`, `.taskfiles/` — task automation
- `DEVELOPMENT.md` — developer setup guide
- `.shellcheckrc` — createOnly, existing file preserved
- `.trivyignore.yaml` — createOnly, existing file preserved
- `.gitignore` — createOnly, existing file preserved

## Transition period

After the xfg sync PR lands but before cleanup issues are completed, both old and new configs will coexist in spruyt-labs:

- **CI workflows**: The new `ci.yaml` (createOnly) will be created alongside the existing 5 standalone workflows. This may cause duplicate CI runs until Issue 3 is completed. The old workflows should be deleted promptly.
- **Renovate**: The new `renovate.json5` (extending repo-operator's shared configs) will coexist with the old `.github/renovate/` modular configs. Since the new file replaces the old one (same path), Renovate will use the new config immediately. The old modular config directory becomes dead code until Issue 4 deletes it.
- **MegaLinter**: The new `.mega-linter-base.yml` will be created, but the existing `.mega-linter.yml` won't reference it until Issue 2 is completed. MegaLinter will continue using the existing `.mega-linter.yml` standalone config, so no disruption.

### Implicit behavioral changes from adopting standard templates

The template introduces standardizations that spruyt-labs did not previously have:

- **Devcontainer mounts**: Template adds `~/.ssh/allowed_signers` and `~/.ssh/known_hosts` bind mounts. These files must exist on the host machine or the devcontainer will fail to start. Verify these exist before merging.
- **Pre-commit `remove-tabs`**: Template adds `--whitespaces-count 2` arg. Minor formatting change.
- **Pre-commit `gitleaks`**: Template adds `--config .gitleaks.toml` arg. The `.gitleaks.toml` file will be created by the devcontainer group (`createOnly: true`), so this is safe.
- **Renovate `rebaseWhen`**: Changes from `"conflicted"` (rebase only on merge conflicts) to `"behind-base-branch"` (rebase whenever base branch updates). This is more aggressive and may increase CI load with more frequent Renovate PR rebases.
- **MegaLinter new linters**: The base config adds `BASH_SHFMT` (shell formatting) and `JSON_JSONLINT` (JSON validation) which spruyt-labs did not previously run. These could surface new lint failures on first run.

These are all caught during the manual PR review (enabled by `prOptions.merge: manual`).

## Execution order

1. Make repo-operator changes (config.yaml, automerge.json5, package-rules.json5)
2. Create GitHub issues in spruyt-labs for each cleanup task
3. Merge repo-operator changes — xfg sync creates PR in spruyt-labs
4. Complete spruyt-labs cleanup issues (setup-devcontainer.sh, megalinter, CI workflows, delete orphaned renovate configs, migrate task-based lint to lint.sh)
