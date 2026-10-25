# Changelog

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
