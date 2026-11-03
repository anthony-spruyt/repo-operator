"""Which markdown files MegaLinter and the pre-commit markdownlint hook each skip.

stdin, JSON:
  dirs     ADDITIONAL_EXCLUDED_DIRECTORIES of the MegaLinter base config
  regexes  FILTER_REGEX_EXCLUDE and MARKDOWN_FILTER_REGEX_EXCLUDE of that config
  exclude  the hook's exclude, or null when it has none
stdout: "<path>\t<MegaLinter>\t<pre-commit>" per sample path, each "excluded" or "checked"
"""

import json
import re
import sys

# megalinter/utils.py DEFAULT_EXCLUDED_DIRECTORIES at v10.1.0; ADDITIONAL_EXCLUDED_DIRECTORIES adds to it
MEGALINTER_DEFAULT_DIRECTORIES = [
    "__pycache__",
    ".angular",
    ".git",
    ".jekyll-cache",
    ".nx",
    ".parcel-cache",
    ".pnpm-store",
    ".pytest_cache",
    ".mypy_cache",
    ".rbenv",
    ".sf",
    ".sfdx",
    ".turbo",
    ".venv",
    ".terraform",
    ".terragrunt-cache",
    ".wireit",
    ".yarn/cache",
    "node_modules",
]

FIXED_PATHS = [
    "README.md",
    "docs/a.md",
    "src/plans.md",
    "planning/x.md",
    "CLAUDE.md",
    "docs/CLAUDE.md",
    "docs/deep/er/CLAUDE.md",
    "docs/NOTCLAUDE.md",
    "CHANGELOG.md",
    "pkg/sub/CHANGELOG.md",
    ".claude/agents/x.md",
    "docs/.claude/x.md",
    "docs/plans/x.md",
    "plans/x.md",
    "a/b/plans/c/x.md",
    "a/tmp/x.md",
    "tmp/x.md",
    "packages/app/node_modules/pkg/README.md",
    "node_modules/pkg/README.md",
    ".venv/lib/x.md",
    "tools/.venv/lib/x.md",
]


def flatten(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [value] if value else []
    return [item for entry in value for item in flatten(entry)]


def normalize(entries):
    normalized = (entry.replace("\\", "/").strip("/") for entry in entries)
    return {entry for entry in normalized if entry}


def sample_paths(directories):
    paths = list(FIXED_PATHS)
    for name in sorted(directories):
        paths += [
            f"{name}/x.md",
            f"a/{name}/x.md",
            f"a/b/{name}/c/x.md",
            f"x{name}/x.md",
            f"{name}x/x.md",
            f"a/{name}.md",
        ]
    return list(dict.fromkeys(paths))


# megalinter/MegaLinter.py list_files_all() prunes an excluded directory, so a file is
# skipped when any ancestor matches by workspace-relative path or by basename at any depth
def megalinter_excludes(path, directories, regexes):
    ancestor = ""
    for part in path.split("/")[:-1]:
        ancestor = f"{ancestor}/{part}" if ancestor else part
        if ancestor in directories or part in directories:
            return True
    return any(re.search(regex, path) for regex in regexes)


# pre_commit/commands/run.py filter_by_include_exclude(): re.search on the repo-relative path
def hook_excludes(path, exclude):
    return re.search(exclude or "^$", path) is not None


def main():
    config = json.load(sys.stdin)
    directories = normalize(MEGALINTER_DEFAULT_DIRECTORIES + config["dirs"])
    regexes = flatten(config["regexes"])
    for path in sample_paths(directories):
        megalinter = megalinter_excludes(path, directories, regexes)
        hook = hook_excludes(path, config["exclude"])
        print(
            f"{path}\t{'excluded' if megalinter else 'checked'}\t{'excluded' if hook else 'checked'}"
        )


main()
