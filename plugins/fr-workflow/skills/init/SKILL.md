---
name: init
description: Set up the fr-workflow in this repository — project profile, FR folder, plugin settings for the whole team. Run once per repository.
disable-model-invocation: true
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh *)
---

# fr-workflow: init

Read `${CLAUDE_PLUGIN_ROOT}/reference/model.md` first.

Goal: afterwards every developer who trusts this repository gets the plugin and
the same workflow, whatever else they have installed.

## 1. Inspect before asking

Derive what you can from the repository; ask only for what you cannot.

- `${CLAUDE_PLUGIN_ROOT}/scripts/fr.sh check` — a missing profile is expected here.
- Base branch: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- An existing FR or requirements folder (`req/`, `docs/requirements/`, …)? Reuse
  its location and prefix. Existing FR docs without frontmatter stay untouched;
  `fr.sh` ignores them.
- `.github/workflows/*.yml`: what runs on `pull_request`; what deploys
  (`environment:`, `deploy`, `workflow_run`); whether a deploy posts or updates a
  PR comment; preview URLs.
- **Builds from planning pushes.** `:new` and `:start` push commits that change
  only `<fr_dir>`. Find workflows with an `on: push` trigger that matches FR
  branches (no `branches:` filter, or a wildcard). For those, propose as a diff —
  never apply it — `paths-ignore: ['<fr_dir>/**']` on the **`push`** trigger. Never
  on `pull_request`: required checks of a PR that skips them stay pending and
  block the merge. Never suggest CI skip markers (see the hard rules). Also note
  services outside Actions that build every branch (Vercel, Netlify branch
  deploys) — their ignore settings are the project's call. Record the outcome in
  the profile's *CI* section.
- Conventions: `commitlint.config.*`, husky hooks, PR-title lint, `CONTRIBUTING.md`.
- Fast local checks: `package.json` scripts, `Makefile`, `pyproject.toml`.
- `CLAUDE.md` rules on production, deployments, git.

## 2. Propose the profile

Fill `${CLAUDE_PLUGIN_ROOT}/templates/workflow.md` with your findings. Pick
`deploy_signal`:

- `pr-checks` — the deployment is a check or status on the PR (preview deploys).
- `pr-comment` — a separate workflow posts or updates a PR comment when it has
  deployed; take both markers from that workflow.
- `url` — the test environment reports its commit SHA (`/version`, `/health`, …).
  The most robust signal when it exists.
- `none` — no test environment per PR; `:ship` then ends after CI.

Also propose:

- `test_env`: `per-pr` when every PR gets its own preview; otherwise `shared`.
- `shared_paths`: what every change tends to touch — lockfiles, a migrations
  folder, translation files, a central route or DI registry. Look at which files
  appear in many recent merged PRs (`git log --name-only` on the base branch).
- `impl_model` / `impl_effort`: `opus` / `high` unless the user wants otherwise.

Show the proposed profile and all open questions in one message. Typical ones:
test environment URL and how to get in, test accounts (names or roles, never
passwords), `issue_repo`, whether `notify_issues` is wanted. For project rules,
point to the `CLAUDE.md` sections instead of copying them.

## 3. Write — after the user confirmed

- `.claude/workflow.md` — the profile.
- `<fr_dir>/README.md` from `${CLAUDE_PLUGIN_ROOT}/templates/fr-readme.md`. If a
  README exists there, propose a short section instead.
- `.gitignore`: make sure `.claude/worktrees/` and `.playwright-mcp/` are listed.
- `.claude/settings.json` — merge into the existing JSON, never drop keys:

  ```json
  {
    "extraKnownMarketplaces": {
      "claude-fr-workflow": {
        "source": { "source": "github", "repo": "bmoers/claude-fr-workflow", "ref": "v<version>" }
      }
    },
    "enabledPlugins": { "fr-workflow@claude-fr-workflow": true }
  }
  ```

  `<version>` is `version` in `${CLAUDE_PLUGIN_ROOT}/.claude-plugin/plugin.json`.
  The pin keeps every developer on the same tested version; raise it on purpose.
- `fr.sh check` again — it must pass now.

## 4. Hand over

Do not commit unless the user asks. Report:

- the files written, and the proposed CI diff if there is one;
- that these changes must be **committed and merged into `<base_branch>` before
  the first `/fr-workflow:new`** — every FR branch starts from
  `origin/<base_branch>` and must see the profile;
- that teammates need read access to `bmoers/claude-fr-workflow` while it is
  private;
- the next step: `/fr-workflow:new <issues>`.
