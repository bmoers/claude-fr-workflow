---
name: idea
description: Turn an idea into a well-formed GitHub issue by talking it through — the same fields as the repository's issue form, including size, model and effort — then plan it into FRs right away.
argument-hint: "[the idea in a few words]"
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: idea — from a conversation to an issue

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` and `.claude/workflow.md`.
`${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` must pass.

Idea: $ARGUMENTS

The issue this produces is the same kind of issue a customer files through the
form on GitHub — one definition, two ways in.

## 1. The fields

Take them from the repository's issue form: the `.github/ISSUE_TEMPLATE/*.yml`
file whose `labels` contain `fr-request`; none → `${CLAUDE_PLUGIN_ROOT}/templates/issue-form.yml`.
Use its labels, options and required flags as they are — a team may have adapted
the form, and the conversation follows it.

## 2. Talk it through

- Start from what the user said; ask about the required fields that are still
  open, a few at a time, not as a questionnaire.
- Read code where it helps to judge feasibility and size — read only.
- Push for checkable *How do we know it is done* sentences: each one must later be
  verifiable by someone who did not write the code.
- **Size:** propose one of the form's options with a one-line reason; explicit
  **model** and **effort** only when the user wants to override what the size
  gives (`size_models` in the profile).
- Never put credentials, tokens or personal data into the issue.

## 3. Create the issue — after the user confirmed it

- Show title and body. The body uses the form's rendering: one `### <label>`
  heading per field, in the form's order, the value below it, `_No response_` for
  an empty optional field — so `new` reads both kinds of issue the same way.
- `gh issue create -R <repo> --title "<title>" --body-file <file> --label fr-request`
  (`<repo>` = `issue_repo` from the profile, else this repository). The label does
  not exist yet → say so, and create it only if the user agrees
  (`gh label create fr-request -R <repo>`), else create the issue without it.

## 4. Plan it right away

Continue with `${CLAUDE_PLUGIN_ROOT}/skills/new/SKILL.md` for the new issue, in this
same session — read that file and follow its steps. The discussion has happened
already, so `new` goes straight to the cut table; it still waits for the user's
confirmation of that table.
