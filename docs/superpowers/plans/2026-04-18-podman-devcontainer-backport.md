# Podman Devcontainer + MegaLinter Backport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backport spruyt-labs' Podman-based devcontainer and lint harness into `repo-operator`'s `src/templates/` so every managed repo moves off Docker-in-Docker and works in both WSL2 local devcontainers and Coder/Kata workspaces.

**Architecture:** Replace the DinD feature with rootful Podman (via `podman-docker`) installed by
`post-create.sh`. The script auto-detects Coder-Kata (via `/dev/containers-disk`) vs WSL2 and
configures storage accordingly. Harden outer container with `runArgs: seccomp=podman-seccomp.json
--device /dev/fuse` (effective locally, ignored by envbuilder in Coder — acceptable). Ship
`agent-run` policy wrapper + Renovate-tracked seccomp profile. Update `lint.sh` to prefer
`sudo podman` when available.

**Tech Stack:** xfg templates (bash + JSON/YAML), MegaLinter, Podman, pre-commit.

**Key constraint — xfg escaping:** All `${VAR}` shell expansions in template scripts MUST be written as `$${VAR}`. Command substitutions `$(...)` are **not** escaped. JSON files are not escaped. The spec file has more detail.

**Escaping recipe used by every script task below:**

```bash
# 1. Pre-scan for nested expansions — the sed below matches the first '}',
#    so ${foo:-${bar}} would leave the outer brace unescaped. If any hits,
#    escape those manually before running sed.
grep -nE '\$\{[^}]*\$\{' "$FILE" && { echo "nested \${...\${...}}; escape manually"; exit 1; }

# 2. Apply xfg escaping to all ${...} expansions.
sed -i -E 's/\$\{([^}]+)\}/\$\$\{\1\}/g' "$FILE"

# 3. Verify no unescaped ${...} remain.
grep -nE '(^|[^$])\$\{' "$FILE" && { echo "unescaped \${...} left"; exit 1; }
echo "$FILE: escaping ok"
```

Run these three steps against each of: `update-podman-seccomp.sh`, `agent-run`, `post-create.sh`, `lint.sh`.

**Reference source:** `github.com/anthony-spruyt/spruyt-labs` is the upstream. Files are fetched via `gh api repos/anthony-spruyt/spruyt-labs/contents/<path>` and base64-decoded. Do not clone the repo.

---

## File Structure

New files:

- `src/templates/.devcontainer/Dockerfile` — apt retry config + `USER vscode`.
- `src/templates/.devcontainer/podman-seccomp.json` — vendored seccomp profile (~600 lines, JSON).
- `src/templates/.devcontainer/update-podman-seccomp.sh` — Renovate-tracked seccomp refresh script.
- `src/templates/.devcontainer/agent-run` — policy-enforcing podman-run wrapper for AI agents.
- `src/templates/.devcontainer/README.md` — devcontainer security/seccomp docs.

Modified files:

- `src/templates/.devcontainer/devcontainer.json` — switch to `build:`, add runArgs/fuse/seccomp, add named-volume mount, drop DinD, pin features.
- `src/templates/.devcontainer/post-create.sh` — full rewrite for Podman + Coder/WSL2 branch.
- `src/templates/lint.sh` — add sudo-podman fallback, tolerate root-owned `.output`.
- `src/files.yaml` — register the five new files.

Not modified (confirmed in spec):

- `src/templates/.devcontainer/initialize.sh`, `package.json`, `setup-devcontainer.sh`.
- `src/templates/.mega-linter-base.yml`, `.mega-linter.yml`, `lint-config.sh`.
- `src/groups.yaml`, `src/repos.yaml`.

---

## Task 1: Fetch upstream files and stage them locally

**Files:**

- Create: `src/templates/.devcontainer/Dockerfile`
- Create: `src/templates/.devcontainer/podman-seccomp.json`
- Create: `src/templates/.devcontainer/README.md`

- [ ] **Step 1: Fetch `Dockerfile` from spruyt-labs and save as-is**

Run:

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/.devcontainer/Dockerfile -o src/templates/.devcontainer/Dockerfile
```

No xfg escaping needed (no `${...}` in Dockerfile). Verify:

```bash
grep -n '\${' src/templates/.devcontainer/Dockerfile || echo "no \${ — ok"
```

Expected: `no ${ — ok`.

- [ ] **Step 2: Fetch `podman-seccomp.json` as-is**

Run:

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/.devcontainer/podman-seccomp.json -o src/templates/.devcontainer/podman-seccomp.json
```

Validate JSON:

```bash
jq empty src/templates/.devcontainer/podman-seccomp.json && echo ok
```

Expected: `ok`.

- [ ] **Step 3: Fetch `README.md` as-is**

Run:

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/.devcontainer/README.md -o src/templates/.devcontainer/README.md
```

No xfg escaping needed in prose.

- [ ] **Step 4: Stage and commit**

```bash
git add src/templates/.devcontainer/Dockerfile src/templates/.devcontainer/podman-seccomp.json src/templates/.devcontainer/README.md
git commit -m "feat(templates): add Dockerfile, seccomp profile, and README for podman devcontainer"
```

---

## Task 2: Add `update-podman-seccomp.sh` template

**Files:**

- Create: `src/templates/.devcontainer/update-podman-seccomp.sh`

- [ ] **Step 1: Fetch the upstream script**

Run:

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/.devcontainer/update-podman-seccomp.sh -o src/templates/.devcontainer/update-podman-seccomp.sh
chmod +x src/templates/.devcontainer/update-podman-seccomp.sh
```

- [ ] **Step 2: Apply xfg escaping**

Apply the escaping recipe from the plan header to `src/templates/.devcontainer/update-podman-seccomp.sh`:

```bash
FILE=src/templates/.devcontainer/update-podman-seccomp.sh
grep -nE '\$\{[^}]*\$\{' "$FILE" && { echo "nested expansion — escape manually first"; exit 1; }
sed -i -E 's/\$\{([^}]+)\}/\$\$\{\1\}/g' "$FILE"
grep -nE '(^|[^$])\$\{' "$FILE" && { echo "unescaped \${...} left"; exit 1; }
echo "ok"
```

Expected: `ok`. Upstream expansions covered: `"${BASH_SOURCE[0]}"` and `"${PODMAN_SECCOMP_VERSION}"`. `$(...)` command substitutions stay unchanged.

- [ ] **Step 3: Sanity-check the diff**

Run:

```bash
diff <(gh api repos/anthony-spruyt/spruyt-labs/contents/.devcontainer/update-podman-seccomp.sh --jq '.content' | base64 -d) src/templates/.devcontainer/update-podman-seccomp.sh
```

Expected: only `${...}` → `$${...}` changes; no other differences.

- [ ] **Step 4: Commit**

```bash
git add src/templates/.devcontainer/update-podman-seccomp.sh
git commit -m "feat(templates): add update-podman-seccomp.sh with xfg escaping"
```

---

## Task 3: Add `agent-run` policy wrapper template

**Files:**

- Create: `src/templates/.devcontainer/agent-run`

- [ ] **Step 1: Fetch upstream**

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/.devcontainer/agent-run -o src/templates/.devcontainer/agent-run
chmod +x src/templates/.devcontainer/agent-run
```

- [ ] **Step 2: Apply xfg escaping**

Apply the escaping recipe from the plan header:

```bash
FILE=src/templates/.devcontainer/agent-run
grep -nE '\$\{[^}]*\$\{' "$FILE" && { echo "nested expansion — escape manually first"; exit 1; }
sed -i -E 's/\$\{([^}]+)\}/\$\$\{\1\}/g' "$FILE"
grep -nE '(^|[^$])\$\{' "$FILE" && { echo "unescaped \${...} left"; exit 1; }
echo "ok"
```

Expected: `ok`. This affects `${FORBIDDEN_FLAGS[@]}`, `${!i}`, `${arg%%=*}`, `${arg#*=}`, `${AGENT_RUN_NET:-slirp4netns:allow_host_loopback=false}`, `${runner[@]}`, and similar.

- [ ] **Step 3: (merged into Step 2)**

_Superseded by the post-sed grep inside Step 2._

- [ ] **Step 4: Shellcheck the escaped version by temporarily unescaping into /tmp**

```bash
sed 's/\$\$/\$/g' src/templates/.devcontainer/agent-run > /tmp/agent-run.check && shellcheck /tmp/agent-run.check
```

Expected: no errors.

- [ ] **Step 5: Commit**

```bash
git add src/templates/.devcontainer/agent-run
git commit -m "feat(templates): add agent-run policy wrapper for podman"
```

---

## Task 4: Rewrite `post-create.sh` template

**Files:**

- Modify: `src/templates/.devcontainer/post-create.sh`

- [ ] **Step 1: Replace the file contents with upstream spruyt-labs `post-create.sh`**

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/.devcontainer/post-create.sh -o src/templates/.devcontainer/post-create.sh
chmod +x src/templates/.devcontainer/post-create.sh
```

- [ ] **Step 2: Apply xfg escaping for `${VAR}` expansions**

```bash
FILE=src/templates/.devcontainer/post-create.sh
grep -nE '\$\{[^}]*\$\{' "$FILE" && { echo "nested expansion — escape manually first"; exit 1; }
sed -i -E 's/\$\{([^}]+)\}/\$\$\{\1\}/g' "$FILE"
grep -nE '(^|[^$])\$\{' "$FILE" && { echo "unescaped \${...} left"; exit 1; }
echo "ok"
```

Expected: `ok`.

- [ ] **Step 3: Verify heredocs are intact**

Heredoc delimiters are quoted (e.g. `<<'CONTAINERS_CONF'`) so their bodies are NOT shell-expanded at runtime, but xfg still processes them. The sed pass in Step 2 already handled any `${...}` inside. Command substitutions `$(id -u)` stay unchanged — confirm:

```bash
grep -n 'id -u' src/templates/.devcontainer/post-create.sh
```

Expected lines should show `$(id -u)` unchanged (no `$$`).

- [ ] **Step 4: Confirm all 14 behaviors from the spec are present**

Grep for every behavior listed in the spec's `post-create.sh` section. Every command below must return at least one match:

```bash
FILE=src/templates/.devcontainer/post-create.sh
for pat in \
  'git config --global --add safe.directory' \
  'git ls-files.*chmod' \
  'safe-chain' \
  'pre-commit install' \
  'claude.ai/install.sh' \
  'local/bin' \
  'apt-get remove.*moby' \
  'podman-docker' \
  'fuse-overlayfs' \
  'slirp4netns' \
  '/etc/subuid' \
  'nodocker' \
  'keep-id' \
  '/dev/containers-disk' \
  'mkfs\.ext4' \
  'cgroups.*disabled' \
  'registries\.conf\.d' \
  'short-name-mode' \
  'alias podman=' \
  'install -m 0755.*agent-run' \
  'setup-devcontainer.sh' \
  'PASSED=0' \
  'FAILED=0' \
  'Results:.*passed' \
  'exit.*FAILED' ; do
    grep -q -E "$pat" "$FILE" || { echo "MISSING: $pat"; exit 1; }
done
echo "all 25 patterns present — ok"
```

Expected: `all 25 patterns present — ok`. If any `MISSING:` line prints, re-fetch from upstream and retry from Task 4 Step 1.

- [ ] **Step 5: Lint the escaped script**

```bash
sed 's/\$\$/\$/g' src/templates/.devcontainer/post-create.sh > /tmp/post-create.check && shellcheck /tmp/post-create.check
```

Some existing warnings may be acceptable (e.g. SC2157 is already disabled in lint.sh). Fix anything new; otherwise add inline `# shellcheck disable=...` with a justification.

- [ ] **Step 6: Commit**

```bash
git add src/templates/.devcontainer/post-create.sh
git commit -m "feat(templates): rewrite post-create.sh to install podman in place of DinD"
```

---

## Task 5: Update `devcontainer.json` template

**Files:**

- Modify: `src/templates/.devcontainer/devcontainer.json`

- [ ] **Step 1: Write the new devcontainer.json**

Replace the entire file with:

```jsonc
{
  "$schema": "https://raw.githubusercontent.com/devcontainers/spec/main/schemas/devContainer.schema.json",
  "name": "Ubuntu",
  "build": {
    "dockerfile": "Dockerfile"
  },
  "containerUser": "vscode",
  "remoteUser": "vscode",
  "runArgs": [
    "--env-file",
    "$${localEnv:HOME}/.secrets/.env",
    "--security-opt",
    "seccomp=$${localWorkspaceFolder}/.devcontainer/podman-seccomp.json",
    "--device",
    "/dev/fuse"
  ],
  "mounts": [
    "source=$${localEnv:HOME}/.ssh/agent.sock,target=/ssh-agent,type=bind",
    "source=$${localEnv:HOME}/.claude,target=/home/vscode/.claude,type=bind",
    "source=$${localWorkspaceFolderBasename}-containers,target=/var/lib/containers,type=volume"
  ],
  "containerEnv": {
    "SSH_AUTH_SOCK": "/ssh-agent"
  },
  "features": {
    "ghcr.io/devcontainers-extra/features/pre-commit": {
      "version": "4.5.1"
    },
    "ghcr.io/devcontainers/features/github-cli": {
      "version": "2.89.0"
    },
    "ghcr.io/devcontainers/features/node": {
      "version": "24.14.1"
    },
    "ghcr.io/devcontainers/features/python": {
      "version": "3.12"
    }
  },
  "initializeCommand": "bash $${localWorkspaceFolder}/.devcontainer/initialize.sh",
  "postCreateCommand": "bash -lc \"cd $${containerWorkspaceFolder} && ./.devcontainer/post-create.sh\"",
  "customizations": {
    "vscode": {
      "extensions": [
        "anthropic.claude-code",
        "bierner.markdown-mermaid",
        "blueglassblock.better-json5",
        "esbenp.prettier-vscode",
        "mhutchie.git-graph",
        "redhat.vscode-yaml"
      ]
    }
  }
}
```

Changes vs current template:

- `image:` → `build: { dockerfile: "Dockerfile" }`
- Added `containerUser: "vscode"`
- Added seccomp + `--device /dev/fuse` to `runArgs`
- Added `${localWorkspaceFolderBasename}-containers` named-volume mount
- Removed `docker-in-docker` feature
- Pinned feature versions

- [ ] **Step 2: Validate JSON**

```bash
jq empty src/templates/.devcontainer/devcontainer.json && echo ok
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add src/templates/.devcontainer/devcontainer.json
git commit -m "feat(templates): switch devcontainer.json to podman with build + seccomp"
```

---

## Task 6: Update `lint.sh` to prefer sudo podman

**Files:**

- Modify: `src/templates/lint.sh`

- [ ] **Step 1: Replace the file contents with upstream spruyt-labs `lint.sh`**

```bash
curl -sSL https://raw.githubusercontent.com/anthony-spruyt/spruyt-labs/main/lint.sh -o src/templates/lint.sh
chmod +x src/templates/lint.sh
```

- [ ] **Step 2: Apply xfg escaping**

```bash
FILE=src/templates/lint.sh
grep -nE '\$\{[^}]*\$\{' "$FILE" && { echo "nested expansion — escape manually first"; exit 1; }
sed -i -E 's/\$\{([^}]+)\}/\$\$\{\1\}/g' "$FILE"
grep -nE '(^|[^$])\$\{' "$FILE" && { echo "unescaped \${...} left"; exit 1; }
echo "ok"
```

Expected: `ok`.

- [ ] **Step 3: Verify the escaped file**

```bash
sed 's/\$\$/\$/g' src/templates/lint.sh > /tmp/lint.check && shellcheck /tmp/lint.check
```

Expected: same SC codes the current template already disables (SC2193, SC2157). Nothing new.

- [ ] **Step 4: Commit**

```bash
git add src/templates/lint.sh
git commit -m "feat(templates): prefer sudo podman with host network in lint.sh"
```

---

## Task 7: Register new files in `src/files.yaml`

**Files:**

- Modify: `src/files.yaml`

- [ ] **Step 1: Add entries for the five new files**

After the existing `.devcontainer/setup-devcontainer.sh:` entry in `src/files.yaml`, insert:

```yaml
  .devcontainer/Dockerfile:
    content: "@templates/.devcontainer/Dockerfile"
  .devcontainer/podman-seccomp.json:
    content: "@templates/.devcontainer/podman-seccomp.json"
  .devcontainer/update-podman-seccomp.sh:
    content: "@templates/.devcontainer/update-podman-seccomp.sh"
  .devcontainer/agent-run:
    content: "@templates/.devcontainer/agent-run"
  .devcontainer/README.md:
    createOnly: true
    content: "@templates/.devcontainer/README.md"
```

Rationale: all four scripts/configs are fully-managed (no createOnly). README is `createOnly: true` so repos can customize it later.

- [ ] **Step 2: Validate YAML**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('src/files.yaml'))" && echo ok
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add src/files.yaml
git commit -m "feat(config): register new podman devcontainer files for xfg sync"
```

---

## Task 8: Local verification

**Files:** none — verification only.

- [ ] **Step 1: Run pre-commit on all staged content**

```bash
pre-commit run --all-files
```

Expected: all hooks pass. If YAML/markdown lint complains about the new files (e.g. line length on README), fix inline and re-run.

- [ ] **Step 2: Lint the repo**

`/workspaces/repo-operator/lint.sh` at the repo root is a prior-sync artifact — a separate file from the new `src/templates/lint.sh` we just edited. Running it exercises the **old** (DinD-based) logic against the current repo contents, which is still a valid smoke test for the template _files_ (shellcheck, yamllint, jsonlint, markdownlint, gitleaks, etc.).

```bash
./lint.sh
```

Expected: MegaLinter runs, no errors on any of the new template files. Allow up to ~3 minutes.

Note: the new **template** `lint.sh` is not executed here — it will be tested end-to-end after the PR merges and the self-sync regenerates this repo's root `lint.sh`.

- [ ] **Step 3: Dry-run xfg against this repo's own config**

```bash
GH_TOKEN="${GH_TOKEN:?set GH_TOKEN}" npx @aspruyt/xfg --config ./src --dry-run 2>&1 | tail -80
```

Expected: xfg reports it _would_ create/update the new `.devcontainer/*` files in target repos. No "template not found" errors. If `--dry-run` is not a supported flag for xfg, skip this step and rely on CI.

- [ ] **Step 4: Open PR**

```bash
git push -u origin HEAD
gh pr create --title "feat: backport podman devcontainer + lint harness from spruyt-labs" --body "$(cat <<'EOF'
## Summary
- Replace Docker-in-Docker with rootful Podman (via podman-docker) in the devcontainer template
- Add seccomp profile, agent-run policy wrapper, and seccomp update script
- Update lint.sh to prefer sudo podman with host network
- Register five new files for xfg sync

## Test plan
- [ ] Pre-commit passes
- [ ] ./lint.sh passes locally
- [ ] CI sync-config job runs without errors
- [ ] Manually verify synced repo rebuilds cleanly
- [ ] Manually verify spruyt-labs' overrides still apply on top

Spec: docs/superpowers/specs/2026-04-18-podman-devcontainer-backport-design.md

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: Monitor CI**

```bash
gh pr checks --watch
```

Expected: lint job green. sync-config job on `main` will run after merge; it creates PRs in each target repo.

---

## Post-Merge Verification (not part of this plan, but worth noting)

After merge, watch for PRs opened by the xfg sync-config job in:

- `anthony-spruyt/claude-config`
- `anthony-spruyt/container-images`
- `anthony-spruyt/esphome`
- `anthony-spruyt/repo-operator` (self-sync)
- `anthony-spruyt/spruyt-labs`
- `anthony-spruyt/SunGather`
- `anthony-spruyt/xfg`

Open each locally in VS Code and confirm devcontainer rebuilds. First rebuild will take ~2 min due to Podman apt install. Spot-check spruyt-labs in Coder to confirm Kata branch still works.
