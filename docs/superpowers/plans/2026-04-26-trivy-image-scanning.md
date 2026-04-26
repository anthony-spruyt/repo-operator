# Centralized Trivy Image Scanning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GHCR container image scanning to the daily Trivy workflow, auto-discovering images per repo, with per-image issues and trivyignore support.

**Architecture:** New reusable workflow `_trivy-image-scan.yaml` discovers GHCR packages via API, scans each as a matrix job, manages per-image issues. Synced template calls both fs and image scan workflows in parallel. Existing `_trivy-scan.yaml` gets dynamic issue titles. xfg config updated to overwrite container-images' custom workflow.

**Tech Stack:** GitHub Actions (reusable workflows), GHCR packages API, Trivy, jq, gh CLI

**Spec:** `docs/superpowers/specs/2026-04-26-trivy-image-scanning-design.md` **Issue:** #115

______________________________________________________________________

## File Structure

| File                                              | Action | Responsibility                                                                   |
| ------------------------------------------------- | ------ | -------------------------------------------------------------------------------- |
| `.github/workflows/_trivy-image-scan.yaml`        | Create | Reusable workflow: discover GHCR images, matrix scan, per-image issue management |
| `.github/workflows/_trivy-scan.yaml`              | Modify | Update issue title from static to dynamic severity counts                        |
| `src/templates/.github/workflows/trivy-scan.yaml` | Modify | Add image-scan job call, add `packages: read` permission                         |
| `src/repos.yaml`                                  | Modify | Remove container-images `createOnly: true` override for trivy-scan.yaml          |

______________________________________________________________________

### Task 1: Create `_trivy-image-scan.yaml` reusable workflow

**Files:**

- Create: `.github/workflows/_trivy-image-scan.yaml`

- [ ] **Step 1: Create the workflow file**

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/SchemaStore/schemastore/master/src/schemas/json/github-workflow.json
name: Trivy Image Vulnerability Scan

on:
  workflow_call: {}

permissions:
  contents: read
  packages: read
  issues: write

env:
  REGISTRY: ghcr.io

jobs:
  discover-images:
    name: Discover Images
    runs-on: ubuntu-latest
    outputs:
      images: ${{ steps.discover.outputs.images }}
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@fe104658747b27e96e4f7e80cd0a94068e53901d
        with:
          egress-policy: audit

      - name: Discover GHCR packages
        id: discover
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          # Query GHCR packages API for container images belonging to this repo
          OWNER="${GITHUB_REPOSITORY_OWNER}"
          REPO="${GITHUB_REPOSITORY}"

          # List all container packages for the owner, filter by source repository
          IMAGES=$(gh api "/users/${OWNER}/packages?package_type=container" \
            --paginate \
            --jq "[.[] | select(.repository.full_name == \"${REPO}\") | .name]")

          # Handle pagination producing multiple JSON arrays by merging them
          IMAGES=$(echo "$IMAGES" | jq -s 'add // []')

          COUNT=$(echo "$IMAGES" | jq 'length')
          echo "Found $COUNT container images for ${REPO}"
          echo "$IMAGES" | jq .

          echo "images=$IMAGES" >> "$GITHUB_OUTPUT"

  scan-images:
    name: Scan ${{ matrix.image }}
    runs-on: ubuntu-latest
    needs: discover-images
    if: needs.discover-images.outputs.images != '[]'
    permissions:
      contents: read
      packages: read
      issues: write
    strategy:
      fail-fast: false
      matrix:
        image: ${{ fromJson(needs.discover-images.outputs.images) }}
    steps:
      - name: Harden Runner
        uses: step-security/harden-runner@fe104658747b27e96e4f7e80cd0a94068e53901d
        with:
          egress-policy: audit

      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Log in to GHCR
        uses: docker/login-action@4907a6ddec9925e35a0a9e82d7399ccc52663121 # v4
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Check if image exists
        id: check-image
        env:
          IMAGE: ${{ matrix.image }}
        run: |
          IMAGE_REF="${REGISTRY}/${GITHUB_REPOSITORY_OWNER}/${IMAGE}:latest"
          if docker manifest inspect "$IMAGE_REF" > /dev/null 2>&1; then
            echo "exists=true" >> "$GITHUB_OUTPUT"
            echo "Image exists: $IMAGE_REF"
          else
            echo "exists=false" >> "$GITHUB_OUTPUT"
            echo "::warning::Image not found: $IMAGE_REF"
          fi

      - name: Detect Trivy ignore file
        id: trivyconfig
        if: steps.check-image.outputs.exists == 'true'
        env:
          IMAGE: ${{ matrix.image }}
        run: |
          if [ -f "${IMAGE}/.trivyignore" ]; then
            echo "ignorefile=${IMAGE}/.trivyignore" >> "$GITHUB_OUTPUT"
            echo "Using per-image ignore: ${IMAGE}/.trivyignore"
          elif [ -f ".trivyignore.yaml" ]; then
            echo "ignorefile=.trivyignore.yaml" >> "$GITHUB_OUTPUT"
            echo "Using repo-level ignore: .trivyignore.yaml"
          else
            echo "ignorefile=" >> "$GITHUB_OUTPUT"
            echo "No ignore file found"
          fi

      - name: Scan image for vulnerabilities
        if: steps.check-image.outputs.exists == 'true'
        uses: aquasecurity/trivy-action@57a97c7e7821a5776cebc9bb87c984fa69cba8f1
        with:
          image-ref: ${{ env.REGISTRY }}/${{ github.repository_owner }}/${{ matrix.image }}:latest
          scanners: vuln,secret,misconfig
          format: json
          output: trivy-results.json
          severity: CRITICAL,HIGH,MEDIUM
          ignore-unfixed: false
          trivyignores: ${{ steps.trivyconfig.outputs.ignorefile }}
          exit-code: 0

      - name: Process results and manage issue
        if: steps.check-image.outputs.exists == 'true'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          IMAGE: ${{ matrix.image }}
        run: |
          if [ ! -f trivy-results.json ]; then
            echo "::error::trivy-results.json not found"
            exit 1
          fi

          IMAGE_REF="${REGISTRY}/${GITHUB_REPOSITORY_OWNER}/${IMAGE}:latest"
          SCAN_DATE=$(date -u +"%Y-%m-%d %H:%M UTC")
          SCAN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

          # Deduplicate vulnerabilities by CVE ID
          VULNS=$(jq '[.Results[]?.Vulnerabilities[]?] | unique_by(.VulnerabilityID)' trivy-results.json)
          CRITICAL=$(echo "$VULNS" | jq '[.[] | select(.Severity == "CRITICAL")] | length')
          HIGH=$(echo "$VULNS" | jq '[.[] | select(.Severity == "HIGH")] | length')
          MEDIUM=$(echo "$VULNS" | jq '[.[] | select(.Severity == "MEDIUM")] | length')
          TOTAL=$((CRITICAL + HIGH + MEDIUM))

          echo "Found $TOTAL vulnerabilities ($CRITICAL critical, $HIGH high, $MEDIUM medium)"

          # Ensure labels exist
          gh label create "security" --color "d73a4a" --description "Security vulnerability" --force 2>/dev/null || true
          gh label create "trivy" --color "0052cc" --description "Trivy scan finding" --force 2>/dev/null || true
          gh label create "critical" --color "b60205" --description "Critical severity" --force 2>/dev/null || true
          gh label create "high" --color "d93f0b" --description "High severity" --force 2>/dev/null || true
          gh label create "medium" --color "fbca04" --description "Medium severity" --force 2>/dev/null || true

          # Find existing issue by title prefix
          ISSUE_PREFIX="[Trivy] ${IMAGE}:"
          ISSUE_NUMBER=$(gh issue list --state open --json number,title \
            | jq -r --arg prefix "$ISSUE_PREFIX" '.[] | select(.title | startswith($prefix)) | .number' \
            | head -1)

          if [ "$TOTAL" -eq 0 ]; then
            echo "::notice::No vulnerabilities found for ${IMAGE}"
            if [ -n "$ISSUE_NUMBER" ]; then
              gh issue close "$ISSUE_NUMBER" \
                --comment "All vulnerabilities resolved as of ${SCAN_DATE}."
            fi
            exit 0
          fi

          # Build issue title with severity counts
          TITLE="[Trivy] ${IMAGE}:"
          [ "$CRITICAL" -gt 0 ] && TITLE="${TITLE} ${CRITICAL} critical,"
          [ "$HIGH" -gt 0 ] && TITLE="${TITLE} ${HIGH} high,"
          [ "$MEDIUM" -gt 0 ] && TITLE="${TITLE} ${MEDIUM} medium,"
          TITLE="${TITLE%,} found"

          # Build CRITICAL/HIGH vulnerability table
          TABLE=$(echo "$VULNS" | jq -r '
            [.[] | select(.Severity == "CRITICAL" or .Severity == "HIGH")]
            | .[]
            | "| \(.VulnerabilityID) | \(.Severity) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion // "unfixed") |"
          ')

          # Build issue body
          BODY="## Trivy Vulnerability Scan Results"
          BODY="${BODY}

          **Image:** \`${IMAGE_REF}\`
          **Scan date:** ${SCAN_DATE}
          **Total:** ${TOTAL} (${CRITICAL} critical, ${HIGH} high, ${MEDIUM} medium)"

          if [ "$((CRITICAL + HIGH))" -gt 0 ]; then
            BODY="${BODY}

          ### Critical & High Vulnerabilities

          | CVE | Severity | Package | Installed | Fixed |
          |-----|----------|---------|-----------|-------|
          ${TABLE}"
          fi

          if [ "$MEDIUM" -gt 0 ]; then
            BODY="${BODY}

          > **${MEDIUM} medium severity** vulnerabilities. See [full scan results](${SCAN_URL}) for details."
          fi

          BODY="${BODY}

          ---
          *Auto-generated by [Trivy scan](${SCAN_URL})*"

          # Determine labels
          LABELS="security,trivy"
          [ "$CRITICAL" -gt 0 ] && LABELS="${LABELS},critical"
          [ "$HIGH" -gt 0 ] && LABELS="${LABELS},high"
          [ "$MEDIUM" -gt 0 ] && LABELS="${LABELS},medium"

          if [ -n "$ISSUE_NUMBER" ]; then
            # Remove stale severity labels before applying current ones
            EXISTING_SEVERITY=$(gh issue view "$ISSUE_NUMBER" --json labels \
              -q '.labels[].name' | grep -E '^(critical|high|medium)$' | paste -sd, || echo "")
            if [ -n "$EXISTING_SEVERITY" ]; then
              gh issue edit "$ISSUE_NUMBER" --remove-label "$EXISTING_SEVERITY"
            fi
            gh issue edit "$ISSUE_NUMBER" --title "$TITLE" --body "$BODY" --add-label "$LABELS"
            echo "::notice::Updated issue #$ISSUE_NUMBER"
          else
            gh issue create --title "$TITLE" --body "$BODY" --label "$LABELS"
            echo "::notice::Created new vulnerability issue"
          fi
```

- [ ] **Step 2: Validate workflow syntax**

Run: `actionlint .github/workflows/_trivy-image-scan.yaml`

Expected: No errors (warnings about `${{ }}` in `run:` are OK).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/_trivy-image-scan.yaml
git commit -m "feat(trivy): add reusable image scanning workflow

Closes #115"
```

______________________________________________________________________

### Task 2: Update `_trivy-scan.yaml` with dynamic issue titles

**Files:**

- Modify: `.github/workflows/_trivy-scan.yaml:47-155`

The issue title changes from static `[Trivy] Security vulnerabilities found` to dynamic `[Trivy] repo: N critical, N high found`. The issue search changes from exact title match to prefix match (since title is now dynamic). The issue body gets a scan URL link.

- [ ] **Step 1: Update the "Process results and manage issue" step**

Replace the entire `run:` block in the "Process results and manage issue" step (lines 50-156) with:

```yaml
      - name: Process results and manage issue
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          ISSUE_PREFIX="[Trivy] repo:"

          if [ ! -f trivy-results.json ]; then
            echo "No Trivy results file found"
            exit 0
          fi

          SCAN_DATE=$(date -u +"%Y-%m-%d %H:%M UTC")
          SCAN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

          # Deduplicate vulnerabilities by CVE ID
          VULNS=$(jq '[.Results[]?.Vulnerabilities[]?] | unique_by(.VulnerabilityID)' trivy-results.json)
          CRITICAL=$(echo "$VULNS" | jq '[.[] | select(.Severity == "CRITICAL")] | length')
          HIGH=$(echo "$VULNS" | jq '[.[] | select(.Severity == "HIGH")] | length')
          MEDIUM=$(echo "$VULNS" | jq '[.[] | select(.Severity == "MEDIUM")] | length')
          TOTAL=$((CRITICAL + HIGH + MEDIUM))

          echo "Found $TOTAL vulnerabilities ($CRITICAL critical, $HIGH high, $MEDIUM medium)"

          # Find existing issue by title prefix
          EXISTING=$(gh issue list --state open --json number,title \
            | jq -r --arg prefix "$ISSUE_PREFIX" '.[] | select(.title | startswith($prefix)) | .number' \
            | head -1)

          if [ "$TOTAL" -eq 0 ]; then
            echo "No vulnerabilities found"
            if [ -n "$EXISTING" ]; then
              gh issue close "$EXISTING" \
                --comment "All vulnerabilities resolved as of $SCAN_DATE."
              echo "Closed issue #$EXISTING"
            fi
            exit 0
          fi

          # Build issue title with severity counts
          TITLE="[Trivy] repo:"
          [ "$CRITICAL" -gt 0 ] && TITLE="${TITLE} ${CRITICAL} critical,"
          [ "$HIGH" -gt 0 ] && TITLE="${TITLE} ${HIGH} high,"
          [ "$MEDIUM" -gt 0 ] && TITLE="${TITLE} ${MEDIUM} medium,"
          TITLE="${TITLE%,} found"

          # Build CRITICAL/HIGH vulnerability table
          TABLE=$(echo "$VULNS" | jq -r '
            [.[] | select(.Severity == "CRITICAL" or .Severity == "HIGH")]
            | .[]
            | "| \(.VulnerabilityID) | \(.Severity) | \(.PkgName) | \(.InstalledVersion) | \(.FixedVersion // "unfixed") |"
          ')

          # Build issue body
          BODY="## Trivy Vulnerability Scan Results"
          BODY="${BODY}

          **Scan date:** ${SCAN_DATE}
          **Total:** ${TOTAL} (${CRITICAL} critical, ${HIGH} high, ${MEDIUM} medium)"

          if [ "$((CRITICAL + HIGH))" -gt 0 ]; then
            BODY="${BODY}

          ### Critical & High Vulnerabilities

          | CVE | Severity | Package | Installed | Fixed |
          |-----|----------|---------|-----------|-------|
          ${TABLE}"
          fi

          if [ "$MEDIUM" -gt 0 ]; then
            BODY="${BODY}

          > **${MEDIUM} medium severity** vulnerabilities. See [full scan results](${SCAN_URL}) for details."
          fi

          BODY="${BODY}

          ---
          *Auto-generated by [Trivy scan](${SCAN_URL})*"

          # Determine labels
          LABELS="security,trivy"
          [ "$CRITICAL" -gt 0 ] && LABELS="${LABELS},critical"
          [ "$HIGH" -gt 0 ] && LABELS="${LABELS},high"
          [ "$MEDIUM" -gt 0 ] && LABELS="${LABELS},medium"

          # Ensure labels exist
          gh label create "security" --color "d73a4a" --description "Security vulnerability" --force 2>/dev/null || true
          gh label create "trivy" --color "0052cc" --description "Trivy scan finding" --force 2>/dev/null || true
          gh label create "critical" --color "b60205" --description "Critical severity" --force 2>/dev/null || true
          gh label create "high" --color "d93f0b" --description "High severity" --force 2>/dev/null || true
          gh label create "medium" --color "fbca04" --description "Medium severity" --force 2>/dev/null || true

          if [ -n "$EXISTING" ]; then
            EXISTING_SEVERITY=$(gh issue view "$EXISTING" --json labels -q '.labels[].name' | grep -E '^(critical|high|medium)$' | paste -sd, || echo "")
            [ -n "$EXISTING_SEVERITY" ] && gh issue edit "$EXISTING" --remove-label "$EXISTING_SEVERITY"
            gh issue edit "$EXISTING" --title "$TITLE" --body "$BODY" --add-label "$LABELS"
            echo "Updated issue #$EXISTING"
          else
            gh issue create --title "$TITLE" --body "$BODY" --label "$LABELS"
            echo "Created new issue"
          fi
```

**Migration note:** Existing repos have issues titled `[Trivy] Security vulnerabilities found`. The new prefix is `[Trivy] repo:`. The first run after deployment won't find the old issue (different prefix), so it will create a new one. The old issue should be manually closed, or a one-time migration step can rename it. This is acceptable — it's a one-time transition.

- [ ] **Step 2: Validate workflow syntax**

Run: `actionlint .github/workflows/_trivy-scan.yaml`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/_trivy-scan.yaml
git commit -m "feat(trivy): use dynamic severity counts in fs scan issue titles"
```

______________________________________________________________________

### Task 3: Update synced template `trivy-scan.yaml`

**Files:**

- Modify: `src/templates/.github/workflows/trivy-scan.yaml`

- [ ] **Step 1: Update the synced template**

Replace the entire file content with:

```yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/SchemaStore/schemastore/master/src/schemas/json/github-workflow.json
# See https://github.com/anthony-spruyt/repo-operator/blob/main/src/templates/.github/workflows/trivy-scan.yaml for template comments
name: Trivy Vulnerability Scan

on:
  schedule:
    # Every day at 6:00 AM UTC
    - cron: "0 6 * * *"
  workflow_dispatch: {}

permissions:
  contents: read
  issues: write
  packages: read

jobs:
  fs-scan:
    uses: anthony-spruyt/repo-operator/.github/workflows/_trivy-scan.yaml@main
    # with:
    #   scan-type: "fs"
    #   trivy-config: "trivy.yaml"
  image-scan:
    uses: anthony-spruyt/repo-operator/.github/workflows/_trivy-image-scan.yaml@main
```

- [ ] **Step 2: Commit**

```bash
git add src/templates/.github/workflows/trivy-scan.yaml
git commit -m "feat(trivy): add image scan job to synced template"
```

______________________________________________________________________

### Task 4: Update `repos.yaml` to remove container-images override

**Files:**

- Modify: `src/repos.yaml:36-37`

- [ ] **Step 1: Remove the createOnly override**

In `src/repos.yaml`, remove lines 36-37:

```yaml
    files:
      .github/workflows/trivy-scan.yaml:
        createOnly: true
```

This allows xfg to overwrite container-images' custom `trivy-scan.yaml` with the synced template on next sync.

- [ ] **Step 2: Validate xfg config syntax**

Run: `npx @aspruyt/xfg --config ./src --dry-run 2>&1 | head -50` (or similar validation command if available)

If no dry-run available, visually confirm YAML is valid:

Run: `python3 -c "import yaml; yaml.safe_load(open('src/repos.yaml'))"`

Expected: No errors.

- [ ] **Step 3: Commit**

```bash
git add src/repos.yaml
git commit -m "feat(trivy): remove container-images createOnly override for trivy-scan"
```

______________________________________________________________________

### Task 5: Lint and final validation

- [ ] **Step 1: Run actionlint on all workflows**

Run: `actionlint .github/workflows/_trivy-image-scan.yaml .github/workflows/_trivy-scan.yaml`

Expected: No errors.

- [ ] **Step 2: Run pre-commit on changed files**

Run: `pre-commit run --all-files`

Expected: All checks pass.

- [ ] **Step 3: Fix any issues and commit**

If pre-commit or actionlint found issues, fix and commit:

```bash
git add -A
git commit -m "fix(trivy): address lint findings"
```
