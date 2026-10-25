---
name: done
description: Close out an FR — after its PR was merged, or to drop it. Refreshes issue backlinks, closes fully served issues after confirmation, removes the worktree and local branch.
argument-hint: "<FR id or PR number> [drop]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: done

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`. Run it
from the main checkout, not from the FR's worktree — that one gets removed.

Arguments: $ARGUMENTS — an FR id, or a PR number (→ the FR whose `pr:` matches in
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh list`), optionally followed by `drop`.

## A. After the merge (default)

1. **Gate:** `gh pr view <N> --json state,mergedAt` says `MERGED`, and `fr.sh list`
   shows the FR as `merged`. Otherwise stop: either it is not merged yet, or the FR
   doc reached the base branch without `status: in-review` — then `:ship` did not
   finish; say so.
2. `fr.sh sync-fr <ID> --no-fetch`.
3. Continue with **C**.

## B. Drop the FR (`drop`)

1. **Gate:** the FR exists and is not `merged`. An open PR for its branch → stop;
   the user closes it first, or decides otherwise.
2. Ask for the reason in one sentence, and confirm that the FR will be dropped.
3. Commit the drop **on top of what is already pushed**, never in the FR's own
   worktree — that one may hold unreviewed local commits, and pushing them would
   publish unreviewed code:
   `git worktree add --detach .claude/worktrees/_drop-<id-lower> origin/<branch>`,
   there set `status: dropped`, add a section `## Dropped` with date and reason,
   commit (`docs(fr): drop <ID>` or the project's convention),
   `git push origin HEAD:<branch>`, remove the temporary worktree.
   The branch was never pushed → nothing to publish: mark it dropped locally.
   The FR exists **only on the base branch** (`location: base`, no branch): the
   change has to reach the base branch, which is usually protected. Create a
   branch from `branch_pattern` (type `docs`) off `origin/<base_branch>` in a
   temporary worktree, make the same change there, push, and open a PR
   (`docs(fr): drop <ID>`). The user merges it; until then the branch already
   shows the FR as dropped.
4. `fr.sh sync-fr <ID> --no-fetch` — the issues now show the FR as `dropped`.
5. Continue with **C**. Keep the remote branch: it is the dropped FR's record and
   keeps it visible in `/fr-workflow:status`.

## C. Issues and cleanup

1. Per issue of the FR, `fr.sh issue-frs <ref> --no-fetch`:
   - every FR `merged` or `dropped`, at least one `merged` → fully served:
     propose closing;
   - every FR `dropped` → nothing was delivered: propose re-planning with
     `/fr-workflow:new <ref>`, or closing as not planned
     (`gh issue close <n> -R <repo> --reason "not planned"`) — the user's call;
   - any FR still open → keep the issue open; its backlink shows what is left.

   Show one table — issue · its FRs with status · proposal — and act only on what
   the user confirms:
   `gh issue close <n> -R <repo> --comment "Done with <FR ids> (<repo>#<PR>, …)."`
2. Clean up, each step only if it is safe:
   - A Claude session still running in the FR's worktree? Check
     `claude agents --json` (match `cwd` to the worktree path, or `name` starting
     with `<ID> `). Running → stop here and name it; the user ends it
     (`claude stop <id>`) or lets it finish. A finished background session: offer
     `claude rm <id>`.
   - `git worktree list --porcelain` shows the worktree `locked claude session …
     (pid N …)`: pid N still running (`ps -p N`) → a session is alive, stop as
     above. Not running → stale lock: `git worktree unlock <path>`.
   - `git worktree remove .claude/worktrees/<…>` — refuses on uncommitted changes:
     report them, never `--force`.
   - `git branch -d <branch>` — refuses after a squash merge or a drop, which git
     cannot see as merged: ask before `-D`. After a drop, first show
     `git log origin/<branch>..<branch> --oneline`: those local commits are lost
     with `-D`.
   - Remote branch after a merge: nothing if GitHub deleted it; otherwise offer
     `git push origin --delete <branch>`. After a drop: keep it (see B.5).
3. Report: issues closed, issues still open with their remaining FRs, cleanup done.
