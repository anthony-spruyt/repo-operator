# Deploy Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compare `src/` changes against the last successful production deploy instead of `HEAD~1`, so rejected deploys don't cause subsequent runs to skip the sync.

**Architecture:** Store the last deployed SHA in a GitHub Actions repository variable (`LAST_XFG_DEPLOY_SHA`). The `xfg-plan` job diffs against this variable. The `xfg-apply` job updates it after a successful deploy using a GitHub App token.

**Tech Stack:** GitHub Actions, GitHub CLI (`gh`), `actions/create-github-app-token`

**Spec:** `docs/superpowers/specs/2026-03-21-deploy-tracking-design.md`

---

### Task 1: Update `xfg-plan` change detection

**Files:**

- Modify: `.github/workflows/ci.yaml:57-73`

- [ ] **Step 1: Update `fetch-depth` in xfg-plan checkout**

Change line 60 from `fetch-depth: 2` to `fetch-depth: 0`:

```yaml
- name: "Checkout"
  uses: "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd" # v6
  with:
    fetch-depth: 0
```

- [ ] **Step 2: Replace the change check step**

Replace the "Check for src/ changes" step (lines 62-73) with:

```yaml
- name: "Check for src/ changes since last deploy"
  id: "changes"
  run: |
    if [ "${{ github.event_name }}" = "workflow_dispatch" ]; then
      echo "::notice::Manual dispatch - forcing sync"
      echo "run_sync=true" >> "$GITHUB_OUTPUT"
    elif [ -z "${{ vars.LAST_XFG_DEPLOY_SHA }}" ]; then
      echo "::notice::No prior deploy recorded - forcing sync"
      echo "run_sync=true" >> "$GITHUB_OUTPUT"
    elif ! git cat-file -e "${{ vars.LAST_XFG_DEPLOY_SHA }}" 2>/dev/null; then
      echo "::notice::Prior deploy SHA not found in history - forcing sync"
      echo "run_sync=true" >> "$GITHUB_OUTPUT"
    elif git diff --quiet "${{ vars.LAST_XFG_DEPLOY_SHA }}" HEAD -- src/; then
      echo "::notice::No changes in src/ since last deploy, skipping sync"
      echo "run_sync=false" >> "$GITHUB_OUTPUT"
    else
      echo "run_sync=true" >> "$GITHUB_OUTPUT"
    fi
```

- [ ] **Step 3: Update the concurrency comment**

Replace lines 46-47:

```yaml
# IMPORTANT: Must be false - canceling a run with src/ changes
# followed by a run without changes would skip the sync
```

With:

```yaml
# IMPORTANT: Must be false to serialize deploys and avoid redundant syncs
```

- [ ] **Step 4: Validate YAML syntax**

Run: `npx prettier --check .github/workflows/ci.yaml`
Expected: file passes formatting check

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "feat(ci): compare src/ changes against last deploy SHA

Replace HEAD~1 diff with comparison against LAST_XFG_DEPLOY_SHA
variable. Handles missing variable, unreachable SHA, and manual
dispatch. Uses full git history (fetch-depth: 0) since last deploy
may be many commits back."
```

---

### Task 2: Add deploy SHA recording to `xfg-apply`

**Files:**

- Modify: `.github/workflows/ci.yaml:100-116`

- [ ] **Step 1: Add app token generation step after "Apply Sync"**

After the "Apply Sync" step (line 116), add:

```yaml
- name: "Generate app token"
  id: "app-token"
  uses: "actions/create-github-app-token@f8d387b68d61c58ab83c6c016672934102569859" # v3
  with:
    app-id: "${{ vars.APP_ID }}"
    private-key: "${{ secrets.APP_PRIVATE_KEY }}"

- name: "Record deploy SHA"
  env:
    GH_TOKEN: "${{ steps.app-token.outputs.token }}"
  run: gh variable set LAST_XFG_DEPLOY_SHA --body "${{ github.sha }}"
```

- [ ] **Step 2: Validate YAML syntax**

Run: `npx prettier --check .github/workflows/ci.yaml`
Expected: file passes formatting check

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yaml
git commit -m "feat(ci): record deploy SHA after successful xfg-apply

Use GitHub App token to write LAST_XFG_DEPLOY_SHA variable after
a successful deploy. This enables accurate change detection across
rejected or delayed deployments."
```

---

### Task 3: Bootstrap the variable

**Prerequisites:** Tasks 1-2 must be merged and a successful deploy must run to populate the variable. Until then, the empty-variable fallback ensures sync runs.

- [ ] **Step 1: Verify GitHub App has `variables: write` permission**

Check the App's permissions at `https://github.com/settings/apps` and ensure the "Variables" repository permission is set to "Read and write". If not, update it.

- [ ] **Step 2: Merge and verify first run**

After merging, trigger a workflow run (push or manual dispatch). Verify:

1. `xfg-plan` logs show "No prior deploy recorded - forcing sync"
2. `xfg-apply` succeeds and the "Record deploy SHA" step completes
3. The `LAST_XFG_DEPLOY_SHA` variable appears in repo settings with the correct SHA

- [ ] **Step 3: Verify subsequent run without `src/` changes**

Trigger another workflow run (e.g., push a non-`src/` change). Verify:

1. `xfg-plan` logs show "No changes in src/ since last deploy, skipping sync"
2. `xfg-apply` is skipped
