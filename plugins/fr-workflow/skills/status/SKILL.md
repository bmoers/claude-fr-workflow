---
name: status
description: Overview of all FRs — defined on GitHub, started on branches, in review — with their requests, PRs, running Claude sessions, the requests still to define, and which FRs may run in parallel. Read-only.
argument-hint: "[request or FR to focus on]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: status

Read-only. Field meanings: `${CLAUDE_PLUGIN_ROOT}/reference/model.md`.

Focus: $ARGUMENTS

1. **FRs.** Nothing given → `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh list`. A request
   → `fr.sh issue-frs <ref>`. An FR → its row from `fr.sh list`, plus
   `gh pr view <pr> --json state,url,statusCheckRollup` when it has a PR.
2. **Requests to define.** `gh issue list -R <repo> --label fr-request --state open --limit 200 --json number,title,labels,subIssuesSummary`
   (`<repo>` = `issue_repo`, else this repository): those without the label `fr`
   and without sub-issues. Each may still be served by an FR that lists it under
   *Requests* — `fr.sh issue-frs <ref>` tells; otherwise it waits for
   `/fr-workflow:new`.
3. **Sessions.** `claude agents --json` (skip silently if it fails). A session
   belongs to an FR when its `cwd` is the FR's worktree
   (`.claude/worktrees/<id-lower>-…`) or its `name` starts with the FR id. Show
   its `status` and `kind`.
4. **Parallel.** `fr.sh overlap --no-fetch` for all `open` and `in-progress` FRs.

Output:

- One table, grouped by status in this order: `in-progress`, `in-review`, `open`
  (defined, not started), `merged` (the last 10 unless asked), `dropped`.
  Columns: FR · title · status · requests · PR · where (`issue`, `base`, the
  branch, or `local`) · session (name and state, or —).
- Below: the requests to define, then which open FRs could start now alongside
  the running ones (wave 1), and the conflicts that hold the others back.
- If sessions run: `claude agents` (live view), `claude logs "<ID>"`,
  `claude attach "<ID>"`.
- Inconsistencies: `in-review` without `pr`; an FR branch whose PR was closed
  unmerged; an FR doc that is not `merged` or `dropped` while its issue is
  closed; files in `fr_dir` without frontmatter (ignored by `fr.sh`); an
  `in-progress` FR without a worktree or session on this machine (may be someone
  else's — say so, don't judge).
