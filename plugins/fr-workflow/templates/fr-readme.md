# Feature requests

This folder holds the feature requests (FRs) of this project, managed with the
`fr-workflow` plugin for Claude Code.

- An **FR** is the unit of work: a spec with acceptance criteria, one branch, one
  PR. **Issues** describe what was asked for. FRs and issues are linked m:n
  through the `issues:` line in each FR's frontmatter.
- The frontmatter is the source of truth. Every linked issue carries a comment
  listing its FRs — generated, do not edit it.
- An FR doc lives on its FR branch until the PR is merged. For an overview that
  includes unmerged FRs, run `/fr-workflow:status`.

| Step                                                   | Command                         |
| ------------------------------------------------------ | ------------------------------- |
| Plan: discuss issues, write one or more FRs            | `/fr-workflow:new <issues…>`    |
| Implement, in its own worktree                         | `/fr-workflow:start FR-012`     |
| Review, PR, CI, test deployment, acceptance check      | `/fr-workflow:ship`             |
| After the merge: close served issues, clean up         | `/fr-workflow:done FR-012`      |
| Drop an FR instead                                     | `/fr-workflow:done FR-012 drop` |
| Refresh the issue comments after editing an FR by hand | `/fr-workflow:sync FR-012`      |

Project-specific settings: `.claude/workflow.md`.
