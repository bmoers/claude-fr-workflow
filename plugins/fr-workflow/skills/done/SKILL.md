---
name: done
description: After an FR's PR was merged — confirm the merge, refresh issue backlinks, close fully served issues after confirmation, remove the worktree and local branch.
argument-hint: "<FR id or PR number>"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: done

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`. Run it
from the main checkout, not from the FR's worktree — that one gets removed.

1. Resolve the FR: $ARGUMENTS is an FR id, or a PR number → the FR whose `pr:`
   matches in `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh list`.
2. **Gate:** `gh pr view <N> --json state,mergedAt` says `MERGED`, and `fr.sh list`
   shows the FR as `merged`. Otherwise stop: either not merged yet, or the FR doc
   reached the base branch without `status: in-review` — then `:ship` did not
   finish; say so.
3. `fr.sh sync <issues of the FR> --no-fetch`.
4. Per issue `fr.sh issue-frs <ref> --no-fetch`. If every FR referencing it is
   `merged` or `dropped`, the issue is fully served. Show one table — issue · its
   FRs with status · proposal (close / keep open) — and close only what the user
   confirms:
   `gh issue close <n> -R <repo> --comment "Done with <FR ids> (<repo>#<PR>, …)."`
   Issues with open FRs stay open; their backlink shows what is left.
5. Clean up, each step only if it is safe:
   - `git worktree remove .claude/worktrees/<…>` — refuses on uncommitted changes:
     report them, never `--force`.
   - `git branch -d <branch>` — refuses after a squash merge, which git cannot see
     as merged: ask before `-D`.
   - Remote branch: nothing if GitHub deleted it; otherwise offer
     `git push origin --delete <branch>`.
6. Report: issues closed, issues still open with their remaining FRs, cleanup done.
