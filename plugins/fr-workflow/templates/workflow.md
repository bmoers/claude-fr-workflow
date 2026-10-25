---
base_branch: main
fr_dir: req/feature-requests
fr_prefix: FR
id_digits: 3
branch_pattern: "{type}/{id-lower}-{slug}"
issue_repo:                       # owner/repo of the issues; empty = this repository
backlinks: on                     # on | off — backlink comment on linked issues
notify_issues: ask                # never | ask | always — "ready for acceptance" comment
review_gate: stop                 # stop | report — what :ship does on review findings
deploy_signal: none               # none | pr-checks | pr-comment | url
deploy_comment_marker:            # pr-comment: text identifying the deploy comment
deploy_success_marker:            # pr-comment: text that means success
deploy_version_url:               # url: endpoint whose response contains the deployed commit SHA
deploy_timeout_min: 30
test_env_url:                     # base URL of the test environment; {pr} = PR number
acceptance_browser: playwright    # playwright | none
---

# Workflow profile

Project facts for the fr-workflow plugin. Keep secrets out of this file — name
accounts and access methods, never passwords or tokens.

## Commit and PR conventions

<!-- e.g. Conventional Commits, enforced by commitlint; the PR title becomes the
squash-merge title and is linted; FR id goes into the subject, not the type. -->

## Local checks before commit

<!-- commands for typecheck, lint, unit tests — the fast ones -->

## CI

<!-- which PR checks matter, typical duration -->

## Test environment

<!-- how a PR reaches it, URL, how to get in (SSO, Cloudflare Access, basic auth),
test accounts by name or role, which data may be used -->

## Deploy verification

<!-- optional, read-only commands that prove the PR is what runs, e.g.
kubectl -n staging get deploy -o wide -->

## Hard rules for this project

<!-- on top of the plugin's rules; point to CLAUDE.md sections instead of copying them -->
