---
name: ship
description: Finish an FR in its worktree — review gate, commit/push/PR, wait for CI and the test deployment, acceptance check against the FR's criteria, results into the FR doc.
argument-hint: "[FR id, if the branch name does not tell]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: ship

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md` — the
profile holds every project fact used below. A value is missing → ask, never guess.

The steps run strictly in order. Each has a **gate**: if it does not hold, stop,
show the evidence, the user decides. No improvised fixes.

**Shared test environment** (`test_env: shared` and `deploy_signal` not `none`):
only one FR at a time may be between its deploying push and its recorded
acceptance check. Acquire `fr.sh lock acquire <ID>` right before the first push in
step 2; exit code 3 = another FR holds it → wait in the background (60 s interval)
and show who holds it; held longer than 120 min → ask the user whether it is
stale. Release it with `fr.sh lock release <ID>` at the end of step 6 — and
**before stopping at any gate**, so other FRs are not blocked.

## 0. Preflight

- `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` passes; the current branch is not
  `base_branch`.
- FR from $ARGUMENTS, else from the branch name; confirm it in `fr.sh list`. Read
  the FR doc.
- Look at uncommitted changes. Anything that does not belong to the FR → ask;
  never restore or discard it.

## 1. Review gate

- Run the built-in `/code-review` over everything this branch changes against
  `origin/<base_branch>`, committed and uncommitted.
- `review_gate: stop` → findings stop the run; list them, the user decides (fix,
  accept, abort). `review_gate: report` → keep them for the report and go on.
- Run the profile's *Local checks before commit*. A failure stops.

## 2. Commit, push, PR

- Commit following the profile's conventions — if a hook enforces them, get it
  right the first time. Push.
- Reuse the branch's open PR (`gh pr view --json number,url`), else
  `gh pr create --base <base_branch>`:
  - title per the profile (it often becomes the squash-merge title);
  - body: link to the FR doc on the branch, a short summary,
    `Refs owner/repo#N` per issue — **never** `Closes`/`Fixes` — and the
    acceptance criteria as the test plan;
  - no CI skip marker in title, body or any commit (see the hard rules).
- Set `pr: <N>` in the frontmatter; it is committed in step 6.

## 2a. Up to date with the base branch

Other FRs may have been merged meanwhile. `gh pr view <N> --json mergeable,mergeStateStatus`
(`UNKNOWN` right after a push → retry shortly):

- `CONFLICTING`, or `BEHIND` where the branch must be up to date →
  `git fetch origin && git merge origin/<base_branch>` in the worktree. **Merge,
  never rebase**, never force-push.
- Git merges cleanly → run the local checks again, push, continue.
- Real conflicts → resolve only what is unambiguous (e.g. both sides added
  different entries). Anything that needs a decision → `git merge --abort`, stop,
  list the conflicting files and both sides' intent.

## 3. CI gate

- `gh pr checks <N> --watch --fail-fast` in the background — never poll in the
  foreground. Right after the PR is created, checks may not be registered yet:
  wait briefly, retry.
- Red → stop: show `gh run view <run-id> --log-failed` and name the cause.

## 4. Test deployment gate — by `deploy_signal`

- `none` → no test environment: skip this step; step 5 checks locally.
- `pr-checks` → covered by step 3. Confirm `test_env_url` (`{pr}` replaced)
  responds.
- `pr-comment` → the PR comment containing `deploy_comment_marker` counts only if
  it was created or updated **after** the CI run of step 3 finished, and contains
  `deploy_success_marker`. Such comments are often updated in place, so an old
  success must not count:

  ```bash
  gh api repos/<repo>/issues/<N>/comments --jq '.[] | select(.body | contains("<marker>")) | {updated_at, body}'
  ```

- `url` → poll `deploy_version_url` until the response contains the PR head SHA
  (`git rev-parse HEAD`, full or short).

Wait in the background (60 s interval) up to `deploy_timeout_min`. Failure or
timeout → stop and report. **Never** trigger or re-run a deployment. Then run the
profile's *Deploy verification* commands, if any — read-only.

## 5. Acceptance check

- Turn every acceptance criterion into a concrete check, list them, then run them
  without asking.
- Shared test environment with `deploy_signal: url`: check that
  `deploy_version_url` reports this PR's head SHA right **before** the first check
  and right **after** the last. Changed in between → someone else deployed; the
  results are void — say so and run the checks again once this PR is deployed.
- UI with the bundled Playwright browser against the test environment; backend
  effects with the read-only means the profile names. Only the test accounts the
  profile names; none named → ask.
- A login or SSO wall (an identity provider, a `cloudflareaccess.com` page, basic
  auth) → stop and ask the user to log in in the open browser window. Its profile
  is persistent; the login lasts as long as that provider's session.
- Screenshots to `.playwright-mcp/<id-lower>/` (gitignored), without personal data.
- No test environment (`deploy_signal: none`) or no browser
  (`acceptance_browser: none`) → check what you can locally: tests, a local run,
  reading the code. Mark every criterion that could not be verified this way as
  **unverified** — never as passed.
- A criterion fails → stop with evidence: screenshot, log, request and response.
  No fix loop without the user.
- Criteria left unverified → list them and ask: the user either accepts them as
  unverified or stops here.

## 6. Record the result

Only when no criterion failed, and the user accepted any unverified ones:

- Fill `## Acceptance check` in the FR doc: date, environment (URL, or "local"),
  PR #N at `<short SHA>`; per criterion what was checked, how, and the result —
  `passed` or `unverified, accepted by <user>`; the limits of the check.
- Tick only the criteria actually verified (`- [x]`); unverified ones stay open.
- `status: in-review`.
- Commit (`docs(fr): acceptance check <ID>` or the project's convention) and push.
  This runs CI and the deployment again — wanted: the commit that gets merged
  must carry green checks. Do not wait for it — except on a shared test
  environment: there wait for that deployment (as in step 4), then
  `fr.sh lock release <ID>`, so the next FR does not get overwritten by it.
- `fr.sh sync-fr <ID> --no-fetch`.

## 7. Notify and report

- `notify_issues`: `never` → nothing; `ask` → offer it; `always` → post. One new
  comment per issue — it notifies watchers, the edited backlink does not:
  "Ready for acceptance on <test env URL> — <ID> <title>, PR <repo>#<N>."
- Report in one block: PR link · CI · deployment · acceptance check per criterion
  · review findings that were accepted · what is left: the merge (the user's),
  then `/fr-workflow:done <ID>`.
