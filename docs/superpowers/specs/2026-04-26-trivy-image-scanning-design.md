# Centralized Trivy Container Image Scanning

## Problem

Daily Trivy scans only cover filesystem (dependencies, IaC misconfig, secrets). Repos that build container images (container-images, SunGather, spruyt-labs) need their published GHCR images scanned too. Currently container-images and SunGather have custom per-repo workflows for this. spruyt-labs has no image scanning despite building 4 images.

## Goals

- Centralize image scanning in repo-operator like fs scanning already is
- Auto-discover images from GHCR — no per-repo config files needed
- No-op for repos without images
- Per-image GitHub issues with severity-based labels
- Support per-image `.trivyignore` files (required for container-images)
- Migrate container-images and SunGather off custom workflows
- Align fs scan issue titles with image scan pattern (include severity counts)

## Architecture

### New reusable workflow: `_trivy-image-scan.yaml`

Location: `.github/workflows/_trivy-image-scan.yaml` in repo-operator

Trigger: `workflow_call` (no inputs)

Permissions: `contents: read`, `packages: read`, `issues: write`

#### Job 1: `discover-images`

- Query GHCR packages API: `GET /users/{owner}/packages?package_type=container`
- Filter packages by `repository.full_name` matching calling repo (`github.repository`)
- Output JSON array of image names
- Empty array = downstream jobs skip (no-op)

#### Job 2: `scan-images`

- Matrix over discovered images (`fail-fast: false`)
- Skip if discover-images output is empty
- Steps:
  1. Checkout repo (for trivyignore files)
  1. Login to GHCR
  1. Check image exists: `docker manifest inspect ghcr.io/<owner>/<image>:latest`
  1. Detect trivyignore: check `<image-name>/.trivyignore` first, fall back to `.trivyignore.yaml`, fall back to none
  1. Scan with `aquasecurity/trivy-action`: `image-ref: ghcr.io/<owner>/<image>:latest`, scanners: `vuln,secret,misconfig`, format: json, exit-code: 0
  1. Process results and manage per-image issue

#### Issue management

- Title pattern: `[Trivy] <image>: N critical, N high found` (dynamic severity counts)
- Title with only medium: `[Trivy] <image>: N medium found`
- Search existing open issues by `[Trivy] <image>:` prefix
- No vulns found → close existing issue with resolution comment
- Labels: `security`, `trivy`, plus severity labels (`critical`, `high`, `medium`) based on findings
- Update existing issue: remove stale severity labels, apply current ones
- Issue body: image ref, scan date, totals, CRITICAL/HIGH table, MEDIUM summary with link to workflow run

### Updated reusable workflow: `_trivy-scan.yaml`

- Change issue title from static `[Trivy] Security vulnerabilities found` to dynamic `[Trivy] repo: N critical, N high found`
- Align issue body format with image scan pattern for consistency

### Updated synced template: `trivy-scan.yaml`

```yaml
permissions:
  contents: read
  issues: write
  packages: read

jobs:
  fs-scan:
    uses: anthony-spruyt/repo-operator/.github/workflows/_trivy-scan.yaml@main
  image-scan:
    uses: anthony-spruyt/repo-operator/.github/workflows/_trivy-image-scan.yaml@main
```

Both jobs run in parallel. fs-scan always runs. image-scan is a no-op when no images found.

### xfg config changes (`repos.yaml`)

- **container-images**: Remove `createOnly: true` override for `.github/workflows/trivy-scan.yaml` so xfg overwrites the custom workflow with the synced template
- **SunGather**: No change needed — already uses synced template (gets updated automatically)
- **spruyt-labs**: No change needed — already has `github-trivy` group

### xfg config changes (`groups.yaml`)

- No changes needed — `github-trivy` group already syncs `trivy-scan.yaml`

## Per-image trivyignore support

The scan-images job detects trivyignore files with this priority:

1. `<image-name>/.trivyignore` — per-image ignore file (used by container-images)
1. `.trivyignore.yaml` — repo-level ignore file (synced by xfg)
1. No ignore file

This matches the existing container-images convention and is required for migration.

## Migration

### Existing issues

- container-images and SunGather already use `[Trivy] <image>:` title prefix
- New centralized workflow uses same prefix → picks up existing open issues seamlessly
- No duplicate issues created

### Workflow replacement

- container-images: xfg sync overwrites custom `trivy-scan.yaml` (remove `createOnly`)
- SunGather: xfg sync overwrites custom `trivy-scan.yaml` (already not `createOnly`)
- Both repos' custom image scanning code is replaced by centralized reusable workflow

### New coverage

- spruyt-labs gains image scanning for: `kata-tap-qdisc-fix`, `shutdown-orchestrator`, `agent-queue-worker`, `bull-board` (latter two from PR #1077)

## Repos affected

| Repo             | Current                    | After                      |
| ---------------- | -------------------------- | -------------------------- |
| container-images | Custom image scan workflow | Centralized (fs + image)   |
| SunGather        | Custom image scan workflow | Centralized (fs + image)   |
| spruyt-labs      | fs scan only               | Centralized (fs + image)   |
| claude-config    | fs scan only               | fs scan + no-op image scan |
| repo-operator    | fs scan only               | fs scan + no-op image scan |
| xfg              | fs scan only               | fs scan + no-op image scan |

## Files to create/modify

| File                                              | Action                                                    |
| ------------------------------------------------- | --------------------------------------------------------- |
| `.github/workflows/_trivy-image-scan.yaml`        | Create — new reusable workflow                            |
| `.github/workflows/_trivy-scan.yaml`              | Modify — dynamic issue titles with severity counts        |
| `src/templates/.github/workflows/trivy-scan.yaml` | Modify — add image-scan job, add packages:read permission |
| `src/repos.yaml`                                  | Modify — remove container-images createOnly override      |
