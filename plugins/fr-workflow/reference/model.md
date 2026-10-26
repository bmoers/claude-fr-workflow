# fr-workflow — model and rules

Every fr-workflow skill reads this first.

## Terms

- **Issue** — what was asked for. A GitHub issue (`jira:KEY-N` is reserved for a
  later version). Its standard shape is the repository's issue form
  (`.github/ISSUE_TEMPLATE/feature-request.yml`, label `fr-request`, template
  `${CLAUDE_PLUGIN_ROOT}/templates/issue-form.yml`): problem, who, desired
  behaviour, how to tell it is done, priority, **size**, optional model and
  effort. People file it on GitHub; `/fr-workflow:idea` writes the same shape from
  a conversation.
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
  areas: [src/checkout, src/api/orders]
  model: opus
  effort: high
  pr:
  created: 2026-10-25
  ---
  ```

- `issues`: canonical refs `owner/repo#N`. Empty list is fine.
- `areas`: the directories or files the FR is expected to change, from reading the
  code at planning time. They decide what may run in parallel (see below).
- `model`, `effort`: for the implementation session, decided by `:new` — from
  the issue's explicit model/effort, else its size via `size_models`, else the
  profile's `impl_model` / `impl_effort`. Empty → `impl_model` / `impl_effort`.
- `status`: `open` → `in-progress` (`:start`) → `in-review` (`:ship`, after the
  acceptance check passed), or `dropped` (`:done <ID> drop`). **`merged` is never written**: `fr.sh`
  derives it when an `in-review` FR is on the base branch. The base branch is
  usually protected, so nothing gets committed there after a merge.

## Branches and worktrees

- One branch per FR, created by `:new` off `origin/<base_branch>` in a temporary
  worktree — never on the branch the user is on, never on the base branch — and
  pushed with the FR doc as its first commit. Name from `branch_pattern`, default
  `{type}/{id-lower}-{slug}` → `feat/fr-012-checkout-coupons`. The branch name
  **must contain the FR number** — that is how `fr.sh` finds FR docs on branches.
- One worktree per FR at `.claude/worktrees/<id-lower>-<slug>` (gitignored),
  created by `:start`.
- The FR doc travels with the code and reaches the base branch with the merge.
- There is **no shared index file**: a table edited in every PR conflicts and
  drifts. The overview is `/fr-workflow:status`.

## Parallel work

- Two FRs may run at the same time when they do not touch the same paths.
  `fr.sh overlap` compares each FR's `areas` **and** the files its branch already
  changed; one path inside the other counts as overlap, and so do two different
  files under one of the profile's `shared_paths` (migrations, lockfiles, i18n).
  An FR with neither areas nor changes overlaps everything — parallel only when it
  is evident. The result groups FRs into waves; wave 1 can start now.
- `:start` with several FRs starts one background session per FR of wave 1
  (`claude -w <name> --bg …`). Claude Code's own tools show them: `claude agents`,
  `claude logs`, `claude attach`.
- While a Claude session runs in a worktree, Claude Code locks the worktree
  (`git worktree list` shows `locked claude session … (pid N …)`). A lock whose pid
  no longer runs is stale and may be removed with `git worktree unlock`; a live
  one means the session is still running — never remove its worktree.
- Parallel PRs reach the base branch one after the other, so a later one can
  conflict. `:ship` then **merges** `origin/<base_branch>` into the FR branch — no
  rebase, no force push.
- `test_env: shared` (one deployment at a time): only one FR may be between its
  deploying push and its recorded acceptance check — `fr.sh lock`. The lock lives
  in the git directory all worktrees of a clone share, so it covers parallel
  sessions on one machine, not other developers. Against those, the deployed
  commit is checked before and after the acceptance check.

## Issue backlinks

- Every linked GitHub issue carries one comment, maintained by `fr.sh sync`,
  listing all FRs that reference it with status and PR. It is derived: never edit
  or write it yourself — re-run sync.
- After an FR's frontmatter changed **and was pushed** (otherwise its link does
  not resolve), run `fr.sh sync-fr <ID>`. It syncs every issue the FR references
  now *or referenced earlier*, so an issue taken out of `issues:` loses its entry
  too. An FR without issues is a no-op.
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
| `list` | all FRs as TSV: `id status location ref path pr issues title areas model effort` |
| `next-id` | next free id — counts base, FR branches, local files and branch names |
| `issue-frs <ref>` | FRs that reference an issue |
| `sync <ref>... [--dry-run]` | create or update the backlink comment of these issues |
| `sync-fr <ID>...\|--all [--dry-run]` | the same for every issue of these FRs, past links included — what the skills use |
| `overlap [<ID>...]` | `running ID` (every `in-progress` FR — always the context), `conflict A B reason`, `wave N ID` for the candidates (default: all `open` FRs). Wave 1 = overlaps neither a running FR nor another wave-1 FR: can start now |
| `lock acquire\|release\|break\|status <ID>` | ship lock for a shared test environment; `acquire` exits 3 when another FR holds it; `break` only after the user confirmed no ship runs |

`location` is `base`, `branch` (then `ref` is the branch) or `local` (uncommitted
in this checkout). `list`, `next-id`, `issue-frs`, `sync`, `sync-fr` and `overlap`
fetch origin first; pass `--no-fetch` after the first call within one skill run.
Issue refs are compared case-insensitively. Two FR branches with the same id make
`fr.sh` print a warning — renumber one of them.

## Hard rules — every skill, every project

The profile and the project's `CLAUDE.md` may add rules; they never relax these.

- **Never merge** a PR. The merge is the user's decision.
- **Never trigger** deploy or release workflows (`gh workflow run`, re-running
  deploy jobs). If a deployment does not come, report it.
- **Never touch production** — no reads, no writes — unless the user explicitly
  asks, for that one action.
- **No code leaves the machine unreviewed.** Implementation sessions commit but
  never push; the first push of code is `:ship`, after its code and security
  review. `:new` and `:start` push only FR docs.
- **Secrets never get pushed.** A credential found in a change always stops,
  cannot be accepted, and is removed from the unpushed commits before any push.
- **Never write a CI skip marker** — `[skip ci]`, `[ci skip]`, `[no ci]`,
  `[skip actions]`, `[actions skip]`, a `skip-checks:` trailer — into a commit
  message, PR title or PR body. A squash merge copies the branch's commit
  messages into the commit on the base branch, and the marker would then skip the
  base branch's release and deploy workflows.
- No force push, no rebase of a pushed FR branch, no `reset --hard`, `restore`,
  `clean` or `stash drop` on the user's changes. Unclear changes → ask.
- Never ask for, store or type credentials. A login wall → the user logs in
  themselves, in the browser window.
- No personal or customer data in commits, PRs, issue comments or screenshots.
- Issue comments are read by the customer: post only the backlink (`fr.sh sync`)
  and what `notify_issues` allows.
- A gate that does not hold **stops** the skill: show the evidence, the user
  decides. No improvised fix loop.
