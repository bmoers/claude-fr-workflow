---
base_branch: main
fr_dir: req/feature-requests
fr_prefix: FR                     # FR-47 = issue #47
branch_pattern: "{type}/{id-lower}-{slug}"
issue_repo:                       # owner/repo of requests and FR issues; empty = this repository
project:                          # GitHub project (title) for the FR issues; empty = none
project_status_field: Status      # the project's single-select status column
project_phase_field:              # the project's phase column (Backlog, Planning, Building, Review, Done), if it has one; project_status values are then Phase/Status
project_status:                   # plugin events -> its values, e.g. "defined=Ready, running=In progress, approval=In review, done=Done" or "defined=Building/Ready, …"; empty = GitHub's workflows move the cards
notify_issues: ask                # never | ask | always — "ready for acceptance" comment
review_gate: stop                 # stop | report — what :ship does on code review findings
security_gate: stop               # stop | report — what :ship does on security review findings
review_agents: [silent-failure-hunter]   # :ship's extra reviewers, also type-design-analyzer; [] = none
deploy_signal: none               # none | pr-checks | pr-comment | url | deployment
deploy_comment_marker:            # pr-comment: text identifying the deploy comment
deploy_success_marker:            # pr-comment: text that means success
deploy_version_url:               # url: endpoint whose response contains the deployed commit SHA
deploy_timeout_min: 30
deploy_environment:               # deployment, required: the deployment's environment — a name or a glob, test-slot-* or pr-{pr}
acceptance_label:                 # deployment: PR label set during the acceptance check so the slot stays with this PR; empty = none
test_env_url:                     # base URL of the test environment; {pr} = PR number
test_env: shared                  # shared | per-pr — one deployment at a time, or one per PR
acceptance_browser: playwright    # playwright | none
impl_model: opus                  # default model for implementation sessions
impl_effort: high                 # low | medium | high | xhigh | max
size_models: "S=sonnet/low, M=sonnet/medium, L=opus/high, XL=opus/xhigh"   # issue Size -> model/effort
ship_model: opus                  # model of the ship session: reviews, gates, acceptance check
ship_effort: high                 # low | medium | high | xhigh | max
shared_paths: []                  # paths every FR may touch, e.g. [package-lock.json, db/migrations]
spec_dir:                         # folder of the living specs, one <capability>/spec.md; the FRs then carry spec deltas instead of acceptance criteria. Empty = off
worktree_setup:                   # command run in every FR worktree after start created or resumed it, e.g. scripts/stack.sh up — idempotent, non-interactive; empty = nothing
worktree_teardown:                # command run before done removes the worktree, e.g. scripts/stack.sh down; empty = nothing
autopilot_model: sonnet           # model of the autopilot session — it drives, it does not judge
autopilot_effort: medium          # low | medium | high | xhigh | max
autopilot_sessions: 3             # FR sessions the autopilot runs at a time
session_permission_mode:          # auto | acceptEdits | dontAsk | default — --permission-mode of the sessions launch starts; empty = your default; never bypassPermissions
notify_command:                   # run for every FR the autopilot reports as needing you, FR_MESSAGE etc. in the env, e.g. terminal-notifier -message "$FR_MESSAGE"; empty = nothing
notify_repeat: 120                # minutes until a row that still needs you is sent again; 0 = once
stop_comments: off                # on = a stop is also posted on the FR issue, and `accept all` / `fix 2` / `abort` as a comment answers it
fix_loop: off                     # off | checks | checks+comments — what the autopilot sends back to a fix session
fix_attempts: 2                   # fix sessions per FR, then it is reported
fix_skip_checks: []               # checks that never go to the fix loop, e.g. [CodeQL, gitleaks]
fix_comment_bots: []              # bots whose PR comments count for checks+comments, e.g. [claude[bot]]
autopilot_queue: manual           # manual | project — the board feeds the queue: open FR issues on the `defined` square
autopilot_assignee:               # project queue: a login (that person's FRs), none (unassigned FRs), empty = any — per machine: set it in .claude/workflow.local.md
autopilot_finish: off             # on = after the merge: worktree hook, worktree, local branch, board done, out of the queue
auto_merge: off                   # auto = after the acceptance check: fr.sh merge-gate, then gh pr merge --auto — GitHub's rules decide
merge_method: squash              # squash | merge | rebase, for fr.sh merge
---

# Workflow profile

Project facts for the fr-workflow plugin. Keep secrets out of this file — name
accounts and access methods, never passwords or tokens.

## Commit and PR conventions

<!-- e.g. Conventional Commits, enforced by commitlint; the PR title becomes the
squash-merge title and is linted; FR id goes into the subject, not the type. -->

## Local checks before commit

<!-- commands for typecheck, lint, unit tests — the fast ones. Security tools the
project already uses, scoped to the FR's own changes (they run after its local
commit, before the first push), e.g.
  gitleaks detect --log-opts="origin/main..HEAD"
  git diff --quiet origin/main...HEAD -- package-lock.json || npm audit --audit-level=high
A full dependency audit belongs in CI: run unscoped it blocks every FR whenever a
new advisory appears anywhere in the tree. -->


## CI

<!-- which PR checks matter, typical duration; whether the FR-doc-only first
push of a new FR branch (from :start) triggers builds, and how that is handled -->


## Test environment

<!-- how a PR reaches it, URL, how to get in (SSO, Cloudflare Access, basic auth),
test accounts by name or role, which data may be used -->

## Deploy verification

<!-- optional, read-only commands that prove the PR is what runs, e.g.
kubectl -n staging get deploy -o wide -->

## Hard rules for this project

<!-- on top of the plugin's rules; point to CLAUDE.md sections instead of copying them -->
