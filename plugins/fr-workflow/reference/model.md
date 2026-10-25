# fr-workflow — model and rules

Every fr-workflow skill reads this first.

## Terms

- **Issue** — what was asked for. A GitHub issue (`jira:KEY-N` is reserved for a
  later version).
- **FR** (feature request) — the unit of work: a spec with acceptance criteria,
  one branch, one worktree, one PR.
- Issues and FRs are **m:n**. One issue may need several FRs; one FR may serve
  several issues.

## Project profile

`.claude/workflow.md` in the repository: flat `key: value` frontmatter (read by
`fr.sh` and by you) plus prose sections with the project's facts — conventions,
checks, test environment, extra rules. Template:
`${CLAUDE_PLUGIN_ROOT}/templates/workflow.md`. Never invent a value the profile
does not give — ask.

## FR document

- Path `<fr_dir>/<ID>-<slug>.md`, e.g.
  `req/feature-requests/FR-012-checkout-coupons.md`. Template:
  `${CLAUDE_PLUGIN_ROOT}/templates/fr.md`.
- The frontmatter is the **single source of truth**. Keep it flat, one line per
  key, the list on one line:

  ```yaml
  ---
  id: FR-012
  title: Coupons in checkout
  status: open
  issues: [acme/shop#12, acme/shop#15]
  pr:
  created: 2026-10-25
  ---
  ```

- `issues`: canonical refs `owner/repo#N`. Empty list is fine.
- `status`: `open` → `in-progress` (`:start`) → `in-review` (`:ship`, after the
  acceptance check passed), or `dropped`. **`merged` is never written**: `fr.sh`
  derives it when an `in-review` FR is on the base branch. The base branch is
  usually protected, so nothing gets committed there after a merge.

## Branches and worktrees

- One branch per FR, created by `:new` off the base branch and pushed with the FR
  doc as its first commit. Name from `branch_pattern`, default
  `{type}/{id-lower}-{slug}` → `feat/fr-012-checkout-coupons`. The branch name
  **must contain the FR number** — that is how `fr.sh` finds FR docs on branches.
- One worktree per FR at `.claude/worktrees/<id-lower>-<slug>` (gitignored),
  created by `:start`.
- The FR doc travels with the code and reaches the base branch with the merge.
- There is **no shared index file**: a table edited in every PR conflicts and
  drifts. The overview is `/fr-workflow:status`.

## Issue backlinks

- Every linked GitHub issue carries one comment, maintained by `fr.sh sync`,
  listing all FRs that reference it with status and PR. It is derived: never edit
  or write it yourself — re-run sync.
- Sync all issues of an FR whenever its frontmatter changed **and was pushed**
  (otherwise its link does not resolve).
- Profile `backlinks: off` → skip sync.

## PRs and closing issues

- The PR body links issues with `Refs owner/repo#N` — **never**
  `Closes`/`Fixes`/`Resolves`: with m:n the first merge would close an issue that
  other FRs still serve.
- Issues are closed only by `:done`, only when every FR referencing them is
  `merged` or `dropped`, and only after the user confirmed.

## Script

`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh`, from anywhere inside the repository:

| Command | Does |
|---|---|
| `check` | prerequisites and profile |
| `list` | all FRs as TSV: `id status location ref path pr issues title` |
| `next-id` | next free id — counts base, FR branches, local files and branch names |
| `issue-frs <ref>` | FRs that reference an issue |
| `sync <ref>... [--dry-run]` | create or update the backlink comment |

`location` is `base`, `branch` (then `ref` is the branch) or `local` (uncommitted
in this checkout). All but `check` fetch origin first; pass `--no-fetch` after
the first call within one skill run.

## Hard rules — every skill, every project

The profile and the project's `CLAUDE.md` may add rules; they never relax these.

- **Never merge** a PR. The merge is the user's decision.
- **Never trigger** deploy or release workflows (`gh workflow run`, re-running
  deploy jobs). If a deployment does not come, report it.
- **Never touch production** — no reads, no writes — unless the user explicitly
  asks, for that one action.
- No force push, no rebase of a pushed FR branch, no `reset --hard`, `restore`,
  `clean` or `stash drop` on the user's changes. Unclear changes → ask.
- Never ask for, store or type credentials. A login wall → the user logs in
  themselves, in the browser window.
- No personal or customer data in commits, PRs, issue comments or screenshots.
- Issue comments are read by the customer: post only the backlink (`fr.sh sync`)
  and what `notify_issues` allows.
- A gate that does not hold **stops** the skill: show the evidence, the user
  decides. No improvised fix loop.
