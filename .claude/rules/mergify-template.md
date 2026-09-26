---
globs: src/templates/.mergify.yml
---

# Mergify Template

This file is the source of truth for Mergify configuration synced to all target repositories via xfg. Changes here affect every repo on next sync.

## Before editing

Mergify config evolves frequently. Do NOT trust training data for field names, allowed values, or deprecated options.

### Research steps

1. **Context7**: `resolve-library-id` for "Mergify" → `query-docs` with specific field/feature query
2. **Official docs**: WebFetch `https://docs.mergify.com/merge-protections/setup` (or relevant subpath)
3. **GitHub source**: `gh search code "<field_name>" --repo Mergifyio/mergify --language yaml` to find real usage
4. **WebSearch** (last resort): "mergify <feature> configuration site:docs.mergify.com"

### Common pitfalls

- Fields get renamed/deprecated with deadlines (e.g. `auto_merge` → `auto_merge_conditions`)
- Mergify bot may open PRs in target repos for deprecated fields — fix must go in THIS template, not in target repos
- After fixing template, close the bot PR in target repo (xfg sync will push the fix)
