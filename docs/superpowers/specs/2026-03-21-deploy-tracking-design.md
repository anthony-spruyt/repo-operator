# Deploy Tracking: Compare Against Last Successful Deploy

## Problem

The CI workflow skips `xfg-apply` when the current commit has no `src/` changes (`git diff HEAD~1 HEAD -- src/`). This only compares against the previous commit. If a prior commit changed `src/` but the production deployment was rejected (approval denied or timing), subsequent commits without `src/` changes silently skip the sync, losing the earlier changes.

## Solution

Track the last successfully deployed commit SHA in a GitHub Actions repository variable (`LAST_XFG_DEPLOY_SHA`). Compare `HEAD` against this SHA instead of `HEAD~1`.

## Changes

### 1. `xfg-plan` job: Change check step

Replace the current `git diff HEAD~1 HEAD -- src/` logic with:

- **Manual dispatch**: always `run_sync=true` (unchanged)
- **Variable not set** (first run): default to `run_sync=true`
- **Variable set**: `git diff --quiet $LAST_XFG_DEPLOY_SHA HEAD -- src/` to detect changes since last deploy

Update `fetch-depth` from `2` to `0` (full history) since the last deploy SHA may be many commits back.

### 2. `xfg-apply` job: Record deploy SHA

Add a step after the successful apply:

```yaml
- name: "Record deploy SHA"
  env:
    GH_TOKEN: "${{ github.token }}"
  run: gh variable set LAST_XFG_DEPLOY_SHA --body "${{ github.sha }}"
```

Runs only on success (default step behavior). No `if:` condition needed.

### 3. Permissions

No changes required. The workflow already has `actions: write` which covers repository variable writes via `GITHUB_TOKEN`.

## Edge Cases

| Scenario                         | Behavior                                                   |
| -------------------------------- | ---------------------------------------------------------- |
| First run (no variable set)      | Defaults to `run_sync=true`                                |
| Deploy rejected at approval gate | Variable not updated; next run still diffs against old SHA |
| `src/` changes later reverted    | Diff shows no changes vs last deploy; correctly skips      |
| Multiple commits between deploys | All `src/` changes captured in the diff                    |

## Rejected Alternatives

- **Git tag (`last-xfg-deploy`)**: Requires force-push and may conflict with tag signing rulesets when re-enabled
- **GitHub Deployments API**: Multiple API calls with pagination, complex shell scripting, couples to deployment status semantics
