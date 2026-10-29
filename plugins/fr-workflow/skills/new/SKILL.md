---
name: new
description: Define feature requests — from an idea or from GitHub issues, worked out against the code into FR issues that are complete specs. Writes only to GitHub.
argument-hint: "[an idea | #12 owner/repo#15 FR-47 label:… milestone:… project:owner/N search:… | a file]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: new — define FRs

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` must pass, else point to
`/fr-workflow:init`.

Input: $ARGUMENTS

The result is one or more FR issues on GitHub, each a complete spec:
`/fr-workflow:start` only pulls it, checks it and starts. This session is for
thinking, not for code, and it writes nothing but issues — no branch, no file in
the repository, no push.

## 1. Collect

Any mix of — nothing given → ask for the idea or the issues:

- **An idea** in the conversation, without any issue → its FRs become new issues.
- Issue refs `#12`, `owner/repo#12`, `FR-47`, issue URLs →
  `gh issue view <n> -R <repo> --json number,title,body,labels,author,parent,subIssues,url`.
  `<repo>` = `issue_repo` from the profile, else this repository.
- `label:<name>` / `milestone:<name>` → `gh issue list -R <repo> --state open --limit 200 --label … / --milestone …`.
- `project:<owner>/<number>` → `gh project item-list <number> --owner <owner> --limit 200 --format json`,
  issues only; apply a status or view filter if the user names one.
- `search:<query>` → `gh issue list -R <repo> --limit 200 --search "<query>"`.
- A list that reaches the limit is incomplete: say so and ask to narrow the
  selection — never plan from a silently cut list.
- A local file — notes, a requirements document, a legacy FR → a source like an
  idea. Do not modify or move it.

Per issue, what it is:

- **A request** (label `fr-request`, or none) → `fr.sh issue-frs <ref>`: FRs may
  serve it already. Requests from the form have one `### <label>` section per
  field of `.github/ISSUE_TEMPLATE/*.yml` (the form labelled `fr-request`; else
  `${CLAUDE_PLUGIN_ROOT}/templates/issue-form.yml`): *Problem or need* → Problem /
  motivation; *Who is affected* and *Desired behaviour* → Desired behaviour; *How
  do we know it is done* → acceptance criteria, rewritten so each one is
  checkable; *Size*, *Model*, *Effort* → Planning (step 2). `_No response_` means
  empty. A request without this structure is fine — the discussion fills the
  gaps.
- **An FR** (label `fr`) → refine it. Already started (`fr.sh list` shows it with
  a location other than `issue`) → its FR doc is the source now: say so and leave
  the issue alone.

## 2. Work it out — with the code

- `git fetch origin`, then read the code as it is on `origin/<base_branch>` — the
  checkout may be another branch or behind; `git show origin/<base_branch>:<path>`
  for files that differ. Read only.
- Summarize what was asked, per issue, in a few lines. Name contradictions, gaps
  and risks.
- Ask the open questions, a few at a time, and iterate until the scope is clear.
  Only what the user wants left open goes under *Open questions* — such an FR
  cannot start yet.
- Settle the **failure behaviour**: what happens when something the change
  depends on fails — a service, a file, input, a permission. What the user sees,
  whether it retries, what is logged. "Nothing can fail here" is an answer too,
  once checked. Where it matters to the user, make it an acceptance criterion —
  `:ship` reviews the error handling against it.
- New data types, or existing ones reshaped: name their invariants — what must
  always hold, which states are invalid. They go into *Technical notes*.
- *Technical notes* name the places in the code that change and how the change
  fits in, concrete enough that the implementation session need not rediscover
  them — as detailed as reading the code allows.
- Propose the cut. This table decides how requests and FRs relate:

  | FR  | Title | Issue                 | Requests | Type | Areas           | Model / effort  |
  | --- | ----- | --------------------- | -------- | ---- | --------------- | --------------- |
  | #12 | …     | #12 rewritten         | —        | feat | src/checkout    | opus / high     |
  | new | …     | new, sub-issue of #15 | #15, #16 | fix  | src/invoice/pdf | sonnet / medium |
  | new | …     | new                   | —        | feat | src/search      | sonnet / low    |

  One FR = one PR that can be reviewed and accepted on its own. Split a request
  that mixes independent changes; join requests that are the same change.
  - **Issue:** a request with exactly one FR becomes that FR — its body is
    rewritten. Several FRs from one request → new sub-issues of it. One FR for
    several requests → a sub-issue of the first, all of them under *Requests*. An
    idea → a new issue.
  - **Areas:** the directories or files it will change, from reading the code —
    as narrow as you can honestly say. They decide what may run in parallel.
  - **Model / effort**, decided for each of the two separately, first match wins:
    1. explicit *Model* / *Effort* in the request (not "From size");
    2. the request's *Size* through the profile's `size_models`
       (e.g. `S=sonnet/low, M=sonnet/medium, L=opus/high, XL=opus/xhigh`);
    3. the profile's `impl_model` / `impl_effort`.

    An FR serving several requests takes the largest size; explicit values that
    disagree → ask. **Explicit model / effort in a request are binding** — whoever
    filed it decided them; never change them. A value derived from the *size* is
    an estimate of the whole request: propose a different one only when the FR
    clearly warrants it (one small FR cut from an `L` request, or a size that
    plainly does not fit the work), mark the deviation in the table with its
    reason, and let the user's confirmation decide.
- Wait for the user to confirm the table. Say what confirming does on GitHub:
  which issue bodies get rewritten, which issues get created, labels, project,
  and the notes to authors (step 3.5).

## 3. Write the FR issues — after the confirmation

*Based on* = `git rev-parse --short=12 origin/<base_branch>`, the commit whose
code you read.

1. **Body** from `${CLAUDE_PLUGIN_ROOT}/templates/fr.md`, every section filled;
   *Open questions* says `None.` unless the user left one open on purpose. Keep
   the headings and the Planning keys in English — `fr.sh` reads them; write the
   text in the language of the issues. Check it against the hard rules before it
   goes out: no credentials, no personal or customer data — requests often hold
   pasted logs: describe instead of copying. Write it to a temporary file outside
   the repository.
2. **Labels** `fr` and `fr-request` must exist in `<repo>`
   (`gh label list -R <repo> --search fr --json name`). Missing → say so, and
   create one only if the user agrees:
   `gh label create fr -R <repo> --description "Feature request, specified"`.
3. **Per FR**, by its *Issue* column:
   - *rewritten* → append the request's body unchanged, as
     `<details><summary>Original request</summary>`, a blank line, the original,
     a blank line, `</details>`. An FR being refined keeps its block as it is.
     `gh issue edit <n> -R <repo> --body-file <file> --add-label fr`, plus
     `--remove-label fr-request` if it has that label, plus `--title` only if the
     user agreed to a new title.
   - *new* → `gh issue create -R <repo> --title "<title>" --body-file <file> --label fr`,
     plus `--parent <request number>` for a sub-issue.
4. **Project** — only with `project` in the profile: `--project "<project>"` on
   `create`, `gh issue edit <n> -R <repo> --add-project "<project>"` for a
   rewritten issue. Missing scope → tell the user to run
   `gh auth refresh -s project`, and go on without.
   Then its board column, when the profile maps it (`project_status`):
   `fr.sh project-status <n> defined` — `input` instead when the user left
   something under *Open questions*. Exit 5 (not written) is a line in the
   report, never a stop.
5. **Notes to authors**, only on issues the current user
   (`gh api user -q .login`) did not open:
   - rewritten → `gh issue comment <n> -R <repo> --body "Worked out into a feature request — see the description. Your original text is kept at its end."`;
   - split or joined → on the request: "Planned as #48, #49." with the FR issues
     that serve it.

## 4. Report

- `fr.sh overlap <FR ids> --no-fetch` for the FRs just written.
- The final table with the issue links; which FRs can start in parallel (wave 1)
  and which must wait, with the reason; which cannot start yet because of open
  questions. Next step: `/fr-workflow:start #47 #48` — one FR, or several at once.
