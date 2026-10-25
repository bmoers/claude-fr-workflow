# claude-fr-workflow

A Claude Code plugin for a feature-request workflow in GitHub projects. It
carries one way of working from project to project, independent of what else a
developer has installed.

```
issues ──m:n── FR docs ──► one branch + worktree per FR ──► ship ──► merge (human) ──► done
                                                            │
                     review gate · PR · CI · test deployment · acceptance check
```

| Command | Session | Does |
|---|---|---|
| `/fr-workflow:init` | once per repo | project profile, FR folder, team settings |
| `/fr-workflow:new` | 1 — plan | issues and/or discussion → one or more FR docs, each on a pushed branch, issues get a backlink |
| `/fr-workflow:start` | 2 — build | worktree for the FR, status `in-progress` |
| `/fr-workflow:ship` | 2 — finish | review gate → PR → CI → test deployment → acceptance check → results into the FR doc |
| `/fr-workflow:done` | after merge | backlinks, close fully served issues (asks first), clean up |
| `/fr-workflow:status` | any | overview of all FRs, including unmerged ones |

The model and the rules every command follows: [`reference/model.md`](plugins/fr-workflow/reference/model.md).

## Design decisions

- **The FR frontmatter is the single source of truth** for the m:n link. The
  backlink comment on each issue is derived by `scripts/fr.sh` and can be
  regenerated at any time.
- **`Refs`, never `Closes`.** With m:n the first merge would close an issue other
  FRs still serve. `:done` closes issues when all their FRs are merged.
- **No shared index file.** A table edited in every PR conflicts and drifts;
  `:status` derives the overview.
- **`merged` is derived, not written** — nothing needs to be committed to a
  protected base branch after a merge.
- **Project facts live in the project** (`.claude/workflow.md`), the process lives
  here. The plugin contains nothing customer-specific.
- **Hard limits:** never merges, never triggers deployments, never touches
  production, never handles credentials.

## Requirements

Claude Code, `git`, an authenticated [`gh`](https://cli.github.com), `bash`
(Git Bash on Windows) and Node/`npx` for the bundled Playwright MCP server. If a
developer already runs their own Playwright server, they can disable the plugin's
one in `/mcp`.

## Use it in a repository

Run `/fr-workflow:init` in the repository. It writes the profile and adds this to
the repository's `.claude/settings.json`, so every teammate who trusts the folder
gets the plugin:

```json
{
  "extraKnownMarketplaces": {
    "claude-fr-workflow": {
      "source": { "source": "github", "repo": "bmoers/claude-fr-workflow", "ref": "v0.1.0" }
    }
  },
  "enabledPlugins": { "fr-workflow@claude-fr-workflow": true }
}
```

To try it before that: `/plugin marketplace add bmoers/claude-fr-workflow`, then
`/plugin install fr-workflow@claude-fr-workflow`.

**Private repository:** every developer needs read access. Background
auto-updates of a private marketplace need `GITHUB_TOKEN` in the environment;
with a pinned `ref` updates are deliberate anyway — raise the tag in the project's
settings.

## Versioning

Tags `vX.Y.Z`; projects pin a tag. Changes go into [`CHANGELOG.md`](CHANGELOG.md).
Raise `version` in `plugins/fr-workflow/.claude-plugin/plugin.json` with every tag.
