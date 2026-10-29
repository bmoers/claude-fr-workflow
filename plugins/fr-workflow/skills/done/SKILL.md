---
name: done
description: Close out an FR — after its PR was merged, or to drop it. Closes the FR issue and, after confirmation, the requests it fully served; removes the worktree and local branch.
argument-hint: "<#47 | FR-47 | PR number> [drop]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: done

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`. Run it
from the main checkout, not from the FR's worktree — that one gets removed.

Arguments: $ARGUMENTS — an FR (`#47`, `FR-47`), or a PR number (→ the FR whose
`pr:` matches in `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh list`), optionally followed
by `drop`.

## A. After the merge (default)

1. **Gate:** `gh pr view <N> --json state,mergedAt` says `MERGED`, and `fr.sh list`
   shows the FR as `merged`. Otherwise stop: either it is not merged yet, or the FR
   doc reached the base branch without `status: in-review` — then `:ship` did not
   finish; say so.
2. The FR's issue (`issue` in the frontmatter):
   `gh issue view <n> -R <repo> --json state,stateReason`. Still open — the PR did
   not go into the default branch, or did not say `Closes` → it goes into the
   table in C.1, proposed for closing as completed.
3. Continue with **C**.

## B. Drop the FR (`drop`)

1. **Gate:** the FR exists and is not `merged`. An open PR for its branch → stop;
   the user closes it first, or decides otherwise.
2. Ask for the reason in one sentence, and confirm that the FR will be dropped.
3. **Started** (a branch or doc exists): commit the drop **on top of what is
   already pushed**, never in the FR's own worktree — that one may hold
   unreviewed local commits, and pushing them would publish unreviewed code:
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
   **Not started** (`location: issue`) → nothing in git.
4. The FR's issue goes into the table in C.1, proposed for closing as not
   planned, with the reason as its comment. When the FR is a request itself (it
   was rewritten from one: no `requests`, an *Original request* block), offer the
   alternative of sending it back for a new definition:
   `gh issue edit <n> -R <repo> --remove-label fr --add-label fr-request`.
5. Continue with **C**. Keep the remote branch: it is the dropped FR's record and
   keeps it visible in `/fr-workflow:status`.

## C. Issues and cleanup

1. One table — issue · its FRs with their state · proposal — and act only on what
   the user confirms:
   - the FR's issue, if still open (A.2, B.4):
     `gh issue close <n> -R <repo> --reason completed --comment "Done with <repo>#<PR>."`,
     or after a drop `--reason "not planned" --comment "Dropped: <reason>"`;
   - per request in the FR's `requests`: `fr.sh issue-frs <ref>`, counting this
     FR as closed the way just proposed:
     - every FR closed, at least one as `completed` → fully served: propose
       closing — `gh issue close <n> -R <repo> --comment "Done with #47, #48."`;
     - every FR closed as `not_planned` → nothing was delivered: propose a new
       definition with `/fr-workflow:new <ref>`, or closing as not planned
       (`gh issue close <n> -R <repo> --reason "not planned"`) — the user's call;
     - any FR still open → keep the request open; name the open FRs.

   Comments are read by the customer: no internals, no personal data, and in
   the issue's language — the texts above are templates (*Language* in the
   model).
2. Clean up, each step only if it is safe:
   - A Claude session still running in the FR's worktree? Check
     `claude agents --json` (match `cwd` to the worktree path, or `name` starting
     with `<ID> `). Running → stop here and name it; the user ends it
     (`claude stop <id>`) or lets it finish. A finished background session:
     `claude rm <id>` — it also removes the session's worktree and its lock when
     that is safe (it refuses on unpushed work), so the next two points may have
     nothing left to do.
   - `git worktree list --porcelain` shows the worktree `locked claude session …
     (pid N …)`: pid N still running (`ps -p N`) → a session is alive, stop as
     above. Not running → stale lock: `git worktree unlock <path>`.
   - `git worktree remove .claude/worktrees/<…>` — refuses on uncommitted changes:
     report them, never `--force`.
   - `git branch -d <branch>` **before** deleting the remote branch — while
     `origin/<branch>` still exists, git accepts `-d` after a squash merge. It
     refuses after a drop, or once the remote branch is gone: ask before `-D`.
     After a drop, first show `git log origin/<branch>..<branch> --oneline`: those
     local commits are lost with `-D`.
   - Remote branch after a merge: nothing if GitHub deleted it; otherwise offer
     `git push origin --delete <branch>`. After a drop: keep it (see B.5).
3. `fr.sh project-status <ID> done` — the FR id is its issue number, so this
   needs no FR doc; the board column is final, merged or dropped (GitHub's
   *Item closed* workflow may have set it already; exit 5 is a note, not a stop).
4. Report: issues closed, requests still open with their remaining FRs, cleanup
   done, the board status.
