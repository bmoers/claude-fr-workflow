---
name: new
description: Plan feature requests from GitHub issues and/or a discussion — one or more FR docs, m:n linked to issues, each on its own pushed branch. Session 1 of the workflow.
argument-hint: "[#12 owner/repo#15 label:… milestone:… project:owner/N search:… or a description]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: new — plan FRs

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` must pass, else point to
`/fr-workflow:init`.

Input: $ARGUMENTS

## 1. Collect

Any mix of:

- Issue refs `#12`, `owner/repo#12`, issue URLs →
  `gh issue view <n> -R <repo> --json number,title,body,labels,comments,url`.
  Default repo: `issue_repo` from the profile, else this repository.
- `label:<name>` / `milestone:<name>` → `gh issue list -R <repo> --state open --limit 200 --label … / --milestone …`.
- `project:<owner>/<number>` → `gh project item-list <number> --owner <owner> --limit 200 --format json`,
  issues only; apply a status or view filter if the user names one.
- `search:<query>` → `gh issue list -R <repo> --limit 200 --search "<query>"`.
- A list that reaches the limit is incomplete: say so and ask to narrow the
  selection — never plan from a silently cut list.
- A local file — notes, a requirements document, an FR draft, a legacy FR without
  frontmatter → read it as the source. The new FR gets a new id; name the source
  file in its *Technical notes*. Do not modify or move the source file.
- A description in the conversation, without any issue.

For every issue also run `fr.sh issue-frs <ref>` — it may be served by FRs already.

**Issues from the form** (filed on GitHub, or by `/fr-workflow:idea`) have one
`### <label>` section per field of `.github/ISSUE_TEMPLATE/*.yml` (the form
labelled `fr-request`; else `${CLAUDE_PLUGIN_ROOT}/templates/issue-form.yml`).
Map them: *Problem or need* → Problem / motivation; *Who is affected* and *Desired
behaviour* → Desired behaviour; *How do we know it is done* → the acceptance
criteria, rewritten so each one is checkable; *Size*, *Model*, *Effort* → model and
effort (step 2). `_No response_` means empty. An issue without this structure is
fine too — then the discussion has to fill those gaps.

## 2. Discuss — this session is for thinking, not for code

- Summarize what was asked, per issue, in a few lines. Name contradictions, gaps
  and risks.
- Read code where it helps to judge scope — read only.
- Ask the open questions; iterate until the scope is clear.
- Propose the cut. This table is where m:n gets decided:

  | FR | Title | Issues | Type | Areas | Model / effort |
  |---|---|---|---|---|---|
  | FR-012 | … | #12, #15 | feat | src/checkout | opus / high |
  | FR-013 | … | #12 | fix | src/invoice/pdf | sonnet / medium |

  One FR = one PR that can be reviewed and accepted on its own. Split an issue
  that mixes independent changes; join issues that are the same change.
  - **Areas:** the directories or files it will change, from reading the code —
    as narrow as you can honestly say. They decide what may run in parallel.
  - **Model / effort**, decided for each of the two separately, first match wins:
    1. explicit *Model* / *Effort* in the FR's issue(s) (not "From size");
    2. the issue's *Size* through the profile's `size_models`
       (e.g. `S=sonnet/low, M=sonnet/medium, L=opus/high, XL=opus/xhigh`);
    3. the profile's `impl_model` / `impl_effort`.

    An FR serving several issues takes the largest size; explicit values that
    disagree → ask.

    **Explicit model / effort in an issue are binding** — whoever filed it decided
    them; never change them. A value derived from the *size* is an estimate of the
    whole request: propose a different one only when the FR clearly warrants it
    (one small FR cut from an `L` issue, or a size that plainly does not fit the
    work), mark the deviation in the table with its reason, and let the user's
    confirmation decide.
- Wait for the user to confirm the table. Say that confirming creates and pushes
  one new branch per FR — off `origin/<base_branch>`, never on their current
  branch or the base branch — and, with `backlinks: on`, comments on the listed
  issues.

## 3. Write each FR

One after another, so ids cannot collide:

1. `fr.sh next-id` (`--no-fetch` from the second call on).
2. Branch name from `branch_pattern`; slug = 3–5 words of the title, lowercase
   ASCII joined with `-` (ä→ae, ö→oe, ü→ue, ß→ss, accents dropped). The file name
   uses the same slug.
3. Create it without touching the user's checkout:
   `git worktree add -b <branch> .claude/worktrees/_new-<id-lower> origin/<base_branch>`
4. There, write `<fr_dir>/<ID>-<slug>.md` from `${CLAUDE_PLUGIN_ROOT}/templates/fr.md`:
   frontmatter with `status: open`, canonical `issues`, `areas`, `model`,
   `effort`, `created` = today; the sections from the discussion. Acceptance
   criteria must be checkable on the test environment by someone who did not
   write the code. Never copy credentials, tokens or personal data from issues
   into the FR doc — issue bodies often hold pasted logs; describe instead.
5. Commit with the project's convention (default `docs(fr): add <ID> <title>`).
   After the commit, before pushing: check the doc for credentials or personal
   data, and run the profile's secret scan on the commit if there is one — the
   documented scans work on a commit range, so they see nothing before the commit.
   Right before pushing, `fr.sh list` (with fetch): if a teammate pushed the same
   id meanwhile, renumber this FR (`fr.sh next-id`; rename file, branch, id) first.
   Then `git push -u origin <branch>`.
6. `git worktree remove .claude/worktrees/_new-<id-lower>` — it is clean after the
   commit; never `--force`.

## 4. Link and report

- `fr.sh sync-fr <ids of the new FRs> --no-fetch`, unless `backlinks: off`.
- `fr.sh overlap <ids of the new FRs> --no-fetch`.
- Report the final table with branch names, and which FRs can run in parallel
  (wave 1) and which must wait, with the reason. Next step:
  `/fr-workflow:start <ids of wave 1>` — one FR, or several at once.
