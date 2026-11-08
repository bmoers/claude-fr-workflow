# Setting up the board

fr-workflow writes a GitHub Projects board when the profile names one: the
plugin's events become the board's column values, and the board is where
people hand FRs to the autopilot. This page is the setup, from a copy of the
reference board to the handful of settings GitHub's API cannot reach.

## The reference layout

Two single-select fields. **Phase** is the column of the Pipeline view, the
stage an FR is in; **Status** is the state inside the phase. A hand-off to the
next phase sets that phase's *Ready*.

| Phase      | Colour | Meaning                                                                      |
| ---------- | ------ | ---------------------------------------------------------------------------- |
| `Backlog`  | yellow | prioritised work items selected for upcoming planning and implementation     |
| `Planning` | pink   | clarify requirements, prepare and approve the implementation plan            |
| `Building` | purple | implement the approved plan, run automated checks and create PRs             |
| `Review`   | blue   | validate technical and visual quality of the PRs against acceptance criteria |
| `Done`     | green  | implementation complete, required PRs merged, ready for release              |

| Status                 | Colour | Meaning                                                                  |
| ---------------------- | ------ | ------------------------------------------------------------------------ |
| `Draft`                | gray   | not ready yet                                                            |
| `Ready`                | yellow | waiting for the responsible agent to start work                          |
| `Running`              | blue   | the agent is actively working on the item                                |
| `Waiting for Input`    | purple | a specific question must be answered before work can continue            |
| `Waiting for Approval` | pink   | the result is ready and awaiting the required approval                   |
| `Complete`             | green  | work in the current phase is complete, including required approvals      |
| `Blocked`              | orange | a dependency or technical issue is preventing progress                   |
| `Failed`               | red    | the agent run ended unsuccessfully and requires investigation or a retry |

Views: **Pipeline** (board, columns by Phase; fields Title, Assignees, Status,
Linked pull requests, Sub-issues progress), **Backlog** (table grouped by
Phase) and **Roadmap**. A fourth view *Needs me* — a table filtered to
`status:"Waiting for Input","Waiting for Approval",Failed,Blocked assignee:@me`
— is the one place that lists everything waiting for a person.

The profile that matches this layout:

```yaml
project: Product Factory
project_status_field: Status
project_phase_field: Phase
project_status: "planning=Planning/Running, defined=Building/Ready, input=Waiting for Input, running=Building/Running, implemented=Building/Complete, review=Review/Ready, shipping=Review/Running, failed=Failed, blocked=Blocked, approval=Review/Waiting for Approval, done=Done/Complete"
```

## 1. Copy the reference board

The fastest way is a copy of a board that already has this layout. Any
project can be marked as a template by its owner; copying it brings the
fields with their colours and descriptions, the views and the configured
workflows (not the auto-add workflow, not the items, not the repository
link). In the project's menu: **Make a copy**, pick the owner and a title. Or
with the API, where `projectId` is the template's node id and `ownerId` the
user or organisation that gets the copy:

```bash
gh api graphql -f query='mutation { copyProjectV2(input: { projectId: "PVT_…", ownerId: "…", title: "Product Factory", includeDraftIssues: false }) { projectV2 { number url } } }'
```

Ids come from `gh api graphql -f query='{ organization(login: "<org>") { id projectV2(number: <n>) { id } } }'`
(or `user(login: …)` for a personal account).

Without a template: create a project, add the two single-select fields with
the options above (`fr.sh project-options` adds missing Status values once the
profile is written; Phase and the colours are set on the field's settings
page), then the three views.

## 2. Link the repository

Copies have no repository link, so the project cannot be chosen from the
repository's issues. On the project page: **Settings → Manage access →
Repositories**, or:

```bash
gh api graphql -f query='mutation { linkProjectV2ToRepository(input: { projectId: "PVT_…", repositoryId: "R_…" }) { repository { nameWithOwner } } }'
```

## 3. Workflows — what the API can and cannot do

GitHub's API reads a project's workflows (name, on/off) and deletes one;
it cannot switch, configure or create them. So:

| Workflow                       | Setting                                                                                                                                                  | How                                                                               |
| ------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| *Auto-close issue*             | **off** — with phases, *Complete* is reached at `implemented`, mid-ship                                                                                  | `fr.sh project-workflow auto-close off` deletes it; `init` offers that            |
| *Item added to project*        | Status `Draft` — a new item is not ready by itself                                                                                                       | Workflows page, by hand (copied with the template)                                |
| *Item closed*                  | Status `Complete` — the safety net for issues closed by hand; the phase stays                                                                            | Workflows page, by hand (copied with the template)                                |
| *Pull request linked to issue* | Status `Running` in the template — the ship session opens the PR, and its event `shipping` writes the same status                                        | Workflows page, by hand (copied with the template)                                |
| *Pull request merged*          | Status `Waiting for Input` in the template — until `finish` (`autopilot_finish`) or `done` writes `Done` / `Complete`; without them the card waits there | Workflows page, by hand (copied with the template)                                |
| *Auto-add to project*          | `is:issue label:fr` on the repository — FR issues someone creates by hand                                                                                | Workflows page, by hand: **not copied with a template**, create it after the link |
| *Auto-add sub-issues*          | as it is                                                                                                                                                 | —                                                                                 |

A built-in workflow sets **one field, the Status** — not the Phase, not two
fields at once ([GitHub's docs](https://docs.github.com/en/issues/planning-and-tracking-with-projects/automating-your-project/using-the-built-in-automations)
describe only the Status; the request for other fields is
[open since 2023](https://github.com/orgs/community/discussions/72181)). So an
item the *Auto-add* workflow brings has no phase until someone sets one; an
FR issue `new` creates gets `Planning` / `Running` from the plugin right after
it is added. *Item added* fires on that addition too and may write its
`Draft` after the plugin: a fresh card showing *Draft* under *Planning* is
that, and the move to *Building / Ready* by hand settles it.

`fr.sh project-options` lists the workflows with on/off and warns when
*Auto-close issue* is on while an event before `done` maps to done's status
value. It cannot see the values a workflow writes: check *Item added* and
*Item closed* on the Workflows page once.

## 4. Check

- `fr.sh check` names the project and the status column.
- `fr.sh project-options` shows every value present and the workflows.
- `fr.sh project-status <issue> defined` on a test issue moves its card to
  *Building / Ready*; `… done` to *Done / Complete*.
- Mark an FR issue *Building / Ready* and assign it: with
  `autopilot_queue: project`, `fr.sh queue sync` lists it.

## Manual steps, as a checklist

What no command does, once per board:

1. Create the *Auto-add to project* workflow with `is:issue label:fr` for the
   repository (and `label:fr-request` if requests go on the board too).
2. Open *Item added to project* and *Item closed* and confirm the values
   (Status `Draft`, Status `Complete` — a workflow cannot set the Phase).
3. Add the *Needs me* view if the team wants one.
4. Give the project a description.
