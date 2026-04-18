# Podman Devcontainer + MegaLinter Backport Design

**Date:** 2026-04-18
**Status:** Draft — awaiting user approval before implementation planning

## Goal

Backport the devcontainer and MegaLinter changes developed in `anthony-spruyt/spruyt-labs` into `repo-operator`'s `src/templates/` so all managed repos move from Docker-in-Docker to rootless/rootful Podman while continuing to support both local WSL2 devcontainers and Coder workspaces.

## Non-Goals

- No changes to CI workflow templates beyond what the lint script transitively touches.
- No changes to Renovate configuration structure.
- No changes to how xfg is invoked by repo-operator.

## Constraints

- **Single template must work in both environments.** Local VS Code devcontainers on WSL2 AND Coder (envbuilder + Kata) workspaces. `runArgs` fields are ignored by envbuilder but are not harmful; seccomp/fuse hardening applies locally only, which matches current spruyt-labs operation.
- **Existing per-repo overrides in `src/repos.yaml` stay intact.** Only remove overrides that become redundant once upstreamed to the base template.
- **xfg template escaping** — all `${…}` shell expansions in template scripts must be escaped as `$${…}`.

## File-by-File Changes

### New files under `src/templates/.devcontainer/`

| File | Purpose |
| --- | --- |
| `Dockerfile` | Layered on `mcr.microsoft.com/devcontainers/base:jammy` (digest-pinned). Adds apt retry conf. Sets `USER vscode`. |
| `podman-seccomp.json` | Vendored upstream seccomp profile from `containers/common`. ~20KB. Applied via `runArgs`; no-op in envbuilder. |
| `update-podman-seccomp.sh` | Re-fetches `podman-seccomp.json` from version pinned by Renovate (`PODMAN_SECCOMP_VERSION`). |
| `agent-run` | Policy-enforcing wrapper around `podman run` for AI agents. Rejects `--privileged`, `--network=host`, etc. Installed to `/usr/local/bin/agent-run` by `post-create.sh`. |
| `README.md` | Describes devcontainer layout, security posture, and seccomp update flow. Ported from spruyt-labs. |

### Rewritten files under `src/templates/.devcontainer/`

**`devcontainer.json`**
- Switch from `"image": "…"` to `"build": { "dockerfile": "Dockerfile" }`.
- Add `"containerUser": "vscode"`.
- Replace `runArgs` with: `--env-file $HOME/.secrets/.env`, `--security-opt seccomp=.../podman-seccomp.json`, `--device /dev/fuse`.
- Extend `mounts` with the per-repo named volume: `source=${localWorkspaceFolderBasename}-containers,target=/var/lib/containers,type=volume`.
- **Remove** `ghcr.io/devcontainers/features/docker-in-docker`.
- **Pin** versions for all remaining features: `pre-commit@4.5.1`, `github-cli@2.89.0`, `node@24.14.1`, `python@3.12`. (Feature versions become Renovatable at a later stage — out of scope here.)

**`post-create.sh`** — full rewrite, behaviour:
1. `git config --global --add safe.directory '*'`
2. `git ls-files -z '*.sh' | xargs -0 -r chmod +x 2>/dev/null || true` (tolerate root-owned).
3. Install safe-chain (unchanged).
4. Install pre-commit hooks (unchanged).
5. Install Claude Code CLI; ensure `~/.local/bin` on PATH.
6. Remove moby/docker CLI; `apt-get install -y podman podman-docker fuse-overlayfs uidmap slirp4netns`.
7. Ensure `/etc/subuid` and `/etc/subgid` have `vscode:` entry; create `/etc/containers/nodocker`.
8. Write `$HOME/.config/containers/containers.conf.d/10-userns.conf` with `userns="keep-id"`.
9. Branch on `[ -b /dev/containers-disk ]`:
   - **Coder-Kata:** mkfs.ext4 + mount the block PVC at `/var/lib/containers`, write rootful `storage.conf` + `containers.conf` with `cgroups=disabled`, `cgroup_manager=cgroupfs`.
   - **WSL2/local:** chown `/var/lib/containers`, write same rootful `storage.conf` + `containers.conf`; also write `$HOME/.config/containers/storage.conf` with fuse-overlayfs for rootless compatibility.
10. Add `alias podman="sudo podman"` to `~/.bashrc` (idempotent).
11. Write `$HOME/.config/containers/registries.conf.d/10-allow-list.conf` with fully-qualified registries and `short-name-mode="enforcing"`.
12. `sudo install -m 0755 "$SCRIPT_DIR/agent-run" /usr/local/bin/agent-run`.
13. Call `./setup-devcontainer.sh` (per-repo hook).
14. Verification block: `docker --version` is Podman, `docker run hello-world` works, pre-commit, safe-chain, GH CLI, SSH agent, Claude CLI.

### Unchanged under `src/templates/.devcontainer/`

- `initialize.sh` — already correct.
- `package.json` — already correct.
- `setup-devcontainer.sh` — stays `createOnly: true` (per-repo hook).

### Updated under `src/templates/`

**`lint.sh`** — add Podman fallback:
- `rm -rf .output 2>/dev/null || sudo -n rm -rf .output` (tolerate root-owned).
- Local mode: if `sudo -n true` succeeds, use `sudo -n podman` with `--network=host`; else fall back to `docker`. Keeps CI mode on `docker`.

### Unchanged under `src/templates/`

- `.mega-linter-base.yml`, `.mega-linter.yml`, `lint-config.sh` — already match spruyt-labs.

### `src/files.yaml` additions

Add entries:

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

No removals.

### `src/groups.yaml`

- No structural changes required.
- Optional: pin `go`, `terraform`, `renovate-cli` feature versions in place of `{}` so all synced repos get deterministic installs. Treated as a non-blocking improvement; can land alongside or later.

### `src/repos.yaml`

**No changes required.** The spruyt-labs override already contains only repo-specific mounts (`.secrets`, `talosconfig`), repo-specific features (`sops`, `jq-likes`), a ports attribute, and extra extensions — all still valid and additive on top of the new base. The `${localWorkspaceFolderBasename}-containers` named volume is introduced by the base template, not by an override.

## xfg Template Escaping

All new/rewritten scripts are processed by xfg. Every shell expansion `${VAR}` must be written as `$${VAR}` in the template:

- `post-create.sh` — many occurrences (`$${BASH_SOURCE[0]}`, `$${HOME}`, `$${PATH}`, heredoc bodies are safe if the heredoc delimiter is quoted, e.g. `<<'CONTAINERS_CONF'`).
- `agent-run` — all parameter expansions and positional args.
- `update-podman-seccomp.sh` — `$${BASH_SOURCE[0]}`, `$${PODMAN_SECCOMP_VERSION}`.
- `lint.sh` — already partly escaped; preserve that style.

`Dockerfile` has no shell expansions at template-processing time.
`podman-seccomp.json` is JSON, not processed for shell variables.

## Rollout

- On next xfg sync, every managed repo receives the new devcontainer files and a rewritten `post-create.sh`.
- First rebuild of each repo's devcontainer pays a one-time apt install cost (~30–60 s) and starts with an empty `${localWorkspaceFolderBasename}-containers` named volume.
- CI `lint` job is unaffected (still uses `docker` in CI mode).

## Risks

| Risk | Mitigation |
| --- | --- |
| A repo's host lacks `/dev/fuse` or `$HOME/.secrets/.env` and fails to boot. | Already the case today (current template references `.secrets/.env`). Documented in `.devcontainer/README.md` in spruyt-labs; we may port that README as well (see "Open Questions"). |
| MegaLinter image tag `ghcr.io/anthony-spruyt/megalinter-spruyt-labs:latest` is spruyt-specific. | Out of scope — `lint-config.sh` is `createOnly:true`, so each repo picks its own image. No change needed. |
| Named volume `*-containers` grows unbounded per repo. | Acceptable — Docker Desktop user can prune. |
| Renovate bumping pinned feature versions creates churn. | Accept — that is the goal of pinning. |

## Success Criteria

- `./lint.sh` runs successfully locally on any synced repo using rootful Podman-via-sudo.
- Opening a synced repo in VS Code on WSL2 builds the devcontainer, runs `post-create.sh` cleanly, and verification block reports all ✓.
- Opening spruyt-labs in Coder still works (detects `/dev/containers-disk` and mounts block PVC).
- `docker run hello-world` works inside the devcontainer (via `podman-docker`).
- No existing per-repo override in `repos.yaml` regresses.
