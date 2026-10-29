---
name: implement
description: Implement the FR of this worktree — the FR doc is the whole brief; commits locally, never pushes, ends with a summary and the command for the ship session. Run it in the worktree session that /fr-workflow:start named.
argument-hint: "[#47 | FR-47 — when the branch does not tell]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: implement

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.

## 0. Where am I

- `git branch --show-current` must be an FR branch: `fr.sh list` shows the FR
  with location `branch` and this branch as `ref`. $ARGUMENTS, if given, must
  name that same FR. The base branch, another branch, or no FR → stop and say
  so: the FR's worktree is opened from the main checkout with
  `claude -w <worktree name>` — the name `start` printed; this skill changes
  nothing anywhere else.
- Read the FR doc (`path` from `fr.sh list`). It is the whole brief: spec,
  acceptance criteria, technical notes, failure behaviour. The issue is history.
- `status` must be `in-progress`. `in-review` → the FR shipped already; only
  changes the user asks for after a review belong here — say so and wait.
- Uncommitted changes in the worktree come from an earlier session of this FR:
  read them and go on from there, never discard them.

## 1. Implement

- Follow the FR doc. What it leaves open and the code decides: decide, and
  write it into the doc — decisions and deviations go into the FR doc, in the
  same commits as the code. Acceptance criteria change only when the user
  agrees.
- The profile's conventions, *Hard rules* and *Local checks before commit*
  apply; run the checks before every commit.
- Commit locally, per the project's convention, with the FR id in the subject.
  **Never push, never merge** — `/fr-workflow:ship` pushes after its code and
  security review.
- A question only the user can answer → `fr.sh project-status <issue> input`
  (`<issue>` from the FR doc's frontmatter; exit 5 is a note, not a stop), then
  ask and stop. When the answer comes and work goes on:
  `fr.sh project-status <issue> running`.

## 2. Hand over

Stop with a short summary: what was done, what is open, which acceptance
criteria deserve a look. Then the ship session — a fresh session of this
worktree with the profile's `ship_model` / `ship_effort` (default `opus` /
`high`), opened from the main checkout:

```bash
claude -w <worktree name> --model <ship_model> --effort <ship_effort> -n '<ID> ship'
```

with `/fr-workflow:ship` as its first message. `<worktree name>` is this
worktree's directory name: `basename "$(git rev-parse --show-toplevel)"`.
`/fr-workflow:ship` in this session works too — its gates and acceptance check
are then this session's judgement, with this session's model; say so when the
FR's model is weaker than `ship_model`.
