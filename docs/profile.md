# Project profile reference

Every repository describes itself in `.claude/workflow.md`. The plugin contains
the process; the profile contains the facts. `/fr-workflow:init` writes a first
version — this page explains every part of it.

The file has two parts:

- **Frontmatter** between the `---` lines: settings, one `key: value` per line.
  Text after ` #` is a comment. Quotes are optional; a value that contains ` #`
  itself goes in double quotes, the comment then starts after the closing quote.
- **Prose sections** below: facts Claude reads before it acts — conventions,
  checks, the test environment, extra rules.

No secrets in either part: name accounts and access methods, never passwords or
tokens.

## Settings

| Key                       | Default                                                       | Meaning                                                                                                                                                                                                                                                                                                                                                         |
| ------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `base_branch`             | `main`                                                        | branch that FR branches start from and PRs go into                                                                                                                                                                                                                                                                                                              |
| `fr_dir`                  | `req/feature-requests`                                        | folder of the FR documents                                                                                                                                                                                                                                                                                                                                      |
| `fr_prefix`               | `FR`                                                          | id prefix: issue #47 is `FR-47`                                                                                                                                                                                                                                                                                                                                 |
| `branch_pattern`          | `{type}/{id-lower}-{slug}`                                    | FR branch names, e.g. `feat/fr-47-coupon-field`. Placeholders: `{type}` (`feat`, `fix`, …), `{id-lower}` (`fr-47`), `{slug}` (short title). Must contain `{id-lower}`                                                                                                                                                                                           |
| `issue_repo`              | this repository                                               | `owner/repo` where requests and FR issues live, if not here. Whoever reads them reads the FR specs                                                                                                                                                                                                                                                              |
| `project`                 | —                                                             | title of a GitHub project: `new` adds every FR issue to it. Needs the `project` scope on the `gh` token (`gh auth refresh -s project`)                                                                                                                                                                                                                          |
| `project_status_field`    | `Status`                                                      | the project's single-select status column that `project_status` writes                                                                                                                                                                                                                                                                                          |
| `project_status`          | —                                                             | `event=value` pairs, comma-separated: the column value each plugin event sets — `defined`, `running`, `input`, `implemented`, `failed`, `blocked`, `approval`, `done`; events left out write nothing. Empty = the project's own workflows move the cards. See [board status](#board-status)                                                                     |
| `notify_issues`           | `ask`                                                         | "ready for acceptance" comment on the FR issue and its requests after a successful ship: `never`, `ask`, `always`. With the autopilot `never` or `always` — a launched session cannot ask                                                                                                                                                                       |
| `review_gate`             | `stop`                                                        | code review findings `stop` the ship, or are only collected for the `report`                                                                                                                                                                                                                                                                                    |
| `security_gate`           | `stop`                                                        | the same for security review findings — set separately, so style findings can be `report` while security findings still stop. **Secrets always stop**, whatever this says. Missing in an older profile → `stop`                                                                                                                                                 |
| `review_agents`           | `[silent-failure-hunter]`                                     | reviewer agents the ship runs beside `/code-review`; their findings follow `review_gate`. `silent-failure-hunter` finds swallowed errors and hidden fallbacks; `type-design-analyzer` reviews the invariants of new or reshaped types — worth it for typed code with its own domain types. `[]` = none. Missing in an older profile → `[silent-failure-hunter]` |
| `deploy_signal`           | `none`                                                        | how ship knows the PR is on the test environment — see below                                                                                                                                                                                                                                                                                                    |
| `deploy_comment_marker`   | —                                                             | for `pr-comment`: text that identifies the deploy comment                                                                                                                                                                                                                                                                                                       |
| `deploy_success_marker`   | —                                                             | for `pr-comment`: text in that comment that means success                                                                                                                                                                                                                                                                                                       |
| `deploy_version_url`      | —                                                             | for `url`: address that returns the deployed commit                                                                                                                                                                                                                                                                                                             |
| `deploy_timeout_min`      | `30`                                                          | how long ship waits for the deployment                                                                                                                                                                                                                                                                                                                          |
| `test_env_url`            | —                                                             | base URL of the test environment; `{pr}` becomes the PR number                                                                                                                                                                                                                                                                                                  |
| `test_env`                | `shared`                                                      | `per-pr` = every PR has its own preview, acceptance checks run in parallel; `shared` = one deployment at a time, acceptance checks run one after the other                                                                                                                                                                                                      |
| `acceptance_browser`      | `playwright`                                                  | `none` = no browser checks; criteria are checked locally                                                                                                                                                                                                                                                                                                        |
| `impl_model`              | `opus`                                                        | default model of implementation sessions; an FR can set its own *Model*                                                                                                                                                                                                                                                                                         |
| `impl_effort`             | `high`                                                        | default effort: `low`, `medium`, `high`, `xhigh`, `max`; an FR can set its own *Effort*                                                                                                                                                                                                                                                                         |
| `size_models`             | `"S=sonnet/low, M=sonnet/medium, L=opus/high, XL=opus/xhigh"` | how the issue form's *Size* becomes model and effort. "Don't know" → `impl_model` / `impl_effort`. Explicit model/effort in the issue win over the size                                                                                                                                                                                                         |
| `ship_model`              | `opus`                                                        | model of the ship session: its gates and the acceptance check are that session's judgement — see [usage](usage.md#step-2--build-fr-workflowstart-20). The review agents run on `opus` regardless                                                                                                                                                                |
| `ship_effort`             | `high`                                                        | effort of the ship session: `low`, `medium`, `high`, `xhigh`, `max`                                                                                                                                                                                                                                                                                             |
| `shared_paths`            | `[]`                                                          | paths many FRs touch, e.g. `[package-lock.json, db/migrations]`. Two FRs that both change something under one of them never run in parallel                                                                                                                                                                                                                     |
| `worktree_setup`          | —                                                             | command `start` runs in an FR worktree it created or resumed — a dev stack per worktree, dependencies, an `.env`. Idempotent, non-interactive; `FR_ID`, `FR_NUMBER`, `FR_BRANCH`, `FR_WORKTREE` in its environment. Empty = nothing. See [worktree hooks](#worktree-hooks)                                                                                      |
| `worktree_teardown`       | —                                                             | command `done` runs before anything removes the worktree, e.g. the stack's `down`. Empty = nothing                                                                                                                                                                                                                                                              |
| `autopilot_model`         | `sonnet`                                                      | model of the autopilot session. It starts sessions and reads results; the judgement stays with the ship session                                                                                                                                                                                                                                                 |
| `autopilot_effort`        | `medium`                                                      | effort of the autopilot session                                                                                                                                                                                                                                                                                                                                 |
| `autopilot_sessions`      | `3`                                                           | FR sessions (implementation, fix, ship) the autopilot runs at a time; further starts wait                                                                                                                                                                                                                                                                       |
| `session_permission_mode` | —                                                             | permission mode of the sessions `launch` starts — the autopilot's, implementation, fix and ship sessions — passed as `--permission-mode`; empty = your own default. A background session cannot answer a prompt: `auto` lets it work unattended within Claude Code's auto mode                                                                                  |
| `fix_loop`                | `off`                                                         | what the autopilot sends back to a fresh implementation session instead of reporting it: `checks` = the local checks and red CI; `checks+comments` = also new PR comments by trusted authors. See [fix loop](#fix-loop)                                                                                                                                         |
| `fix_attempts`            | `2`                                                           | fix sessions per FR; then the FR is reported                                                                                                                                                                                                                                                                                                                    |
| `fix_skip_checks`         | `[]`                                                          | check names that always stop, never go to the fix loop — security scanners above all, e.g. `[CodeQL, gitleaks]`                                                                                                                                                                                                                                                 |
| `fix_comment_bots`        | `[]`                                                          | bots whose PR comments count as trusted for `checks+comments`, e.g. your review workflow's `[claude[bot]]`. People count when they have write access; a bot only in its bot form, `app/<name>` or `<name>[bot]`                                                                                                                                                 |

## Choosing `deploy_signal`

The question is: *how can you tell that the test environment runs this PR?*

| Value        | Use it when                                                                   | Example                                                                                                                                                       |
| ------------ | ----------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pr-checks`  | the deployment is itself a check on the PR                                    | Netlify deploy previews: `test_env_url: https://deploy-preview-{pr}--shop.netlify.app`                                                                        |
| `pr-comment` | a separate workflow posts or updates a comment on the PR when it has deployed | a workflow comments "Deployed to staging (pr-91) — Status: success": `deploy_comment_marker: Deployed to staging`, `deploy_success_marker: "Status: success"` |
| `url`        | the test environment reports which commit it runs                             | `deploy_version_url: https://staging.shop.example/version` returns `{"commit":"3f2a9c1…"}`                                                                    |
| `none`       | there is no test environment per PR                                           | ship ends the automatic part after CI and checks the criteria locally                                                                                         |

`url` is the most reliable signal: it proves the exact commit is running. With
`pr-comment`, ship only trusts a comment that was written or updated after CI
finished, because such comments are usually edited in place and an old "success"
must not count.

If the preview URL cannot be built from the PR number (for example, it contains a
hash), leave `test_env_url` empty and describe in *Test environment* where to find
it — Claude reads it there.

## Review agents

Besides `/code-review` and `/security-review`, ship runs the agents listed in
`review_agents`. They come with the plugin — no other plugin needs to be
installed.

| Agent                   | Finds                                                                                                                             |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| `silent-failure-hunter` | errors that disappear: empty or broad catch blocks, failures only logged, fallbacks the FR's *Failure behaviour* does not ask for |
| `type-design-analyzer`  | new or reshaped types whose invariants can be broken from outside or hold only by convention — for typed code                     |

Their findings follow `review_gate`, like those of `/code-review`. Without the key
in the profile, ship runs `silent-failure-hunter`.

**Turn them off** — all of them:

```yaml
review_agents: []
```

Or keep only some: `review_agents: [type-design-analyzer]`.

## Board status

A GitHub project knows when an item was added and when it was closed. What a
Claude session is doing — running, waiting for you, blocked, failed — only the
commands know. With `project_status` they write it into the board's status
column at every start and stop:

```yaml
project: Shop roadmap
project_status_field: Status
project_status: "defined=Ready, running=Running, input=Waiting for Input, failed=Failed, blocked=Blocked, approval=Waiting for Approval, done=Complete"
```

| Event      | Set when                                                                                                                           |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `defined`  | `new` wrote the FR issue and nothing is open                                                                                       |
| `input`    | a command stops with a question for you: open questions, unclear changes, unverified criteria, a login wall                        |
| `running`  | `start` created branch, worktree and session; `ship` starts or starts again                                                        |
| `failed`   | a gate found a defect: review or security findings, a secret, red CI, a failed acceptance criterion                                |
| `blocked`  | something outside the change: a worktree hook that failed, the shared-environment lock, a missing deployment, a conflict to decide |
| `approval` | `ship` finished — the PR waits for your merge                                                                                      |
| `done`     | `done` closed it, merged or dropped                                                                                                |

The values are the board's own option names — map only the events you have a
value for. Values the column does not have yet: `fr.sh project-options` (from
the repository, with the profile in place) adds them, grey, and keeps every
existing option with its id, colour and text; `init` offers it. The project's
workflows have no API — set them on its *Workflows* page: *Item added to
project* → your `defined` value, or a column for requests such as *Backlog*
when they are on the board too (`fr.sh project-options Backlog` adds it; FR
issues leave it as soon as `new` writes the `defined` value), *Item closed* →
your `done` value, *Auto-add to project* with `is:issue label:fr` — or
`is:issue label:fr,fr-request` to add requests as well. Writing the board is best effort: a `gh` older than 2.97, a missing
`project` scope (`gh auth refresh -s project`), a title that does not match
(`gh project list --owner <owner>`; case does not matter) or an unknown value
is reported by the command and never stops it. The project must belong to the
owner of the issue repository — the organisation or user — like
`gh issue create --project`. Keep GitHub's *Item closed* workflow on as the
safety net for issues closed by hand.

## Worktree hooks

Every FR gets its own worktree under `.claude/worktrees/`. A project that needs
more than the checkout there — a dev stack per worktree so FRs are tested in
parallel, installed dependencies, an `.env` with this worktree's ports — names
one command for each end of the worktree's life:

```yaml
worktree_setup: scripts/stack.sh up        # derives project name and ports from FR_NUMBER
worktree_teardown: scripts/stack.sh down
```

| Hook                | Runs                                                                                          |
| ------------------- | --------------------------------------------------------------------------------------------- |
| `worktree_setup`    | in `start`, after the worktree was created or resumed, before the session is handed over      |
| `worktree_teardown` | in `done`, before anything removes the worktree — `git worktree remove` and `claude rm` alike |

The contract, on both sides:

- The command runs **in the worktree**, through `bash -c`, without stdin, with
  `FR_ID` (`FR-47`), `FR_NUMBER` (`47`), `FR_BRANCH` and `FR_WORKTREE` (absolute
  path) in its environment. It is read from the main checkout's profile — the
  one on your base branch, reviewed like any change — never from the copy on
  the FR branch. Everything it prints is shown; `start` repeats its
  last lines in the hand-over, so print what the session needs — the stack's URL,
  its ports.
- **Idempotent.** Setup runs on every `start` of the FR, a resume included (after
  a reboot the stack is gone, the worktree is not); a stack that is up stays up.
- **A failed hook stops that FR, nothing else.** Non-zero exit → the output is
  shown, the worktree stays, the FR is `blocked` on the board, the user decides.
  No retry, no `--force`, no session for that FR. `/fr-workflow:start <ID>`
  runs the setup again; `done` runs the teardown again.
- **Ignored files are invisible.** What the hooks generate in the worktree —
  compose overrides, `.env` files, data directories — goes into `.gitignore`:
  ignored files are never a question in `ship` and do not stop
  `git worktree remove`. Generated files that are not ignored do stop it; the
  teardown removes them.
- The plugin knows nothing about Docker or anything else the hooks do. A hook
  runs only at the root of an FR worktree of this clone — never in the main
  checkout, never for the temporary `_drop-` worktrees of `done … drop`; is the
  worktree already gone, `done` reports the command for you to run by hand. Text
  after ` #` in the value is a comment, like everywhere in the frontmatter;
  quote the command when it contains ` #` itself.
- Worktrees live inside the repository. `.claude/` belongs in `.dockerignore` —
  a `COPY . .` would copy every worktree into the image — and in the ignore list
  of file watchers that watch the whole repository.

## Two copies of the profile

Each FR branch carries its own `.claude/workflow.md` from the commit it started
on. The skills that run in an FR worktree — `implement` and `ship` — read that
copy; `fr.sh hook`, `pipeline`, `launch` and `fix-brief` read the main
checkout's, the base branch's. A change on the base branch reaches an FR's
sessions once its branch has it: merge the base branch into the FR branch, or
change the profile before the FR starts.

## Fix loop

Without `fix_loop`, every stopped gate waits for you — the autopilot reports it.
With it, the autopilot starts a fresh implementation session for a red check or a
trusted review comment, and a new ship session then runs every gate again.

| Setting           | Pick it when                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `off`             | client repositories until the sandbox showed what the loop does; any project where you want every red build in your hands |
| `checks`          | lint, type and test failures are routine and cheap to fix                                                                 |
| `checks+comments` | a review bot or teammates comment on PRs, and you want those addressed before you look                                    |

Never in the loop, whatever the setting: secrets, security findings, review
findings under `stop`, failed acceptance criteria, deployments, merge conflicts
that need a decision, and the checks in `fix_skip_checks`. Comments by anyone
without write access are ignored — on a public repository, that is everyone
outside the team.

## Prose sections

| Section                         | What to write                                                                                                                                                                                                                                                                                                                                                                                                                               |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Commit and PR conventions**   | e.g. "Conventional Commits, enforced by commitlint. The PR title becomes the squash-merge title and is linted. The FR id goes into the subject: `feat(checkout): coupon field (FR-47)`."                                                                                                                                                                                                                                                    |
| **Local checks before commit**  | the fast commands: `npm run typecheck`, `npm run lint`, `npm test` — and security tools the project already uses, **scoped to the FR's changes**: `gitleaks detect --log-opts="origin/main..HEAD"`, or `git diff --quiet origin/main...HEAD -- package-lock.json \|\| npm audit --audit-level=high` (audit only when the lockfile changed). A full audit belongs in CI — unscoped, a new advisory anywhere in the tree would block every FR |
| **CI**                          | which PR checks matter, how long they usually take; whether the first push of an FR branch, which changes only its FR document, starts builds, and how that is handled (e.g. `paths-ignore` on the push trigger)                                                                                                                                                                                                                            |
| **Test environment**            | how a PR gets there, the URL, how to get in (SSO, Cloudflare Access, basic auth), test accounts by name or role, which data may be used                                                                                                                                                                                                                                                                                                     |
| **Deploy verification**         | optional read-only commands that prove what runs, e.g. `kubectl -n staging get deploy -o wide`                                                                                                                                                                                                                                                                                                                                              |
| **Hard rules for this project** | what must never happen here. Point to `CLAUDE.md` sections instead of copying them                                                                                                                                                                                                                                                                                                                                                          |

## Example

```markdown
---
base_branch: main
fr_dir: docs/fr
fr_prefix: FR
branch_pattern: "{type}/{id-lower}-{slug}"
issue_repo: acme/shop-requests
project: Shop roadmap
project_status: "defined=Todo, running=In Progress, approval=In Review, done=Done"
notify_issues: always
review_gate: report
security_gate: stop
review_agents: [silent-failure-hunter, type-design-analyzer]
deploy_signal: url
deploy_version_url: https://staging.shop.example/version
deploy_timeout_min: 20
test_env_url: https://staging.shop.example
test_env: shared
acceptance_browser: playwright
impl_model: opus
impl_effort: high
ship_model: opus
ship_effort: high
shared_paths: [package-lock.json, db/migrations, src/i18n]
---

# Workflow profile

## Commit and PR conventions
Conventional Commits (commitlint). PR title = squash title; FR id in the subject.

## Local checks before commit
`npm run typecheck && npm run lint && npm test -- --run`

## CI
`build` and `test` must pass; about 6 minutes.

## Test environment
Every PR deploys to staging (one at a time — the newest PR wins). Login via
company SSO; test customer "Test Shopper (EUR)". Only test data; never copy
production data.

## Deploy verification
`curl -s https://staging.shop.example/version`

## Hard rules for this project
See CLAUDE.md "Production". No database migrations against staging without asking.
```
