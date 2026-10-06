# Shared CI

Reusable workflows and composite actions that other repos call from this repo. Pin them to `@main` for now; a floating `v1` tag is planned (#494).

Reusable workflows suit single-package repos that follow the standard layout: the project at the repo root and a `Dockerfile` there too. For Go, `go.mod` sits at the root and binaries live under `cmd/`. Monorepos can call the composite actions from their own jobs instead.

A reusable workflow resolves `uses: ./...` against the caller's checkout, not against this repo. That is why these workflows refer to each other, and to the actions, with `$/` (for example `uses: $/.github/actions/build-image`), which resolves to this repo at the same ref as the calling workflow. To test a branch of this repo, point the caller at the branch; the internal references follow it.

## Composite actions

### `build-image`

Builds an image with buildx. With `push: "true"` it also pushes to GHCR, and to Docker Hub when `dockerhub-namespace` is set. The push includes an SBOM, `provenance: mode=max` and an `actions/attest-build-provenance` attestation.

Tags are `<prefix><version>`, `<prefix><major>.<minor>` and `latest`, plus any `extra-tags` rules. Check out the repo first. Pushing needs `packages`, `id-token` and `attestations: write`.

- `image` (default: repository name): image and GHCR package name
- `context` (default `.`): build context
- `dockerfile` (default `<context>/Dockerfile`): Dockerfile path
- `push` (default `"false"`): push the image, SBOM and attestation
- `version`: version without a leading `v`; required when pushing
- `tag-prefix`: `""` or `v`, applied to the version tags only
- `extra-tags`: extra `docker/metadata-action` tag rules
- `build-args`: `KEY=VALUE` lines
- `go-mod`: path to `go.mod`; adds `GO_VERSION`, `VERSION` (`v<version>`) and `COMMIT` build args
- `dockerhub-namespace`: also push to `docker.io/<namespace>/<image>`
- `dockerhub-username` (default: `dockerhub-namespace`): Docker Hub login, for organisation namespaces
- `dockerhub-token`: Docker Hub token; required with a namespace when pushing
- `test-command`: shell command run against a locally loaded build (`$IMAGE_REF`) before anything is pushed
- `github-token` (default `github.token`): GHCR login

The action outputs `digest` and `image-ref` (`ghcr.io/<owner>/<image>:<prefix><version>`).

### `publish-release`

Appends the image reference, digest and run link to a release-please draft release, then publishes it. Run it as the last step of the job that pushed the image. If any earlier step fails, the release stays a draft, so a published release always has an image behind it. The action refuses to publish with an empty digest.

Inputs: `tag`, `image-ref`, `digest`, and `github-token` (defaults to `github.token`, which needs `contents: write`).

## Reusable workflows

- `_go-test.yaml`: `go build ./...` and `go test -race ./...` from `workdir` (default `.`). Needs `contents: read`.
- `_python-uv-test.yaml`: `uv run --frozen pytest`, once per `test-paths` line, then `extra-commands`. `groups` adds PEP 735 dependency groups (`--group`) on top of uv's default `dev`; `extras` adds optional extras. Needs `contents: read`.
- `_build-image.yaml`: run the tests for `language` (`go`, `python` or `none`), then `build-image`. Without `push`, a `contents: read` job builds only. With `push: true`, a separate job pushes and runs `publish-release`; only that job needs the publishing permissions.
- `_release-please.yaml`: release-please for one root (`.`) package. On release, runs `_build-image.yaml` with `push: true` on the new tag. release-please itself acts with the app token, so callers grant only the publishing permissions. Repos without an image should not use it: only the image job undrafts the release.
- `_rebuild-release.yaml`: rebuild and publish a release whose image job failed. Needs the publishing permissions.
- `_container-retention.yaml`: delete old GHCR package versions. See [Container retention](#container-retention).

Publishing permissions are `contents`, `packages`, `id-token` and `attestations: write`.

`_build-image.yaml`, `_release-please.yaml` and `_rebuild-release.yaml` share these inputs:

- `language`, `workdir`, `image`, `context`, `dockerfile`, `tag-prefix`, `test-command`
- `dockerhub-namespace`, `dockerhub-username`
- `python-version`, `python-groups`, `python-extras`, `python-test-paths`, `python-extra-commands`

Pass `secrets: DOCKERHUB_TOKEN` for Docker Hub. `_release-please.yaml` also needs `RELEASE_PLEASE_APP_CLIENT_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY`, which the `release-please` group syncs.

Go linting is not a workflow job. MegaLinter (`_lint.yaml`) owns it.

### Container retention

`_container-retention.yaml` runs [ghcr-cleanup-action](https://github.com/dataaxiom/ghcr-cleanup-action) with the caller's `GITHUB_TOKEN`, so no account-wide token is needed. It deletes:

- tagged versions beyond the newest `keep-n-tagged` that are older than `older-than`. Old release tags go too, so consumers that pin a release must keep up. `latest` is never deleted.
- ghost multi-arch images, whose platform images are all missing.

Untagged versions are kept: setting `keep-n-tagged` turns off the action's default of deleting them. Multi-arch children, attestations and signatures are deleted only with their parent.

- `packages` (default: repository name): comma-separated package names. Wildcards are refused, because expanding them needs a PAT.
- `older-than` (default `4 weeks`): must be a positive interval of at most 99999 units, such as `4 weeks` or `30 days`
- `keep-n-tagged` (default `5`): must be at least `1`
- `dry-run` (default `false`): log what would be deleted, delete nothing

Runs for the same repo queue rather than overlap, because the action is not safe to run in parallel.

The calling job needs `packages: write`, and each package must give the calling repo the **Admin** role under its Actions access settings. Write is enough to push but not to delete versions. The role is set in the package settings; there is no API for it.

Start a caller with `workflow_dispatch` only, so nothing deletes before a dry run has been read:

```yaml
name: Container Retention
on:
  workflow_dispatch:
    inputs:
      dry-run:
        description: List what would be deleted without deleting it
        type: boolean
        default: true
permissions: {}
jobs:
  cleanup:
    permissions:
      packages: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_container-retention.yaml@main
    with:
      dry-run: ${{ inputs.dry-run || false }}
```

Roll it out in this order:

1. Give the calling repo the **Admin** role on each package.
2. Dispatch with `dry-run` on, and check the logged deletions.
3. Dispatch once with `dry-run` off.
4. Confirm that `latest`, the newest `keep-n-tagged` tags and every digest a consumer pins still pull.
5. Only then add a `schedule` trigger, for example `cron: "0 5 * * 0"`. A scheduled run has no inputs, so `dry-run` falls back to `false` and the run deletes.

### Release flow

1. release-please opens a release PR. Merging it creates the tag and a **draft** release (`"draft": true` and `"force-tag-creation": true` in the config).
2. The image is built from that tag, tested, pushed and attested.
3. `publish-release` adds the image details and undrafts the release.

The image job checks out the commit the run started from, never a caller-supplied ref, and refuses to publish unless the release tag points at that commit. release-please tags the release PR's merge commit, which is the commit its run starts from.

If step 2 fails, fix the cause and run `rebuild-release.yaml` **from the tag** (`gh workflow run rebuild-release.yaml --ref vX.Y.Z -f version=X.Y.Z`). It refuses to run when the tag is missing, when the release is already published, or when a newer version is already published (that would move `latest` and `major.minor` backwards).

`_rebuild-release.yaml` derives the tag from the root package in `release-please-config.json`, using release-please's defaults (component in tag, `v` in tag, `-` separator). It reads the component from `component` or `package-name`. `node`, `rust` and `helm` packages derive the component from their manifest, so set `component` explicitly for them.

## Managed image repos

Single-package image repos don't write these callers themselves. The xfg groups in `src/groups.yaml` sync them, along with the lint image pin and lint config, and overwrite them on every sync:

| Group               | Extends                                | Syncs                                                                                                                          |
| ------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `megalinter-flavor` | `megalinter`                           | `lint.sh` with the language flavor pin; `.golangci.yml` (with `go`); `ruff-base.toml` (with `python`); linter list             |
| `image`             | `github-ci`, `release-please`          | `.github/workflows/ci.yaml`, `release-please.yaml`, `rebuild-release.yaml`, `container-retention.yaml`                         |
| `go-image`          | `image`, `go`, `megalinter-flavor`     | the above with `language: go`                                                                                                  |
| `python-image`      | `image`, `python`, `megalinter-flavor` | the above with `language: python`; drops the `python` group's `.pylintrc` (ruff replaces pylint)                               |

Repos still own `release-please-config.json`, `.release-please-manifest.json` and `pyproject.toml`.

### Lint image pin

Every `megalinter` repo gets a managed `lint.sh`, rendered from `src/templates/lint.sh.tmpl` with the pin as `MEGALINTER_IMAGE`. repo-operator owns every pin through the `megalinterImage` var, and Renovate bumps it here. The synced file carries no Renovate annotation, so downstream repos get no pin PRs of their own. The template writes shell expansions as `$${...}`, because xfg reads a bare `${...}` as a variable. The pin comes from the first match below:

1. A per-repo `lint.sh` `vars` override in `src/repos.yaml`, for a repo on its own flavor (spruyt-labs, SunGather).
2. `megalinter-flavor` repos: a conditional group keyed on the language groups. `cpp` gives `megalinter-cpp`, `go` gives `megalinter-go`, `python` gives `megalinter-python`, `typescript` gives `megalinter-typescript`, and no language group gives `megalinter-base`.
3. Other `megalinter` repos: the conditional group for `megalinter` without `megalinter-flavor`, which pins `megalinter-container-images`.

Each language conditional excludes the others with `noneOf`, so a repo never gets two pins. A `megalinter-flavor` repo with two language groups gets none and fails the plan with `Unknown xfg template variable: megalinterImage`.

Two languages need a compound flavor such as `megalinter-go-python`: once it is built, add an `allOf: [megalinter-flavor, go, python]` conditional with its pin.

### Reverting a bad bump

A flavor or pin bump here reaches every repo on that pin on the next sync, and no downstream PR gates it. If it turns a downstream `main` red, revert the bump commit in this repo and approve the XFG Apply that the revert's push to `main` starts. The sync rewrites `lint.sh` and the other managed files back to the previous values in every affected repo. Don't fix it in the downstream repo: the next sync overwrites managed files.

### Lint config

- **Go**: `.golangci.yml` (v2) is synced whole. `goimports` `local-prefixes` comes from the repo name. Add linters per repo with a content overlay in `repos.yaml` (`linters.enable` with `$arrayMerge: append`, plus `linters.settings`).
- **Python**: ruff config stays in `pyproject.toml`. The group syncs `ruff-base.toml` and points MegaLinter's `PYTHON_RUFF` and `PYTHON_RUFF_FORMAT` at `pyproject.toml`, which extends the base and adds repo-specific settings:

```toml
[tool.ruff]
extend = "ruff-base.toml"
target-version = "py313"

[tool.ruff.lint.isort]
known-first-party = ["my_package"]
```

The base is not named `ruff.toml` or `.ruff.toml`: ruff prefers those over `pyproject.toml` in the same directory, and `.ruff.toml` is also MegaLinter's default config name, so either would bypass `pyproject.toml`.

### Per-repo values

Each workflow passes `language` from the group with xfg `vars`. Other `with:` inputs are added per repo as a content overlay in `repos.yaml`, one per workflow file. A YAML anchor writes the inputs once, so the three files can't drift apart:

```yaml
files:
  .github/workflows/ci.yaml:
    content:
      jobs:
        image:
          with: &my-repo-with
            test-command: "./scripts/test-image.sh"
  .github/workflows/release-please.yaml:
    content:
      jobs:
        release:
          with: *my-repo-with
  .github/workflows/rebuild-release.yaml:
    content:
      jobs:
        rebuild:
          with: *my-repo-with
```

The job is `image` in `ci.yaml`, `release` in `release-please.yaml` and `rebuild` in `rebuild-release.yaml`. Anchors only resolve within one file, so give each repo's anchor a unique name in `repos.yaml`. The anchor may only hold inputs that all three called workflows accept; put any other input (such as `push`, `tag-name` or `config-file`) in that file's own overlay, or GitHub rejects the callers that don't declare it.

## Caller example (Go)

`.github/workflows/ci.yaml`:

```yaml
name: CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  lint:
    permissions:
      actions: write
      contents: read
      security-events: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@main
  image:
    uses: anthony-spruyt/repo-operator/.github/workflows/_build-image.yaml@main
    with:
      language: go
  summary:
    needs: [lint, image]
    if: always()
    permissions:
      actions: read
      contents: read
    uses: anthony-spruyt/repo-operator/.github/workflows/_summary.yaml@main
```

`.github/workflows/release-please.yaml`:

```yaml
name: Release Please
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: write
  packages: write
  id-token: write
  attestations: write
jobs:
  release:
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@main
    with:
      language: go
    secrets:
      RELEASE_PLEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      RELEASE_PLEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
```

`.github/workflows/rebuild-release.yaml`:

```yaml
name: Rebuild Release
on:
  workflow_dispatch:
    inputs:
      version:
        description: Version to rebuild, without a leading v
        required: true
        type: string
permissions:
  contents: write
  packages: write
  id-token: write
  attestations: write
jobs:
  rebuild:
    uses: anthony-spruyt/repo-operator/.github/workflows/_rebuild-release.yaml@main
    with:
      version: ${{ inputs.version }}
      language: go
```

`release-please-config.json` for a single root package with plain `vX.Y.Z` tags:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "draft": true,
  "force-tag-creation": true,
  "include-component-in-tag": false,
  "packages": {
    ".": { "release-type": "simple", "bump-minor-pre-major": true }
  }
}
```

## Monorepo use

Call the actions from a job that already checked out the right ref:

```yaml
- uses: anthony-spruyt/repo-operator/.github/actions/build-image@main
  id: build
  with:
    image: my-service
    context: services/my-service
    go-mod: services/my-service/go.mod
    push: "true"
    version: ${{ needs.release.outputs.my-service-version }}
- uses: anthony-spruyt/repo-operator/.github/actions/publish-release@main
  with:
    tag: ${{ needs.release.outputs.my-service-tag }}
    image-ref: ${{ steps.build.outputs.image-ref }}
    digest: ${{ steps.build.outputs.digest }}
```
