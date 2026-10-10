# Progress Notes

Compaction loses detail, so keep the state of multi-step work on disk, as in Anthropic's [long-running agent harness](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents). A session that resumes, compacts or clears gets its notes reloaded; `git log` stays the source of truth.

## When

Any task with more than one step, or that may outlive this session. Skip one-shot edits and questions.

## Where

`.agent-progress/<session_id>.md` in the main checkout, even when you work in a git worktree. A SessionStart hook prints the exact path at the start of every session, so use that path; sessions sharing a checkout or branch each get their own file. The folder is gitignored and stays on this machine.

The hook loads the file again after compaction and `--resume`, which keep the same session ID. `/clear` and a new session get a new ID and so a new, empty file. For work that spans sessions, the next session reads the old file by hand (`ls -t .agent-progress/`) and copies what it needs into its own.

A forked session gets a new ID. Its notes path is the newest one the hook printed; it copies what it needs from the parent's file. Subagents get no path and keep no notes file.

The issue body stays the public plan and checklist; the progress file is your working memory.

## What

Under 100 lines; the hook loads only the first 9,000 characters. Write for a reader with no memory of this session:

- Goal and issue number
- Done, with commit SHAs
- The exact next step
- Decisions and why
- Dead ends, so they are not retried
- Commands and gotchas that matter

## How

1. **Start**: read the notes if the hook loaded any, and `git log --oneline -10`, before anything else. When they disagree, git wins.
2. **One step at a time**: finish it, test it, commit it, then update the notes.
3. **Before you stop**: update the notes so the next session can start without asking.
4. **Done**: delete your file when the task is finished, so a later session does not pick up stale notes.
