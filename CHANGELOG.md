# Changelog

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

### Fixed

- `fr.sh`: a branch without merge base ended the branch loop of `list`, hiding
  every FR branch sorted after it.

### Upgrade notes

- Create the label `fr` in the issue repository
  (`gh label create fr -R <repo>`), or run `/fr-workflow:init` again.
- Remove `backlinks` and `id_digits` from the profile; add `project` if the FR
  issues should go into a GitHub project (`gh auth refresh -s project` on every
  machine that runs `new`).
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
