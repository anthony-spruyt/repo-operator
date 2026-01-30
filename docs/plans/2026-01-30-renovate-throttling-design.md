# Renovate Throttling Design

## Problem

The `container-images` repository consumed all 2000 free GitHub Actions minutes in a month due to frequent Renovate PRs. Each PR triggers CI which builds Docker images (expensive).

Main offenders:

- `renovate` npm package: 10+ updates in 5 days
- GitHub Actions digest updates (`docker/login-action`, `actions/attest-build-provenance`): 8+ updates in 5 days
- Various other high-frequency packages

## Solution

Two-tier approach:

1. **Global conservative defaults** - Throttle high-frequency packages for all repos
2. **Container-images aggressive throttling** - Batch all non-major updates weekly

## Design

### Global Changes

Add to `.github/renovate/package-rules.json5`:

```json5
{
  description: "Limit GitHub Actions digest updates to weekly and group them",
  matchManagers: ["github-actions"],
  matchUpdateTypes: ["digest"],
  schedule: ["before 9am on monday"],
  groupName: "github-actions-digest",
  group: { commitMessageTopic: "GitHub Actions digest updates" },
}
```

This complements the existing renovate CLI weekly rule.

### Container-Images Specific

Add to `src/config.yaml` under container-images repo:

```yaml
.github/renovate/package-rules.json5:
  content:
    packageRules:
      $arrayMerge: append
      - description: "Weekly batch for all non-major updates in container-images"
        matchUpdateTypes: ["minor", "patch", "digest", "pin", "pinDigest"]
        schedule: ["before 9am on monday"]
        groupName: "weekly-dependencies"
        group: { commitMessageTopic: "weekly dependency updates" }
```

## Expected Impact

| Metric                      | Before | After |
| --------------------------- | ------ | ----- |
| container-images PRs/week   | ~20-30 | ~1-3  |
| Other repos digest PRs/week | ~5-10  | ~1    |

## Implementation Steps

1. Edit `.github/renovate/package-rules.json5` - add GitHub Actions digest rule
2. Edit `src/config.yaml` - add container-images override
3. Commit and push
4. xfg syncs changes to all repos
5. Verify Renovate Dashboard shows new schedule
