"""Which markdown files MegaLinter and the pre-commit markdownlint hook each skip.

stdin, JSON:
  dirs     ADDITIONAL_EXCLUDED_DIRECTORIES of the MegaLinter base config
  regexes  {name: regex} for FILTER_REGEX_EXCLUDE and MARKDOWN_FILTER_REGEX_EXCLUDE of that config
  exclude  the hook's exclude, or null when it has none
stdout: "<path>\t<MegaLinter>\t<pre-commit>" per sample path, each "excluded" or "checked"

Sample paths come from both sides, one set per top-level alternative of each regex, so drift in
either direction is a disagreement. An alternative with no sample path exits 1 ("add a sample for").
"""

import json
import re
import sys

try:
    from re import _parser as sre_parse
except ImportError:  # Python < 3.11
    import sre_parse

# Copy of megalinter/utils.py DEFAULT_EXCLUDED_DIRECTORIES at v10.1.0. The container-images
# MegaLinter flavor images set the version, so re-check this list when they upgrade MegaLinter.
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

MAX_STRINGS_PER_ALTERNATIVE = 500


class Unsupported(Exception):
    pass


def flatten(value):
    if value is None:
        return []
    if isinstance(value, str):
        return [value] if value else []
    return [item for entry in value for item in flatten(entry)]


def normalize(entries):
    normalized = (entry.replace("\\", "/").strip("/") for entry in entries)
    return {entry for entry in normalized if entry}


def scan(regex):
    """Yield (index, char, depth after it) for each unescaped character outside a class."""
    depth, in_class, i = 0, False, 0
    while i < len(regex):
        char = regex[i]
        if char == "\\":
            i += 2
            continue
        if in_class:
            in_class = char != "]"
        elif char == "[":
            in_class = True
        else:
            depth += {"(": 1, ")": -1}.get(char, 0)
            yield i, char, depth
        i += 1


def closes_at_end(regex):
    for i, char, depth in scan(regex):
        if char == ")" and depth == 0:
            return i == len(regex) - 1
    return False


def top_level_alternatives(regex):
    """Split on `|` outside groups, looking through a group that wraps the whole regex."""
    while regex.startswith("(") and closes_at_end(regex):
        regex = regex[3:-1] if regex.startswith("(?:") else regex[1:-1]
    alternatives, start = [], 0
    for i, char, depth in scan(regex):
        if char == "|" and depth == 0:
            alternatives.append(regex[start:i])
            start = i + 1
    alternatives.append(regex[start:])
    return alternatives


def expand(items):
    """Every string the parsed regex can match, anchors ignored; raises Unsupported otherwise."""
    options = [""]
    for opcode, arg in items:
        name = str(opcode)
        if name == "LITERAL":
            choices = [chr(arg)]
        elif name == "AT":
            choices = [""]
        elif name == "ANY":
            choices = ["a"]
        elif name == "SUBPATTERN":
            choices = expand(arg[-1])
        elif name == "BRANCH":
            choices = [string for branch in arg[1] for string in expand(branch)]
        elif name in ("MAX_REPEAT", "MIN_REPEAT"):
            low, _, body = arg
            body_choices = expand(body)
            choices = ([""] if low == 0 else []) + [s * max(low, 1) for s in body_choices]
        elif name == "IN":
            choices = []
            for kind, value in arg:
                if str(kind) == "LITERAL":
                    choices.append(chr(value))
                elif str(kind) == "RANGE":
                    choices.append(chr(value[0]))
                else:
                    raise Unsupported(f"unsupported character class item {kind}")
        else:
            raise Unsupported(f"unsupported regex element {name}")
        options = [option + choice for option in options for choice in choices]
        if len(options) > MAX_STRINGS_PER_ALTERNATIVE:
            raise Unsupported(f"more than {MAX_STRINGS_PER_ALTERNATIVE} matching strings")
    return options


def paths_for(seed):
    """Sample paths around one matching string: a file name, or a directory at several depths."""
    if seed.endswith(".md"):
        return [seed, f"a/{seed}", f"a/b/{seed}", f"x{seed}"]
    name = seed.strip("/")
    if not name:
        raise Unsupported("matches an empty name")
    return [
        f"{name}/x.md",
        f"a/{name}/x.md",
        f"a/b/{name}/c/x.md",
        f"x{name}/x.md",
        f"{name}x/x.md",
        f"a/{name}.md",
    ]


def alternative_paths(label, regex, problems):
    paths = []
    for alternative in top_level_alternatives(regex):
        try:
            seeds = {s.lstrip("/") for s in expand(sre_parse.parse(alternative))}
            derived = [path for seed in sorted(seeds) for path in paths_for(seed)]
            if not any(re.search(alternative, path) for path in derived):
                raise Unsupported("no generated path matches it")
        except (Unsupported, re.error) as error:
            problems.append(f"add a sample for {label} alternative {alternative!r}: {error}")
            continue
        paths += derived
    return paths


def sample_paths(directories, labelled_regexes, problems):
    paths = list(FIXED_PATHS)
    for name in sorted(directories):
        paths += paths_for(name)
    for label, regex in labelled_regexes:
        paths += alternative_paths(label, regex, problems)
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
    megalinter_regexes = [
        (name, regex) for name, value in config["regexes"].items() for regex in flatten(value)
    ]
    hook_regexes = [("pre-commit exclude", config["exclude"])] if config["exclude"] else []
    problems = []
    paths = sample_paths(directories, megalinter_regexes + hook_regexes, problems)
    if problems:
        sys.exit("\n".join(problems))
    megalinter_only = [regex for _, regex in megalinter_regexes]
    for path in paths:
        megalinter = megalinter_excludes(path, directories, megalinter_only)
        hook = hook_excludes(path, config["exclude"])
        print(
            f"{path}\t{'excluded' if megalinter else 'checked'}\t{'excluded' if hook else 'checked'}"
        )


main()
