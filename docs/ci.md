# Shared CI

Reusable workflows and composite actions that other repos call from this repo. Callers pin a commit on `main` by its full SHA, with a `# main` comment: `uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@<sha> # main`. Renovate reads the comment, looks up the branch's current commit through its `github-digest` datasource, and bumps every pin in a repo in one monthly
`repo-operator shared CI` PR. Every merge here moves `main`, so that PR comes every month whether or not a shared workflow changed. A pin with no comment is never bumped, and an unpinned `@main` gets a pin PR.

The synced callers (`src/templates/.github/workflows/`) carry the comment here, so Renovate bumps them in this repo and the next sync carries the new SHA out. xfg drops YAML comments when it writes a file, so the synced copies hold a bare SHA that Renovate skips: downstream repos get no pin PRs for managed files. Callers a repo owns (a hand-edited `ci.yaml`, or an unmanaged workflow) keep the
comment, and Renovate bumps them in that repo. A `ci.yaml` that a repo keeps through a `createOnly` override is seeded the same way, without the comment, so add `# main` to its `uses:` lines by hand after the first sync, or it stays on that SHA. To ship a fix before the monthly window, tick the group on a Renovate dashboard: repo-operator's for the synced callers (the next Apply carries it out),
or the owning repo's for its own callers.

The image workflows build every release-please package that holds a `Dockerfile` or `flavor.yaml` (a MegaLinter flavor, whose Dockerfile is generated), so a repo with one image at the root and a monorepo with several use the same callers (see [Images](#images)). Each image's tests run in its `workdir`: the package path (the repo root for a single-image repo) unless its `metadata.yaml` sets one, so
`go.mod`, `pyproject.toml` or `package.json` sits there. Repos with their own build jobs can call the composite actions instead.

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
- `test-command`: shell command run against the built image (`$IMAGE_REF`). A `test.sh` in the package runs only when this calls it, such as `bash ./<path>/test.sh "$IMAGE_REF"`; nothing finds it on its own
- `language`: the tests to run before the build, `go`, `node`, `python` or `none`; empty uses the calling workflow's `language` input, so a repo with one language sets nothing
- `workdir` (default: the package path): directory the tests run in, holding `go.mod`, `package.json` or `pyproject.toml`

`prepare-command` and `test-command` run as shell on the runner, in the pull request build and in the release `publish` job, which holds the publishing permissions (`id-token: write` and `packages: write` among them). Treat them as code with that access.

In `changed` mode each changed file belongs to the package with the longest matching path, so a change in a nested package does not rebuild its parent. A file under one of a package's `exclude-paths` (repo-relative, as in release-please) does not belong to that package and falls through to the next-longest match, or to none. An image builds when a file it owns changed, a `watch` path changed, or a
file under its `build_context` changed. A pull request diffs against the merge base with `base-sha`; anything else diffs `HEAD~1`, which suits squash merges. Check out with `fetch-depth: 0` on pull requests and at least 2 on pushes.

On a pull request, images are selected twice: once with the PR's `release-please-config.json` and once with the config at `base-sha`. An image that either selects builds. The base branch's config also selects images, so a PR's config can only add builds, and a package the PR adds still builds. A push uses the pushed commit's config only.

Release files never trigger a build. Each package's changelog (`changelog-path`, default `CHANGELOG.md`) and `.release-please-manifest.json` are always skipped. A diff that changes the manifest and nothing but release files is a release PR and builds nothing. Release files also include the version files release-please writes, which skip only in a release PR, because dependency updates change them
too:

- the package's `extra-files` (else the top-level ones): string entries and `{ "type", "path" }` objects, relative to the package path unless they start with `/`. Glob entries are not matched
- `node`, release-please's default: `package.json`, `package-lock.json`, `npm-shrinkwrap.json`, `samples/package.json`, and the root `changelog.json`
- `python`: `setup.cfg`, `setup.py`, `pyproject.toml`, `<name>/__init__.py`, `src/<name>/__init__.py`, any `version.py`, and the root `changelog.json`
- `simple`: `version-file`, default `version.txt`
- `go`: `version-file` when set

Other release types count only their changelog and `extra-files`, so their release PRs still build.

- `mode` (default `changed`): `changed`; `all` for every image without diffing; `released` for the images release-please just released
- `image`: select exactly this image; fails when the repo has no such image. `released` mode refuses it
- `base-sha` (default: the pull request's base commit): diff against the merge base with this commit, and select images with its config as well; empty diffs `HEAD~1`
- `releases`: `released` mode only, the release-please-action outputs as JSON (`toJSON(steps.<id>.outputs)`)
- `root-name`: image name for a package at path `.`; empty uses the lowercased repository name

The action outputs `matrix` (`{"include":[...]}`) and `has-images` (`"true"` or `"false"`). Each entry holds `name`, `path`, `context`, `dockerfile`, `watch`, `prepare-command`, `free-disk` (a boolean), `extra-tags`, `test-command`, `language` (empty when `metadata.yaml` sets none) and `workdir`, with the defaults filled in. In `released` mode each entry also holds `version`, `tag-name` (the git
tag) and `tag-prefix` (the docker tag's).

`released` mode reads each released path's `<path>--tag_name` and `<path>--version` outputs (unprefixed for path `.`) and fails unless the tag ends with the version. A released package without a `Dockerfile` or `flavor.yaml` is not an image and is left out.

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
- `_build-image.yaml`: one image. Runs `prepare-command` and frees disk when asked, the tests for `language` (`go`, `python`, `node` or `none`) from `workdir`, then `build-image`. `go` runs `_go-test.yaml` and passes `<workdir>/go.mod` to the build; `python` runs `_python-uv-test.yaml`; `node` sets up Node.js `node-version` (default `24`), runs `npm ci --ignore-scripts` and `tsc --noEmit`, then
  `npm test` when `package.json` has a `test` script. The build waits for the tests. Without `push`, a `contents: read` job builds only. With `push: true`, a separate job pushes and runs `publish-release` in the `release` environment; only that job needs the publishing permissions.
- `_release-please.yaml`: release-please, then a matrix that publishes each released image with `push: true` on its own tag. release-please itself acts with the app token, so callers grant only the publishing permissions. Only the image job undrafts a release, so a released package without a `Dockerfile` or `flavor.yaml` stays a draft.
- `_container-retention.yaml`: delete old GHCR package versions. See [Container retention](#container-retention).

Publishing permissions are `contents`, `packages`, `id-token` and `attestations: write`.

`_images.yaml` and `_release-please.yaml` share these inputs, which apply to every image:

- `language` (default `none`): for images whose `metadata.yaml` sets none
- `image`: the name of an image at the repo root (default: the lowercased repository name)
- `test-command`: for images whose `metadata.yaml` sets none
- `dockerhub-namespace`, `dockerhub-username`
- `python-version`, `python-groups`, `python-extras`, `python-test-paths`, `python-extra-commands`

`_build-image.yaml` takes the same inputs and `node-version`, plus the per-image ones that `detect-images` fills in: `language` (the image's, else the caller's), `workdir`, `context`, `dockerfile`, `prepare-command`, `free-disk`, `extra-tags`, and for publishing `push`, `version`, `tag-name` and `tag-prefix`.

Pass `secrets: DOCKERHUB_TOKEN` for Docker Hub. `_release-please.yaml` also needs `RELEASE_PLEASE_APP_CLIENT_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY`.

The `release-please` group creates a `release` environment whose deployment branch policy allows only `main`, and syncs both release App secrets into it; the `dockerhub` group adds `DOCKERHUB_TOKEN`. These three secrets live only in `release`, never at repo level. The `Release please` job and `_build-image.yaml`'s publish job run in `release`, so a run from any other ref is refused before it reads
them. No job on the pull request path (`_images.yaml`, the `build` job) uses the environment. A called workflow still gets only the secrets its caller passes, so callers pass each one by name even though the environment holds it; in a job that sets `environment:`, the environment's value wins over a repo secret of the same name.

xfg publishes from its own `release.yaml`, whose `Publish` job runs in `release` on a push of a `v*.*.*` tag, and `docs.yaml` deploys on a push of the floating `vN` tag. xfg's entry in `src/repos.yaml` therefore sets its `release` policy to `main` and the tag pattern `v*`, which covers both. A repo-level policy replaces the group's whole, so the entry restates `main`; the secrets still come from
the group. `tag-rules` lets only its bypass actors create those tags. Every other repo's `release` allows only `main`.

Go linting is not a workflow job. MegaLinter (`_lint.yaml`) owns it.

`_lint.yaml` runs three jobs. Callers grant `actions: read`, `contents: read` and `security-events: write`:

- `megalinter`: every linter but lychee, with no token and harden-runner `block`. On public repos it saves the SARIF report as an artifact.
- `lint`: uploads that SARIF to code scanning. It is the only job with `security-events: write`, and it never checks out the PR's code. Its id stays `lint` because the id is part of the code scanning analysis key, so existing alerts carry over.
- `lychee`: the link checker alone, with no token (MegaLinter hides `*TOKEN*` variables from linters anyway) and harden-runner `audit`, because links reach arbitrary hosts.

The `megalinter` allowlist comes from egress logged across all repos: GitHub, GHCR (the image pull), Trivy's database mirrors, the Go module proxy (golangci-lint), `registry.coder.com` (Trivy on spruyt-labs' Terraform), and the artifact service. A new linter that downloads at runtime fails there until its host is added.

### Images

The standard `ci.yaml`'s `image` job calls `_images.yaml` after `lint` and `repo`. It runs when `lint` succeeded and `repo` succeeded or was skipped (the seeded `ci-repo.yaml` has no job that runs, so `repo` is skipped); a failed `lint` or `repo`, or a cancelled run, skips it. Its `Detect` job runs [`detect-images`](#detect-images) and a matrix job runs `_build-image.yaml` for each image whose
files changed: build and test, no push. A repo without images, or a change that touches none, skips the matrix and runs only `Detect`. A `workflow_dispatch` run builds every image, or only the one in the caller's `image` dispatch input. Each image's jobs show up as `image / <name> / ...`.

Per-image settings live in the repo, in `<path>/metadata.yaml` (see [`detect-images`](#detect-images)), so a new image needs no change here. The `with:` inputs on the `image` job apply to every image.

`_release-please.yaml` runs release-please, then `detect-images` in `released` mode, and publishes every released image with its own version and tag; one merge that releases several packages publishes them all.

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

A repo with several images passes them all in `packages`: container-images and spruyt-labs list theirs in the `retentionPackages` var in `src/repos.yaml`. Only GHCR is cleaned; Docker Hub tags are kept, and so are old GitHub releases and git tags.

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

A push to `main` while a Release Please run is pending makes GitHub cancel that run. If the cancelled run was the release PR's merge, the next run's release-please creates the release for the earlier merge commit, and its image job refuses: the tag is not the commit that run started from. The release stays a draft.

If step 2 fails, the release stays a draft, so no public release lacks its image. To recover a stuck draft:

- When the cause lies outside the commit (a registry outage, a flaky test, a missing secret), fix it and use **Re-run failed jobs** on the release run. The re-run builds the same commit and tag, and publishes the draft.
- Otherwise, merge the fix and cut the next release. This covers a cause in the code, the cancelled run above, and a run that dies between creating the release and relabelling the release PR (the next run fails once on the duplicate release and starts no image job). No re-run can publish that draft; delete it once the next release is out.

`publish-release` leaves a release that is already published unchanged.

### Verifying an image attestation

The attestation is signed by the workflow that ran `build-image`, not by the repo that owns the image. Every image repo publishes through the shared `_build-image.yaml`, so its images are signed by repo-operator:

```bash
gh attestation verify oci://ghcr.io/anthony-spruyt/<image>:<tag> \
  --repo anthony-spruyt/<repo> \
  --signer-repo anthony-spruyt/repo-operator
```

`--repo` is the source repo that the attestation names. Without `--signer-repo` the check fails, because by default `gh` expects the signer to be a workflow in the source repo.

Tags released before container-images or spruyt-labs joined the `image` group are signed by that repo's own `_build-image.yaml`, which called the `build-image` action rather than the shared workflow. That covers every image of both repos, all three of spruyt-labs' (shutdown-orchestrator, agent-queue-worker and bull-board) included. Pin the signer workflow for those:

```bash
gh attestation verify oci://ghcr.io/anthony-spruyt/llm-guard:<tag> \
  --repo anthony-spruyt/container-images \
  --signer-workflow anthony-spruyt/container-images/.github/workflows/_build-image.yaml

gh attestation verify oci://ghcr.io/anthony-spruyt/<spruyt-labs-image>:<tag> \
  --repo anthony-spruyt/spruyt-labs \
  --signer-workflow anthony-spruyt/spruyt-labs/.github/workflows/_build-image.yaml
```

## Standard `ci.yaml` and `ci-repo.yaml`

A repo's CI lives in two workflow files ([#610](https://github.com/anthony-spruyt/repo-operator/issues/610)):

| File                             | Owner                                                         | Contents                                                                                                                                                                                                                                                    |
| -------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/ci.yaml`      | repo-operator, written on every sync by the `github-ci` group | `lint`, then `repo` (`needs: lint`, calls `./.github/workflows/ci-repo.yaml` with `secrets: inherit`), then `image` (`needs: [lint, repo]`, runs when `repo` succeeded or was skipped, calls `_images.yaml`), then `summary` (`needs: [lint, repo, image]`) |
| `.github/workflows/ci-repo.yaml` | the repo, seeded once by the `github-ci` group (`createOnly`) | `on: workflow_call` and the repo-only jobs. The seed holds one job that never runs, because a workflow needs at least one job and `ci.yaml` calls it                                                                                                        |

The seed's job, `No repo jobs yet`, skips itself with `if: "github.event_name == 'never'"`. actionlint rejects a constant condition such as `if: false`, and target repos lint every workflow, so the seed would fail their `lint`. Guard Tests run actionlint, with the synced `actionlint.yaml`, on the seed and the rendered `ci.yaml`; MegaLinter only lints this repo's own `.github/workflows/`. They
check the actionlint tarball against a sha256 pinned beside its version, not the release's own `checksums.txt`. The `digest=sha256` Renovate annotation puts the pair on the `github-release-attachments` datasource, so one Renovate PR bumps both.

`summary / Check Results` is the one required check from `ci.yaml`, in the rulesets and in the Mergify queue; the rulesets also require [`PR Title`](#pr-title-check). `_summary.yaml` judges every job in the run, reading every page of the jobs API, and the jobs `ci-repo.yaml` runs show up in it as `repo / <job name>`, so a failing repo job fails `summary`. Repo jobs wait for `lint`. Move a job into
`ci-repo.yaml` in the same PR that adds the `repo` call, so it never runs ungated.

`repo` gets `contents: read`, and permissions only narrow down a call chain, so a repo job can't take more than that. A repo that needs more, and any other repo quirk (an extra trigger, a dispatch input, a concurrency setting), gets an xfg overlay on `ci.yaml` in `src/repos.yaml`. spruyt-labs' overlay gives `repo` `actions: read` and `pull-requests: read` as well, for its paths filter. xfg's
overlay adds the `labeled` pull request trigger for its `run-integration` label, and guards `lint`, `repo`, `image`, `sonar` and `summary` so that any other label skips the run instead of posting a green `summary` over a failed one. Keep the job ids `lint`, `summary` and `image`: the Mergify queue condition, the code scanning analysis key and the per-repo `jobs.image.with` overlays depend on them.
An environment's secrets reach a called job that declares `environment:` itself.

Every repo gets the same `ci.yaml`. The `image` job builds the repo's images (see [Images](#images)); `image` waits for `repo`, so repo tests gate the builds. The `go-image` and `python-image` groups add only `language` to the `image` job. The `sonar` group adds a `sonar` job that calls `_sonar-new-issues.yaml` with no permissions and no `needs`, and appends it to `summary.needs` with
`$arrayMerge: append`, so `summary` judges [`sonar-new-issues`](#sonar-new-issues) as `sonar / New Issues`. Its skip outside pull requests and on Mergify merge-queue PRs counts as a pass, because `summary` fails only on a failed or cancelled job. A `sonar` repo lists `github-ci` before `sonar`, so the job merges onto the synced `ci.yaml`. The group pins the call in `src/groups.yaml` to the
template's `main` commit, and repo-operator's Renovate reads that file with its `github-actions` manager, so the monthly `repo-operator shared CI` PR bumps it with the template pins. xfg pushes each repo's changes as one commit (`prOptions.merge: direct`), so the seed lands with the `ci.yaml` that calls it; a `ci.yaml` that calls a missing `ci-repo.yaml` makes the whole run invalid.

A new push to a pull request cancels that PR's older `CI` run. Every other run (a push to `main`, a `labeled` event from xfg's overlay) gets its own concurrency group, so it never waits for or cancels another run: GitHub keeps one pending run per group and cancels the older pending one even with `cancel-in-progress: false`, and on `main` the summary and the release that follows must finish.

Only repo-operator keeps its own `ci.yaml`, through a per-repo `createOnly: true` override, because its `ci.yaml` hosts XFG Plan and Apply. It carries the same `sonar` job by hand, calling `./.github/workflows/_sonar-new-issues.yaml` so a PR checks its own branch of the workflow, and Guard Tests keep it in `summary.needs`.

xfg never touches `ci-repo.yaml` after the seed, and the seed holds no pins (xfg drops comments, so a pin there would carry no `# main`). Jobs a repo adds keep their `# main` comments, and the repo's own Renovate bumps them.

## PR title check

Repos squash-merge with the PR title and a blank body, so the title becomes the commit on `main` that release-please reads. The `github-ci` group syncs `.github/workflows/pr-title.yaml` on every sync, and its `PR Title` job checks that the title follows [Conventional Commits](https://www.conventionalcommits.org/):

| Part     | Rule                                                                                           |
| -------- | ---------------------------------------------------------------------------------------------- |
| Type     | `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore` or `revert` |
| Scope    | Optional, any value: `feat: ...` and `feat(ci): ...` both pass                                 |
| Breaking | `!` after the type or scope: `feat(api)!: ...`                                                 |
| Subject  | Must not start with an uppercase letter: `fix: Add x` fails, `fix: add x` passes               |

It runs [`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request), pinned by SHA, on `pull_request` into `main` (`opened`, `edited`, `synchronize`, `reopened`). The job has only `pull-requests: read`, checks out nothing, and runs behind harden-runner with egress blocked except the GitHub API. The action reads the PR's current title through the API, so it works
the same on fork PRs, whose `GITHUB_TOKEN` is read-only. Renaming a PR re-runs only this workflow, not `CI`. It skips Mergify merge-queue PRs, with the same condition as `_sonar-new-issues.yaml`, and a skipped required check counts as a pass.

`PR Title` is a required check in every `pr-rules` ruleset, next to `summary / Check Results`. Repos without `pr-rules` run it as advisory. repo-operator's own copy in `.github/workflows/` is the synced file, and Guard Tests keep it equal to the template.

## Managed image repos

Image repos don't write these callers themselves. The xfg groups in `src/groups.yaml` sync them, along with the lint image pin and lint config, and overwrite them on every sync:

| Group               | Extends                                    | Syncs                                                                                                                   |
| ------------------- | ------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `megalinter-flavor` | `megalinter`                               | `lint.sh` with the language flavor pin; `.golangci.yml` (with `go`); `ruff-base.toml` (with `python`); linter list      |
| `image`             | `github-ci`, `release-please`, `dockerhub` | `.github/workflows/release-please.yaml` with `language: none`, `container-retention.yaml`; the `DOCKERHUB_TOKEN` secret |
| `go-image`          | `image`, `go`, `megalinter-flavor`         | the above with `language: go`, and `language: go` on `ci.yaml`'s `image` job                                            |
| `python-image`      | `image`, `python`, `megalinter-flavor`     | the above with `language: python`, and `language: python` on `ci.yaml`'s `image` job                                    |

A repo whose images use more than one language, such as spruyt-labs or container-images, joins `image` without a language group, and each image's `metadata.yaml` can set its `language`; an image that sets none gets the group default, `none`, and runs no language tests. A .NET repo such as agent-platform joins `image` and `dotnet` (the .NET SDK in the dev container): `_build-image.yaml` has no .NET
tests, so its image builds with `language: none` and the repo runs `dotnet test` in its `ci-repo.yaml`. Every image repo gets `image`, directly or through `go-image` or `python-image`, and sets `retentionPackages` in `src/repos.yaml` when it has more than one image or its image name isn't the lowercased repo name.

Every image publishes to GHCR and to Docker Hub as `aspruyt/<image>`, because GHCR is often slow or down. The release callers pass `dockerhub-namespace: aspruyt` and the `DOCKERHUB_TOKEN` secret, which `image` syncs through the `dockerhub` group, to `_release-please.yaml`. The `image` job in `ci.yaml` never pushes, so it gets no token.

Repos still own `release-please-config.json`, `.release-please-manifest.json` and `pyproject.toml`.

### Lint image pin

Every `megalinter` repo gets a managed `lint.sh`, rendered from `src/templates/lint.sh.tmpl` with the pin as `MEGALINTER_IMAGE`. repo-operator owns every pin through the `megalinterImage` var, and Renovate bumps it here. The synced file carries no Renovate annotation, so downstream repos get no pin PRs of their own. The template writes shell expansions as `$${...}`, because xfg reads a bare
`${...}` as a variable. The pin comes from the first match below:

1. A per-repo `lint.sh` `vars` override in `src/repos.yaml`, for a repo on its own flavor (spruyt-labs).
2. `megalinter-flavor` repos: a conditional group keyed on the language groups. `cpp` gives `megalinter-cpp`, `go` gives `megalinter-go`, `python` gives `megalinter-python`, `typescript` gives `megalinter-typescript`, and no language group gives `megalinter-base`. `dotnet` has no flavor, so it gets `megalinter-base` too.

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

The group sets `language`: with xfg `vars` in `release-please.yaml`, and with a content overlay on `ci.yaml`. Settings for one image go in its `metadata.yaml`, whose `language` overrides the group's. Other `with:` inputs, which apply to every image, are added per repo as a content overlay in `repos.yaml`, one per workflow file. A YAML anchor writes the inputs once, so the two files can't drift
apart:

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
```

The job is `image` in `ci.yaml` and `release` in `release-please.yaml`. Anchors only resolve within one file, so give each repo's anchor a unique name in `repos.yaml`. The anchor may only hold inputs that both called workflows accept; put any other input in that file's own overlay, or GitHub rejects the callers that don't declare it.

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
    if: "!cancelled() && needs.lint.result == 'success' && (needs.repo.result == 'success' || needs.repo.result == 'skipped')"
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
