# Changelog

## [0.8.0] — 2026-11-07

For an autonomous factory: the board hands FRs to the autopilot, the ship
session may hand the merge to GitHub, and the autopilot cleans up after it.

### Added

- **Phases on the board:** `project_phase_field` names a second single-select
  column (Backlog, Planning, Building, Review, Done); `project_status` values
  may then be `Phase/Status`, written as two edits. A value without a phase
  leaves the phase as it is — `input`, `failed` and `blocked` keep the card
  where it stopped. Three events so every phase change has one: `planning`
  (`new`, before `defined` or `input`), `review` (`fr.sh launch ship`, the
  hand-off to the ship session), `shipping` (`ship` at its start, instead of
  `running`).
- **The queue from the board:** `autopilot_queue: project` — every `pipeline`
  call runs `fr.sh queue sync`, which takes the open FR issues of the issue
  repository standing on the square `project_status` maps `defined` to,
  filtered by `autopilot_assignee` (a login, `none` for unassigned FRs, empty
  for any). Several autopilots share one repository by assignment. Read
  through GraphQL with pagination; an unreadable board is a line on stderr,
  never a stop. `fr.sh queue sync` by hand shows what it takes.
- **`fr.sh merge-gate <ID>`:** the deterministic checks before a merge request
  — in review on its branch, an open PR of this repository that does not
  conflict and has no red check (pending is fine), the local log's last event
  no stopped gate, the acceptance check recorded with nothing failed and
  nothing unverified left unaccepted, no test file deleted on the branch, no
  focused or skipped test added in a test file, no CI skip marker in the PR
  or a commit. Exit 4 with every reason.
- **`fr.sh merge <ID>` and `auto_merge`:** with `auto_merge: auto` the ship
  session's step 6b runs the gate and then `gh pr merge --auto
  --<merge_method>` (`merge_method`, default `squash`): GitHub merges at once
  when the base branch's rules are met, otherwise when they are. The rules
  decide — never `--admin`, never a bypass; the pipeline shows the PR as
  `merging` and does not report it as waiting for the user. Default `off`:
  nothing changes.
- **`fr.sh finish <ID>` and `autopilot_finish`:** after the merge the
  autopilot's action is `finish` — the worktree hook, the worktree (never on
  uncommitted changes; the session the autopilot launched for the FR,
  idle once the FR is merged, is ended first, a lock whose process is gone
  is lifted, anyone else's live session stops it), the local branch (`-d`; after a squash merge with
  *Delete branch on merge* git refuses, so `-D` when the branch tip is the
  merged PR's head — nothing is lost then), the board's `done`, out of the
  queue. A finish that fails is logged and reported once. Issues and requests
  stay with `done`. Default `off`.
- **Per-machine profile values:** `.claude/workflow.local.md` beside the
  profile, ignored by git, may set `autopilot_assignee`, `notify_command`,
  `session_permission_mode`, `autopilot_model` and `autopilot_effort` — facts
  about the machine, not the project. A value there wins; other keys are
  ignored, `fr.sh check` names them and a missing `.gitignore` entry.
- **The autopilot container** (`docker/`, [docs/container.md](docs/container.md)):
  an image with Claude Code pinned, gh, git, jq and a Chromium under Xvfb for
  the Playwright server, run as an unprivileged user; its entrypoint clones
  the repository, registers the plugin marketplaces at the repository's pinned
  tag, writes the trust, the per-machine profile and the classifier's auto-mode
  context, and keeps `fr.sh launch autopilot` alive. Tokens come from the
  environment (`claude setup-token`, a gh token), never from the image. The
  workflow `image.yml` publishes it as
  `ghcr.io/bmoers/fr-workflow-autopilot:<tag>` for arm64 and amd64 on every
  release tag; the manual in `docs/container.md` takes a developer from the
  tokens to the first FR. First run 2026-11-07 against the sandbox.
- **Stops reach the person.** The pipeline's `failed`, `waiting` and `input`
  rows say how to go on — `attach_command` of this machine (a per-machine
  key, default `claude attach`; the container writes its `docker exec` form)
  with the session that lingers, the skill to run again once it ended, or that
  a comment answers it. `notify_repeat` (default 120 minutes, `0` = once)
  sends a row that still needs the user again, with how long it has waited.
  `stop_comments: on`: a skill that stops posts the ask on the FR issue through
  `fr.sh stop-comment` — the body in the issue's language, the other
  assignees, the attach command — and waits with `fr.sh decision --wait` for
  a comment `accept all`, `accept 1,3`, `fix 2` or `abort` from someone with
  write access (the fix loop's trust rule). The review gate triages first:
  findings that object to what the FR requires or excludes go into the review
  notes instead of stopping. From the first FR through the container: the ask
  sat in a session for an hour that nobody saw.
- The PR facts carry whether auto-merge is enabled (`autoMergeRequest`).

### Changed

- The hard rule *never merge a PR* reads *never merge a PR by own judgement*:
  with `auto_merge: auto` the ship session asks GitHub through `fr.sh merge`
  after the gate; no other command merges, approves or closes a PR, the
  autopilot never does.
- `ship` writes `shipping` at its start where it wrote `running`; profiles
  without a value for it write nothing there — map it like `running`.
- `init` proposes `project_phase_field` and `Phase/Status` values for a board
  with a phase column, and `.claude/workflow.local.md` for `.gitignore`.
- The autopilot skill says in so many words that a board queue never ends the
  loop: an empty queue is a wait, not an end — a sandbox run showed a session
  ending there, and every relaunch costs a session start.

## [0.7.1] — 2026-11-06

### Security

- The fix loop trusted PR comments by `authorAssociation` `OWNER`, `MEMBER` or
  `COLLABORATOR` — but `MEMBER` is any member of the organization and
  `COLLABORATOR` may have read access only, so on a public organization
  repository someone without write access could brief an autonomous fix
  session. `fr.sh pipeline` and `fix-brief` now ask GitHub's collaborator
  permission per login and take `admin` or `write` only; the repository's
  owner needs no lookup, anyone outside `MEMBER`/`COLLABORATOR` gets none, a
  permission that cannot be read is no permission (said on stderr), a looked-up
  one is kept for 15 minutes in the local state. Bots as before, listed in
  `fix_comment_bots` and in bot form only.

## [0.7.0] — 2026-11-06

### Added

- **Spec model**, opt-in with `spec_dir`: living specs per capability in
  OpenSpec's shape (`<spec_dir>/<capability>/spec.md`). An FR carries a flat
  **spec delta** instead of acceptance criteria — `## Spec delta`, `Specs:`,
  `### ADDED|MODIFIED|REMOVED|RENAMED <capability>: <requirement>`, scenarios
  with `- Evidence: unit test | eval | check on test` — in the issue before the
  start and in the FR doc after. `fr.sh validate` (a scenario with WHEN, THEN
  and evidence per ADDED/MODIFIED, sources exist, ADDED is new, `Base:`
  fingerprints still match, nothing outside the blocks), `fr.sh fingerprint`,
  `fr.sh fold` (ADDED appends, MODIFIED replaces, REMOVED deletes, RENAMED
  renames; a new capability gets a new file). `fr.sh spec` takes a valid delta
  as readiness and pins the `Base:` lines; `fr.sh overlap` keeps two FRs on one
  requirement apart. `new` writes deltas from `templates/fr-delta.md`, `ship`
  folds after the review gate as its own commit (`blocked spec` when the base
  moved) and checks the scenarios by their evidence, `implement` keeps
  `## Tasks` in the FR doc. Documents with acceptance criteria keep working.
- **`deploy_signal: deployment`:** `ship` takes the test URL from the GitHub
  Deployment of the PR's commit — the head, or the merge commit `pull_request`
  workflows build and deploy — whose environment matches `deploy_environment`
  (a glob; `{pr}` = the PR number). Its latest status is the signal: `success`
  with `environment_url`; `failure` or `error` is `blocked deploy`; `inactive`
  during the acceptance check means the slot was redeployed, the results are
  void. `fr.sh deployment <head sha> [--pr <N>]` reads the head's deployments
  and, with the PR number, those of GitHub's test merge commit
  (`refs/pull/N/merge`), both filtered by the API; `deploy_environment` is
  required — the newest deployment of a commit may be production. Read-only.
- `fr.sh pr-commit <sha> <head sha>`: whether a SHA is this PR's commit — the
  head, or a merge commit of it whose other parent is on the base branch — in
  code; the ship skill no longer spells the rule out for `pr-comment` and `url`.
  `deployment` and `pr-commit` read the main checkout's profile.
- **`acceptance_label`:** a PR label `ship` sets right before the acceptance
  check and removes after it, and before any stop — the project's deploy
  workflow leaves that PR's slot alone. `init` creates the label.
- **`notify_command`:** a command the autopilot runs for every FR that needs
  you — a session waiting at a prompt, a stopped gate, a stalled session, a PR
  waiting for your merge — with `FR_ID`, `FR_PHASE`, `FR_DETAIL`, `FR_SESSION`,
  `FR_REPO` and `FR_MESSAGE` in its environment. `pipeline --wait` runs it for
  rows new since its last result, `fr.sh notify` for the autopilot's summary.
  Claude Code itself notifies about a waiting background session only while
  `claude agents` is open; the docs say so.

### Fixed

- Text from GitHub or a spec delta — an issue title, a requirement name — reaches
  awk through the environment, never `-v`, which processes backslash escapes: a
  `\n` in a requirement name forged a second row in `fr.sh list`.
- `fr.sh pipeline --wait` / `--max` and `fr.sh deployment --pr` as the last
  argument say what is missing instead of failing silently.
- `fr.sh` without a known command prints the whole usage header again.
- `session_permission_mode` accepts `default`, `acceptEdits`, `auto` and
  `dontAsk` only — `bypassPermissions` from a committed profile is refused.

## [0.6.0] — 2026-11-04

### Added

- **`/fr-workflow:autopilot`:** drives queued FRs without a hand-off per step.
  It starts wave 1, opens the ship session once an implementation reports
  `implemented`, and after each merge starts the FRs that waited for it. Runs
  as the background session `fr-autopilot` (`--here`: in your session);
  `status`, `stop`, `rm`. Never merges, never answers a session's question.
- **Fix loop**, opt-in: `fix_loop: off | checks | checks+comments`,
  `fix_attempts` (default 2), `fix_skip_checks`, `fix_comment_bots`. A red
  local check or CI run, and with `checks+comments` a new PR comment by an
  author with write access or a listed bot, goes to a fresh implementation
  session (`/fr-workflow:implement <ID> fix`), then to a full new ship. Secrets,
  security findings, review findings under `stop` and failed acceptance criteria
  never enter it.
- `fr.sh pipeline` (phase and next action per queued FR, `--wait` until it
  changes), `fr.sh launch implement|fix|ship|autopilot`, `fr.sh queue`,
  `fr.sh fix-brief`.
- Event `implemented`, written by `:implement` at its hand-over.
- Profile: `autopilot_model` (`sonnet`), `autopilot_effort` (`medium`),
  `autopilot_sessions` (3), `session_permission_mode` (empty: your own default;
  `default`, `acceptEdits`, `auto` or `dontAsk`, never `bypassPermissions`) —
  passed to every launched session as `--permission-mode`; a background
  session inherits no environment and cannot answer a prompt.

### Changed

- `fr.sh project-status <issue> <event> [<gate>]`: every event is appended to
  the FR's local log in the git common dir first, whatever the board does.
  `:ship` passes the gate that stopped it (`failed ci`, `blocked conflict`, …).
- Hard rule: a skill still never fixes what its own gate found; the only fix
  loop is the autopilot's, opt-in and bounded.
- `:done` removes the FR from the autopilot's queue.
- Fix loop, after review: a listed bot matches only in its bot form
  (`app/<name>`, `<name>[bot]`), never a plain login; the FR's PR is taken from
  this repository only, a fork's PR with the same branch name is ignored — in
  `ship` too; `pipeline`, `launch` and `fix-brief` read the main checkout's
  profile wherever they run.
- `start` and `done` pass `setup` / `teardown` as the gate of a failed
  worktree hook (`blocked setup`, `blocked teardown`).
- `fr.sh pipeline` reads what a launched session is doing from
  `claude agents --json`: busy → `implementing` / `shipping`, `waiting` at a
  prompt → reported with `claude attach <id>`, idle without a result →
  `stalled`; after `approval` the PR decides, however long the ship session's
  process lingers. The worktree lock counts for another pid's session and
  decides alone when `claude agents` says nothing (first sandbox run of 0.6: a
  finished ship session kept its FR in `shipping`). `pipeline --wait 0` returns
  at once and records the result.
- `fr.sh launch autopilot` refuses while the recorded autopilot runs (exit 3)
  or `claude agents` cannot tell (exit 1), stops one whose loop ended, starts
  the new one with nothing seen, and prints
  its session id — `claude logs <id>`; the name `fr-autopilot` is ambiguous
  once a second one ran.

## [0.5.4] — 2026-11-04

### Added

- **Worktree hooks:** `worktree_setup` and `worktree_teardown` in the profile —
  one command each, for projects that need more than the checkout in every FR
  worktree (a dev stack per worktree so FRs are tested in parallel, dependencies,
  an `.env`). `start` runs the setup after it created or resumed a worktree,
  `done` the teardown before anything removes one, `claude rm` included.
  `fr.sh hook setup|teardown <ID> <path>` runs them in the worktree, without
  stdin, with `FR_ID`, `FR_NUMBER`, `FR_BRANCH` and `FR_WORKTREE`; exit 6 = the
  hook failed — the worktree stays, the FR is `blocked`, the user decides. The
  setup's last lines go into `start`'s hand-over. The command is read from the
  main checkout's profile, never from an FR branch's copy. Empty keys = nothing,
  as before.
- `fr.sh check` shows the hooks when the profile has them.

### Changed

- `done` tears the worktree down before `claude rm`, which deletes a finished
  session's worktree too; a stack still running on a removed worktree would keep
  its ports and volumes.
- Ignored files (`.gitignore`) are never a question in `ship` and never block
  `git worktree remove`; `init` proposes `.gitignore` entries for what the hooks
  generate, and `.claude/` for `.dockerignore`.
- `blocked` is also written by `start` and `done`, for a worktree hook that
  failed; `done` then stops before it writes `done`.
- A double-quoted value in the profile frontmatter may contain ` #` — the
  comment starts after the closing quote. Before, the value was cut there.

## [0.5.3] — 2026-10-29

### Added

- **`ship_model` / `ship_effort`** (default `opus` / `high`): the ship
  session's model and effort. `implement` ends with the command for it — a
  fresh session of the same worktree — and `start` lists it per FR: the gates
  and the acceptance check are that session's judgement, so a sonnet/low
  implementation session no longer judges its own code. `/fr-workflow:ship` in
  the implementation session still works.

### Changed

- The review agents `silent-failure-hunter` and `type-design-analyzer` run on
  `opus` instead of inheriting the session's model.
- Docs: the pin is raised from the command line, no session needed —
  `claude plugin marketplace remove claude-fr-workflow --scope user`,
  `claude plugin marketplace add 'bmoers/claude-fr-workflow#<tag>'`,
  `claude plugin install … -s project` in the repository. `remove` without
  `--scope`, run inside a repository, also strips the plugin entries from its
  `.claude/settings.json`.

## [0.5.2] — 2026-10-29

### Added

- **`/fr-workflow:implement`:** the implementation session's own command — in
  the worktree `start` prepared, it finds the FR from the branch, reads the FR
  doc and the profile, implements, commits locally and never pushes; writes
  *input* / *running* on the board when it has to ask.

### Changed

- **`start` hands over two short things** for one FR — the `claude -w …`
  command without a prompt, and `/fr-workflow:implement` as the first message.
  The one-line command with the prompt wrapped when copied from a terminal and
  started the session without its brief. Background sessions for several FRs
  keep the prompt (nothing is copied there).
- Docs: raising the pin on a machine that already has the marketplace needs
  `claude plugin marketplace remove`, a session, and
  `claude plugin install … -s project`; never a user-scope install.

## [0.5.1] — 2026-10-29

First full end-to-end run of 0.5 in the sandbox, with the board: every event
showed the expected status; the fixes below are what the run and its review
asked for.

### Added

- **`fr.sh project-options`:** adds the values of `project_status` that the
  board's status column lacks, keeping existing options with id, colour and
  text; `init` offers it and names the *Workflows* page for what has no API.

### Changed

- **Language of what goes to GitHub:** FR issues, comments and PR descriptions
  are written in the language of their source — the idea, the draft file, the
  request — never switched to English. Headings and Planning keys stay English.

## [0.5.0] — 2026-10-29

**Breaking:** the issue is the spec until the start. FR docs written by earlier
versions keep working once started; FRs planned with 0.4 but not started have no
FR issue — define them again with `/fr-workflow:new`.

### Changed

- **`/fr-workflow:new` defines FRs as GitHub issues** (label `fr`) that hold the
  full spec — from an idea (local first) or from requests filed on GitHub
  (GitHub first), worked out with the code. A request that is one change
  becomes the FR itself (its original text kept at the end), one that needs
  several gets a sub-issue per FR; an FR serving several requests lists them
  under *Requests*. `new` writes only to GitHub — no branch, no push — and adds
  the FR issues to the GitHub project named by the new profile key `project`.
  Authors of rewritten or split requests get a short note.
- **The FR id is the issue number:** issue #47 is `FR-47`, its branch
  `feat/fr-47-…`. No more id allocation or renumbering.
- **`/fr-workflow:start` pulls the FR issue:** it refuses one that is not ready
  (no acceptance criteria, open questions), shows what changed in the FR's areas
  since the commit the spec was based on, then creates the branch with the FR
  doc as its first commit (`fr.sh spec`), the worktree and the session. From
  then on the FR doc is the source.
- **PRs say `Closes` for the FR's own issue** and `Refs` for its requests; `done`
  closes the FR issue if the merge did not, and a request once all its FRs are
  closed — after confirmation, as before. Dropping an FR closes its issue as
  *not planned*, or sends a rewritten request back to `fr-request`.
- `fr.sh list` and `overlap` include FRs not started yet, from their issue's
  *Planning*; `fr.sh issue-frs` reads the FRs of a request from GitHub
  (sub-issues and mentions); `status` also lists the requests still to define.
- FR doc frontmatter: `issue`, `requests`, `based_on`, `started` instead of
  `issues`, `created`.

### Removed

- `/fr-workflow:idea` — `/fr-workflow:new` with an idea does it.
- `/fr-workflow:sync`, `fr.sh sync`, `sync-fr`, `next-id` and the backlink
  comments on issues: GitHub's sub-issues and mentions show the link.
- Profile keys `backlinks` and `id_digits`.

### Added

- **Review agents in `ship`:** the plugin brings `silent-failure-hunter`
  (swallowed errors, broad catches, fallbacks that hide problems) and
  `type-design-analyzer` (invariants and encapsulation of new or reshaped
  types), adapted from Anthropic's `pr-review-toolkit` (Apache-2.0): scoped to
  the FR's range and its FR doc, the project's own conventions instead of those
  of Anthropic's codebase, read-only. `ship` runs those in the new profile key
  `review_agents` beside `/code-review` and `/security-review`, and again after
  every fix; their findings follow `review_gate`. `review_agents` defaults to
  `[silent-failure-hunter]`, also in older profiles — expect more findings under
  `review_gate: stop`; `review_agents: []` turns it off
  ([profile](docs/profile.md#review-agents)). `init` proposes
  `type-design-analyzer` for typed codebases.
- **Failure behaviour in the FR spec:** `new` settles what happens when something
  fails, into a new section — the spec the silent-failure review checks against.
  Invariants of new or reshaped data types go into *Technical notes*.
- `init` creates the labels `fr-request` and `fr` (after asking) and proposes a
  GitHub project.
- **Board status from the commands:** with `project_status` in the profile
  (`defined=Ready, running=In progress, …`) `new`, `start`, `ship` and `done`
  set the project's status column at every start and stop —
  `fr.sh project-status <issue> <event>`, best effort: a board that cannot be
  written is a line in the report, never a stop. Without the key GitHub's
  workflows move the cards, as before
  ([profile](docs/profile.md#board-status)).

### Fixed

- `fr.sh`: a branch without merge base ended the branch loop of `list`, hiding
  every FR branch sorted after it.

### Upgrade notes

- Create the label `fr` in the issue repository
  (`gh label create fr -R <repo>`), or run `/fr-workflow:init` again.
- Remove `backlinks` and `id_digits` from the profile; add `project` if the FR
  issues should go into a GitHub project, and `project_status` if its status
  column should follow the FRs (`gh auth refresh -s project` and `gh` 2.97 or
  newer on every machine that runs the commands).
- Old backlink comments on issues are no longer updated; delete them if they
  confuse.

## [0.4.0] — 2026-10-26

### Added

- **One standard shape for issues:** an issue form
  (`templates/issue-form.yml` → `.github/ISSUE_TEMPLATE/feature-request.yml`,
  label `fr-request`) with problem, who, desired behaviour, how we know it is
  done, priority, **size**, and optional model and effort. `init` installs it
  (alongside existing templates, translated on request) and offers the label.
- **`/fr-workflow:idea`:** talks an idea through along the form's fields, creates
  the issue in the same shape after confirmation, and goes straight on to
  planning.
- **Model and effort from the issue,** each decided separately: explicit values
  in the issue are binding; else the issue's size through the new profile key
  `size_models`; else `impl_model` / `impl_effort`. A size-derived value is an
  estimate — `new` may propose another per FR, with the reason in its table.
- `new` maps form issues field by field into the FR doc.

## [0.3.1] — 2026-10-26

Findings of the first full end-to-end run in the sandbox (new → start in
parallel → status → ship → merge → done).

### Fixed

- `ship`: a review's report could end the run — seen after `/security-review` in
  a headless run, which then stopped before the push. The skill now states that
  both reviews are inputs and the run continues up to step 7.
- `done`: `claude rm` removes a finished background session together with its
  worktree and lock; the local branch is deleted before the remote one, so
  `git branch -d` works after a squash merge.

### Added

- `tests/fr-sh.sh`: the regression suite for `fr.sh` (33 cases, throwaway repos,
  stub `gh`), now part of the release checklist.

### Docs

- Raising the pinned `ref` takes effect with a **new session**;
  `/plugin marketplace update` alone keeps following the old `ref`.
- Headless runs (`claude -p`, CI) do not load the plugin from project settings —
  use `--plugin-dir` with the marketplace copy.
- `claude logs` is the raw terminal capture; `claude attach` is easier to read.

## [0.3.0] — 2026-10-25

### Added

- `ship` runs the built-in `/security-review` alongside `/code-review`. Security
  findings follow the new profile key `security_gate` (default `stop`),
  independent of `review_gate`. Accepted security findings go into the PR body
  under *Review notes* with the user's reason.
- `init` picks up security tooling the repository already uses (dependency audit,
  secret scanning) into *Local checks before commit*, scoped to the FR's changes.
- `fr.sh lock break` for a lock left without owner.

### Changed

- **Implementation sessions commit but no longer push.** `ship` commits locally,
  runs both reviews on `origin/<base>...HEAD` — side by side, again after every
  fix — and only then pushes. Before, `/code-review` without a target saw only
  what was ahead of the upstream, which could be nothing.
- **Secrets always stop** in `ship`, cannot be accepted, and are removed from the
  unpushed commits; a credential pushed earlier must be rotated.
- `security_gate: report` puts every security finding into *Review notes*; a
  reused PR gets its body updated; public repositories get no finding details.
- `ship` takes the shared-environment lock before the first push *or* PR creation,
  reuses only an **open** PR, accepts the test merge commit as "this PR's commit"
  for `url` and `pr-comment`, paginates and matches SHAs in deploy comments, and no
  longer waits forever after step 6 when `paths-ignore` skips the deployment.
- `start` keeps main-worktree paths with spaces, strips quotes from the session
  name, and fast-forwards a stale local branch.
- `new` uses `--limit 200`, ASCII slugs, and re-checks the id right before pushing.
- `done … drop` also covers FRs that exist only on the base branch.

### Fixed

- `fr.sh`: FR docs with non-ASCII file names were invisible (git path quoting) and
  their id was handed out again; issue refs were compared case-sensitively;
  `check` passed without `origin`; owners starting with a digit were mangled;
  docs renamed on their branch were dropped; branch names like `i18n/fr-2024`
  moved `next-id`; two branches with the same id went unnoticed; parallel syncs
  could leave a second, stale backlink comment; globs in `areas` and unpushed
  local commits were ignored by `overlap`.
- `fr.sh`: one rule decides what an FR branch is (from `branch_pattern`), so
  `i18n/fr-2024-cleanup` neither moves `next-id` nor counts as an FR branch; a
  local branch ahead of origin is read instead of origin's; an FR doc edited on
  another branch (e.g. main) no longer masks its FR branch; a rename on the base
  branch is not reported as a duplicate id; `areas: [.]` and `{…}` globs count
  as overlap; a branch without merge base no longer aborts `overlap`; a failed
  duplicate-comment delete no longer aborts `sync`; the lock is only called stale
  after a failed `mkdir` and a short wait, and `lock break` reports failure.
- `ship`: secret removal runs in a safe order — check for unpushed merges and
  foreign pushes first, commit the removal, then squash onto `origin/<branch>` or
  the merge base, then verify; a merge commit only counts as "this PR's" when
  its other parent is on the base branch.

### Upgrade notes

- Profiles written before 0.3.0 have no `security_gate`; the default `stop`
  applies. Add `security_gate: stop` (or `report`) to make it explicit.
- Implementation sessions no longer push. Teammates see an FR's code on GitHub
  only after `ship`.

## [0.2.0] — 2026-10-25

### Added

- **Parallel work.** FRs record their `areas` at planning time. `fr.sh overlap`
  compares areas and the files each branch already changed (plus the profile's
  `shared_paths`) and groups FRs into waves. `start` with several FRs starts one
  background session per FR of wave 1 (`claude -w … --bg`); `status` shows each
  FR's session next to it. Follow them with `claude agents`, `claude logs`,
  `claude attach`.
- **Model and effort per FR.** `new` proposes `model` / `effort` per FR
  (frontmatter), defaults from the profile's `impl_model` / `impl_effort`. `start`
  hands over `claude -w <worktree> --model … --effort … -n "<ID> <title>"`; the
  session first checks it is on the FR branch.
- **Parallel-safe ship.** A PR that conflicts after other merges gets
  `origin/<base>` merged in (never rebased). With `test_env: shared`, `fr.sh lock`
  lets one FR at a time from its deploying push to its recorded acceptance
  check; with `deploy_signal: url` the deployed commit is checked before and after.
- `done` handles Claude Code's worktree lock: stale locks are removed, a live
  session stops the cleanup.
- `sync` command and `fr.sh sync-fr <ID>…|--all`: refreshes every issue an FR
  references now or referenced earlier (read from git history), so an issue taken
  out of `issues:` loses its entry. All commands now sync through it; an FR
  without issues is a no-op.
- `done <ID> drop`: drops an FR with a reason, updates its issues, keeps the
  branch as the record. Issues whose FRs were all dropped are offered for
  re-planning or closing as not planned, never closed as done.
- `new` accepts a local file (notes, requirements, an FR draft) as its source.
- `init` finds workflows that build on every push and proposes `paths-ignore` for
  the FR folder on the push trigger, as a diff.

### Changed

- Hard rule: never write CI skip markers (`[skip ci]` and the like) into commits,
  PR titles or bodies — a squash merge copies them onto the base branch and skips
  its release and deployment.
- `init` says explicitly that its changes must reach the base branch before the
  first `new`.
- Docs: where `new` commits (a new branch off `origin/<base>`, never the current
  branch), which pushes build, dropping and syncing.

## [0.1.1] — 2026-10-25

### Fixed

- `ship` without a test environment (`deploy_signal: none`) or browser now
  checks locally and lets the user accept unverified criteria. Before, it never
  reached `in-review`, so `done` could not see the FR as merged.

## [0.1.0] — 2026-10-25

### Added

- Skills `init`, `new`, `start`, `ship`, `done`, `status`.
- `scripts/fr.sh`: FR overview across base branch, FR branches and local edits;
  next free id; FRs per issue; idempotent backlink comment on GitHub issues.
- m:n model between GitHub issues and FR docs; `jira:` refs reserved.
- Bundled Playwright MCP server for the acceptance check.
- Templates for the FR doc, the project profile and the FR folder README.
