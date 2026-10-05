# Shared CI

Reusable workflows and composite actions that other repos call from this repo. Pin them to `@main` for now; a floating `v1` tag is planned (#494).

Reusable workflows suit single-package repos that follow the standard layout: the project at the repo root and a `Dockerfile` there too. For Go, `go.mod` sits at the root and binaries live under `cmd/`. Monorepos can call the composite actions from their own jobs instead.

A reusable workflow resolves `uses: ./...` against the caller's checkout, not against this repo. That is why these workflows refer to each other, and to the actions, by full path (`anthony-spruyt/repo-operator/...@main`). To test a branch of this repo, point the caller and those internal references at the branch.

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
- `dockerhub-token`: Docker Hub token; required with a namespace when pushing
- `github-token` (default `github.token`): GHCR login

The action outputs `digest` and `image-ref` (`ghcr.io/<owner>/<image>:<prefix><version>`).

### `publish-release`

Appends the image reference, digest and run link to a release-please draft release, then publishes it. Run it as the last step of the job that pushed the image. If any earlier step fails, the release stays a draft, so a published release always has an image behind it. The action refuses to publish with an empty digest.

Inputs: `tag`, `image-ref`, `digest`, and `github-token` (defaults to `github.token`, which needs `contents: write`).

## Reusable workflows

- `_go-test.yaml`: `go build ./...` and `go test -race ./...` from `workdir` (default `.`). Needs `contents: read`.
- `_python-uv-test.yaml`: `uv run --frozen pytest`, once per `test-paths` line, then `extra-commands`. Needs `contents: read`.
- `_build-image.yaml`: run the tests for `language` (`go`, `python` or `none`), then `build-image`. With `push: true`, also `publish-release`. PR callers need `contents: read`.
- `_release-please.yaml`: release-please for one root (`.`) package. On release, runs `_build-image.yaml` with `push: true` on the new tag. Needs `pull-requests: write` plus the publishing permissions.
- `_rebuild-release.yaml`: rebuild and publish a release whose image job failed. Needs the publishing permissions.

Publishing permissions are `contents`, `packages`, `id-token` and `attestations: write`.

`_build-image.yaml`, `_release-please.yaml` and `_rebuild-release.yaml` share these inputs:

- `language`, `workdir`, `image`, `context`, `dockerfile`, `tag-prefix`, `dockerhub-namespace`
- `python-extras`, `python-test-paths`, `python-extra-commands`

Pass `secrets: DOCKERHUB_TOKEN` for Docker Hub. `_release-please.yaml` also needs `RELEASE_PLEASE_APP_CLIENT_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY`, which the `release-please` group syncs.

Go linting is not a workflow job. MegaLinter (`_lint.yaml`) owns it.

### Release flow

1. release-please opens a release PR. Merging it creates the tag and a **draft** release (`"draft": true` and `"force-tag-creation": true` in the config).
2. The image is built from that tag, tested, pushed and attested.
3. `publish-release` adds the image details and undrafts the release.

If step 2 fails, fix the cause and run `rebuild-release.yaml` with the version. It refuses to run when the tag is missing, when the release is already published, or when a newer version is already published (that would move `latest` and `major.minor` backwards).

`_rebuild-release.yaml` derives the tag from the root package in `release-please-config.json`, using release-please's defaults (component in tag, `v` in tag, `-` separator).

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
  actions: write
  contents: read
  security-events: write
jobs:
  lint:
    uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@main
    secrets: inherit
  image:
    uses: anthony-spruyt/repo-operator/.github/workflows/_build-image.yaml@main
    with:
      language: go
  summary:
    needs: [lint, image]
    if: always()
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
  pull-requests: write
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
