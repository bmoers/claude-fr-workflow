---
name: start
description: Start implementing one or more FRs — pulls each FR issue, checks it against the current code, creates branch, worktree and FR doc, then a fresh Claude session per FR. Several FRs that do not overlap run in parallel as background sessions.
argument-hint: "<#47 | FR-47> [more…]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: start

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` must pass.

FRs: $ARGUMENTS — `#47`, `47`, `FR-47` or issue URLs. None given → `fr.sh list`,
offer the `open` FRs and the `in-progress` ones to resume, ask.

Work from the **main worktree** — `claude -w` resolves worktree names there:
`cd "$(git worktree list --porcelain | sed -n '1s/^worktree //p')"` (keeps paths
with spaces intact).

## 1. Check each FR

From `fr.sh list`, by its id `<fr_prefix>-<number>`:

- `open` (location `issue`) → a **new start**. `fr.sh spec <issue>` prints the FR
  doc it would write — read it, it is the session's whole brief — or exits 4 with
  the reasons the issue is not ready: leave the FR out, show them; it is
  finished with `/fr-workflow:new <issue>`.
- `in-progress` or `in-review` → **resume**: a worktree may exist
  (`git worktree list`); reuse it, never create a second one. Nothing is pulled
  from the issue — the FR doc is the source.
- `merged` or `dropped` → leave it out and say so.
- Not listed → no open FR issue: closed, or not defined yet (`/fr-workflow:new`).

## 2. Has the code moved since the definition?

Per new start, with `based_on` and `areas` from the printed doc:
`git log --oneline <based_on>..origin/<base_branch> -- <areas>`.

- Nothing → the spec still fits.
- Commits → read their changes in the areas against the *Technical notes*, and
  say what no longer fits. The user decides: start anyway — the session adapts
  and records it in the FR doc — or refine first with `/fr-workflow:new <issue>`.
- `based_on` empty or unknown here (`git cat-file -e <based_on>` fails) → say so;
  the user decides.

## 3. Several FRs: what may run in parallel

`fr.sh overlap <ids> --no-fetch` lists conflicts and waves. Start **wave 1** only.
Show the other waves with the reason for each conflict, and that they can start
once the conflicting FR is merged — or now, if the user accepts the overlap.

## 4. Prepare each FR

**New start:**

1. Branch name from `branch_pattern`: `{type}` from the FR (`feat`, `fix`, …;
   unclear → ask), slug = 3–5 words of the title, lowercase ASCII joined with
   `-` (ä→ae, ö→oe, ü→ue, ß→ss, accents dropped). A branch for this FR exists
   already (`git branch -a --list '*<id-lower>-*'`) → it was started before:
   stop and say so.
2. `git worktree add -b <branch> .claude/worktrees/<id-lower>-<slug> origin/<base_branch>`
   — a new branch off the base branch, never the user's branch.
3. `fr.sh spec <issue> .claude/worktrees/<id-lower>-<slug>/<fr_dir>/<ID>-<slug>.md`.
4. In the worktree, commit it (`docs(fr): start <ID>` or the project's
   convention). After the commit, before pushing: check the doc for credentials
   or personal data, and run the profile's secret scan on the commit if there is
   one. Then `git push -u origin <branch>` — the branch holds nothing but the FR
   doc.
5. `fr.sh project-status <issue> running` — the board column, when the profile
   maps it (`project_status`). Exit 5 (not written) is a line in the report,
   never a stop.

**Resume:**

1. No worktree yet → `git worktree add .claude/worktrees/<id-lower>-<slug> <branch>`
   (slug from the FR doc's file name); git creates the local branch from origin.
2. A local branch that existed already may be behind origin (someone pushed to
   it): when `origin/<branch>` exists, `git merge --ff-only origin/<branch>` in
   the worktree — name it explicitly, the upstream may be the base branch. Not a
   fast-forward (both sides moved) → leave this FR out and say so; never rebase or
   force.
3. Change nothing, push nothing — the worktree may hold unreviewed local commits,
   and a push to a branch with an open PR can deploy.
4. `fr.sh project-status <issue> running` — a resumed FR is running again; the
   board column is not a git change.

Model and effort: the FR doc's `model` and `effort`, else the profile's
`impl_model` and `impl_effort`, else `opus` and `high`.

## 5. Start the sessions

- **One FR** → give the user two things for a fresh terminal, from the main
  checkout: the command that opens the worktree session,

  ```bash
  claude -w <id-lower>-<slug> --model <model> --effort <effort> -n '<ID> <clean title>'
  ```

  and `/fr-workflow:implement` as its first message — it finds the FR from the
  branch, reads the FR doc and the profile, implements, commits, never pushes.
  No prompt on the command line: copied from a terminal, a long line wraps and
  breaks. If the user prefers to go on in this session: `cd` into the worktree
  and follow `${CLAUDE_PLUGIN_ROOT}/skills/implement/SKILL.md` there.
- **Several FRs** → start each one in the background yourself, adding `--bg`,
  from the main worktree, with the prompt below as the initial message:

  ```bash
  claude -w <id-lower>-<slug> --bg --model <model> --effort <effort> -n '<ID> <clean title>' '<prompt>'
  ```

  It prints the session id. If it answers *Workspace not trusted*, the user
  must run `claude` once in the repository and accept the trust prompt — never
  work around it.

`-w` with an existing name opens that worktree on its FR branch; it does not
create a new one. The quoted values go in **single quotes**, and contain no
single quotes, double quotes, backticks, `$` or backslashes — remove them from
the title (it often comes from customer-written issues). The prompt for a
background session:

> Implement <ID>. First run git branch --show-current: it must print <branch>, else
> stop and say so. Read <fr_dir>/<file> - it is your whole brief - and
> .claude/workflow.md. Keep the FR document current: decisions and deviations go
> into it, in the same commits as the code. Run the profile's local checks and
> commit. Do not push: /fr-workflow:ship pushes after its code and security
> review. Never merge. When done, stop with a short summary of what you did and
> what is open; the user then runs /fr-workflow:ship here.

## 6. Hand over

Report per FR: worktree, model and effort, session name, and whether the code had
moved since the definition; for one FR the command and `/fr-workflow:implement`.
Then how to follow them:

| To                                    | Run                    |
| ------------------------------------- | ---------------------- |
| see all sessions and their state live | `claude agents`        |
| read what one is doing                | `claude logs "<ID>"`   |
| answer its questions or take over     | `claude attach "<ID>"` |
| the FRs with their sessions           | `/fr-workflow:status`  |

Background sessions stop at permission prompts and wait — `claude agents` shows
them as waiting; attach to answer. Each one finishes with `/fr-workflow:ship` in its
own session.
