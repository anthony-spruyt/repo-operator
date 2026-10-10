# Public Repos

Every repo is public. Anything written in it, or on GitHub about it, can be read and indexed by anyone.

## Never write publicly

- Known gaps, unfixed weaknesses, or what a control does not cover
- Attack paths, bypass steps, exploit recipes
- What a credential, token or service account can reach
- Risk ratings, "accepted risk", "residual risk", "fails open"

This covers issues, PRs, comments, commit messages, READMEs, docs, code comments and `.claude/` files.

## Instead

- Describe controls as the end state: "Only the API gateway can reach this service"
- Word open security work as a neutral task: "Restrict admin paths to the LAN"
- Track security work and findings as issues in the private `anthony-spruyt/security` repo
- Report security findings off GitHub: a subagent reports them to the agent that called it, and the main session reports them to the owner
- Post other reports as usual, with security findings removed
