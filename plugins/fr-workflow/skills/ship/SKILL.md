---
name: ship
description: Finish an FR in its worktree — code and security review, then the first push and the PR, wait for CI and the test deployment, acceptance check against the FR's criteria, results into the FR doc.
argument-hint: "[FR id, if the branch name does not tell]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: ship

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md` — the
profile holds every project fact used below. A setting missing from the profile
takes its documented default (`${CLAUDE_PLUGIN_ROOT}/templates/workflow.md`); a
fact without a default (a URL, a test account) → ask, never guess.

The steps run strictly in order. Each has a **gate**: if it does not hold, stop,
show the evidence, the user decides. No improvised fixes.

**Nothing leaves the machine before step 1 passed.** Implementation sessions
commit without pushing; the first push of code is in step 2.

**Shared test environment** (`test_env: shared` and `deploy_signal` not `none`):
only one FR at a time may be between its first deploying event and its recorded
acceptance check. `fr.sh lock acquire <ID>` at the **start of step 2** — before
the first push *and* before `gh pr create`, either can deploy. Exit code 3 =
another FR holds it → wait in the background (60 s interval) and show who holds
it; held longer than 120 min, or reported stale → ask the user, and only on their
word `fr.sh lock break`. Release with `fr.sh lock release <ID>` at the end of
step 6 — and **before stopping at any gate**, so other FRs are not blocked.

**Board status** (`project_status` in the profile; `<issue>` is the FR doc's
`issue`): `fr.sh project-status <issue> running` once step 0 passed. Whenever
this skill **stops** before step 7, write why, in the same breath as the
evidence: `failed` when a gate found a defect in the change — review or
security findings under `stop`, a secret, red CI, a failed criterion; `blocked`
when something outside the change holds it up — the lock, a deployment that
does not come, a merge conflict that needs a decision; `input` when it stops
with a question — unclear uncommitted changes, unverified criteria, a login
wall. Exit 5 (not written) is a line in the report, never a reason to stop.

## 0. Preflight

- `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` passes; the current branch is not
  `base_branch`.
- FR from $ARGUMENTS, else from the branch name; confirm it in `fr.sh list`. Read
  the FR doc.
- Open PR of this branch, if any: `gh pr list --head <branch> --state open --json number,url`
  (`gh pr view` without a number may return a closed or merged PR).
- Look at uncommitted changes. Anything that does not belong to the FR → ask;
  never restore or discard it.

## 1. Review gate — code and security

1. Commit everything that belongs to the FR **locally** (project convention), so
   new files are part of the reviewed range. Do not push.
2. Run the reviews on the FR's range:
   - `/code-review high origin/<base_branch>...HEAD` — a revision range is a
     documented target; without one it would review only what is ahead of the
     branch's upstream, which can be nothing. It runs in the background as its
     own agent, so start it first;
   - the profile's `review_agents` (default `[silent-failure-hunter]`): each as
     the agent `fr-workflow:<name>`, given the range and the FR doc's path. They
     run in the background too. A name the plugin has no agent for → ask, never
     skip it silently;
   - meanwhile `/security-review`, telling it the range
     `origin/<base_branch>...HEAD`. If `base_branch` is not the repository's
     default branch it may compare against the default branch: check that its
     findings concern this FR's files.

   Take all results before applying the gates. **No review ends this skill:**
   when one returns its report, do not end your turn — wait for the others (the
   background reviews report back by themselves) and continue with 3. in the
   same run, up to step 7.
3. **Secrets always stop** — hard-coded credentials, tokens, private keys —
   whatever the gates say, and they cannot be accepted. The unpushed commits that
   contain one are rewritten so it never reaches the remote. `<target>` is
   `origin/<branch>` when it exists, else `$(git merge-base origin/<base_branch> HEAD)`
   — **never** `origin/<base_branch>` itself, which would undo the base branch's
   newer changes. Strictly in this order:
   1. **Check first.** Stop and let the user decide if the unpushed commits
      include a merge (`git rev-list --merges <target>..HEAD` prints anything,
      e.g. from step 2a), or if `origin/<branch>` exists but is not an ancestor of
      HEAD (`git merge-base --is-ancestor origin/<branch> HEAD` fails — someone
      else pushed; a reset would revert their commits).
   2. Remove the secret from the code (configuration or the project's secret
      store), `git add -A`, and **commit the removal** — `reset --soft` keeps the
      index, so an uncommitted removal would bring the secret back.
   3. `git reset --soft <target>`, then commit again: the unpushed commits become
      one, without the secret.
   4. Verify: `git log -p <target>..HEAD` must not contain a distinctive part of
      the secret.
   5. Was it ever pushed? `git log --all -S'<distinctive part>' --oneline` searches
      local and remote-tracking refs. A hit, or any doubt — a branch deleted on the
      remote, an earlier PR (GitHub keeps PR refs and unreachable commits) → the
      credential is compromised: tell the user to rotate it; changing history
      does not help.
4. Other findings: code findings — from `/code-review` and the review agents —
   follow `review_gate`, security findings follow `security_gate` (default
   `stop`, independent of `review_gate`):
   - `stop` → list them; the user decides per finding: fix, accept, or abort;
   - `report` → collect them and go on.
5. After **any** fix (a new local commit): run **all** reviews again on the range.
   A fix for a code finding can open a security hole.
6. *Review notes* for the PR: every accepted security finding with the user's
   reason, and under `report` every security finding. Describe the risk, not how
   to exploit it; never secrets. **Public repository**
   (`gh repo view --json visibility -q .visibility` is `PUBLIC`): no details in the
   PR or the FR doc — only "N security findings accepted, recorded with the
   maintainers"; tell the user to record the details privately.
7. Run the profile's *Local checks before commit*, including the security tools it
   lists. A failure stops.

## 2. Push and PR

- Shared test environment → acquire the lock now (see above).
- Push the branch.
- PR: the open PR from step 0, else `gh pr create --base <base_branch>`:
  - title per the profile (it often becomes the squash-merge title);
  - body, in the FR's language (*Language* in the model): link to the FR doc on
    the branch, a short summary, `Closes <issue>` for
    the FR's own issue (`issue` in the frontmatter) and `Refs <request>` for each
    of its `requests` — **never** `Closes`/`Fixes` for a request — the acceptance
    criteria as the test plan, and *Review notes* (step 1.6) if there are any;
  - no CI skip marker in title, body or any commit (see the hard rules).
- Reused PR whose *Review notes* changed → `gh pr edit <N> --body-file <file>`.
- Set `pr: <N>` in the frontmatter; it is committed in step 6.

## 2a. Up to date with the base branch

Other FRs may have been merged meanwhile. `gh pr view <N> --json mergeable,mergeStateStatus`
(`UNKNOWN` right after a push → retry shortly):

- `CONFLICTING`, or `BEHIND` where the branch must be up to date →
  `git fetch origin && git merge origin/<base_branch>` in the worktree. **Merge,
  never rebase**, never force-push.
- Git merges cleanly → run all reviews on the merged range and the local checks
  again, push, continue.
- Real conflicts → resolve only what is unambiguous (e.g. both sides added
  different entries). Anything that needs a decision → `git merge --abort`, stop,
  list the conflicting files and both sides' intent.

## 3. CI gate

- `gh pr checks <N> --watch --fail-fast` in the background — never poll in the
  foreground. Right after the PR is created, checks may not be registered yet:
  wait briefly, retry.
- Red → stop: show `gh run view <run-id> --log-failed` and name the cause.

## 4. Test deployment gate — by `deploy_signal`

"This PR's commit" is a SHA S that is either the head
(`gh pr view <N> --json headRefOid -q .headRefOid`) or a merge commit of the head
into the base branch: its parents (`gh api repos/<repo>/commits/<S> --jq '[.parents[].sha]'`)
are the head and a commit of the base branch
(`gh api repos/<repo>/compare/<other parent>...<base_branch> --jq .status` is
`ahead` or `identical`). `pull_request` workflows build GitHub's test merge
commit, which GitHub recomputes whenever the base branch moves — so compare by
parents, not with `merge_commit_sha`. The base-branch condition keeps out another
branch that merely merged this one.

- `none` → no test environment: skip this step; step 5 checks locally.
- `pr-checks` → covered by step 3. Confirm `test_env_url` (`{pr}` replaced)
  responds.
- `pr-comment` → find the comment containing `deploy_comment_marker`, with
  `--paginate` (bots push it past the first page):

  ```bash
  gh api repos/<repo>/issues/<N>/comments --paginate --jq '.[] | select(.body | contains("<marker>")) | {updated_at, body}'
  ```

  It must contain `deploy_success_marker`, and then:
  - it names this PR's commit (its first 7 characters appear) → counts;
  - it names another commit — a hex token of 7 to 40 characters with at least one
    letter a–f, which is not this PR's commit → stale, keep waiting;
  - it names no commit → counts only if it was updated **after** the CI run for
    the head commit finished (`gh run list --commit <head sha> --json updatedAt`)
    — weaker, an in-place edit by an older deploy can still slip through; say so
    in the report.
- `url` → poll `deploy_version_url` until its response contains this PR's commit.

Wait in the background (60 s interval) up to `deploy_timeout_min`. Failure or
timeout → stop and report. **Never** trigger or re-run a deployment. Then run the
profile's *Deploy verification* commands, if any — read-only.

## 5. Acceptance check

- Turn every acceptance criterion into a concrete check, list them, then run them
  without asking.
- Shared test environment with `deploy_signal: url`: `deploy_version_url` must
  report this PR's commit right **before** the first check and right **after** the
  last. Changed in between → someone else deployed; the results are void — say so
  and run the checks again once this PR is deployed.
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
  This runs CI again — wanted: the commit that gets merged must carry green
  checks. Do not wait for it — except on a shared test environment: wait until the
  CI run for this commit has finished; if a deployment of it follows (by
  `deploy_signal`), wait for that too; if none starts within 5 minutes after CI
  (e.g. `paths-ignore` skips FR-doc-only pushes), go on. Then
  `fr.sh lock release <ID>`.

## 7. Notify and report

- `notify_issues`: `never` → nothing; `ask` → offer it; `always` → post. One new
  comment on the FR's issue and on each of its `requests` — their watchers learn
  it there: "Ready for acceptance on <test env URL> — <ID> <title>, PR <repo>#<N>."
  — in the issue's language, the text is a template (*Language* in the model).
  The FR's body stays as it was at the start; the result lives in the FR doc and
  the PR.
- `fr.sh project-status <issue> approval` — the merge is the user's.
- Report in one block: PR link · CI · deployment · acceptance check per criterion
  · review findings accepted or reported · the board status, or why it was not
  written · what is left: the merge (the user's), then `/fr-workflow:done <ID>`.
