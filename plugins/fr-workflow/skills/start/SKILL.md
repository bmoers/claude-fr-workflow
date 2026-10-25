---
name: start
description: Start implementing an FR — its own worktree on the FR branch, status in-progress, issue backlinks updated. Session 2 of the workflow.
argument-hint: "<FR id, e.g. FR-012>"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: start

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` must pass.

FR: $ARGUMENTS — none given → `fr.sh list`, offer the `open` FRs, ask.

1. Find the FR in `fr.sh list`:
   - `location: branch` → `ref` is its branch.
   - `location: base` with `status: open` (FR committed to the base branch
     directly) → create the branch from `branch_pattern` off `origin/<base_branch>`.
   - `in-progress` or `in-review` → a worktree may exist (`git worktree list`);
     reuse it, never create a second one.
   - `merged` or `dropped` → stop and say so.
   - **Gate:** the FR doc's acceptance criteria are still the template
     placeholders or empty → stop. The FR is not specified yet; that is
     session-1 work with the user (`/fr-workflow:new`), not a guess made here.
2. `git worktree add .claude/worktrees/<id-lower>-<slug> <branch>` — git creates
   the local tracking branch from origin.
3. In the worktree: `status: in-progress` in the frontmatter, commit
   (`docs(fr): start <ID>` or the project's convention), push, then
   `fr.sh sync <issues of the FR> --no-fetch`.
4. Hand over. Implementation belongs in a fresh session inside the worktree, with
   the FR doc as its whole brief:

   ```bash
   cd .claude/worktrees/<id-lower>-<slug> && claude "Implement <ID> as specified in <fr_dir>/<file>. Read it first."
   ```

   If the user wants to go on in this session, switch into the worktree and read
   the FR doc before writing code.
5. While implementing: keep the FR doc current — decisions, deviations, answered
   questions go into it, in the same commits as the code. Finish with
   `/fr-workflow:ship`.
