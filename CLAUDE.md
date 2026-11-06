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
  issue, the FRs of a request, overlap, lock, board status, worktree hooks, the
  autopilot's pipeline and launches), the skill texts and the two review agents.
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
- The implementation session is opened by the user (`claude -w <worktree>`)
  and briefed by `/fr-workflow:implement`, not by a prompt on the command line
  (0.5.2): a long quoted prompt wraps when copied from a terminal and the
  session starts without it. Background sessions (`start` with several FRs)
  still get the prompt as an argument — nothing is copied there.
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
  its size via `size_models`; else `impl_model` / `impl_effort`. The ship
  session has its own, `ship_model` / `ship_effort` (0.5.3): the gates and the
  acceptance check judge with the session's model, so the implementation
  session's choice must not weaken them — `implement` ends with the ship
  session's command. The review agents run on `opus`, not `inherit`, for the
  same reason.
- `agents/` holds adapted copies of `silent-failure-hunter` and
  `type-design-analyzer` from Anthropic's `pr-review-toolkit` (Apache-2.0,
  `LICENSE` beside them): the originals assume Anthropic's own codebase (Sentry,
  `logError`, error ids) and a plugin the client machine may not have. Upstream
  changes are not followed automatically. Its other agents duplicate built-ins.
- **Worktree hooks** (0.5.4): `worktree_setup` / `worktree_teardown` are all
  the plugin knows about what a project runs beside a worktree — a dev stack
  per worktree, dependencies. They run through `fr.sh hook`, not from the skill
  text, so environment and failure are cases in the suite. Not Claude Code's
  `WorktreeCreate` hook: it fires only for `claude -w`, `isolation: "worktree"`
  and background sessions, and replaces the creation of the worktree, while
  `start` creates worktrees itself with `git worktree add`. Setup runs on every
  start, resume included (idempotent by contract); teardown runs before
  `claude rm` as well, which removes a finished session's worktree. A failed
  hook is `blocked`, never retried, never `--force`. Ignored files are invisible
  to the skills — the hooks' generated files belong in `.gitignore`.
- **Autopilot** (0.6): the hand-offs between the sessions (implement → ship,
  merge → next wave) are driven by `/fr-workflow:autopilot`, a background
  session that decides with `fr.sh pipeline` and acts with `fr.sh launch`.
  Deterministic parts live in `fr.sh`, testable with stub `gh` and `claude`; the
  skill only executes actions. State is derived; the two facts git and GitHub
  lack (what a session reported, which session the autopilot launched) go into
  a local log per FR in the git common dir, like the ship lock. `launch` stops
  only sessions it started or one named with `--replace`, and its prompts are
  fixed slash commands: no issue text reaches a shell or a prompt. Whether a
  launched session still works comes from `claude agents --json` (busy,
  waiting, idle) first; the worktree lock counts for another pid's session, and
  decides alone when `claude agents` says nothing — a finished session lingers
  idle with its lock, and the first sandbox run waited on one forever.
- **Fix loop** (0.6) reopens "no improvised fix loop" for one reason: routine
  red checks and review comments cost a human round trip each. Bounded instead
  of forbidden: opt-in `fix_loop` (default `off`), `fix_attempts`, a fresh
  implementation session per attempt (the session that judges is still never
  the one that wrote the code), a full new ship after every fix. Never in the
  loop: secrets, security findings, review findings under `stop`, acceptance,
  deployments, conflicts, `fix_skip_checks`. PR comments only from
  `OWNER`/`MEMBER`/`COLLABORATOR` or listed bots, since on a public repository
  comments are an injection channel. The skills' own gates still never fix.
- **Deployment signal** (0.7.0): `deploy_signal: deployment` reads GitHub's
  Deployment records through `fr.sh deployment`, never creates one. Which
  commit is "this PR's" — the head, or a merge commit of it whose other parent
  is on the base branch — is decided in code, the same rule the ship skill
  states in prose for the other signals. `acceptance_label` is all the plugin
  does to tell a project that a slot is in use: one label on the PR, set before
  the acceptance check, removed after it and before any stop.
- **Notifications** (0.7.0): Claude Code tells about a waiting or finished
  background session only while `claude agents` is open, and its `Notification`
  hooks are not documented to fire in `--bg` sessions. So the autopilot's
  `pipeline --wait` runs the profile's `notify_command` for every row that
  needs the user and is new since its last result, and `fr.sh notify` for the
  autopilot's summary — the channel is the project's, the plugin ships no hook.
- **Spec model** (0.7.0): opt-in with `spec_dir`. The delta is flat — one
  requirement per `###`, operation, capability and name in the heading — with
  English keywords and the three evidence words `unit test`, `eval`,
  `check on test`, because `fr.sh` parses them; decided with Boris 2026-11-05
  against OpenSpec's grouped `## ADDED Requirements` headings. The issue body
  and the FR doc carry the identical section. `Base:` fingerprints pin what
  MODIFIED/REMOVED/RENAMED refer to — written by `fr.sh spec` at the start,
  checked by `validate`; a moved base is `blocked spec`, never a silent merge.
  The fold happens in `ship` after the review gate and before the first push,
  in its own commit — never on the base branch. Overlap compares requirements,
  not spec files: two FRs may change one capability, not one requirement.
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
- Under `set -o pipefail` a consumer that stops early — `awk … exit`,
  `grep -q`, `head` — kills its producer and fails the pipeline: read everything
  (`!f { …; f = 1 }`, `grep … >/dev/null`). `read` with `IFS=$'\t'` collapses
  empty fields: never emit an empty field between tabs — print `-`.
- Text from GitHub or a delta — a title, a requirement name — reaches awk
  through `ENVIRON`, never `-v`: `-v` processes backslash escapes, and a `\n`
  in a name would forge a row.
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
- **Background sessions** (`claude --bg`, used by `fr.sh launch` and `start`)
  are pre-spawned daemon processes: nothing of the caller's environment reaches
  them, only flags and the project's settings. `FR_CLAUDE` (the `claude` that
  fr.sh calls) is a test hook for the shell running fr.sh; a launched session
  gets it only from the sandbox's `.claude/settings.local.json` `env`. A plugin
  disabled with `claude plugin disable -s local` is disabled in worktree
  sessions too.
- A raised pin takes effect only after the marketplace is re-registered at
  the new tag: `claude plugin marketplace remove claude-fr-workflow --scope user`
  (without `--scope`, run inside a repository, it also strips the pin from that
  repository's `.claude/settings.json`), `claude plugin marketplace add
  'bmoers/claude-fr-workflow#<tag>'`, then in the repository
  `claude plugin install fr-workflow@claude-fr-workflow -s project`. The
  marketplace is registered once per machine with the first `ref` it was
  brought with, `/plugin marketplace update` keeps following that `ref`, and a
  session does not re-register a known one (an interactive session registers
  an unknown marketplace from the project settings; `claude -p` registers
  nothing). One `ref` per machine — the sandbox and any client repository on
  the same machine move together. A user-scope install of the plugin
  overrides every pin: never.
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
  run of 0.5 with the board · 0.5.2 `implement`, the pin procedure · 0.5.3 the
  ship session's own model, agents on `opus` · 0.5.4 worktree hooks
  (`worktree_setup` / `worktree_teardown`, `fr.sh hook`) · 0.6 autopilot,
  opt-in fix loop · 0.7.0 deployment signal (`deploy_signal: deployment`,
  `acceptance_label`), `notify_command`, spec model (`spec_dir`, spec deltas,
  `fr.sh validate|fingerprint|fold`). Details:
  [CHANGELOG.md](CHANGELOG.md).
- Before 0.3.0, three `/code-review` rounds found 37, 23 and 19 issues. Recurring
  bug classes: `set -e` exit codes, git path quoting, ref normalization, branch
  name rules, unpushed local commits, the order of secret removal. 0.3.1 came
  from the first full end-to-end run in the sandbox.
