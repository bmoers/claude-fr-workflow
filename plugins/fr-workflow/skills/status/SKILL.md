---
name: status
description: Overview of all FRs — on the base branch, on FR branches and uncommitted — with status, linked issues and PRs. Read-only.
argument-hint: "[issue ref or FR id to focus on]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: status

Read-only. Field meanings: `${CLAUDE_PLUGIN_ROOT}/reference/model.md`.

Focus: $ARGUMENTS

- Nothing given → `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh list`. An issue ref →
  `fr.sh issue-frs <ref>`. An FR id → its row from `fr.sh list`, plus
  `gh pr view <pr> --json state,url,statusCheckRollup` when it has a PR.
- One table, grouped by status in this order: `in-progress`, `in-review`, `open`,
  `merged` (the last 10 unless asked), `dropped`. Columns: FR · title · status ·
  issues · PR · where (`base`, the branch, or `local`).
- Flag inconsistencies below the table: `in-review` without `pr`; an FR branch
  whose PR was closed unmerged; issue refs that are not canonical
  `owner/repo#N`; files in `fr_dir` without frontmatter (ignored by `fr.sh`).
