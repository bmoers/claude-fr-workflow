# fr-workflow — model and rules

Every fr-workflow skill reads this first.

## Terms

- **Request** — what someone asked for: a GitHub issue with the label
  `fr-request`, in the shape of the repository's issue form
  (`.github/ISSUE_TEMPLATE/feature-request.yml`, template
  `${CLAUDE_PLUGIN_ROOT}/templates/issue-form.yml`). It may be rough — it is the
  input, not the spec.
- **FR** (feature request) — the unit of work: a spec with acceptance criteria,
  one branch, one worktree, one PR. An FR is a GitHub issue with the label `fr`,
  its body in the shape of `${CLAUDE_PLUGIN_ROOT}/templates/fr.md`. Its id is the
  issue number with `fr_prefix`: issue `#47` is `FR-47`.
- Requests and FRs are m:n, expressed with what GitHub has:
  - **one request, one change** → the request itself becomes the FR: label
    `fr`, body rewritten into the spec, the original text kept at its end;
  - **one request, several changes** → every FR is a **sub-issue** of the
    request;
  - **several requests, one change** → the FR is a sub-issue of one of them and
    lists all of them under *Requests* in its Planning; GitHub records the
    mention on each.

  `fr.sh issue-frs <request>` finds the FRs of a request in all three cases.
- Requests and FR issues live in `issue_repo` (default: this repository).
  Whoever reads the requests reads the specs: technical notes are fine there;
  secrets, internal hostnames, customer data and the details of a security
  weakness are not.

## Life of an FR

| Step                     | The spec is                                           | Status                                                    |
| ------------------------ | ----------------------------------------------------- | --------------------------------------------------------- |
| defined — `:new`         | the FR issue                                          | `open` — derived: open issue, label `fr`, no FR doc yet   |
| started — `:start`       | the FR doc on the FR's branch, written from the issue | `in-progress` — `:implement` builds it in the worktree    |
| shipped — `:ship`        | the FR doc, with the acceptance check                 | `in-review`                                               |
| merged — by the user     | the FR doc on the base branch                         | `merged` — derived: an `in-review` doc on the base branch |
| dropped — `:done … drop` | the FR doc, or only the issue if never started        | `dropped`                                                 |

- **Until the start, the issue is the spec.** Refine it with `:new #47` or by
  hand on GitHub; everything `:start` needs must be in it.
- **From the start on, the FR doc is the source.** The issue's body is not
  updated any more — decisions and deviations go into the FR doc, in the same
  commits as the code; `:ship` reports the result on the issue.

## FR issue

- Body sections from `${CLAUDE_PLUGIN_ROOT}/templates/fr.md`: *Problem /
  motivation*, *Desired behaviour*, *Failure behaviour*, *Scope*, *Acceptance
  criteria*, *Technical notes*, *Open questions*, *Planning* — and, when a
  request was rewritten, its original text at the end in
  `<details><summary>Original request</summary>`.
- `fr.sh` reads *Planning*:

  ```markdown
  ## Planning

  - Areas: src/checkout, src/api/orders
  - Size: M
  - Model: opus
  - Effort: high
  - Based on: 3f2a9c1d2e4b
  - Requests: #12, #15
  ```

  - **Areas:** the directories or files the FR is expected to change, from
    reading the code. They decide what may run in parallel (see below).
  - **Model**, **Effort:** for the implementation session, decided by `:new` —
    explicit values in the request, else its size via `size_models`, else
    `impl_model` / `impl_effort`.
  - **Based on:** the commit of `origin/<base_branch>` whose code the definition
    read. `:start` checks what changed in the areas since.
  - **Requests:** the request issues this FR serves; empty when the FR is the
    request itself.
- **Language:** what the skills write to GitHub — FR issue titles and bodies,
  comments, PR descriptions — is in the language of its source: the idea, the
  draft file, the request issue. Never switch to English or any other language
  on your own; the quoted comment texts in the skills are templates to render in
  that language. Only the headings and the Planning keys stay English — `fr.sh`
  reads them. Sources in different languages → ask.
- **Ready to start:** open, label `fr`, at least one acceptance criterion, no
  items under *Open questions*. `fr.sh spec` refuses anything else.

## FR document

- `<fr_dir>/<ID>-<slug>.md` on the FR's branch, e.g.
  `req/feature-requests/FR-47-coupons-in-checkout.md`. `fr.sh spec` writes it at
  the start: the issue's sections verbatim — without *Planning*, which becomes
  the frontmatter, and without the original request, which may hold customer
  data (never in a commit) — plus `## Acceptance check` for `:ship`.
- Frontmatter, flat, one line per key, lists on one line:

  ```yaml
  ---
  id: FR-47
  issue: acme/shop#47
  title: Coupons in checkout
  status: in-progress
  requests: [acme/shop#12, acme/shop#15]
  areas: [src/checkout, src/api/orders]
  model: opus
  effort: high
  based_on: 3f2a9c1d2e4b
  pr:
  started: 2026-10-29
  ---
  ```

- `status`: `in-progress` (`:start`) → `in-review` (`:ship`, after the
  acceptance check passed), or `dropped` (`:done <ID> drop`). **`merged` is never
  written**: `fr.sh` derives it when an `in-review` FR is on the base branch. The
  base branch is usually protected, so nothing gets committed there after a
  merge.

## Branches and worktrees

- One branch per FR, created by `:start` off `origin/<base_branch>` — never on the
  branch the user is on, never on the base branch — with the FR doc as its first
  commit, pushed. Name from `branch_pattern`, default `{type}/{id-lower}-{slug}`
  → `feat/fr-47-coupons-in-checkout`. The branch name **must contain the FR id**
  — that is how `fr.sh` finds FR docs on branches.
- One worktree per FR at `.claude/worktrees/<id-lower>-<slug>` (gitignored),
  created by `:start`.
- The FR doc travels with the code and reaches the base branch with the merge.
- There is **no shared index file**: a table edited in every PR conflicts and
  drifts. The overview is `/fr-workflow:status`.

## Sessions

- The **implementation session** runs in the FR's worktree with the FR's
  `model` and `effort` — `:start` names the command, `:implement` is its brief.
  It commits, never pushes.
- The **ship session** is a second session of the same worktree, opened from
  the main checkout with the profile's `ship_model` / `ship_effort` (default
  `opus` / `high`):
  `claude -w <worktree> --model <ship_model> --effort <ship_effort> -n '<ID> ship'`,
  then `/fr-workflow:ship`. The gates and the acceptance check are that
  session's judgement, and the session that wrote the code is not the one to
  judge it. `:implement` ends with this command; `:start` lists it per FR.
  `:ship` in the implementation session works too — the judgement is then that
  session's, with its model.
- The review agents (`review_agents`) run on `opus` whatever the session's
  model; `/code-review` runs as its own agent; `/security-review` runs in the
  session.

## Parallel work

- Two FRs may run at the same time when they do not touch the same paths.
  `fr.sh overlap` compares each FR's `areas` **and** the files its branch already
  changed; one path inside the other counts as overlap, and so do two different
  files under one of the profile's `shared_paths` (migrations, lockfiles, i18n).
  An FR with neither areas nor changes overlaps everything — parallel only when it
  is evident. FRs not started yet count with the *Areas* of their issue. The
  result groups FRs into waves; wave 1 can start now.
- `:start` with several FRs starts one background session per FR of wave 1
  (`claude -w <name> --bg …`). Claude Code's own tools show them: `claude agents`,
  `claude logs`, `claude attach`.
- While a Claude session runs in a worktree, Claude Code locks the worktree
  (`git worktree list` shows `locked claude session … (pid N …)`). A lock whose pid
  no longer runs is stale and may be removed with `git worktree unlock`; a live
  one means the session is still running — never remove its worktree.
- Parallel PRs reach the base branch one after the other, so a later one can
  conflict. `:ship` then **merges** `origin/<base_branch>` into the FR branch — no
  rebase, no force push.
- `test_env: shared` (one deployment at a time): only one FR may be between its
  deploying push and its recorded acceptance check — `fr.sh lock`. The lock lives
  in the git directory all worktrees of a clone share, so it covers parallel
  sessions on one machine, not other developers. Against those, the deployed
  commit is checked before and after the acceptance check.

## PRs and closing issues

- The PR body says `Closes <issue>` for the FR's own issue — one FR, one issue,
  one PR, so the merge closes it — and `Refs <request>` for every request in
  `requests`. **Never** `Closes`/`Fixes`/`Resolves` for a request: other FRs may
  still serve it.
- GitHub honours closing keywords only for PRs into the repository's default
  branch. Otherwise, or when the merge did not close it, `:done` closes the FR
  issue.
- Requests are closed only by `:done`, only when every FR serving them is closed,
  and only after the user confirmed.
- A GitHub project (`project` in the profile) gets every FR issue `:new` writes.
  Without `project_status` the project's own workflows move the cards (*Item
  closed* → Done, …); with it the skills write the status column — see *Board
  status*.

## Board status

GitHub's project workflows know *added* and *closed*; *running*, *waiting* and
*failed* only the session knows. `project_status` in the profile maps the
plugin's events to the board's own values (`defined=Ready, running=In progress,
…`; the column is `project_status_field`, default `Status`); an event without a
value writes nothing. `fr.sh project-status <issue> <event>`:

| Event      | Written by                      | When                                                                                                                                                             |
| ---------- | ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `defined`  | `:new`                          | the FR issue is written and ready — no open questions                                                                                                            |
| `input`    | `:new`, `:implement`, `:ship`   | a skill stops with a question: open questions left on purpose, a decision only the user can take, unclear uncommitted changes, unverified criteria, a login wall |
| `running`  | `:start`, `:implement`, `:ship` | branch, worktree and session exist; a resumed FR; `:implement` goes on after an answer; `:ship` starts                                                           |
| `failed`   | `:ship`                         | a gate found a defect in the change: review or security findings under `stop`, a secret, red CI, a failed criterion                                              |
| `blocked`  | `:ship`                         | something outside the change holds it up: the ship lock, a deployment that does not come, a merge conflict that needs a decision                                 |
| `approval` | `:ship`                         | finished: PR open, acceptance check recorded — the merge is the user's                                                                                           |
| `done`     | `:done`                         | merged or dropped                                                                                                                                                |

Best effort by design: exit 5 means *not written*, with the reason — a `gh`
older than 2.97, no `project` scope on the token, no project of that title
under the issue repository's owner, no such column value. A skill puts that
line into its report and goes on: **the board is never a gate.** An FR issue
not on the board yet is added first. Without `project_status` nothing is
written.

## Script

`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh`, from anywhere inside the repository:

| Command                                     | Does                                                                                                                                                                                                                     |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `check`                                     | prerequisites and profile                                                                                                                                                                                                |
| `list`                                      | all FRs as TSV: `id status location ref path pr issue requests title areas model effort`                                                                                                                                 |
| `spec <issue> [<file>]`                     | the FR doc of an FR issue — to stdout to check it, into a new `<file>` at the start. Exit 4 = not ready, with the reasons                                                                                                |
| `issue-frs <issue>`                         | the FRs serving a request: `ref state reason via` — `reason` `completed`, `not_planned` or `duplicate` once closed; `via` `self`, `sub` or `requests`                                                                    |
| `overlap [<ID>...]`                         | `running ID` (every `in-progress` FR — always the context), `conflict A B reason`, `wave N ID` for the candidates (default: all `open` FRs). Wave 1 = overlaps neither a running FR nor another wave-1 FR: can start now |
| `lock acquire\|release\|break\|status <ID>` | ship lock for a shared test environment; `acquire` exits 3 when another FR holds it; `break` only after the user confirmed no ship runs                                                                                  |
| `project-status <issue> <event>`            | the board column of an FR issue per `project_status`: `defined`, `input`, `running`, `failed`, `blocked`, `approval`, `done`. Exit 5 = not written, reason on stderr — a line for the report, never a stop               |
| `project-options [<value>...]`              | adds the values of `project_status` (or the given ones) that the status column lacks; existing options keep id, colour and text. Prints the project's *Workflows* page. Exit 5 = nothing changed, reason on stderr       |

`location` is `issue` (not started; `ref` is the issue), `base`, `branch` (then
`ref` is the branch) or `local` (uncommitted in this checkout). `list` and
`overlap` fetch origin first; pass `--no-fetch` after the first call within one
skill run. Issue arguments: `#47`, `47`, `FR-47`, `owner/repo#47` or the URL;
refs are compared case-insensitively. Two FR branches with the same id make
`fr.sh` print a warning — one of them was started twice.

## Hard rules — every skill, every project

The profile and the project's `CLAUDE.md` may add rules; they never relax these.

- **Never merge** a PR. The merge is the user's decision.
- **Never trigger** deploy or release workflows (`gh workflow run`, re-running
  deploy jobs). If a deployment does not come, report it.
- **Never touch production** — no reads, no writes — unless the user explicitly
  asks, for that one action.
- **No code leaves the machine unreviewed.** Implementation sessions commit but
  never push; the first push of code is `:ship`, after its code and security
  review. `:new` writes only issues; `:start` pushes only FR docs.
- **Secrets never get pushed.** A credential found in a change always stops,
  cannot be accepted, and is removed from the unpushed commits before any push.
- **Never write a CI skip marker** — `[skip ci]`, `[ci skip]`, `[no ci]`,
  `[skip actions]`, `[actions skip]`, a `skip-checks:` trailer — into a commit
  message, PR title or PR body. A squash merge copies the branch's commit
  messages into the commit on the base branch, and the marker would then skip the
  base branch's release and deploy workflows.
- No force push, no rebase of a pushed FR branch, no `reset --hard`, `restore`,
  `clean` or `stash drop` on the user's changes. Unclear changes → ask.
- Never ask for, store or type credentials. A login wall → the user logs in
  themselves, in the browser window.
- No personal or customer data in commits, PRs, issues, issue comments or
  screenshots.
- Issues are read by the customer: write into them only what the skills name —
  the FR spec, the short notes of `:new`, the result of `:ship` as far as
  `notify_issues` allows, the closing comments of `:done`.
- A gate that does not hold **stops** the skill: show the evidence, the user
  decides. No improvised fix loop.
