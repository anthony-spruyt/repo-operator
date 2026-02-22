# CI Optimization Design

Reduce wasted GitHub Actions minutes by skipping jobs when changes don't affect them.

## Changes

### 1. Skip sync-config when src/ unchanged

**File:** `.github/workflows/ci.yaml`

Add a git diff check after checkout. Skip remaining steps if no `src/` changes.

```yaml
sync-config:
  name: "Sync Configuration"
  runs-on: "ubuntu-latest"
  needs:
    - "lint"
  if: "github.event_name == 'push'"
  concurrency:
    group: "config-sync"
    # IMPORTANT: Must be false - canceling a run with src/ changes
    # followed by a run without changes would skip the sync
    cancel-in-progress: false
  steps:
    - name: "Checkout"
      uses: "actions/checkout@v6"
      with:
        fetch-depth: 2 # Need previous commit for diff

    - name: "Check for src/ changes"
      id: "changes"
      run: |
        if git diff --quiet HEAD~1 HEAD -- src/; then
          echo "::notice::No changes in src/, skipping sync"
          echo "run_sync=false" >> "$GITHUB_OUTPUT"
        else
          echo "run_sync=true" >> "$GITHUB_OUTPUT"
        fi

    - name: "Generate GitHub App token"
      if: "steps.changes.outputs.run_sync == 'true'"
      id: "app-token"
      uses: "actions/create-github-app-token@v2"
      with:
        app-id: "${{ vars.APP_ID }}"
        private-key: "${{ secrets.APP_PRIVATE_KEY }}"

    - name: "Sync config"
      if: "steps.changes.outputs.run_sync == 'true'"
      uses: "anthony-spruyt/xfg@v2.2.1"
      with:
        config: "./src/config.yaml"
        github-app-token: "${{ steps.app-token.outputs.token }}"
```

**Key points:**

- `fetch-depth: 2` ensures previous commit is available for diff
- `git diff --quiet` exits 0 if no changes, 1 if changes
- Steps get `if:` conditions to skip when no src/ changes
- Job still "succeeds" for branch protection even when skipped
- `cancel-in-progress: false` prevents race condition where a no-change run cancels a with-change run

### 2. Exclude Claude files from MegaLinter

**File:** `src/templates/.mega-linter-base.yml`

Add exclusions for Claude-specific files and plan documents.

```yaml
EXCLUDED_DIRECTORIES:
  - ".git"
  - ".claude"
  - "docs/plans"

FILTER_REGEX_EXCLUDE: "(CLAUDE\\.md$)"
```

**What gets excluded:**

| Path           | Reason                                         |
| -------------- | ---------------------------------------------- |
| `.claude/`     | Claude Code configuration, not project code    |
| `docs/plans/`  | Auto-generated plan documents from skills      |
| `**/CLAUDE.md` | Project instructions for Claude, can be nested |

## Existing Optimizations

Already in place (no changes needed):

- **Bot commit skipping** - `lint.sh` line 21 skips linting for renovate[bot] and dependabot[bot]
- **Concurrency** - `cancel-in-progress: true` on lint job prevents duplicate runs

## Files to Modify

1. `.github/workflows/ci.yaml` - Add src/ change detection
2. `src/templates/.mega-linter-base.yml` - Add exclusions (synced to all repos)
