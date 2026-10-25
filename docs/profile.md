# Project profile reference

Every repository describes itself in `.claude/workflow.md`. The plugin contains
the process; the profile contains the facts. `/fr-workflow:init` writes a first
version — this page explains every part of it.

The file has two parts:

- **Frontmatter** between the `---` lines: settings, one `key: value` per line.
  Text after ` #` is a comment. Quotes are optional.
- **Prose sections** below: facts Claude reads before it acts — conventions,
  checks, the test environment, extra rules.

No secrets in either part: name accounts and access methods, never passwords or
tokens.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `base_branch` | `main` | branch that FR branches start from and PRs go into |
| `fr_dir` | `req/feature-requests` | folder of the FR documents |
| `fr_prefix` | `FR` | id prefix: `FR-012` |
| `id_digits` | `3` | digits of the number: `FR-012` |
| `branch_pattern` | `{type}/{id-lower}-{slug}` | FR branch names, e.g. `feat/fr-012-coupon-field`. Placeholders: `{type}` (`feat`, `fix`, …), `{id-lower}` (`fr-012`), `{slug}` (short title). Must contain `{id-lower}` |
| `issue_repo` | this repository | `owner/repo` where the issues live, if not here |
| `backlinks` | `on` | `off` = no generated comment on issues |
| `notify_issues` | `ask` | "ready for acceptance" comment after a successful ship: `never`, `ask`, `always` |
| `review_gate` | `stop` | review findings `stop` the ship, or are only collected for the `report` |
| `deploy_signal` | `none` | how ship knows the PR is on the test environment — see below |
| `deploy_comment_marker` | — | for `pr-comment`: text that identifies the deploy comment |
| `deploy_success_marker` | — | for `pr-comment`: text in that comment that means success |
| `deploy_version_url` | — | for `url`: address that returns the deployed commit |
| `deploy_timeout_min` | `30` | how long ship waits for the deployment |
| `test_env_url` | — | base URL of the test environment; `{pr}` becomes the PR number |
| `acceptance_browser` | `playwright` | `none` = no browser checks; criteria are checked locally |

## Choosing `deploy_signal`

The question is: *how can you tell that the test environment runs this PR?*

| Value | Use it when | Example |
|---|---|---|
| `pr-checks` | the deployment is itself a check on the PR | Netlify deploy previews: `test_env_url: https://deploy-preview-{pr}--shop.netlify.app` |
| `pr-comment` | a separate workflow posts or updates a comment on the PR when it has deployed | a workflow comments "Deployed to staging (pr-91) — Status: success": `deploy_comment_marker: Deployed to staging`, `deploy_success_marker: "Status: success"` |
| `url` | the test environment reports which commit it runs | `deploy_version_url: https://staging.shop.example/version` returns `{"commit":"3f2a9c1…"}` |
| `none` | there is no test environment per PR | ship ends the automatic part after CI and checks the criteria locally |

`url` is the most reliable signal: it proves the exact commit is running. With
`pr-comment`, ship only trusts a comment that was written or updated after CI
finished, because such comments are usually edited in place and an old "success"
must not count.

If the preview URL cannot be built from the PR number (for example, it contains a
hash), leave `test_env_url` empty and describe in *Test environment* where to find
it — Claude reads it there.

## Prose sections

| Section | What to write |
|---|---|
| **Commit and PR conventions** | e.g. "Conventional Commits, enforced by commitlint. The PR title becomes the squash-merge title and is linted. The FR id goes into the subject: `feat(checkout): coupon field (FR-012)`." |
| **Local checks before commit** | the fast commands: `npm run typecheck`, `npm run lint`, `npm test` |
| **CI** | which PR checks matter, how long they usually take |
| **Test environment** | how a PR gets there, the URL, how to get in (SSO, Cloudflare Access, basic auth), test accounts by name or role, which data may be used |
| **Deploy verification** | optional read-only commands that prove what runs, e.g. `kubectl -n staging get deploy -o wide` |
| **Hard rules for this project** | what must never happen here. Point to `CLAUDE.md` sections instead of copying them |

## Example

```markdown
---
base_branch: main
fr_dir: docs/fr
fr_prefix: FR
id_digits: 3
branch_pattern: "{type}/{id-lower}-{slug}"
issue_repo: acme/shop-requests
backlinks: on
notify_issues: always
review_gate: stop
deploy_signal: url
deploy_version_url: https://staging.shop.example/version
deploy_timeout_min: 20
test_env_url: https://staging.shop.example
acceptance_browser: playwright
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
