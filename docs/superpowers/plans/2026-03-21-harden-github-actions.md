# Harden GitHub Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden all managed repos against GitHub Actions supply chain attacks per issue #80.

**Architecture:** Five changes applied to repo-operator's Renovate config, reusable workflows, xfg config, and templates. Each task produces one commit. No tests — this is infrastructure config only.

**Important:** Tasks must be applied in order. Tasks 2 and 5 modify the same workflow files; Tasks 3 and 4 modify the same config file. Line numbers reference the state **after** all prior tasks have been applied. Use the content-based descriptions (e.g., "before the `- name: Checkout` step") as the primary guide, not line numbers.

**Tech Stack:** GitHub Actions YAML, Renovate JSON5, xfg config YAML

**Spec:** `docs/superpowers/specs/2026-03-21-harden-github-actions-design.md`

---

### Task 1: Add Renovate SHA pinning preset

**Files:**

- Modify: `.github/renovate/base.json5`

- [ ] **Step 1: Add `helpers:pinGitHubActionDigests` to extends array**

In `.github/renovate/base.json5`, add the preset after `"docker:enableMajor"`:

```json5
  extends: [
    "config:recommended",
    "docker:enableMajor",
    "helpers:pinGitHubActionDigests",
    ":dependencyDashboard",
    ":disableRateLimiting",
    ":semanticCommits",
    ":enablePreCommit",
    ":separatePatchReleases"
  ],
```

- [ ] **Step 2: Verify lint passes**

Run: `npx prettier --check .github/renovate/base.json5`
Expected: file passes prettier check

- [ ] **Step 3: Commit**

```bash
git add .github/renovate/base.json5
git commit -m "feat: add Renovate SHA pinning for GitHub Actions (#80)"
```

---

### Task 2: Add permissions to reusable workflows

**Files:**

- Modify: `.github/workflows/_trivy-scan.yaml`
- Modify: `.github/workflows/_lint.yaml`
- Modify: `.github/workflows/_summary.yaml`

- [ ] **Step 1: Add permissions to `_trivy-scan.yaml`**

Add a `permissions:` block between the `on:` block and `jobs:`, preserving blank line separation:

```yaml
on:
  workflow_call:
    inputs:
      # ... existing inputs unchanged ...
      default: "fs"

permissions:
  contents: read
  issues: write

jobs:
```

- [ ] **Step 2: Add permissions to `_lint.yaml`**

Add a `permissions:` block between the `on:` block and `jobs:`, preserving blank line separation:

```yaml
on:
  workflow_call:

permissions:
  contents: read
  security-events: write

jobs:
```

- [ ] **Step 3: Add permissions to `_summary.yaml`**

Add a `permissions:` block between the `on:` block and `jobs:`, preserving blank line separation:

```yaml
on:
  workflow_call:

permissions:
  contents: read

jobs:
```

- [ ] **Step 4: Verify lint passes**

Run: `npx prettier --check .github/workflows/_trivy-scan.yaml .github/workflows/_lint.yaml .github/workflows/_summary.yaml`
Expected: all files pass

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/_trivy-scan.yaml .github/workflows/_lint.yaml .github/workflows/_summary.yaml
git commit -m "feat: add least-privilege permissions to reusable workflows (#80)"
```

---

### Task 3: Add CODEOWNERS template and config

**Files:**

- Create: `src/templates/.github/CODEOWNERS`
- Modify: `src/config.yaml` (protected-main-branch group)

- [ ] **Step 1: Create CODEOWNERS template**

Create `src/templates/.github/CODEOWNERS` with the following content (ensure file ends with a trailing newline):

```
# Protect CI/CD configuration from unauthorized changes
.github/workflows/ @anthony-spruyt
.github/actions/   @anthony-spruyt
```

- [ ] **Step 2: Add files section to protected-main-branch group**

In `src/config.yaml`, change the `protected-main-branch` group (line 399) from:

```yaml
protected-main-branch:
  settings:
```

to:

```yaml
protected-main-branch:
  files:
    .github/CODEOWNERS:
      content: "@templates/.github/CODEOWNERS"
  settings:
```

- [ ] **Step 3: Verify lint passes**

Run: `npx prettier --check src/config.yaml`
Expected: passes

- [ ] **Step 4: Commit**

```bash
git add src/templates/.github/CODEOWNERS src/config.yaml
git commit -m "feat: add CODEOWNERS template to protected-main-branch group (#80)"
```

---

### Task 4: Enable CODEOWNERS review enforcement with Renovate bypass

**Files:**

- Modify: `src/config.yaml` (protected-main-branch group, pr-rules section)

**Note:** Task 3 added 3 lines to this group. The `bypassActors` and `requireCodeOwnerReview` fields are now ~3 lines lower than the original file.

- [ ] **Step 1: Add Renovate as bypass actor for pr-rules**

In `src/config.yaml`, find `bypassActors: []` inside the `protected-main-branch` > `settings` > `rulesets` > `pr-rules` section, and change:

```yaml
bypassActors: []
```

to:

```yaml
bypassActors:
  - actorId: 2740
    actorType: Integration
    bypassMode: always
```

- [ ] **Step 2: Enable requireCodeOwnerReview**

In the same `pr-rules` section, find `requireCodeOwnerReview: false` and change to:

```yaml
requireCodeOwnerReview: true
```

- [ ] **Step 3: Verify lint passes**

Run: `npx prettier --check src/config.yaml`
Expected: passes

- [ ] **Step 4: Commit**

```bash
git add src/config.yaml
git commit -m "feat: enable CODEOWNERS review enforcement with Renovate bypass (#80)"
```

---

### Task 5: Add StepSecurity harden-runner

**Files:**

- Modify: `.github/workflows/_lint.yaml`
- Modify: `.github/workflows/_trivy-scan.yaml`
- Modify: `.github/workflows/_summary.yaml`
- Modify: `.github/workflows/ci.yaml`

The harden-runner step to add as the **first step** in each job:

```yaml
- name: Harden Runner
  uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2.16.0
  with:
    egress-policy: audit
```

**Note:** Task 2 added `permissions:` blocks to `_lint.yaml`, `_trivy-scan.yaml`, and `_summary.yaml`. Use content-based references below, not original line numbers.

- [ ] **Step 1: Add harden-runner to `_lint.yaml`**

Add as the first step in the `lint` job, immediately before the existing `- name: Checkout` step:

```yaml
- name: Harden Runner
  uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2.16.0
  with:
    egress-policy: audit
```

- [ ] **Step 2: Add harden-runner to `_trivy-scan.yaml`**

Add as the first step in the `scan` job, immediately before the existing `- name: Checkout` step:

```yaml
- name: Harden Runner
  uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2.16.0
  with:
    egress-policy: audit
```

- [ ] **Step 3: Add harden-runner to `_summary.yaml`**

Add as the first step in the `summary` job, immediately before the existing `- name: Check job results` step:

```yaml
- name: Harden Runner
  uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2.16.0
  with:
    egress-policy: audit
```

- [ ] **Step 4: Add harden-runner to repo-operator `ci.yaml` — `xfg-plan` job**

Add as the first step in the `xfg-plan` job, immediately before the existing `- name: "Checkout"` step:

```yaml
- name: Harden Runner
  uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2.16.0
  with:
    egress-policy: audit
```

- [ ] **Step 5: Add harden-runner to repo-operator `ci.yaml` — `xfg-apply` job**

Add as the first step in the `xfg-apply` job, immediately before the existing `- name: "Checkout"` step:

```yaml
- name: Harden Runner
  uses: step-security/harden-runner@fa2e9d605c4eeb9fcad4c99c224cee0c6c7f3594 # v2.16.0
  with:
    egress-policy: audit
```

- [ ] **Step 6: Verify lint passes**

Run: `npx prettier --check .github/workflows/_lint.yaml .github/workflows/_trivy-scan.yaml .github/workflows/_summary.yaml .github/workflows/ci.yaml`
Expected: all files pass

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/_lint.yaml .github/workflows/_trivy-scan.yaml .github/workflows/_summary.yaml .github/workflows/ci.yaml
git commit -m "feat: add StepSecurity harden-runner in audit mode (#80)"
```
