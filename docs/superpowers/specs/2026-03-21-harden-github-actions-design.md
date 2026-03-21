# Harden GitHub Actions Across All Managed Repos

**Issue:** [#80](https://github.com/anthony-spruyt/repo-operator/issues/80)
**Date:** 2026-03-21
**Severity:** High (Security)

## Context

The Trivy supply chain compromise (March 2026) exploited mutable git tags on GitHub Actions. Attackers force-pushed 75 tags to inject infostealer payloads. This design hardens all managed repos against similar attacks through SHA pinning, least-privilege permissions, code ownership enforcement, and runtime monitoring.

## Changes

### 1. Renovate: Pin GitHub Actions to SHAs

**File:** `.github/renovate/base.json5`

Add `helpers:pinGitHubActionDigests` to the `extends` array. Renovate will auto-create PRs converting tag-referenced actions to SHA pins across all managed repos, and keep them updated.

Existing `automerge.json5` automerges `pin` and `digest` update types, and `package-rules.json5` groups digest updates weekly with a 2-day minimum release age for github-actions. The preset produces `pin` updates (initial SHA pinning) and `digest` updates (subsequent SHA changes) — both already covered.

**Expected behavior after rollout:**

- Initial wave of "pin" PRs across all managed repos converting tag refs to SHAs
- Subsequent digest updates grouped weekly per existing package rules
- Major/minor/patch version bumps continue as separate PRs with labels

### 2. Permissions on Reusable Workflows

**Files:** `_lint.yaml`, `_trivy-scan.yaml`, `_summary.yaml`

Add explicit least-privilege `permissions` blocks as defense-in-depth. Reusable workflows can only downgrade (not elevate) permissions from the caller.

| Workflow           | Permissions                                | Reason                                                                                      |
| ------------------ | ------------------------------------------ | ------------------------------------------------------------------------------------------- |
| `_trivy-scan.yaml` | `contents: read`, `issues: write`          | Checkout + create/update vulnerability issues                                               |
| `_lint.yaml`       | `contents: read`, `security-events: write` | Checkout + SARIF upload to GitHub Security                                                  |
| `_summary.yaml`    | `contents: read`                           | Token can list jobs within its own run implicitly; `contents: read` is a safe minimal scope |

**Note on `_summary.yaml`:** The `gh api repos/$REPO/actions/runs/$RUN_ID/jobs` call technically uses the Actions API, but GitHub allows a token to access its own workflow run's jobs without explicit `actions: read`. Verified working in production with callers that don't grant `actions`. Using `contents: read` avoids requiring caller workflow changes.

**Caller workflow verification:**

- `src/templates/.github/workflows/ci.yaml` grants `contents: write`, `pull-requests: write`, `security-events: write`, `statuses: write` — superset, reusable workflows downgrade correctly.
- `src/templates/.github/workflows/trivy-scan.yaml` grants `contents: read`, `issues: write` — exact match.
- Repo-operator's own `.github/workflows/ci.yaml` grants the same superset as the template — correct.
- No caller changes required — all callers already grant sufficient permissions.

### 3. CODEOWNERS Template

**New file:** `src/templates/.github/CODEOWNERS`
**Config change:** `src/config.yaml` — add `files` section to `protected-main-branch` group

Content:

```
.github/workflows/ @anthony-spruyt
.github/actions/   @anthony-spruyt
```

Force-synced (no `createOnly`) so repos always get the latest version. Repos can opt out via per-repo `files: { .github/CODEOWNERS: false }` overrides.

**Scope:** Repos using `protected-main-branch` group: claude-config, container-images, xfg. Repo-operator excluded (trunk-based, manages its own rulesets).

### 4. Enable CODEOWNERS Review Enforcement

**File:** `src/config.yaml` — `protected-main-branch` group ruleset

Change `requireCodeOwnerReview: false` to `requireCodeOwnerReview: true`.

PRs touching `.github/workflows/` or `.github/actions/` in repos using `protected-main-branch` will require review from `@anthony-spruyt`. Since `requiredApprovingReviewCount` is `0`, only CODEOWNERS-matched paths require approval.

Add the Renovate GitHub App (ID: `2740`, type: `Integration`) as a bypass actor for the `pr-rules` ruleset in `protected-main-branch`, so Renovate can continue to automerge workflow digest/pin updates without manual CODEOWNERS approval:

```yaml
bypassActors:
  - actorId: 2740
    actorType: Integration
    bypassMode: always
```

### 5. StepSecurity Harden-Runner

**Files:** `_lint.yaml`, `_trivy-scan.yaml`, `_summary.yaml`, `.github/workflows/ci.yaml`

Add `step-security/harden-runner` (SHA-pinned) as the first step in every job that has inline steps:

- Reusable workflows: `_lint.yaml`, `_trivy-scan.yaml`, `_summary.yaml`
- Repo-operator inline jobs: `xfg-plan`, `xfg-apply`

Starting with `egress-policy: audit` to baseline allowed endpoints. Future follow-up can tighten to `block` (note: `_lint.yaml` will be the most complex to transition due to MegaLinter Docker pulls).

Calling workflow templates (`src/templates/.github/workflows/ci.yaml`, `trivy-scan.yaml`) have no inline steps (only `uses:` calls), so no harden-runner there.

**Note:** Existing tag references in reusable workflows (e.g., `actions/checkout@v6` in `_trivy-scan.yaml`) are not manually pinned in this PR. Renovate will handle these automatically after item 1 rolls out.

## Rollout

Single PR with one commit per item. All items are additive security hardening with no functional behavior changes.

**Affected repos via sync:** claude-config, container-images, xfg (all 5 items)
**Affected directly:** repo-operator (items 1, 2, 5)
**Affected via Renovate only:** spruyt-labs (item 1)

## Not Covered (Manual)

Per issue #80:

- **firemerge** — `pull_request_target` fix needed (not managed by repo-operator)
- **gastown-dev** — same `pull_request_target` fix (gastown-dev#38)
- **SunGather** — permissions blocks needed (fork, not managed)
