# Changelog

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
