# Spruyt-Labs Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fully migrate spruyt-labs into repo-operator's xfg configuration system by enabling all standard groups with content overrides, adding global/scoped Renovate rules, and creating GitHub issues in spruyt-labs for follow-up cleanup.

**Architecture:** Three files are modified in repo-operator (config.yaml, automerge.json5, package-rules.json5). After merging, xfg sync will create a PR in spruyt-labs with all the synced config files. Follow-up cleanup in spruyt-labs is tracked via GitHub issues created as part of this plan.

**Tech Stack:** xfg (YAML config sync), Renovate (JSON5), GitHub CLI (issue creation)

**Spec:** `docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md`

---

### Task 1: Add calver automerge disable rule (global)

**Files:**

- Modify: `.github/renovate/automerge.json5:49-55`

- [ ] **Step 1: Add calver rule to automerge.json5**

Add the calver automerge disable rule to the package-specific overrides section, before the closing of the rook-ceph rule. This is a global rule — it applies to all repos.

In `.github/renovate/automerge.json5`, replace:

```json5
// ============ Package-specific overrides ============
{
  description: "Disable automerge for rook-ceph (critical storage component)",
  matchPackagePatterns: ["^(ghcr\\.io/)?rook(/|-)ceph"],
  automerge: false,
}
```

With:

```json5
    // ============ Package-specific overrides ============
    {
      description: "Disable automerge for calver packages (date-based versions are not true semver patches)",
      matchCurrentVersion: "/^20\\d{2}\\./",
      automerge: false
    },
    {
      description: "Disable automerge for rook-ceph (critical storage component)",
      matchPackagePatterns: ["^(ghcr\\.io/)?rook(/|-)ceph"],
      automerge: false
    }
```

- [ ] **Step 2: Verify the file is valid JSON5**

Run: `npx json5 .github/renovate/automerge.json5`
Expected: Parses without error (or use `cat` to visually inspect structure)

- [ ] **Step 3: Commit**

```bash
git add .github/renovate/automerge.json5
git commit -m "feat(renovate): disable automerge for calver packages

Calver packages use date-based versions that masquerade as semver
patches but may contain breaking changes. Applies globally to all repos."
```

---

### Task 2: Add openclaw automerge disable rule (scoped to spruyt-labs)

**Files:**

- Modify: `.github/renovate/package-rules.json5:139-145`

- [ ] **Step 1: Add openclaw rule to package-rules.json5**

Add the openclaw automerge disable rule at the end of the packageRules array, scoped to spruyt-labs only.

In `.github/renovate/package-rules.json5`, replace:

```json5
    {
      matchManagers: ["custom.regex"],
      matchFileNames: ["talos/**"],
      labels: ["renovate/talos"],
      minimumReleaseAge: "3 days"
    }
  ]
}
```

With:

```json5
    {
      matchManagers: ["custom.regex"],
      matchFileNames: ["talos/**"],
      labels: ["renovate/talos"],
      minimumReleaseAge: "3 days"
    },

    // ============ Repo-specific overrides ============
    {
      description: "Disable automerge for openclaw",
      matchRepositories: ["anthony-spruyt/spruyt-labs"],
      matchPackagePatterns: ["^(ghcr\\.io/)?openclaw"],
      automerge: false
    }
  ]
}
```

- [ ] **Step 2: Verify the file is valid JSON5**

Run: `npx json5 .github/renovate/package-rules.json5`
Expected: Parses without error

- [ ] **Step 3: Commit**

```bash
git add .github/renovate/package-rules.json5
git commit -m "feat(renovate): disable automerge for openclaw in spruyt-labs"
```

---

### Task 3: Replace spruyt-labs entry in config.yaml

**Files:**

- Modify: `src/config.yaml:81-127`

- [ ] **Step 1: Replace the spruyt-labs entry**

In `src/config.yaml`, replace the entire spruyt-labs block (lines 81-127):

```yaml
- git: https://github.com/anthony-spruyt/spruyt-labs.git
  groups:
    # - devcontainer
    # - github-ci
    # - github-trivy
    # - renovate
    # - pre-commit
    # - megalinter
    - private-repo
  # prOptions:
  #   merge: manual
  # files:
  #   .github/renovate.json5:
  #     content:
  #       ignorePaths: ["talos/helmfile"]
  files:
    inherit: false
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

With:

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

- [ ] **Step 2: Validate YAML syntax**

Run: `yamllint -d relaxed src/config.yaml`
Expected: No errors (warnings about line length are acceptable)

- [ ] **Step 3: Commit**

```bash
git add src/config.yaml
git commit -m "feat: fully migrate spruyt-labs into repo-operator

Enable all standard groups (devcontainer, github-ci, github-trivy,
renovate, pre-commit, megalinter, private-repo) with xfg content
overrides for repo-specific needs.

Uses merge: manual for safe initial migration review."
```

---

### Task 4: Run linter to validate all changes

- [ ] **Step 1: Run MegaLinter locally**

Run: `./lint.sh`
Expected: All checks pass. Pay attention to YAML and JSON5 linting.

- [ ] **Step 2: Fix any lint issues found**

If lint fails, fix the issues and amend the relevant commit.

---

### Task 5: Create GitHub issues in spruyt-labs

Create 6 issues in spruyt-labs for follow-up cleanup work. Each issue should reference the design spec.

- [ ] **Step 1: Create Issue 1 — setup-devcontainer.sh**

```bash
gh issue create --repo anthony-spruyt/spruyt-labs \
  --title "Create setup-devcontainer.sh for repo-operator migration" \
  --body "$(cat <<'EOF'
## Context

As part of the repo-operator migration ([spec](https://github.com/anthony-spruyt/repo-operator/blob/main/docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md)), the template `post-create.sh` now handles safe-chain, pre-commit, and claude-cli installation. Repo-specific tool installs should move to `setup-devcontainer.sh`.

## Task

Create `.devcontainer/setup-devcontainer.sh` with task-based tool installs:

- Install taskfile runner
- Run all `task install:*` commands (kubectl, kustomize, helm, helmfile, helm-plugins, cilium, hubble, talosctl, talhelper, flux, flux-capacitor, age, velero, cnpg-plugin, falcoctl)
- Remove duplicated setup from `post-create.sh` (safe-chain, pre-commit init, claude-cli are now handled by template)
EOF
)"
```

- [ ] **Step 2: Create Issue 2 — MegaLinter base config**

```bash
gh issue create --repo anthony-spruyt/spruyt-labs \
  --title "Update .mega-linter.yml to extend base config" \
  --body "$(cat <<'EOF'
## Context

As part of the repo-operator migration ([spec](https://github.com/anthony-spruyt/repo-operator/blob/main/docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md)), the megalinter group syncs `.mega-linter-base.yml` (managed). The existing `.mega-linter.yml` needs to be updated to extend the base config.

## Task

Update `.mega-linter.yml` to:
- Add `EXTENDS: .mega-linter-base.yml`
- Remove linters already in base (keep only `TERRAFORM_TFLINT` as addition)
- Keep repo-specific settings: `FILTER_REGEX_EXCLUDE`, `EXCLUDED_DIRECTORIES`, `REPOSITORY_SECRETLINT_ARGUMENTS`, `IGNORE_GITIGNORED_FILES`

Base provides: ACTION_ACTIONLINT, BASH_SHELLCHECK, BASH_SHFMT, JSON_JSONLINT, MARKDOWN_MARKDOWNLINT, REPOSITORY_GITLEAKS, REPOSITORY_SECRETLINT, REPOSITORY_TRIVY, SPELL_LYCHEE, YAML_YAMLLINT
EOF
)"
```

- [ ] **Step 3: Create Issue 3 — CI workflow consolidation**

```bash
gh issue create --repo anthony-spruyt/spruyt-labs \
  --title "Consolidate CI workflows into single ci.yaml" \
  --body "$(cat <<'EOF'
## Context

As part of the repo-operator migration ([spec](https://github.com/anthony-spruyt/repo-operator/blob/main/docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md)), the template creates `ci.yaml` as a single orchestrator that calls reusable workflows.

## Task

1. Convert standalone workflows to local reusable workflows callable via `workflow_call`:
   - `kubeconform.yaml`
   - `kyverno-test.yaml`
   - `terraform-validate.yaml`
   - `flux-differ.yaml`
2. Update `ci.yaml` to call:
   - Shared lint workflow from repo-operator (using `./lint.sh --ci`)
   - The 4 local reusable workflows above
   - Trivy scan workflow from repo-operator
3. Add `summary` job to aggregate results
4. Delete old standalone `lint.yaml` workflow
5. Delete old standalone workflow files after confirming ci.yaml works

**Important:** During transition, both old and new workflows may run simultaneously. Delete old workflows promptly to avoid duplicate runs.
EOF
)"
```

- [ ] **Step 4: Create Issue 4 — Delete orphaned renovate configs**

```bash
gh issue create --repo anthony-spruyt/spruyt-labs \
  --title "Delete orphaned .github/renovate/ modular configs" \
  --body "$(cat <<'EOF'
## Context

As part of the repo-operator migration ([spec](https://github.com/anthony-spruyt/repo-operator/blob/main/docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md)), spruyt-labs now uses the template `renovate.json5` which extends `github>anthony-spruyt/repo-operator//.github/renovate/...`.

## Task

Delete the local `.github/renovate/` directory containing 8 orphaned modular config files:
- `disabledDatasources.json5`
- `customManagers.json5`
- `groups.json5`
- `kubernetes.json5`
- `terraform.json5`
- `regex-managers.json5`
- `customDatasources.json5`
- `automerge.json5`

These are no longer referenced. The equivalent configs exist in repo-operator's shared `.github/renovate/` directory.
EOF
)"
```

- [ ] **Step 5: Create Issue 5 — Migrate task-based lint**

```bash
gh issue create --repo anthony-spruyt/spruyt-labs \
  --title "Migrate task-based lint to repo-operator lint.sh" \
  --body "$(cat <<'EOF'
## Context

As part of the repo-operator migration ([spec](https://github.com/anthony-spruyt/repo-operator/blob/main/docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md)), the megalinter group syncs `lint.sh` and `lint-config.sh` which replace the custom `run-mega-linter.sh` script.

## Task

1. Update `task dev-env:lint` in `.taskfiles/dev-env/tasks.yaml` to call `./lint.sh` instead of `bash {{ .devEnvScriptsDir }}/run-mega-linter.sh`
2. Delete `.taskfiles/dev-env/scripts/run-mega-linter.sh`
3. The CI workflow (Issue 3) should use `./lint.sh --ci`

The new `lint.sh` improvements:
- Uses custom MegaLinter image (`ghcr.io/anthony-spruyt/megalinter-container-images:latest`)
- Supports `--ci` mode for GitHub Actions
- Handles bot commit skipping
- Configurable via `lint-config.sh`
EOF
)"
```

- [ ] **Step 6: Create Issue 6 — Clean up replaced config files**

```bash
gh issue create --repo anthony-spruyt/spruyt-labs \
  --title "Clean up config files replaced by repo-operator migration" \
  --body "$(cat <<'EOF'
## Context

As part of the repo-operator migration ([spec](https://github.com/anthony-spruyt/repo-operator/blob/main/docs/superpowers/specs/2026-03-21-spruyt-labs-migration-design.md)), several config files are now managed by repo-operator templates.

## Task

Review and clean up files that are now redundant or conflicting after the xfg sync PR lands:

- Old `post-create.sh` content — safe-chain, pre-commit, claude-cli installs are now handled by template's `post-create.sh`. Remove duplicated logic.
- Old `devcontainer.json` inline `initializeCommand` — replaced by template's `initialize.sh`. The devcontainer.json will be synced by xfg with the correct `initializeCommand` pointing to the script.
- Review any other configs that the template now manages for conflicts.
EOF
)"
```

- [ ] **Step 7: Commit (no code change, just record issue creation)**

No commit needed — issues are created in the spruyt-labs repo, not in repo-operator.

---

### Task 6: Final verification

- [ ] **Step 1: Review all changes**

Run: `git diff main --stat` and `git log --oneline main..HEAD`
Expected: 3 commits modifying 3 files:

- `.github/renovate/automerge.json5` — calver rule
- `.github/renovate/package-rules.json5` — openclaw rule
- `src/config.yaml` — spruyt-labs full migration

- [ ] **Step 2: Verify issue creation**

Run: `gh issue list --repo anthony-spruyt/spruyt-labs --state open --search "repo-operator migration"`
Expected: 6 open issues

- [ ] **Step 3: Verify config.yaml structure**

Run: `yamllint -d relaxed src/config.yaml`
Expected: No errors
