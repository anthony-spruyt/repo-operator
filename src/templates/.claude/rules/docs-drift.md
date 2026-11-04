# Docs That Drift

Documentation never holds a value someone must update by hand when a version or release changes: version numbers, build or release ids, image tags, digests, or counts and lists copied from config. Point to the file or command that holds the value instead, e.g. "the supported builds are listed in `data/builds.json`".

This covers READMEs, `docs/`, guides, and `.claude/` skill, rule and agent files.

A value that stays true when the thing updates is fine: a minimum version ("1.1.3 or newer") or a fixed historical fact.

When you touch a doc, replace any such value you find in it.
