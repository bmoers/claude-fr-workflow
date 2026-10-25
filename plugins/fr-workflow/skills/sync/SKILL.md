---
name: sync
description: Refresh the generated FR comments on GitHub issues — for some FRs, some issues, or everything. Use after editing an FR's issues or status by hand.
argument-hint: "[FR-012 … | #12 owner/repo#15 … | all]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: sync

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md`. Profile `backlinks: off` → say
so and stop.

Arguments: $ARGUMENTS

- FR ids → `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh sync-fr <ids>` — every issue these
  FRs reference now or referenced earlier.
- Issue refs → `fr.sh sync <refs>`.
- `all` → `fr.sh sync-fr --all`.
- Nothing → ask which of the three.

The comments link to the FR docs on GitHub, so local changes must be committed and
pushed first; `fr.sh` warns about FRs that are not. Report each issue and whether
its comment was created or updated.
