# claude-fr-workflow — working on this repository

This repository is the marketplace **and** the plugin `fr-workflow`. User docs:
[README.md](README.md) and [docs/](docs/). This file is for whoever maintains the
plugin — person or Claude, on any machine: the decisions, conventions and
pitfalls that the code does not show.

## Principles

- **Minimal maintenance budget.** Prefer what someone else maintains: Claude Code
  built-ins (`/code-review`, `/security-review`, worktrees, `claude agents`,
  `--bg`) over GitHub features (issue forms) over own code. Own code only where
  nothing equivalent exists — here `scripts/fr.sh` (FR list, FR doc from the
  issue, the FRs of a request, overlap, lock, board status), the skill texts and
  the two review agents.
- **Projects only get better, never worse.** Client repositories pin a tag. A
  change is released as a new tag, tested in the sandbox, and only then does a
  client's pin go up. Never move a pushed tag.
- **Nothing project- or customer-specific in the plugin.** Project facts live in
  each repository's `.claude/workflow.md`.
- Discuss changes with the maintainer before building them.

## Decisions — do not reopen without a new reason

- **The issue is the spec until the start** (0.5). An FR is a GitHub issue with
  the label `fr` holding the full spec, written by `new` — local first from an
  idea, or GitHub first from a request. `start` turns it into the FR doc
  (`fr.sh spec`); from then on the doc is the source and the issue body is not
  synced back. Replaces FR docs from `new` on, `next-id` and the backlink
  comments.
- The FR id is the issue number. Requests and FRs are linked with what GitHub
  has: sub-issues, and the *Requests* line of the FR's Planning, found back
  through the request's timeline (`fr.sh issue-frs`) — no own bookkeeping.
- The board is written, not derived, when a project asks for it (0.5): GitHub's
  workflows know *added* and *closed*, not *running*, *waiting*, *blocked* or
  *failed*. `project_status` maps the plugin's seven events to the project's own
  column values; `fr.sh project-status` writes them best effort (exit 5 = not
  written) with gh's name-based `item-edit` (gh ≥ 2.97; the node-id form needs
  three lookups more), no skill ever stops for the board, and without the key
  nothing is written.
- What the skills write to GitHub is in the language of its source — the idea,
  the file, the request — never switched to English (0.5.1); the plugin's own
  files stay English.
- PRs say `Closes` for the FR's own issue and `Refs` for its requests; `done`
  closes a request only when all its FRs are closed, and only after
  confirmation.
- No shared index file; `merged` is derived (an `in-review` doc on the base
  branch), never written.
- `new` writes only to GitHub. An FR's branch is created by `start` off
  `origin/<base>` in its worktree, the FR doc as first commit — never on the
  user's branch or the base branch.
- Implementation sessions commit but never push; `ship` pushes after its code
  and security review. Secrets always stop and are removed from unpushed
  commits; a secret ever pushed must be rotated.
- No CI skip markers anywhere — a squash merge copies them onto the base branch
  and skips its release. Builds from planning pushes are avoided with
  `paths-ignore` on push triggers, which `init` proposes.
- Two shapes of issue: requests follow `templates/issue-form.yml` (the GitHub
  form, label `fr-request`), FR issues `templates/fr.md` (label `fr`). Headings
  and Planning keys stay English — `fr.sh` parses them.
- Model and effort per field: explicit values in the request are binding; else
  its size via `size_models`; else `impl_model` / `impl_effort`.
- `agents/` holds adapted copies of `silent-failure-hunter` and
  `type-design-analyzer` from Anthropic's `pr-review-toolkit` (Apache-2.0,
  `LICENSE` beside them): the originals assume Anthropic's own codebase (Sentry,
  `logError`, error ids) and a plugin the client machine may not have. Upstream
  changes are not followed automatically. Its other agents duplicate built-ins.
- Playwright MCP stays on `@latest` — maintained by Microsoft; accepted trade-off.
- Jira is not implemented — FRs are GitHub issues. When needed, via Atlassian's
  official MCP server, not own code.
- The plugin never merges, never triggers deployments, never touches production.

## Code conventions

- `fr.sh` runs on bash 3.2 (macOS `/bin/bash`) and Git Bash: no associative
  arrays, no `mapfile`, no `case` inside `$(…)`. Never end a function or loop
  body with `[ … ] && cmd` — under `set -e` its exit code leaks out.
- Path-listing git commands go through `g` (`core.quotePath=false`), issue refs
  only through `NORM_AWK`'s `canon()`, FR branch names only through
  `fr_branch_re` / `fr_branches`, branch refs through `pick_ref`. Diffs that may
  fail get `|| true`.
- Skills are English, `disable-model-invocation: true`, and allow `fr.sh` via
  `${CLAUDE_PLUGIN_ROOT}` in `allowed-tools`. They read `reference/model.md`
  first. A skill cannot invoke another one (`disable-model-invocation`), so it
  reads the other's `SKILL.md` and follows it.
- Agents get read-only `tools` and a short `description` — it is loaded in every
  session. Their attribution comment stays and says what was changed.
- Issue bodies are read only through `PLAN_AWK` (`planning()`), fetched with the
  `J_ROW` / `J_REST` jq expressions: lines joined by `\037`, never `@tsv`, whose
  escapes are ambiguous.
- Every bug fixed in `fr.sh` gets a case in `tests/fr-sh.sh`.
- Markdown tables are column-aligned, so they read in plain text too: every cell
  padded to its column's width, separator rows as `| --- |`. Re-align the whole
  table after any edit to it.

## Testing

- `/bin/bash tests/fr-sh.sh` — throwaway repos, stub `gh`, nothing reaches GitHub.
- `claude plugin validate .` and `claude plugin validate plugins/fr-workflow`.
- **Sandbox:** private repo `bmoers/fr-workflow-sandbox`, pinned in its
  `.claude/settings.json`, with profile, issue form and labels `fr-request` and
  `fr` set up. The local clone must be a folder Claude Code trusts, otherwise background
  sessions refuse to start.
- **Headless runs** (`claude -p`) do not load plugins from project settings: use
  `--plugin-dir plugins/fr-workflow` of this working copy for unreleased changes,
  or `~/.claude/plugins/marketplaces/claude-fr-workflow/plugins/fr-workflow` for
  the pinned version. Prompts must carry the user's confirmations — skills stop
  at their gates otherwise.
- A raised pin takes effect with a **new session** in the repository;
  `/plugin marketplace update` alone keeps following the old `ref`.
- The auto-mode classifier refuses to create GitHub repositories and to merge
  PRs: the maintainer does those, in the sandbox too.
- After a test, reset the sandbox: delete FR branches (remote and local), close
  test issues as *not planned*; keep its setup.

## Release

The checklist is in the README (*Maintaining the plugin → Release*): suite and
validation green, CHANGELOG, `version` in `plugin.json`, example tag in
`docs/installation.md`, commit, tag, push — then raise the sandbox pin and start
a new session there.

## History

- 0.1 m:n model, backlinks · 0.2 parallel FRs, model/effort per FR, sync and drop
  · 0.3 security review in `ship`, nothing pushed unreviewed · 0.4 issue form and
  `/fr-workflow:idea` · 0.5 the issue is the spec until the start (local or
  GitHub first, sub-issues, project; `idea` and `sync` gone), review agents in
  `ship`, failure behaviour, board status · 0.5.1 board setup
  (`project-options`), the language of what goes to GitHub, first end-to-end
  run of 0.5 with the board. Details: [CHANGELOG.md](CHANGELOG.md).
- Before 0.3.0, three `/code-review` rounds found 37, 23 and 19 issues. Recurring
  bug classes: `set -e` exit codes, git path quoting, ref normalization, branch
  name rules, unpushed local commits, the order of secret removal. 0.3.1 came
  from the first full end-to-end run in the sandbox.
