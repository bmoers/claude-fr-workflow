# Feature requests

This folder holds the feature requests (FRs) of this project, managed with the
`fr-workflow` plugin for Claude Code.

- A **request** is what someone asked for: a GitHub issue with the label
  `fr-request`. An **FR** is the unit of work: a GitHub issue with the label
  `fr` that holds the full spec — one branch, one PR. `FR-47` is issue #47.
- Until an FR is started, its issue is the spec. `/fr-workflow:start` writes it
  into a document here, on the FR's branch; from then on that document is the
  source, and it reaches the base branch with the merge.
- For an overview that includes FRs not started or not merged yet, run
  `/fr-workflow:status`.

| Step                                                 | Command                          |
| ---------------------------------------------------- | -------------------------------- |
| Define: an idea or issues → FR issues with full spec | `/fr-workflow:new <idea or #12>` |
| Implement, in its own worktree                       | `/fr-workflow:start #47`         |
| Review, PR, CI, test deployment, acceptance check    | `/fr-workflow:ship`              |
| After the merge: close served requests, clean up     | `/fr-workflow:done #47`          |
| Drop an FR instead                                   | `/fr-workflow:done #47 drop`     |

Project-specific settings: `.claude/workflow.md`.
