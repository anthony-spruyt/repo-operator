# Shared CI

Reusable workflows and composite actions that other repos call from this repo. Callers pin a commit on `main` by its full SHA, with a `# main` comment: `uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@<sha> # main`. Renovate reads the comment, looks up the branch's current commit through its `github-digest` datasource, and bumps every pin in a repo in one monthly
`repo-operator shared CI` PR. Every merge here moves `main`, so that PR comes every month whether or not a shared workflow changed. A pin with no comment is never bumped, and an unpinned `@main` gets a pin PR.

The synced callers (`src/templates/.github/workflows/`) carry the comment here, so Renovate bumps them in this repo and the next sync carries the new SHA out. xfg drops YAML comments when it writes a file, so the synced copies hold a bare SHA that Renovate skips: downstream repos get no pin PRs for managed files. Callers a repo owns (a hand-edited `ci.yaml`, or an unmanaged workflow) keep the
comment, and Renovate bumps them in that repo. A `ci.yaml` that a repo keeps through a `createOnly` override is seeded the same way, without the comment, so add `# main` to its `uses:` lines by hand after the first sync, or it stays on that SHA. To ship a fix before the monthly window, tick the group on a Renovate dashboard: repo-operator's for the synced callers (the next Apply carries it out),
or the owning repo's for its own callers.

The image workflows build every release-please package that holds a `Dockerfile`, so a repo with one image at the root and a monorepo with several use the same callers (see [Images](#images)). For Go tests, `go.mod` sits in `workdir` (default the repo root). Repos with their own build jobs can call the composite actions instead.

A reusable workflow resolves `uses: ./...` against the caller's checkout, not against this repo. That is why these workflows refer to each other, and to the actions, with `$/` (for example `uses: $/.github/actions/build-image`), which resolves to this repo at the same ref as the calling workflow. To test a branch of this repo, point the caller at the branch; the internal references follow it.

## Composite actions

### `build-image`

Builds an image with buildx. With `push: "true"` it also pushes to GHCR, and to Docker Hub when `dockerhub-namespace` is set. The push includes an SBOM, `provenance: mode=max` and an `actions/attest-build-provenance` attestation.

Tags are `<prefix><version>`, `<prefix><major>.<minor>` and `latest`, plus any `extra-tags` rules. The `org.opencontainers.image.version` label is `<prefix><version>`. Check out the repo first: labels such as `org.opencontainers.image.revision` come from the checked-out commit (`docker/metadata-action` `context: git`). Check out a branch, tag or pull request ref, not a bare SHA, which
metadata-action v6.2.0 can't resolve ([docker/metadata-action#720](https://github.com/docker/metadata-action/issues/720)). Pushing needs `packages`, `id-token` and `attestations: write`.

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

Appends the image reference, digest and run link to a release-please draft release, then publishes it. Run it as the last step of the job that pushed the image. If any earlier step fails, the release stays a draft, so a published release always has an image behind it. The action refuses to publish with an empty digest, and leaves an already published release unchanged.

Inputs: `tag`, `image-ref`, `digest`, and `github-token` (defaults to `github.token`, which needs `contents: write`).

### `detect-images`

Lists a repo's images as a build matrix. An image is a package in `release-please-config.json` whose path holds a `Dockerfile` or `flavor.yaml` (not searched recursively). A repo without that file, or without such a package, has no images. The image name is the package's `component`, else the path's basename, else (path `.`) the lowercased repository name.

An optional `<path>/metadata.yaml` sets each image's settings. All are optional, and paths are relative to the repo root:

- `build_context`: build context directory (default: the package path); the Dockerfile stays `<path>/Dockerfile`
- `watch`: extra paths whose changes rebuild the image; each matches that file or anything under that directory
- `prepare-command`: shell command the build runs before building, such as generating a Dockerfile
- `free-disk` (default `false`): free runner disk space before building
- `extra-tags`: extra `docker/metadata-action` tag rules, as a string or a list
- `test-command`: shell command run against the built image (`$IMAGE_REF`)

In `changed` mode each changed file belongs to the package with the longest matching path, so a change in a nested package does not rebuild its parent. A file under one of a package's `exclude-paths` (repo-relative, as in release-please) does not belong to that package and falls through to the next-longest match, or to none. An image builds when a file it owns changed, a `watch` path changed, or a file under its
`build_context` changed. A pull request diffs against the merge base with `base-sha`; anything else diffs `HEAD~1`, which suits squash merges. Check out with `fetch-depth: 0` on pull requests and at least 2 on pushes.

Release files never trigger a build. Each package's changelog (`changelog-path`, default `CHANGELOG.md`) and `.release-please-manifest.json` are always skipped. A diff that changes the manifest and nothing but release files is a release PR and builds nothing. Release files also include the version files release-please writes, which skip only in a release PR, because dependency updates change them too:

- the package's `extra-files` (else the top-level ones): string entries and `{ "type", "path" }` objects, relative to the package path unless they start with `/`. Glob entries are not matched
- `node`, release-please's default: `package.json`, `package-lock.json`, `npm-shrinkwrap.json`, `samples/package.json`, and the root `changelog.json`
- `python`: `setup.cfg`, `setup.py`, `pyproject.toml`, `<name>/__init__.py`, `src/<name>/__init__.py`, any `version.py`, and the root `changelog.json`
- `simple`: `version-file`, default `version.txt`
- `go`: `version-file` when set

Other release types count only their changelog and `extra-files`, so their release PRs still build.

- `mode` (default `changed`): `changed`; `all` for every image without diffing; `released` for the images release-please just released; `rebuild` for one image at `version`
- `image`: select exactly this image; fails when the repo has no such image. In `rebuild` mode it may be empty only when the repo has one image, and `released` mode refuses it
- `base-sha` (default: the pull request's base commit): diff against the merge base with this commit; empty diffs `HEAD~1`
- `releases`: `released` mode only, the release-please-action outputs as JSON (`toJSON(steps.<id>.outputs)`)
- `version`: `rebuild` mode only, the version without a leading `v`
- `root-name`: image name for a package at path `.`; empty uses the lowercased repository name

The action outputs `matrix` (`{"include":[...]}`) and `has-images` (`"true"` or `"false"`). Each entry holds `name`, `path`, `context`, `dockerfile`, `watch`, `prepare-command`, `free-disk` (a boolean), `extra-tags` and `test-command`, with the defaults filled in. In `released` and `rebuild` mode each entry also holds `version`, `tag-name` (the git tag) and `tag-prefix` (the docker tag's).

`released` mode reads each released path's `<path>--tag_name` and `<path>--version` outputs (unprefixed for path `.`) and fails unless the tag ends with the version. A released package without a `Dockerfile` is not an image and is left out. `rebuild` mode derives the git tag the way release-please's `TagName` does: the component (`component`, else `package-name`), then
`tag-separator` (default `-`), then `v` when `include-v-in-tag` (default `true`), then the version; `include-component-in-tag: false` drops the component and separator. Each setting comes from the package, else the top level. `node`, `rust` and `helm` packages derive the component from their manifest, so set `component` explicitly for them.

The docker tag prefix is `v` only when `include-v-in-tag` is set to `true` on the package or at the top level. Left unset it is empty, even though release-please's git tag then has a `v`, so a `v1.2.3` release keeps its `1.2.3` docker tag.

### `sonar-new-issues`

Fails a pull request when SonarQube Cloud reports any open issue on it, or any security hotspot still to review. The free plan's locked "Sonar way" gate fails only when a rating drops, so new code smells pass it; this check closes that gap. Run it from `pull_request` events only.

It first polls `api/project_pull_requests/list` until SonarQube Cloud has analysed the PR's head commit, then waits until `api/issues/search` returns as many open issues as that analysis counted, and `api/hotspots/search` as many hotspots to review as `api/measures/component` reports, because the search indexes can trail the analysis. All waits share `timeout-seconds`. It fails with a clear
message if SonarQube Cloud never catches up, if a call keeps failing after retries, or if the project does not exist.

Issues marked Accepted or False positive, and hotspots reviewed as Safe, never fail it. Each finding becomes an error annotation on its file and line, with a link to SonarQube Cloud.

All calls are unauthenticated, so it needs no token and no permissions, and it works on fork PRs. That limits it to public projects. Everything SonarQube Cloud returns is escaped before it reaches a workflow command or the step summary.

- `project-key` (default `<owner>_<repo>`): SonarQube Cloud project key
- `min-severity` (default `INFO`): lowest impact severity that fails: `INFO`, `LOW`, `MEDIUM`, `HIGH` or `BLOCKER`. An issue with no impact severity always fails
- `include-hotspots` (default `"true"`): also fail on hotspots to review
- `timeout-seconds` (default `900`): how long to wait for SonarQube Cloud

## Reusable workflows

- `_go-test.yaml`: `go build ./...` and `go test -race ./...` from `workdir` (default `.`). Needs `contents: read`.
- `_python-uv-test.yaml`: `uv run --frozen pytest`, once per `test-paths` line, then `extra-commands`. `groups` adds PEP 735 dependency groups (`--group`) on top of uv's default `dev`; `extras` adds optional extras. Needs `contents: read`.
- `_sonar-new-issues.yaml`: the [`sonar-new-issues`](#sonar-new-issues) check as a job (`New Issues`), skipped outside `pull_request` events and on Mergify merge-queue PRs, which hold only PRs that already passed it and would not see their Accepted issues. It takes the action's inputs, needs no permissions, and blocks all egress except SonarQube Cloud and GitHub.
- `_images.yaml`: the `image` job of the standard `ci.yaml`. See [Images](#images). Needs `contents: read`.
- `_build-image.yaml`: one image. Runs `prepare-command` and frees disk when asked, the tests for `language` (`go`, `python` or `none`), then `build-image`. Without `push`, a `contents: read` job builds only. With `push: true`, a separate job pushes and runs `publish-release`; only that job needs the publishing permissions.
- `_release-please.yaml`: release-please, then a matrix that publishes each released image with `push: true` on its own tag. release-please itself acts with the app token, so callers grant only the publishing permissions. Only the image job undrafts a release, so a released package without a `Dockerfile` stays a draft.
- `_rebuild-release.yaml`: rebuild and publish one release whose image job failed. Needs the publishing permissions.
- `_container-retention.yaml`: delete old GHCR package versions. See [Container retention](#container-retention).

Publishing permissions are `contents`, `packages`, `id-token` and `attestations: write`.

`_images.yaml`, `_release-please.yaml` and `_rebuild-release.yaml` share these inputs, which apply to every image:

- `language`, `workdir`
- `image`: the name of an image at the repo root (default: the lowercased repository name)
- `test-command`: for images whose `metadata.yaml` sets none
- `dockerhub-namespace`, `dockerhub-username`
- `python-version`, `python-groups`, `python-extras`, `python-test-paths`, `python-extra-commands`

`_rebuild-release.yaml` also takes `version`. `_build-image.yaml` takes the same inputs plus the per-image ones that `detect-images` fills in: `context`, `dockerfile`, `prepare-command`, `free-disk`, `extra-tags`, and for publishing `push`, `version`, `tag-name` and `tag-prefix`.

Pass `secrets: DOCKERHUB_TOKEN` for Docker Hub. `_release-please.yaml` also needs `RELEASE_PLEASE_APP_CLIENT_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY`, which the `release-please` group syncs.

Go linting is not a workflow job. MegaLinter (`_lint.yaml`) owns it.

`_lint.yaml` runs three jobs. Callers grant `actions: read`, `contents: read` and `security-events: write`:

- `megalinter`: every linter but lychee, with no token and harden-runner `block`. On public repos it saves the SARIF report as an artifact.
- `lint`: uploads that SARIF to code scanning. It is the only job with `security-events: write`, and it never checks out the PR's code. Its id stays `lint` because the id is part of the code scanning analysis key, so existing alerts carry over.
- `lychee`: the link checker alone, with no token (MegaLinter hides `*TOKEN*` variables from linters anyway) and harden-runner `audit`, because links reach arbitrary hosts.

The `megalinter` allowlist comes from egress logged across all repos: GitHub, GHCR (the image pull), Trivy's database mirrors, the Go module proxy (golangci-lint), `registry.coder.com` (Trivy on spruyt-labs' Terraform), and the artifact service. A new linter that downloads at runtime fails there until its host is added.

### Images

The standard `ci.yaml`'s `image` job calls `_images.yaml` after `lint` and `repo`. Its `Detect` job runs [`detect-images`](#detect-images) and a matrix job runs `_build-image.yaml` for each image whose files changed: build and test, no push. A repo without images, or a change that touches none, skips the matrix and runs only `Detect`. A `workflow_dispatch` run builds every image,
or only the one in the caller's `image` dispatch input. Each image's jobs show up as `image / <name> / ...`.

Per-image settings live in the repo, in `<path>/metadata.yaml` (see [`detect-images`](#detect-images)), so a new image needs no change here. The `with:` inputs on the `image` job apply to every image.

`_release-please.yaml` runs release-please, then `detect-images` in `released` mode, and publishes every released image with its own version and tag; one merge that releases several packages publishes them all. `_rebuild-release.yaml` runs `detect-images` in `rebuild` mode for the caller's `image` dispatch input and its `version` input, so it rebuilds one image per run.

### Container retention

`_container-retention.yaml` runs [ghcr-cleanup-action](https://github.com/dataaxiom/ghcr-cleanup-action) with the caller's `GITHUB_TOKEN`, so no account-wide token is needed. It deletes:

- tagged versions beyond the newest `keep-n-tagged` that are older than `older-than`. Old release tags go too, so consumers that pin a release must keep up. `latest` is never deleted.
- ghost multi-arch images, whose platform images are all missing.

Untagged versions are kept: setting `keep-n-tagged` turns off the action's default of deleting them. Multi-arch children, attestations and signatures are deleted only with their parent.

- `packages` (default: repository name, lowercased): comma-separated package names. Wildcards are refused, because expanding them needs a PAT.
- `older-than` (default `4 weeks`): must be a positive interval of at most 99999 units, such as `4 weeks` or `30 days`
- `keep-n-tagged` (default `5`): must be at least `1`
- `dry-run` (default `false`): log what would be deleted, delete nothing

Runs for the same repo queue rather than overlap, because the action is not safe to run in parallel.

The calling job needs `packages: write`, and each package must give the calling repo the **Admin** role under its Actions access settings. Write is enough to push but not to delete versions. The role is set in the package settings; there is no API for it, and the packages API does not report it.

A package first pushed by the calling repo's own workflow with `GITHUB_TOKEN` already gives that repo Admin. A package first pushed from another repo keeps that repo's link and roles, so grant the role by hand at `https://github.com/users/<owner>/packages/container/<package>/settings`. mcp-header-proxy and kata-tap-qdisc-fix were first pushed from spruyt-labs, for example.

A repo with several images passes them all in `packages`. container-images#2131 moves container-images onto this workflow, with a job before the call that reads the list from `release-please-config.json`.

The `image` group syncs a caller to each image repo as `container-retention.yaml` (see [Managed image repos](#managed-image-repos)). It deletes for real every Saturday at 17:00 UTC, and a dispatch defaults to a dry run. A caller looks like this:

```yaml
name: Container Retention
on:
  schedule:
    - cron: "0 17 * * 6"
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
    uses: anthony-spruyt/repo-operator/.github/workflows/_container-retention.yaml@<sha> # main
    with:
      dry-run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry-run }}
```

On a scheduled run `github.event_name == 'workflow_dispatch'` is false, so `dry-run` is `false` without reading `inputs.dry-run`. Before a new repo's first scheduled run:

1. Give the calling repo the **Admin** role on each package.
2. Dispatch with `dry-run` on, and check the logged deletions.
3. Dispatch once with `dry-run` off.
4. Confirm that `latest`, the newest `keep-n-tagged` tags and every digest a consumer pins still pull.

### Release flow

1. release-please opens a release PR. Merging it creates a tag and a **draft** release per released package (`"draft": true` and `"force-tag-creation": true` in the config).
2. Each released image is built from its tag, tested, pushed and attested.
3. `publish-release` adds the image details and undrafts that image's release.

The image job checks out the commit the run started from, never a caller-supplied ref, and refuses to publish unless the release tag points at that commit. The provenance attestation always names the run's commit (`github.sha`), and no input overrides it, so building any other commit would sign the wrong source. release-please tags the release PR's merge commit, which is the commit its run starts
from.

A push to `main` while a Release Please run is pending makes GitHub cancel that run. If the cancelled run was the release PR's merge, the next run's release-please creates the release for the earlier merge commit, and its image job refuses: the tag is not the commit that run started from. The release stays a draft and the run fails with the rebuild command.

If step 2 fails, fix the cause and run `rebuild-release.yaml` **from the tag**, once per failed image (`gh workflow run rebuild-release.yaml --ref <tag> -f image=<image> -f version=X.Y.Z`; `image` may be left out in a repo with one image).
It refuses to run when it was not started from the tag, when the tag is missing, when the release is already published, or when a newer version of that image is already published (that would move `latest` and `major.minor` backwards). A draft also needs a rebuild
if a run dies between creating the release and relabelling the release PR: the next run fails on the duplicate release and starts no image job.

`publish-release` leaves a release that is already published unchanged, so a rebuild that overlaps the release run's image job doesn't append a second image section.

### Verifying an image attestation

The attestation is signed by the workflow that ran `build-image`, not by the repo that owns the image. Images built by the shared `_build-image.yaml` (mcp-header-proxy, kata-tap-qdisc-fix, traefik-api-key-auth, litellm-middleware, SunGather) are signed by repo-operator:

```bash
gh attestation verify oci://ghcr.io/anthony-spruyt/<image>:<tag> \
  --repo anthony-spruyt/<repo> \
  --signer-repo anthony-spruyt/repo-operator
```

`--repo` is the source repo that the attestation names. Without `--signer-repo` the check fails, because by default `gh` expects the signer to be a workflow in the source repo.

llm-guard (container-images) and bull-board (spruyt-labs) are signed by their own repo's `_build-image.yaml`, which calls the `build-image` action rather than the shared workflow. Pin the signer workflow for those:

```bash
gh attestation verify oci://ghcr.io/anthony-spruyt/llm-guard:<tag> \
  --repo anthony-spruyt/container-images \
  --signer-workflow anthony-spruyt/container-images/.github/workflows/_build-image.yaml

gh attestation verify oci://ghcr.io/anthony-spruyt/bull-board:<tag> \
  --repo anthony-spruyt/spruyt-labs \
  --signer-workflow anthony-spruyt/spruyt-labs/.github/workflows/_build-image.yaml
```

`_rebuild-release.yaml` derives the tag from `release-please-config.json` as `detect-images` describes.

## Standard `ci.yaml` and `ci-repo.yaml`

A repo's CI lives in two workflow files ([#610](https://github.com/anthony-spruyt/repo-operator/issues/610)):

| File                             | Owner                                                         | Contents                                                                                                                                                                                                         |
| -------------------------------- | ------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/ci.yaml`      | repo-operator, written on every sync by the `github-ci` group | `lint`, then `repo` (`needs: lint`, calls `./.github/workflows/ci-repo.yaml` with `secrets: inherit`), then `image` (`needs: [lint, repo]`, calls `_images.yaml`), then `summary` (`needs: [lint, repo, image]`) |
| `.github/workflows/ci-repo.yaml` | the repo, seeded once by the `github-ci` group (`createOnly`) | `on: workflow_call` and the repo-only jobs. The seed holds one job that never runs, because a workflow needs at least one job and `ci.yaml` calls it                                                             |

The seed's job, `No repo jobs yet`, skips itself with `if: "github.event_name == 'never'"`. actionlint rejects a constant condition such as `if: false`, and target repos lint every workflow, so the seed would fail their `lint`. Guard Tests run actionlint, with the synced `actionlint.yaml`, on the seed and the rendered `ci.yaml`; MegaLinter only lints this repo's own
`.github/workflows/`.

`summary / Check Results` stays the one required check, in the rulesets and in the Mergify queue. `_summary.yaml` judges every job in the run, reading every page of the jobs API, and the jobs `ci-repo.yaml` runs show up in it as `repo / <job name>`, so a failing repo job fails `summary`. Repo jobs wait for `lint`. Move a job into `ci-repo.yaml` in the same PR that adds the `repo` call, so it never
runs ungated.

`repo` gets `contents: read`, and permissions only narrow down a call chain, so a repo job can't take more than that. A repo that needs more, and any other repo quirk (an extra trigger, a dispatch input, a concurrency setting), gets an xfg overlay on `ci.yaml` in `src/repos.yaml`.
xfg's overlay adds the `labeled` pull request trigger for its `run-integration` label, and guards `lint`, `repo`, `image` and
`summary` so that any other label skips the run instead of posting a green `summary` over a failed one. Keep the job ids `lint`, `summary` and `image`: the Mergify queue condition, the code scanning analysis key and the per-repo `jobs.image.with` overlays depend on them. An environment's secrets reach a called job that declares `environment:` itself.

Every repo gets the same `ci.yaml`. The `image` job builds the repo's images (see [Images](#images)); `image` waits for `repo`, so repo tests gate the builds. The `go-image` and `python-image` groups add only `language` to the `image` job. xfg pushes each repo's changes as one commit (`prOptions.merge: direct`), so the seed lands with the `ci.yaml` that calls it; a `ci.yaml` that calls a missing
`ci-repo.yaml` makes the whole run invalid.

Three repos keep their own `ci.yaml` through a per-repo `createOnly: true` override: repo-operator for good, because its `ci.yaml` hosts XFG Plan and Apply, and spruyt-labs and container-images until [#604](https://github.com/anthony-spruyt/repo-operator/issues/604) moves them onto the standard file.

xfg never touches `ci-repo.yaml` after the seed, and the seed holds no pins (xfg drops comments, so a pin there would carry no `# main`). Jobs a repo adds keep their `# main` comments, and the repo's own Renovate bumps them.

## Managed image repos

Single-package image repos don't write these callers themselves. The xfg groups in `src/groups.yaml` sync them, along with the lint image pin and lint config, and overwrite them on every sync:

| Group               | Extends                                | Syncs                                                                                                              |
| ------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `megalinter-flavor` | `megalinter`                           | `lint.sh` with the language flavor pin; `.golangci.yml` (with `go`); `ruff-base.toml` (with `python`); linter list |
| `image`             | `github-ci`, `release-please`          | `.github/workflows/release-please.yaml`, `rebuild-release.yaml`, `container-retention.yaml`                        |
| `go-image`          | `image`, `go`, `megalinter-flavor`     | the above with `language: go`, and `language: go` on `ci.yaml`'s `image` job                                       |
| `python-image`      | `image`, `python`, `megalinter-flavor` | the above with `language: python`, and `language: python` on `ci.yaml`'s `image` job                               |

Repos still own `release-please-config.json`, `.release-please-manifest.json` and `pyproject.toml`.

### Lint image pin

Every `megalinter` repo gets a managed `lint.sh`, rendered from `src/templates/lint.sh.tmpl` with the pin as `MEGALINTER_IMAGE`. repo-operator owns every pin through the `megalinterImage` var, and Renovate bumps it here. The synced file carries no Renovate annotation, so downstream repos get no pin PRs of their own. The template writes shell expansions as `$${...}`, because xfg reads a bare
`${...}` as a variable. The pin comes from the first match below:

1. A per-repo `lint.sh` `vars` override in `src/repos.yaml`, for a repo on its own flavor (spruyt-labs).
2. `megalinter-flavor` repos: a conditional group keyed on the language groups. `cpp` gives `megalinter-cpp`, `go` gives `megalinter-go`, `python` gives `megalinter-python`, `typescript` gives `megalinter-typescript`, and no language group gives `megalinter-base`.

Each language conditional excludes the others with `noneOf`, so a repo never gets two pins. A `megalinter-flavor` repo with two language groups gets none and fails the plan with `Unknown xfg template variable: megalinterImage`.

Two languages need a compound flavor such as `megalinter-go-python`: once it is built, add an `allOf: [megalinter-flavor, go, python]` conditional with its pin.

### Reverting a bad bump

A flavor or pin bump here reaches every repo on that pin on the next sync, and no downstream PR gates it; the [lint canary](#lint-canary) is the check before merge. If it turns a downstream `main` red, revert the bump commit in this repo and approve the XFG Apply that the revert's push to `main` starts. The sync rewrites `lint.sh` and the other managed files back to the previous values in every
affected repo. Don't fix it in the downstream repo: the next sync overwrites managed files.

### Lint canary

`.github/workflows/lint-canary.yaml` catches a bad bump before it merges. It runs on PRs here that touch a lint pin or lint template (`src/groups.yaml`, `src/repos.yaml`, and the lint files under `src/templates/`):

1. **Render**: `xfg sync --dry-run --render-dir` writes every file the sync would change, per repo. A repo is affected when one of its lint files (`lint.sh`, `.mega-linter-base.yml`, `.mega-linter.yml`, `.golangci.yml`, `ruff-base.toml`, `trivy-mega-linter.yaml`, `.pylintrc`) would be written or deleted. The job summary lists them.
2. **Lint**: one job per affected repo checks out its `main`, copies the rendered files over it, deletes the files the sync would delete, and runs `./lint.sh --ci` on the whole codebase.

A pin to an image that lacks one of a repo's enabled linters fails, because MegaLinter cannot run the missing linter. So do new findings from a changed rule. The canary is not a required check: read its result before merging. A failure can also come from a repo whose `main` is already red; compare with that repo's last CI run.

The canary renders against each repo's current `main`, so it also lints changes merged here but not yet synced.

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

The group sets `language`: with xfg `vars` in `release-please.yaml` and `rebuild-release.yaml`, and with a content overlay on `ci.yaml`. Settings for one image go in its `metadata.yaml`. Other `with:` inputs, which apply to every image, are added per repo as a content overlay in `repos.yaml`, one per workflow file. A YAML anchor writes the inputs once, so the three files can't drift apart:

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

The job is `image` in `ci.yaml`, `release` in `release-please.yaml` and `rebuild` in `rebuild-release.yaml`. Anchors only resolve within one file, so give each repo's anchor a unique name in `repos.yaml`. The anchor may only hold inputs that all three called workflows accept; put any other input (such as `version`) in that file's own overlay, or GitHub rejects the callers
that don't declare it.

`container-retention.yaml` cleans the lowercased repository name. A repo whose package has another name sets it with the `retentionPackages` var (comma-separated):

```yaml
files:
  .github/workflows/container-retention.yaml:
    vars:
      retentionPackages: "my-image"
```

## Caller example (Go)

`.github/workflows/ci.yaml`:

```yaml
name: CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
permissions: {}
jobs:
  lint:
    permissions:
      actions: read
      contents: read
      security-events: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@<sha> # main
  repo:
    needs: [lint]
    permissions:
      contents: read
    uses: ./.github/workflows/ci-repo.yaml
    secrets: inherit
  image:
    needs: [lint, repo]
    permissions:
      contents: read
    uses: anthony-spruyt/repo-operator/.github/workflows/_images.yaml@<sha> # main
    with:
      language: go
  summary:
    needs: [lint, repo, image]
    if: always()
    permissions:
      actions: read
      contents: read
    uses: anthony-spruyt/repo-operator/.github/workflows/_summary.yaml@<sha> # main
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
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@<sha> # main
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
      image:
        description: Image to rebuild; leave empty when the repo has one image
        required: false
        type: string
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
    uses: anthony-spruyt/repo-operator/.github/workflows/_rebuild-release.yaml@<sha> # main
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
- uses: anthony-spruyt/repo-operator/.github/actions/build-image@<sha> # main
  id: build
  with:
    image: my-service
    context: services/my-service
    go-mod: services/my-service/go.mod
    push: "true"
    version: ${{ needs.release.outputs.my-service-version }}
- uses: anthony-spruyt/repo-operator/.github/actions/publish-release@<sha> # main
  with:
    tag: ${{ needs.release.outputs.my-service-tag }}
    image-ref: ${{ steps.build.outputs.image-ref }}
    digest: ${{ steps.build.outputs.digest }}
```
