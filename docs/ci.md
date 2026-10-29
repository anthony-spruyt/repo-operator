# Shared CI

Reusable workflows and composite actions that other repos call from this repo. Callers pin a commit on `main` by its full SHA, with a `# main` comment: `uses: anthony-spruyt/repo-operator/.github/workflows/_lint.yaml@<sha> # main`. Renovate reads the comment, looks up the branch's current commit through its `github-digest` datasource, and bumps every pin in a repo in one daily
`repo-operator shared CI` PR, opened between 15:00 and 18:59 UTC (2-6am in Melbourne, 1-5am in winter). Every merge here moves `main`, so that PR comes after any day with a merge, whether or not a shared workflow changed. The window sits where `main` rarely moves: in a wider one, each bump that merges is followed by the next. repo-operator, which bumps the synced callers in `src/templates/` and `src/groups.yaml`, gets it monthly instead: merging it moves `main`, so a daily schedule would open the next PR, and an XFG Apply, every day. A pin with no comment is never bumped,
and an unpinned `@main` gets a pin PR.

The synced callers (`src/templates/.github/workflows/`) carry the comment here, so Renovate bumps them in this repo and the next sync carries the new SHA out. xfg drops YAML comments when it writes a file, so the synced copies hold a bare SHA that Renovate skips: downstream repos get no pin PRs for managed files. Callers a repo owns (a hand-edited `ci.yaml`, or an unmanaged workflow) keep the
comment, and Renovate bumps them in that repo. A `ci.yaml` that a repo keeps through a `createOnly` override is seeded the same way, without the comment, so add `# main` to its `uses:` lines by hand after the first sync, or it stays on that SHA. To ship a fix to the synced callers before repo-operator's monthly window, tick the group on repo-operator's Renovate dashboard (the next Apply carries it
out).

The image workflows build every release-please package that holds a `Dockerfile` or `flavor.yaml` (a MegaLinter flavor, whose Dockerfile is generated), so a repo with one image at the root and a monorepo with several use the same callers (see [Images](#images)). Each image's tests run in its `workdir`: the package path (the repo root for a single-image repo) unless its `metadata.yaml` sets one, so
`go.mod`, `pyproject.toml` or `package.json` sits there. Repos with their own build jobs can call the composite actions instead.

A reusable workflow resolves `uses: ./...` against the caller's checkout, not against this repo. That is why these workflows refer to each other, and to the actions, with `$/` (for example `uses: $/.github/actions/build-image`), which resolves to this repo at the same ref as the calling workflow. To test a branch of this repo, point the caller at the branch; the internal references follow it.

## Composite actions

### `build-image`

Builds an image with buildx. With `push: "true"` it also pushes to GHCR, and to Docker Hub when `dockerhub-namespace` is set. The push includes an SBOM, `provenance: mode=max` and an `actions/attest-build-provenance` attestation.

Tags are `<prefix><version>`, `<prefix><major>.<minor>` and `latest`, plus any `extra-tags` rules. With `latest: "false"` the push carries the `<prefix><version>` tag only, for a release that a newer one has superseded.
The `org.opencontainers.image.version` label is `<prefix><version>`. Check out the repo first: labels such as `org.opencontainers.image.revision` come from the checked-out commit (`docker/metadata-action` `context: git`). Check out a branch, tag or pull request ref, not a bare SHA, which
metadata-action v6.2.0 can't resolve ([docker/metadata-action#720](https://github.com/docker/metadata-action/issues/720)). Pushing needs `packages`, `id-token` and `attestations: write`.

- `image` (default: repository name): image and GHCR package name
- `context` (default `.`): build context
- `dockerfile` (default `<context>/Dockerfile`): Dockerfile path
- `push` (default `"false"`): push the image, SBOM and attestation
- `version`: version without a leading `v`; required when pushing
- `tag-prefix`: `""` or `v`, applied to the version tags only
- `extra-tags`: extra `docker/metadata-action` tag rules; ignored when `latest` is `"false"`
- `latest` (default `"true"`): `"false"` pushes the version tag only; a value other than `"true"` or `"false"` fails the action
- `build-args`: `KEY=VALUE` lines
- `go-mod`: set it for a Go image (the value is not read); adds `VERSION` (`v<version>`) and `COMMIT` build args. The Go version comes from the Dockerfile's `ARG GO_VERSION`, which Renovate bumps; Renovate never updates the `go.mod` `go` directive
- `dockerhub-namespace`: also push to `docker.io/<namespace>/<image>`
- `dockerhub-username` (default: `dockerhub-namespace`): Docker Hub login, for organisation namespaces
- `dockerhub-token`: Docker Hub token; required with a namespace when pushing
- `test-command`: shell command run against a locally loaded build (`$IMAGE_REF`) before anything is pushed
- `github-token` (default `github.token`): GHCR login

The action outputs `digest` and `image-ref` (`ghcr.io/<owner>/<image>:<prefix><version>`).

### `publish-release`

Appends the image reference, digest and run link to a release-please draft release, then publishes it. Run it as the last step of the job that pushed the image. If any earlier step fails, the release stays a draft, so a published release always has an image behind it. The action refuses to publish with an empty digest, and leaves an already published release unchanged.

Inputs: `tag`, `image-ref`, `digest`, `latest` (default `"true"`; `"false"` publishes with `--latest=false`, so the release does not take the repo's latest-release marker), and `github-token` (defaults to `github.token`, which needs `contents: write`).

### `detect-images`

Lists a repo's images as a build matrix. An image is a package in `release-please-config.json` whose path holds a `Dockerfile` or `flavor.yaml` (not searched recursively). A repo without that file, or without such a package, has no images. The image name is the package's `component`, else the path's basename, else (path `.`) the lowercased repository name.

An optional `<path>/metadata.yaml` sets each image's settings. All are optional, and paths are relative to the repo root:

- `build_context`: build context directory (default: the package path); the Dockerfile stays `<path>/Dockerfile`
- `watch`: extra paths whose changes rebuild the image; each matches that file or anything under that directory
- `prepare-command`: shell command the build runs before building, such as generating a Dockerfile. What the build needs from it must be inside `context`, and so must the Dockerfile
- `free-disk` (default `false`): free runner disk space before building
- `extra-tags`: extra `docker/metadata-action` tag rules, as a string or a list
- `test-command`: shell command run against the built image (`$IMAGE_REF`). A `test.sh` in the package runs only when this calls it, such as `bash ./<path>/test.sh "$IMAGE_REF"`; nothing finds it on its own
- `language`: the tests to run before the build, `go`, `node`, `python` or `none`; empty uses the calling workflow's `language` input, so a repo with one language sets nothing
- `workdir` (default: the package path): directory the tests run in, holding `go.mod`, `package.json` or `pyproject.toml`
- `egress`: `host:port` endpoints the image's tests, build and publish reach besides the shared lists (see [Egress](#egress)), such as `deb.debian.org:80` or `"*.example.com:443"`. Those jobs run harden-runner with the shared lists plus `egress`, so an image with no `egress` gets only the shared lists.

`prepare-command` and `test-command` run as shell on the runner only in `_build-image.yaml`'s `build` job, which has `contents: read` and no environment, for pull requests and releases alike. On a release it packs the prepared `context` as a tar artifact; `publish` waits for `build`, restores that tar (plain files and directories only) and builds and pushes from it without running either command.

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

The action outputs `matrix` (`{"include":[...]}`) and `has-images` (`"true"` or `"false"`). Each entry holds `name`, `path`, `context`, `dockerfile`, `watch`, `prepare-command`, `free-disk` (a boolean), `extra-tags`, `test-command`, `language` (empty when `metadata.yaml` sets none), `workdir` and `egress` (space-separated), with the defaults filled in. In `released` mode each entry also holds
`version`, `tag-name` (the git tag), `tag-prefix` (the docker tag's) and `latest` (a boolean).

`released` mode reads each released path's `<path>--tag_name` and `<path>--version` outputs (unprefixed for path `.`) and fails unless the tag ends with the version. `latest` is `false` only when the path's `<path>--superseded` output is `"true"`, which only [`release-drafts`](#release-drafts) sets. A released package without a `Dockerfile` or `flavor.yaml` is not an image and is left out.

The docker tag prefix is `v` only when `include-v-in-tag` is set to `true` on the package or at the top level. Left unset it is empty, even though release-please's git tag then has a `v`, so a `v1.2.3` release keeps its `1.2.3` docker tag.

### `release-drafts`

Publishes the release-please drafts that never got their image. [`_release-recover.yaml`](#release-recovery) runs it in two modes. It reads the repo through the API and checks out nothing, so the job needs only `api.github.com`. The scripts are `drafts.sh` and the action's `action.yaml`; `test/release-drafts.bats` covers them with a fake `gh`. `drafts.sh` and `detect-images` read the package list from the same `detect-images/packages.jq`.

- `mode`: `recover` on a branch ref, `synthesize` on a tag ref
- `github-token` (default `github.token`): reads contents and workflow runs; `recover` dispatches with it, which needs `actions: write`
- `app-token`: `recover` only, a token that can list draft releases, the release App token in `_release-recover.yaml`
- `releases`: `recover` only, the release-please outputs of this run as JSON (`_release-please.yaml`'s `releases` output); the drafts it names belong to this run's `images` job and are left alone
- `max-failures` (default `3`): `recover` only, the number of failed dispatched runs of one tag after which it is no longer retried

`recover` lists the draft releases and dispatches the caller workflow (`gh workflow run <caller file> --ref <tag>`, the file named by `github.workflow_ref`) on the tag of each draft that passes every check. A draft is skipped, with a notice, when:

- its tag is not a plain tag name, or does not exist
- the tag is not the exact release tag of an image package. Each package's tag is rebuilt from the `release-please-config.json` and `.release-please-manifest.json` at that tag, with the package list of `detect-images` (`packages.jq`) and release-please's `[component + separator][v]version` form, and the package must hold a `Dockerfile` or `flavor.yaml` there.
  A component that release-please reads from a package file (`node`, `dart`, `helm`, `rust`, `sfdx` without a `component` or `package-name`) cannot be rebuilt, so that draft is skipped
- the caller workflow at that tag has no job that calls `_release-recover.yaml`. **This is the signal that a draft is recoverable**: a tag cut before the caller wired it would run a workflow that ignores the tag ref, so it is left for the next release
- a run of the caller on that tag is queued or in progress

When `max-failures` or more dispatched runs of the tag have failed, the step adds a warning annotation to the run instead of dispatching again. A draft listing that fails adds a warning and fails the step. The step runs with `continue-on-error`, so a recovery failure never fails the `dispatch` job or blocks the `images` job for the run's own releases.

`synthesize` runs when the caller is a `workflow_dispatch` run on a tag ref. It checks that the tag is an image package's release tag at that tag, then outputs `release-created` (`true`) and `releases`, the JSON that `release-please-action` would have written,
in the form `detect-images` reads in `released` mode: `paths_released` as a JSON string, `<path>--tag_name` and `<path>--version` (unprefixed for path `.`), and `<path>--superseded`, which is `"true"` when the default branch's manifest holds a newer version of that package and `"false"` when it holds this one.
It fails without outputs when it cannot read the default branch, its manifest or the package's entry there, or cannot compare the two versions. The run's `images` job then builds the draft from its tag and publishes it. A tag-ref run never dispatches another run.

### `sonar-new-issues`

Fails a pull request when SonarQube Cloud reports any open issue on it, or any security hotspot still to review. The free plan's locked "Sonar way" gate fails only when a rating drops, so new code smells pass it; this check closes that gap. Run it from `pull_request` events only.

It first polls `api/project_pull_requests/list` until SonarQube Cloud has analysed the PR's head commit, then waits until `api/issues/search` returns as many open issues as that analysis counted, and `api/hotspots/search` as many hotspots to review as `api/measures/component` reports, because the search indexes can trail the analysis. All waits share `timeout-seconds`. It fails with a clear
message if SonarQube Cloud never catches up, if a call keeps failing after retries, or if the project does not exist.

Issues marked Accepted or False positive, and hotspots reviewed as Safe, never fail it. Each finding becomes an error annotation on its file and line, with a link to SonarQube Cloud.

All calls are unauthenticated, so it needs no token and no permissions, and it works on fork PRs. That limits it to public projects. Everything SonarQube Cloud returns is escaped before it reaches a workflow command or the step summary.

- `project-key` (default `<owner>_<repo>`): SonarQube Cloud project key
- `min-severity` (default `INFO`): lowest impact severity that fails: `INFO`, `LOW`, `MEDIUM`, `HIGH` or `BLOCKER`. An issue with no impact severity always fails
- `include-hotspots` (default `"true"`): also fail on hotspots to review
- `timeout-seconds` (default `900`): how long to wait for SonarQube Cloud, up to 99999. In `_sonar-new-issues.yaml` the job's 20-minute limit caps it

### `dockerhub-cleanup`

Deletes old tags from `docker.io/<namespace>/<package>` with the same rules as the GHCR cleanup (see [Container retention](#container-retention)). A version is a digest with all its tags; it is as old as its most recent tag push. The version tagged `latest` stays, and so does every version pushed within `older-than`. Of the rest, the newest `keep-n-tagged` stay and every tag of the others is
deleted. A month is 30 days and a year 365, as in the GHCR cleanup.

It logs in once through `POST /v2/auth/token`, and again when the Hub token, which lasts 10 minutes, expires. If Hub rejects a fresh token too, it stops that package. The token reaches `curl` and `jq` only through files and the environment, never their arguments. Each page of tags goes to a file, so a repository with thousands of tags lists fine.

A package whose repository is missing on the first page is skipped with a warning. Every other failure fails the run, after the remaining packages and tags are tried: a 404 on a later page or on a delete, and a tag name the registry never produces, which is not deleted.

- `namespace` (required): Docker Hub namespace
- `username` (default: `namespace`): Docker Hub login
- `token` (required): personal access token with the **Read, Write, Delete** scope; Read & Write cannot delete
- `packages` (required): comma-separated repository names
- `older-than` (default `4 weeks`), `keep-n-tagged` (default `5`), `dry-run` (default `"false"`): as in `_container-retention.yaml`

### `harden-runner`

Runs [`step-security/harden-runner`](https://github.com/step-security/harden-runner), pinned by SHA, as the first step of every job except `lychee` (below).
Its one step sets `egress-policy`, so that line in `.github/actions/harden-runner/action.yaml` is the switch for the egress mode of every job that calls it, in this repo and in the repos that call the shared workflows.
`audit` records each job's outbound calls; `block` refuses calls to hosts off the job's allowlist. Those are the only two values.

The action passes `allowed-endpoints` (default empty) and `disable-sudo-and-containers` (default `"false"`) to harden-runner unchanged. A caller never sets `egress-policy` itself.
Repo-operator's own workflows call it as `$/.github/actions/harden-runner`; workflows in other repos, and the synced `pr-title.yaml` template, call `anthony-spruyt/repo-operator/.github/actions/harden-runner@<sha> # main`. Renovate bumps that pin with the `repo-operator shared CI` group. Keep every job's allowlist current in either mode, so a flip to `block` needs no other edit.
`test/ci/harden-runner.bats` keeps every job's first step on the action, passing an allowlist and only its inputs, except `lychee`. It reads a synced workflow at its `src/templates/` source and wants the pin to be a full SHA of `anthony-spruyt/repo-operator` with a `# main` comment.

Only `lychee` in `_lint.yaml` calls harden-runner directly. It runs in `audit`, whatever the switch says, because link checks reach arbitrary hosts.

To flip the mode, edit the `egress-policy` line. The file is under `.github/`, so the owner approves the PR. After it merges:

1. Tick `repo-operator shared CI` on repo-operator's Renovate dashboard, which opens the pin bump for the synced callers.
2. Merge the pin bump.
3. Approve the XFG Apply, which carries the new pin to the synced callers.

Repo-operator's own workflows follow the merge itself, but its synced copies (`pr-title.yaml`, `trivy-scan.yaml`) change only after the pin bump and the XFG Apply. Repo-owned workflows in other repos follow their own repo's Renovate pin bump.

The mode is `block`. It needs harden-runner v2.22.3 or later: earlier versions drop allowlisted connections under `block` on some GitHub-hosted runners ([step-security/harden-runner#708](https://github.com/step-security/harden-runner/issues/708)).

## Reusable workflows

- `_go-test.yaml`: `go build ./...` and `go test -race ./...` from `workdir` (default `.`). The Go version is the `ARG GO_VERSION=<version>` of the `dockerfile` input, the same one the image build uses; with no such Dockerfile or ARG (a `FROM scratch` plugin image), setup-go reads the `go.mod` `go` directive. Needs `contents: read`.
- `_python-uv-test.yaml`: `uv run --frozen pytest`, once per `test-paths` line, then `extra-commands`. `groups` adds PEP 735 dependency groups (`--group`) on top of uv's default `dev`; `extras` adds optional extras. Needs `contents: read`.
- `_sonar-new-issues.yaml`: the [`sonar-new-issues`](#sonar-new-issues) check as a job (`New Issues`), skipped outside `pull_request` events and on Mergify merge-queue PRs, which hold only PRs that already passed it and would not see their Accepted issues. It takes the action's inputs, needs no permissions, and runs harden-runner with an allowlist of SonarQube Cloud and GitHub.
- `_images.yaml`: the `image` job of the standard `ci.yaml`. See [Images](#images). Needs `contents: read`.
- `_build-image.yaml`: one image. Runs `prepare-command` and frees disk when asked, the tests for `language` (`go`, `python`, `node` or `none`) from `workdir`, then `build-image`. `go` runs `_go-test.yaml` with the image's Dockerfile and passes `<workdir>/go.mod` to the build (only whether it is set matters), which sets `VERSION` and `COMMIT` and leaves `GO_VERSION` to the Dockerfile; `python` runs `_python-uv-test.yaml`; `node` sets up Node.js
  `node-version` (default `24`), runs `npm ci --ignore-scripts` and `tsc --noEmit`, then `npm test` when `package.json` has a `test` script. The build waits for the tests. A `contents: read` job prepares, builds and tests. With `push: true`, a separate job then builds from the prepared context, pushes and runs `publish-release` in the `publish` environment; only that job needs the publishing
  permissions.
- `_release-please.yaml`: release-please alone. It acts with the app token, minted with only contents and pull requests write, so its caller job needs only `contents: read`. Outputs `release-created` and `releases`, release-please's outputs as JSON.
- `_release-recover.yaml`: publishes the release-please drafts that never got their image. See [Release recovery](#release-recovery). The synced image release caller calls it. Takes `releases`, the output of `_release-please.yaml`, and the same two App secrets. Its `dispatch` job runs on a branch ref in the `release` environment and dispatches the caller on the tag of each stuck draft. Its `synthesize` job runs on a tag ref with no environment and no App token, and outputs `release-created` and `releases` for that tag in the form `_release-images.yaml` reads. Its caller job grants `contents: read` and `actions: write`, because a called job cannot hold more than its caller.
- `_release-images.yaml`: takes `releases` from `_release-please.yaml`, then a matrix that publishes each released image with `push: true` on its own tag. Its caller job grants the publishing permissions. Only this workflow undrafts a release, so a released package without a `Dockerfile` or `flavor.yaml` stays a draft.
- `_container-retention.yaml`: delete old GHCR package versions, and old Docker Hub tags when given a namespace. See [Container retention](#container-retention).

None of the release workflows sets `concurrency`; the caller sets it once at the top, so release-please, recovery and the image builds of one run hold the same group. The same group in the caller and a called workflow deadlocks.

Publishing permissions are `contents`, `packages`, `id-token` and `attestations: write`.

`_images.yaml` and `_release-images.yaml` share these inputs, which apply to every image:

- `language` (default `none`): for images whose `metadata.yaml` sets none
- `image`: the name of an image at the repo root (default: the lowercased repository name)
- `test-command`: for images whose `metadata.yaml` sets none
- `dockerhub-namespace`, `dockerhub-username`
- `python-version`, `python-groups`, `python-extras`, `python-test-paths`, `python-extra-commands`

`_build-image.yaml` takes the same inputs and `node-version`, plus the per-image ones that `detect-images` fills in: `language` (the image's, else the caller's), `workdir`, `context`, `dockerfile`, `prepare-command`, `free-disk`, `extra-tags` and `egress`, and for publishing `push`, `version`, `tag-name`, `tag-prefix` and `latest`. `_go-test.yaml` and `_python-uv-test.yaml` take `egress` too; `_go-test.yaml` also takes `dockerfile`.

Pass `secrets: DOCKERHUB_TOKEN` for Docker Hub. `_release-please.yaml` and `_release-recover.yaml` need `RELEASE_PLEASE_APP_CLIENT_ID` and `RELEASE_PLEASE_APP_PRIVATE_KEY`, and no other secret.

The `release-please` group creates a `release` environment whose deployment branch policy allows only `main`, and syncs both release App secrets into it; the `dockerhub` group adds `DOCKERHUB_TOKEN` to it. Release keys stay in the main-only `release` environment: the `Release please` job, the `dispatch` job of [`_release-recover.yaml`](#release-recovery) and `Docker Hub Cleanup` run there, so a run from any other ref is refused before it reads them.

The `dockerhub` group also creates a `publish` environment that holds `DOCKERHUB_TOKEN` and no other secret, and whose deployment policy allows `main` and version tags (`*.*.*`, and `*/*.*.*` for a tag that contains a slash). `_build-image.yaml`'s publish job runs in `publish`, so the image build of a run on a release tag can push and publish its draft; a ref outside those patterns is refused. XFG Apply creates `publish` before any consumer pin points at a `_build-image.yaml` that uses it.

The three secrets live only in these environments, never at repo level. Neither `_images.yaml` nor `_build-image.yaml`'s `build` job uses an environment. A called workflow still gets only the secrets its caller passes, so callers pass each one by name even though the environment holds it; in a job that sets `environment:`, the environment's value wins over a repo secret of the same name.

xfg publishes from its own `release.yaml`, whose `Publish` job runs in `release` on a push of a `v*.*.*` tag, and `docs.yaml` deploys on a push of the floating `vN` tag. xfg's entry in `src/repos.yaml` therefore sets its `release` policy to `main` and the tag pattern `v*`, which covers both. A repo-level policy replaces the group's whole, so the entry restates `main`; the secrets still come from
the group. `tag-rules` lets only its bypass actors create those tags. Every other repo's `release` allows only `main`.

xfg's entry also copies the four LiteLLM gateway secrets (`LITELLM_HOST`, `LITELLM_API_KEY`, `CF_ACCESS_CLIENT_ID`, `CF_ACCESS_CLIENT_SECRET`) into its `integration` and `integration-main` environments. It sets `deleteOrphaned: false` on the environments and on each environment's secrets, so secrets and settings already there are never removed, and `integration-main` restates its `main`-only
branch policy.

Go linting is not a workflow job. MegaLinter (`_lint.yaml`) owns it.

`_lint.yaml` runs three jobs. Callers grant `actions: read`, `contents: read` and `security-events: write`:

- `megalinter`: every linter but lychee, with no token and harden-runner in the [shared mode](#harden-runner). On public repos it saves the SARIF report as an artifact.
- `lint`: uploads that SARIF to code scanning. It is the only job with `security-events: write`, and it never checks out the PR's code. Its id stays `lint` because the id is part of the code scanning analysis key, so existing alerts carry over.
- `lychee`: the link checker alone, with no token (MegaLinter hides `*TOKEN*` variables from linters anyway) and harden-runner always in `audit`, because links reach arbitrary hosts.

The `megalinter` allowlist comes from egress logged across all repos: GitHub, GHCR (the image pull), Trivy's database mirrors, the Go module proxy (golangci-lint), `registry.coder.com` (Trivy on spruyt-labs' Terraform), and the artifact service. Under `block`, a new linter that downloads at runtime fails there until its host is added.

### Egress

Shared jobs run harden-runner through the [`harden-runner`](#harden-runner) action, each with its own allowlist built from the egress logged across all repos.
Under `block` a job that reaches a host off its list fails, so a new download needs its host added; add it under `audit` too, so the list is ready for a flip.
`test/ci/harden-runner.bats` keeps every job on the action, passing an allowlist, except the ones it lists.

An image's jobs (its Go, Python or Node tests, `build` and `publish`) take the same switch, and add the extra hosts from its `metadata.yaml` `egress`.
Each shared list covers GitHub, the artifact and cache store and the job's toolchain: the Go module proxy, PyPI and uv, or Node.js and npm. `build` adds Docker Hub (buildx pulls BuildKit from it) and GHCR; `publish` adds Sigstore and the OIDC token service for
the attestation. A base image from another registry, and every host a `Dockerfile`, `prepare-command`, `test-command` or test reaches, goes in `egress`. The build cache hides fetches that a cold build makes, so under `block` prove a new list with a build that misses the cache.

### Job timeouts

Every job that runs steps sets `timeout-minutes`: in each reusable workflow, each synced template and each workflow of this repo. A job that calls a reusable workflow (`uses:`) sets none, because GitHub rejects it there; the called workflow's own jobs carry the limit. `test/ci/job-timeouts.bats` fails when a step-running job has no limit, or a calling job has one.

A job's limit is the larger of twice its slowest successful job in the last 30 days across every repo that calls it, whatever the run's conclusion, and its own built-in wait plus 5 minutes (`_sonar-new-issues.yaml` polls SonarQube Cloud for up to 900 s, so 20), rounded up to a multiple of 5, with a minimum of 5.
Aim for 40 or less; where the runs need more (the image `build` job is 50: the slowest healthy build takes 1369 s, and 2x rounds up to 50), use what they need. A job that has no recent runs keeps its limit. Re-size a limit when its job gets slower: a healthy job that hits it needs more minutes, not a retry.

Why: a GitHub-hosted runner can hit a network error early in a step, then hang at "Cleaning up orphan processes" until "The hosted runner lost communication with the server" after 48 to 50 minutes. Runners in one region did this under harden-runner's `block` policy before v2.22.3, when GitHub's egress-proxy DNS experiment ([actions/runner-images#14925](https://github.com/actions/runner-images/issues/14925)) clashed with it
([step-security/harden-runner#708](https://github.com/step-security/harden-runner/issues/708)). With a limit of T minutes, GitHub cancels the hung job about T+5 minutes after it starts, so a limit over about 43 gains nothing over that kill; `build` is 50 because healthy builds need it, not to catch a hang.

A job cancelled this way, and its run, end `cancelled` with "The job has exceeded the maximum execution time". Nothing re-runs it: use "Re-run failed jobs" by hand.

### Images

The standard `ci.yaml`'s `image` job calls `_images.yaml` after `lint` and `repo`. It runs when `lint` succeeded and `repo` succeeded or was skipped (the seeded `ci-repo.yaml` has no job that runs, so `repo` is skipped); a failed `lint` or `repo`, or a cancelled run, skips it. Its `Detect` job runs [`detect-images`](#detect-images) and a matrix job runs `_build-image.yaml` for each image whose
files changed: build and test, no push. A repo without images, or a change that touches none, skips the matrix and runs only `Detect`. A `workflow_dispatch` run builds every image, or only the one in the caller's `image` dispatch input. Each image's jobs show up as `image / <name> / ...`.

Per-image settings live in the repo, in `<path>/metadata.yaml` (see [`detect-images`](#detect-images)), so a new image needs no change here. The `with:` inputs on the `image` job apply to every image.

`_release-images.yaml` runs `detect-images` in `released` mode on the releases `_release-please.yaml` made (or `_release-recover.yaml` outputs for a tag), and publishes every released image with its own version and tag; one merge that releases several packages publishes them all.

### Container retention

`_container-retention.yaml` runs [ghcr-cleanup-action](https://github.com/dataaxiom/ghcr-cleanup-action) with the caller's `GITHUB_TOKEN`, so no account-wide token is needed. It deletes:

- tagged versions beyond the newest `keep-n-tagged` that are older than `older-than`. Old release tags go too, so consumers that pin a release must keep up. `latest` is never deleted.
- ghost multi-arch images, whose platform images are all missing.

Untagged versions are kept: setting `keep-n-tagged` turns off the action's default of deleting them. Multi-arch children, attestations and signatures are deleted only with their parent.

- `packages` (default empty): comma-separated package names that override discovery. Empty cleans every image the repo builds, found by [`detect-images`](#detect-images) in `all` mode (a root package uses the `image` name). A repo with no images skips the cleanup with a notice; a detect result that is not a valid matrix fails the run. Wildcards are refused, because expanding them needs a PAT.
- `image` (default empty): image name for a package at the repo root, passed to `detect-images` as `root-name`. Empty uses the lowercased repo name. Set it only when the root image is not named after the repo; the synced caller does not pass it.
- `older-than` (default `4 weeks`): must be a positive interval of at most 99999 units, such as `4 weeks` or `30 days`
- `keep-n-tagged` (default `5`): must be at least `1`
- `dry-run` (default `false`): log what would be deleted, delete nothing
- `dockerhub-namespace` (default empty): also clean `docker.io/<namespace>/<package>` for every package, with the same rules, through [`dockerhub-cleanup`](#dockerhub-cleanup). Empty skips Docker Hub
- `dockerhub-username` (default: `dockerhub-namespace`): Docker Hub login

A `Find Packages` job resolves the package list once; `GHCR Cleanup` and `Docker Hub Cleanup` then run side by side and skip when the list is empty. Runs for the same repo queue rather than overlap, per registry: the GHCR action is not safe to run in parallel, and two Docker Hub runs would plan from different snapshots.

`Docker Hub Cleanup` runs in the main-only `release` environment with the `DOCKERHUB_TOKEN` secret that the `dockerhub` group syncs there (it syncs the same secret into `publish` for the image build), and fails without it. The caller must pass the secret by name. The job reaches only `hub.docker.com`.

The calling job needs `packages: write`, and `contents: read` so the job can check out the repo to find its images. Each package must give the calling repo the **Admin** role under its Actions access settings. Write is enough to push but not to delete versions. The role is set in the package settings; there is no API for it, and the packages API does not report it.

A package first pushed by the calling repo's own workflow with `GITHUB_TOKEN` already gives that repo Admin. A package first pushed from another repo keeps that repo's link and roles, so grant the role by hand at `https://github.com/users/<owner>/packages/container/<package>/settings`. mcp-header-proxy and kata-tap-qdisc-fix were first pushed from spruyt-labs, for example.

The packages come from the repo's own `release-please-config.json`, so a new image is cleaned without any change here. Old GitHub releases and git tags are kept.

The `image` group syncs a caller to each image repo as `container-retention.yaml` (see [Managed image repos](#managed-image-repos)). It cleans GHCR and Docker Hub (`aspruyt/<package>`, where the image release publishes), deletes for real every Saturday at 17:00 UTC, and a dispatch defaults to a dry run. A caller looks like this:

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
      contents: read
      packages: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_container-retention.yaml@<sha> # main
    with:
      dry-run: ${{ github.event_name == 'workflow_dispatch' && inputs.dry-run }}
      dockerhub-namespace: aspruyt
    secrets:
      DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }}
```

On a scheduled run `github.event_name == 'workflow_dispatch'` is false, so `dry-run` is `false` without reading `inputs.dry-run`. Before a new repo's first scheduled run:

1. Give the calling repo the **Admin** role on each package.
2. Dispatch with `dry-run` on, and check the logged deletions. Dispatch from `main`: `Docker Hub Cleanup` runs in the main-only `release` environment even for a dry run.
3. Dispatch once with `dry-run` off.
4. Confirm that `latest`, the newest `keep-n-tagged` tags and every digest a consumer pins still pull.

### Release flow

1. release-please opens a release PR. Merging it creates a tag and a **draft** release per released package (`"draft": true` and `"force-tag-creation": true` in the config).
2. Each released image is built from its tag, tested, pushed and attested.
3. `publish-release` adds the image details and undrafts that image's release.

The image job checks out the commit the run started from, never a caller-supplied ref, and refuses to publish unless the release tag points at that commit. The provenance attestation always names the run's commit (`github.sha`), and no input overrides it, so building any other commit would sign the wrong source. release-please tags the release PR's merge commit, which is the commit its run starts
from.

A new run on `main` (a push or the schedule) while a Release Please run is pending makes GitHub cancel that run. If the cancelled run was the release PR's merge, the next run's release-please creates the release for the earlier merge commit, and its image job refuses: the tag is not the commit that run started from. The release stays a draft.

If step 2 fails, the release stays a draft, so no public release lacks its image. The synced image release caller wires `_release-recover.yaml`, which recovers the draft by itself (see [Release recovery](#release-recovery)). For a tag cut before the caller wired it:

- When the cause lies outside the commit (a registry outage, a flaky test, a missing secret), fix it and use **Re-run failed jobs** on the release run. The re-run builds the same commit and tag, and publishes the draft.
- Otherwise, merge the fix and cut the next release. This covers a cause in the code, the cancelled run above, and a run that dies between creating the release and relabelling the release PR (the next run fails once on the duplicate release and starts no image job). No re-run can publish that draft; delete it once the next release is out.

`publish-release` leaves a release that is already published unchanged.

### Release recovery

The synced image release caller wires [`_release-recover.yaml`](#reusable-workflows), so a stuck draft recovers without a new release:

1. Every run of the caller on a branch (a push to `main`, a manual dispatch or a schedule) lists the repo's drafts through [`release-drafts`](#release-drafts). For each draft whose tag is an image package's release tag, whose caller at that tag has a job that calls `_release-recover.yaml` and which has no run in progress, it dispatches the caller on the tag.
   The drafts the run created itself are left to its own `images` job.
2. The dispatched run is a `workflow_dispatch` run on the tag ref: the `release` job is skipped, the `synthesize` job outputs that tag's release, and the `images` job builds the draft from the tag (the run's commit is the tag's commit, so the provenance check passes) and publishes it.
   This covers the cancelled run described in [Release flow](#release-flow), a cause outside the commit once it is fixed (a registry outage, a flaky test, a missing secret), and a run that dies between creating the release and relabelling the release PR.
3. When a newer release of the same package exists on the default branch, the recovered build pushes only its own version tag and publishes with `--latest=false`, so it never replaces `latest`, the `major.minor` tag or the latest-release marker.
4. After three failed dispatched runs of one tag, recovery stops dispatching it and adds a warning to the run. A cause in the code is fixed on `main`; the next release is cut, and the stuck draft is deleted once it is out.

A draft is not recovered when the caller workflow at its tag has no job that calls `_release-recover.yaml`: that tag was cut before the repo wired it. Re-run its failed jobs for a cause outside the commit, or merge the fix, cut the next release and delete the draft.

**What a caller wires.** The synced image `release-please.yaml` has the jobs below and also runs on a six-hourly `schedule`, so a stuck draft recovers without a push. A caller kept outside the `image` group wires the same:

```yaml
jobs:
  release:
    if: github.ref_type == 'branch'
    permissions:
      contents: read
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@<sha> # main
    secrets:
      RELEASE_PLEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      RELEASE_PLEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
  recover:
    needs: release
    if: "!cancelled()"
    permissions:
      contents: read
      actions: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-recover.yaml@<sha> # main
    with:
      releases: ${{ needs.release.outputs.releases }}
    secrets:
      RELEASE_PLEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      RELEASE_PLEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
  images:
    needs: [release, recover]
    if: "!cancelled() && (needs.release.outputs.release-created == 'true' || needs.recover.outputs.release-created == 'true')"
    permissions:
      contents: write
      packages: write
      id-token: write
      attestations: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-images.yaml@<sha> # main
    with:
      releases: ${{ needs.recover.outputs.releases || needs.release.outputs.releases }}
```

- `release` runs on a branch ref only, so a run on a tag ref skips release-please.
- `recover` grants `contents: read` and `actions: write`. `releases` is optional. Both App secrets are passed by name.
- `images` reads `releases` from `recover` first, because only a tag-ref run has them there, and runs on `!cancelled()` so a failed recovery never blocks the images of the run's own release.

`dispatch` runs in the main-only `release` environment, with `contents: read` and `actions: write` for `GITHUB_TOKEN` (it reads the repo and runs and dispatches the caller) and an App token minted with `contents: write` only (it lists the drafts). `synthesize` has `contents: read`, no environment and no App token. The `images` job of a tag-ref run publishes in the `publish` environment, which allows release tags.

To test it end to end, create the tag and a draft release for an image package's manifest version in a repo whose caller at that tag wires `_release-recover.yaml`, then run `gh workflow run release-please.yaml --ref <tag>`; the `images` job builds the tag and publishes the draft. A push to `main` or the next schedule makes the same dispatch without the manual step.

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
template's `main` commit, and repo-operator's Renovate reads that file with its `github-actions` manager, so repo-operator's monthly `repo-operator shared CI` PR bumps it with the template pins. xfg pushes each repo's changes as one commit (`prOptions.merge: direct`), so the seed lands with the `ci.yaml` that calls it; a `ci.yaml` that calls a missing `ci-repo.yaml` makes the whole run invalid.

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

It runs [`amannn/action-semantic-pull-request`](https://github.com/amannn/action-semantic-pull-request), pinned by SHA, on `pull_request` into `main` (`opened`, `edited`, `synchronize`, `reopened`). The job has only `pull-requests: read`, checks out nothing, and runs behind the [`harden-runner`](#harden-runner) action with an allowlist of the GitHub API and the Actions results service. The action reads the PR's current title through the API, so it works
the same on fork PRs, whose `GITHUB_TOKEN` is read-only. Renaming a PR re-runs only this workflow, not `CI`. It skips Mergify merge-queue PRs, with the same condition as `_sonar-new-issues.yaml`, and a skipped required check counts as a pass.

`PR Title` is a required check in every `pr-rules` ruleset, next to `summary / Check Results`. Repos without `pr-rules` run it as advisory. repo-operator's own copy in `.github/workflows/` is written by XFG Apply from the template, and the tests check the template.

## Managed image repos

Image repos don't write these callers themselves. The xfg groups in `src/groups.yaml` sync them, along with the lint image pin and lint config, and overwrite them on every sync:

| Group               | Extends                                    | Syncs                                                                                                                  |
| ------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- |
| `megalinter-flavor` | `megalinter`                               | `lint.sh` with the language flavor pin; `.golangci.yml` (with `go`); `ruff-base.toml` (with `python`); linter list     |
| `release-please`    |                                            | `.github/workflows/release-please.yaml`, which runs `_release-please.yaml` only; the release App secrets               |
| `image`             | `github-ci`, `release-please`, `dockerhub` | the image `release-please.yaml` with `language: none`, `container-retention.yaml`, `.hadolint.yaml`; `DOCKERHUB_TOKEN` |
| `go-image`          | `image`, `go`, `megalinter-flavor`         | the above with `language: go`, and `language: go` on `ci.yaml`'s `image` job                                           |
| `python-image`      | `image`, `python`, `megalinter-flavor`     | the above with `language: python`, and `language: python` on `ci.yaml`'s `image` job                                   |

A repo whose images use more than one language, such as spruyt-labs or container-images, joins `image` without a language group, and each image's `metadata.yaml` can set its `language`; an image that sets none gets the group default, `none`, and runs no language tests. A .NET repo such as agent-platform joins `image` and `dotnet` (the .NET SDK in the dev container): `_build-image.yaml` has no .NET
tests, so its image builds with `language: none` and the repo runs `dotnet test` in its `ci-repo.yaml`. Every image repo gets `image`, directly or through `go-image` or `python-image`, and lists neither `release-please` nor `dockerhub` beside it.

A repo that releases without images, such as claude-plugins, joins `release-please` alone. Its caller has one `release` job with `contents: read` and the two App secrets.
The image caller runs the `release` job on a branch ref only, then a `recover` job (see [Release recovery](#release-recovery)), then an `images` job that calls `_release-images.yaml` with the publishing permissions and `DOCKERHUB_TOKEN`, when a release was created or recovered.
xfg publishes from its own `release.yaml`, so its entry turns the synced caller off with `.github/workflows/release-please.yaml: false`.

xfg deep-merges the `image` entry over the `release-please` one, so the image caller must be the plain caller plus its `schedule`, the `if` on `release`, and the `recover` and `images` jobs; a key only the plain caller has would reach every image repo.

Every image publishes to GHCR and to Docker Hub as `aspruyt/<image>`, because GHCR is often slow or down. The image release caller passes `dockerhub-namespace: aspruyt` and the `DOCKERHUB_TOKEN` secret, which `image` syncs through the `dockerhub` group, to `_release-images.yaml`. The `image` job in `ci.yaml` never pushes, so it gets no token.

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

`.github/workflows/lint-canary.yaml` catches a bad bump before it merges. `ci.yaml` calls it on every PR, and `.github/scripts/lint-canary-needed.sh` skips it unless the PR touches a lint pin or lint template (`src/groups.yaml`, `src/repos.yaml`, and the lint files under `src/templates/`). It never runs on merge queue PRs:

1. **Render**: `xfg sync --dry-run --render-dir` writes every file the sync would change, per repo. A repo is affected when one of its lint files (`lint.sh`, `.mega-linter-base.yml`, `.mega-linter.yml`, `.golangci.yml`, `ruff-base.toml`, `trivy-mega-linter.yaml`, `.pylintrc`) would be written or deleted. The job summary lists them.
2. **Lint**: one job per affected repo checks out its `main`, copies the rendered files over it, deletes the files the sync would delete, and runs `./lint.sh --ci` on the whole codebase, behind the `megalinter` job's allowlist and without lychee, as in `_lint.yaml`.

A pin to an image that lacks one of a repo's enabled linters fails, because MegaLinter cannot run the missing linter. So do new findings from a changed rule. `summary` judges the canary, so a failure blocks the merge and a skip passes. A repo whose `main` is already red fails it too; fix that repo first.

The canary renders against each repo's current `main`, so it also lints changes merged here but not yet synced.

### Lint config

- **Docker and Terraform**: the `image` group adds `DOCKERFILE_HADOLINT` and the `terraform` group adds `TERRAFORM_TFLINT` to `.mega-linter-base.yml`. The repo's flavor must ship the linter. hadolint comes from `.hadolint.yaml` (`createOnly`); tflint uses the repo's own `.tflint.hcl`.
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
        images:
          with: *my-repo-with
```

The job is `image` in `ci.yaml` and `images` in `release-please.yaml`; the `release` job takes no inputs. Anchors only resolve within one file, so give each repo's anchor a unique name in `repos.yaml`. The anchor may only hold inputs that both called workflows accept; put any other input in that file's own overlay, or GitHub rejects the callers that don't declare it.

`container-retention.yaml` needs no per-repo setting unless the root image is not named after the repo: it cleans every image `detect-images` finds, so a repo with several images is covered once it is in `release-please-config.json`. Such a repo needs the `image` input, as in `ci.yaml` and `release-please.yaml`. The synced template does not pass it, so set it with a content overlay in
`repos.yaml`; no repo needs one today.

## Image age

`.github/workflows/image-age.yaml` dates the container images that registries other than Docker Hub serve, so Renovate holds back tags and rebuilds younger than 7 days. It runs every six hours and on dispatch, in four jobs behind harden-runner, each with its own allowlist. Every job checks out the commit (`github.sha`, `persist-credentials: false`) and runs `.github/scripts/image-age.sh` from that
checkout. The artifacts carry data only: `inventory.json`, `image-age.json`, `image-age-data.json`, `report.txt` and the Renovate logs of the extract job. The extract and validate jobs run Renovate on Node 24 (set up with `actions/setup-node`), the engine Renovate requires.

1. **extract** (`contents: read`): `image-age.sh extract` runs the pinned Renovate (`RENOVATE_VERSION` in the script, bumped by Renovate) in `--dry-run=extract` mode on every public repo in `src/repos.yaml`, and lists the images whose registry is neither Docker Hub nor `ghcr.io/anthony-spruyt/`, with the tags and digests in use. A repo counts as extracted when Renovate logs
   `Extracted dependencies`; any other end is an `::error` and the repo's images keep their stored rows. The images in the `Registry moves` rules are left out, because Renovate dates them on Docker Hub. Every image name must be a valid reference; any other is dropped with an `::error`. Renovate runs with the job token and `github-actions[bot]` as username and git author, so it does not ask GitHub
   who the token belongs to. When a repo fails, the job log and `report.txt` list up to 15 warning and error lines of its Renovate log (`msg`, `errorMessage` and `err.message`), the `result` of its run and the last 10 lines of its stderr. The `inventory` artifact holds `inventory.json` and `report.txt`; the `image-age-extract-logs` artifact (3 days) holds the log and stderr of every repo.
2. **render** (`contents: read`, `packages: read`): `image-age.sh render` reads the previous `image-age-data.json` from the data repo, then each image's tags, digests and push times from its registry (ghcr.io, quay.io, mcr.microsoft.com, gcr.io, registry.k8s.io), paging until 50 tags older than 7 days and every tag in use are listed (20 pages at most; at the cap the listing counts as complete once
   one tag is at least 7 days old, and an image with none is an `::error`). A tag in use that the listing does not reach, such as a floating tag whose build is older than the pages read, is read from the registry with a `HEAD` on its manifest, using an anonymous pull token where the registry asks for one (mcr.microsoft.com and registry.k8s.io send none). Its digest is stored under `unlisted` in
   `image-age-data.json` with the time it was first seen, and the tag and that digest are admitted like a listed build once that time is 7 days ago; a different digest restarts the time, and an entry is dropped once its tag is listed again or no longer used. Until then the job prints one `::notice` per waiting tag, and a lookup that fails is a `::warning` for that tag, which stays out with its
   stored entry kept. Names, tags, digests and push times from the registry and from the previous data pass the same checks. It writes `image-age.json` and `image-age-data.json` (the rows per image as `tag`, `digest` and `pushedAt` in epoch seconds, the `unlisted` tags as `digest` and `firstSeen`, the inventory and `generatedAt`). Per image, one rule allows the newest 50 tags built at least 7 days
   ago, plus every tag in use, minus the tags in `image-age-skips.yaml`; a second rule drops a digest update whose digest the registry lists for that tag only as a build younger than 7 days. A catch-all rule holds back an image not yet dated, and a stale rule holds back updates of these images once the data is 36 hours old. When a registry answers with an error, an unreadable body, no tags or a
   push time that is not a number, the image's rules are rendered again from its stored rows and the run reports an `::error`; an image with no stored rows, or none old enough, or on a registry the script has no adapter for, is held back. `render` also checks each repo's `renovate-overrides.json5`: a rule that sets `enabled: true` for an image it dates is an `::error`, and one that sets
   `allowedVersions` for it is a `::warning`. The job outputs the sha256 of the two JSON files.
3. **validate** (`contents: read`): checks `image-age.json` against the shape `render` writes (only the keys it uses, `matchDatasources` exactly `["docker"]`, `enabled` only `false`, one `allowedVersions` rule and one digest rule or one hold rule per image, the catch-all and the stale rule), against the pinned `renovate-config-validator --strict --no-global` (as a repo config, the way repos load
   it), and against a 512 KB limit. It also checks that `image-age-data.json` holds `generatedAt`, `inventory` and `rows`, and that every `unlisted` entry holds a digest and a `firstSeen` time. A failure stops `publish`.
4. **publish** (`environment: plan-main`, `contents: read`, `main` only): recomputes the sha256 of both JSON files from the artifact and stops unless they equal the outputs of `render`. It then mints a token scoped to `anthony-spruyt/renovate-data` and writes both files to its `main` with one `PUT` each to the contents API, so GitHub signs the commits; the file content goes through `jq -Rs`,
   because `jq --arg` takes at most 128 KiB. The run fails after publishing when `report.txt` holds an `::error`.

The data repo `anthony-spruyt/renovate-data` is public. xfg creates it from its `src/repos.yaml` entry, which syncs no files, labels or collaborators, and it is not in `protected-main-branch`. Only this workflow writes to it. Repos extend `github>anthony-spruyt/renovate-data//image-age` after the shared presets and before `renovate-overrides.json5`.

The script is tested offline by `test/image-age.bats`, with a fake `curl` and `npx`; `test/ci/renovate-image-age.bats` keeps the workflow, the pins and the rules wired as described.

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
  schedule:
    - cron: "23 */6 * * *"
  workflow_dispatch:
concurrency:
  group: release-please-${{ github.ref }}
  cancel-in-progress: false
permissions: {}
jobs:
  release:
    if: github.ref_type == 'branch'
    permissions:
      contents: read
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-please.yaml@<sha> # main
    secrets:
      RELEASE_PLEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      RELEASE_PLEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
  recover:
    needs: release
    if: "!cancelled()"
    permissions:
      contents: read
      actions: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-recover.yaml@<sha> # main
    with:
      releases: ${{ needs.release.outputs.releases }}
    secrets:
      RELEASE_PLEASE_APP_CLIENT_ID: ${{ secrets.RELEASE_PLEASE_APP_CLIENT_ID }}
      RELEASE_PLEASE_APP_PRIVATE_KEY: ${{ secrets.RELEASE_PLEASE_APP_PRIVATE_KEY }}
  images:
    needs: [release, recover]
    if: "!cancelled() && (needs.release.outputs.release-created == 'true' || needs.recover.outputs.release-created == 'true')"
    permissions:
      contents: write
      packages: write
      id-token: write
      attestations: write
    uses: anthony-spruyt/repo-operator/.github/workflows/_release-images.yaml@<sha> # main
    with:
      releases: ${{ needs.recover.outputs.releases || needs.release.outputs.releases }}
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
    go-mod: "true"
    push: "true"
    version: ${{ needs.release.outputs.my-service-version }}
- uses: anthony-spruyt/repo-operator/.github/actions/publish-release@<sha> # main
  with:
    tag: ${{ needs.release.outputs.my-service-tag }}
    image-ref: ${{ steps.build.outputs.image-ref }}
    digest: ${{ steps.build.outputs.digest }}
```
