# Deploy Tracking: Compare Against Last Successful Deploy

## Problem

The CI workflow skips `xfg-apply` when the current commit has no `src/` changes (`git diff HEAD~1 HEAD -- src/`). This only compares against the previous commit. If a prior commit changed `src/` but the production deployment was rejected (approval denied or timing), subsequent commits without `src/` changes silently skip the sync, losing the earlier changes.

## Solution

Track the last successfully deployed commit SHA in a GitHub Actions repository variable (`LAST_XFG_DEPLOY_SHA`). Compare `HEAD` against this SHA instead of `HEAD~1`.

## Changes

### 1. `xfg-plan` job: Change check step

Replace the current `git diff HEAD~1 HEAD -- src/` logic with:

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

Update `fetch-depth` from `2` to `0` (full history) since the last deploy SHA may be many commits back. The `xfg-apply` job's `fetch-depth` remains at `2` as it only runs the xfg action, not the diff.

### 2. `xfg-apply` job: Record deploy SHA

Generate a GitHub App installation token (since `GITHUB_TOKEN` cannot write repository variables) and use it to record the deployed SHA:

```yaml
- name: "Generate app token"
  id: "app-token"
  uses: "actions/create-github-app-token@<pinned-sha>"
  with:
    app-id: "${{ vars.APP_ID }}"
    private-key: "${{ secrets.APP_PRIVATE_KEY }}"

- name: "Record deploy SHA"
  env:
    GH_TOKEN: "${{ steps.app-token.outputs.token }}"
  run: gh variable set LAST_XFG_DEPLOY_SHA --body "${{ github.sha }}"
```

Runs only on success (default step behavior). No `if:` condition needed.

### 3. Permissions

`GITHUB_TOKEN` does not have a `variables` permission scope and cannot write repository variables. The GitHub App token (already used by the xfg action) is used instead via `actions/create-github-app-token`. The App must have the `variables: write` repository permission.

### 4. Concurrency note

Update the concurrency comment in `xfg-plan` to reflect the new behavior. With variable-based tracking, the concern about "canceling a run with src/ changes followed by a run without changes" is mitigated — both runs would correctly detect changes against the last deploy SHA. The `cancel-in-progress: false` is still correct to serialize deploys and avoid redundant syncs.

## Edge Cases

| Scenario                         | Behavior                                                                                                 |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- |
| First run (no variable set)      | Defaults to `run_sync=true`                                                                              |
| Deploy rejected at approval gate | Variable not updated; next run still diffs against old SHA                                               |
| `src/` changes later reverted    | Diff shows no changes vs last deploy; correctly skips                                                    |
| Multiple commits between deploys | All `src/` changes captured in the diff                                                                  |
| Stored SHA no longer in history  | `git cat-file -e` fails; defaults to `run_sync=true`                                                     |
| Concurrent runs queued           | Serialized by concurrency group; both detect changes correctly, second apply is redundant but idempotent |

## Rejected Alternatives

- **Git tag (`last-xfg-deploy`)**: Requires force-push and may conflict with tag signing rulesets when re-enabled
- **GitHub Deployments API**: Multiple API calls with pagination, complex shell scripting, couples to deployment status semantics
