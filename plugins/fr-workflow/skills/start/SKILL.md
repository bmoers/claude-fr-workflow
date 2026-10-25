---
name: start
description: Start implementing one or more FRs — a worktree per FR on its branch, status in-progress, then a fresh Claude session per FR. Several FRs that do not overlap run in parallel as background sessions.
argument-hint: "<FR id> [more FR ids…]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: start

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` must pass.

FRs: $ARGUMENTS — none given → `fr.sh list`, offer the `open` FRs, ask.

Work from the **main worktree** — `claude -w` resolves worktree names there:
`cd "$(git worktree list --porcelain | awk 'NR==1 { print $2 }')"`.

## 1. Check each FR

From `fr.sh list`:

- `location: branch` → `ref` is its branch.
- `location: base` with `status: open` (committed to the base branch directly) →
  create its branch from `branch_pattern` off `origin/<base_branch>`.
- `in-progress` or `in-review` → a worktree may exist (`git worktree list`); reuse
  it, never create a second one.
- `merged` or `dropped` → leave it out and say so.
- **Gate:** acceptance criteria still the template placeholders or empty → leave
  it out. It is not specified yet; that is session-1 work (`/fr-workflow:new`).

## 2. Several FRs: what may run in parallel

`fr.sh overlap <ids> --no-fetch` lists conflicts and waves. Start **wave 1** only.
Show the other waves with the reason for each conflict, and that they can start
once the conflicting FR is merged — or now, if the user accepts the overlap.

## 3. Prepare each FR to start

1. `git worktree add .claude/worktrees/<id-lower>-<slug> <branch>` — git creates the
   local tracking branch from origin.
2. In the worktree: `status: in-progress`, commit (`docs(fr): start <ID>` or the
   project's convention), push. Then `fr.sh sync-fr <ID> --no-fetch`.
3. Model and effort: the FR's `model` and `effort` from the frontmatter, else the
   profile's `impl_model` and `impl_effort`, else `opus` and `high`.

## 4. Start the sessions

The command for an FR:

```bash
claude -w <id-lower>-<slug> --model <model> --effort <effort> -n "<ID> <title>" '<prompt>'
```

`-w` with an existing name opens that worktree on its FR branch; it does not
create a new one. The prompt, in single quotes, without backticks or single
quotes inside:

> Implement <ID>. First run git branch --show-current: it must print <branch>, else
> stop and say so. Read <fr_dir>/<file> — it is your whole brief — and
> .claude/workflow.md. Keep the FR document current: decisions and deviations go
> into it, in the same commits as the code. Run the profile's local checks, commit
> and push. Never merge. When done, stop with a short summary of what you did and
> what is open; the user then runs /fr-workflow:ship here.

- **One FR** → give the user the command for a fresh terminal. If they prefer to go
  on in this session: switch into the worktree and read the FR doc first.
- **Several FRs** → start each one in the background yourself, adding `--bg`, from
  the main worktree. It prints the session id. If it answers *Workspace not
  trusted*, the user must run `claude` once in the repository and accept the
  trust prompt — never work around it.

## 5. Hand over

Report per FR: worktree, model and effort, session name. Then how to follow them:

| To | Run |
|---|---|
| see all sessions and their state live | `claude agents` |
| read what one is doing | `claude logs "<ID>"` |
| answer its questions or take over | `claude attach "<ID>"` |
| the FRs with their sessions | `/fr-workflow:status` |

Background sessions stop at permission prompts and wait — `claude agents` shows
them as waiting; attach to answer. Each one finishes with `/fr-workflow:ship` in its
own session.
