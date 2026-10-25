# Changelog

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
