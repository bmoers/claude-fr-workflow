# Installation

Setting up fr-workflow takes two kinds of work:

| Who | What | How often |
|---|---|---|
| Whoever sets up the repository | add the plugin to the repository, run `/fr-workflow:init`, merge the result | once per repository |
| Every developer | install the prerequisites, open the repository in Claude Code | once per machine |

Nobody installs the plugin by hand. The repository's `.claude/settings.json`
names it, and Claude Code installs it for everyone who opens the repository —
whatever other plugins and skills they use.

## 1. Prerequisites — every developer

| Tool | Needed for | Check |
|---|---|---|
| Claude Code (tested with 2.1.310) | runs the plugin | `claude --version` |
| git | branches and worktrees | `git --version` |
| GitHub CLI `gh`, logged in | PRs, checks, issues, comments | `gh auth status` |
| bash | the plugin's helper script. On Windows: Git Bash, which Claude Code uses anyway | `bash --version` |
| Node.js with `npx` | the bundled Playwright browser for acceptance checks | `npx --version` |

**While the plugin repository is private**, every developer also needs:

- read access to `bmoers/claude-fr-workflow` on GitHub — ask the maintainer
  (Boris Moers);
- git credentials for HTTPS. Test it:
  `git clone https://github.com/bmoers/claude-fr-workflow.git /tmp/frw-test`.
  If git asks for a password, run `gh auth setup-git` once and try again.

## 2. Set up a repository — once

1. **Add the plugin to the repository.** Create or extend `.claude/settings.json`
   (keep any keys that are already there):

   ```json
   {
     "extraKnownMarketplaces": {
       "claude-fr-workflow": {
         "source": { "source": "github", "repo": "bmoers/claude-fr-workflow", "ref": "v0.2.0" }
       }
     },
     "enabledPlugins": { "fr-workflow@claude-fr-workflow": true }
   }
   ```

   `ref` pins a version. Use the newest tag from the [changelog](../CHANGELOG.md).

2. **Start Claude Code in the repository root** (`claude`) and accept the trust
   dialog. Claude Code now installs the plugin. Type `/fr-workflow:` — seven
   commands appear: `init`, `new`, `start`, `ship`, `done`, `status`, `sync`.

3. **Run `/fr-workflow:init`.** It looks at the repository first — CI workflows,
   commit conventions, test commands, an existing requirements folder — and then
   proposes a project profile and asks only what it could not find out, typically:
   the test environment's URL and how to get in, which test accounts to use, and
   whether customers should get a "ready for acceptance" comment on their issues.
   After you confirm, it writes:

   | File | Content |
   |---|---|
   | `.claude/workflow.md` | the project profile — see [profile reference](profile.md) |
   | `req/feature-requests/README.md` | a short explanation for everyone who opens the folder |
   | `.gitignore` | `.claude/worktrees/` and `.playwright-mcp/` |
   | `.claude/settings.json` | the plugin entry from step 1, if it is missing |

   If CI workflows build on every push, it also proposes — as a diff, without
   applying it — to ignore the FR folder on those push triggers, so that planning
   commits do not start builds. It does not commit.

4. **Commit and merge into the base branch** — through a PR if the branch is
   protected. Do this **before the first `/fr-workflow:new`**: every FR branch
   starts from the base branch and must see the profile.

## 3. Every developer — first time

1. Pull the base branch.
2. Start `claude` in the repository root and accept the trust dialog.
3. Check: `/fr-workflow:` shows the seven commands, and `/mcp` lists
   `plugin:fr-workflow:playwright`. If you run your own Playwright server as well,
   disable one of the two in `/mcp`.

Nothing appears? See [troubleshooting](#troubleshooting).

## Updating to a new version

Repositories pin a version, so nobody gets changes by surprise.

1. Read the [changelog](../CHANGELOG.md) for the new tag.
2. Raise `ref` in `.claude/settings.json`, commit, merge.
3. Every developer, after pulling:
   `/plugin marketplace update claude-fr-workflow`, then `/reload-plugins` (or
   start a new session).

## Opting out — one developer

Project settings switch the plugin on for everyone. To switch it off only for
yourself, add to `.claude/settings.local.json` (not committed):

```json
{ "enabledPlugins": { "fr-workflow@claude-fr-workflow": false } }
```

## Removing it from a repository

Remove the two entries from `.claude/settings.json`. Keep `.claude/workflow.md` and
the FR documents — they are plain Markdown and stay readable without the plugin.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Plugin "fr-workflow" is enabled in project settings but isn't installed` | Claude Code could not clone the plugin repository: no read access, or git has no HTTPS credentials | check access, run `gh auth setup-git`, then `/plugin marketplace update claude-fr-workflow` |
| No `/fr-workflow:` commands and no message | the folder is not trusted — Claude Code ignores the plugin entry there without a word | start `claude` in the repository root and accept the trust dialog |
| The plugin is listed under **Errors** in `/plugin` | see the message there | — |
| `profile: MISSING` when a command starts | `/fr-workflow:init` not run, or its result not merged yet | run it, merge it |
| `gh: NOT LOGGED IN` | — | `gh auth login` |
| `npx: command not found` when Playwright starts | Node.js missing, or not on the `PATH` of the terminal that started Claude Code | install Node.js; start `claude` from a terminal where `npx` works |
| Playwright tools appear twice | your own server and the plugin's | disable one in `/mcp` |
| `Workspace not trusted` when `start` launches background sessions | background sessions only run in a trusted folder | run `claude` once in the repository root and accept the trust prompt |
