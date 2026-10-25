---
name: status
description: Overview of all FRs — on the base branch, on FR branches and uncommitted — with status, linked issues, PRs, running Claude sessions, and which FRs may run in parallel. Read-only.
argument-hint: "[issue ref or FR id to focus on]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: status

Read-only. Field meanings: `${CLAUDE_PLUGIN_ROOT}/reference/model.md`.

Focus: $ARGUMENTS

1. **FRs.** Nothing given → `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh list`. An issue
   ref → `fr.sh issue-frs <ref>`. An FR id → its row from `fr.sh list`, plus
   `gh pr view <pr> --json state,url,statusCheckRollup` when it has a PR.
2. **Sessions.** `claude agents --json` (skip silently if it fails). A session
   belongs to an FR when its `cwd` is the FR's worktree
   (`.claude/worktrees/<id-lower>-…`) or its `name` starts with the FR id. Show
   its `status` and `kind`.
3. **Parallel.** `fr.sh overlap --no-fetch` for all `open` and `in-progress` FRs.

Output:

- One table, grouped by status in this order: `in-progress`, `in-review`, `open`,
  `merged` (the last 10 unless asked), `dropped`. Columns: FR · title · status ·
  issues · PR · where (`base`, the branch, or `local`) · session (name and state,
  or —).
- Below: which open FRs could start now alongside the running ones (wave 1), and
  the conflicts that hold the others back.
- If sessions run: `claude agents` (live view), `claude logs "<ID>"`,
  `claude attach "<ID>"`.
- Inconsistencies: `in-review` without `pr`; an FR branch whose PR was closed
  unmerged; issue refs that are not canonical `owner/repo#N`; files in `fr_dir`
  without frontmatter (ignored by `fr.sh`); an `in-progress` FR without a worktree
  or session on this machine (may be someone else's — say so, don't judge).
