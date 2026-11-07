# Running the autopilot in a container

This is the manual for the fr-workflow autopilot container: what it is, how
to start it on your laptop, how to see that it works, and how to give it
work. The [reference](#reference) at the end has every variable and the
details for running it as a pod.

## What it is, in plain words

The autopilot is the part of fr-workflow that moves feature requests from
the board through implementation, review and pull request without someone
typing the next command. It runs as a background Claude Code session, and a
background session dies when the terminal that started it closes.

The container removes the terminal. It is a small Linux machine that runs
inside Docker on your laptop (later on a server), with Claude Code, GitHub's
command-line tool and a browser already installed. When it starts, it clones
your repository, makes sure the fr-workflow plugin is installed at the
version your repository pins, and starts the autopilot. Every five minutes
it checks that the autopilot is still there and starts a new one if not.

Everything the container does happens under **your** accounts: your Claude
subscription pays for the sessions, your GitHub login writes the commits and
pull requests. Nothing about your project is inside the container image; it
reads your repository's `.claude/workflow.md` like any developer's machine.

## Before you start

- Docker Desktop or OrbStack is installed and running (`docker version`
  prints a server version).
- The repository you want to run uses fr-workflow: it pins a plugin version
  in `.claude/settings.json` and has a profile `.claude/workflow.md` with
  `autopilot_queue: project`, so the board feeds the queue — see
  [the profile reference](profile.md#autopilot-queue-from-the-board).
- The repository ignores `.claude/workflow.local.md` (`init` adds it to
  `.gitignore`); the container writes your per-machine values there.
- You have a Claude subscription (Pro, Max, Ultra, Team or Enterprise) and
  the `gh` command is logged in to GitHub on your laptop.

## Step 1 — Create your two tokens

The container cannot open a browser to log in, so it needs two tokens from
you. Put them into one file that only you can read. Pick a path outside any
repository, for example `~/.config/fr-autopilot.env`.

**Claude token.** In a terminal, run:

```bash
claude setup-token
```

A browser window opens; approve the access. The command then prints a long
token that is valid for one year and works only for model requests under
your subscription. Copy it into the file as the value of
`CLAUDE_CODE_OAUTH_TOKEN`:

```
CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat01-…
```

**GitHub token.** The simplest is the token your `gh` command already uses.
Make sure it has the scopes the autopilot needs, then append it:

```bash
gh auth refresh -s repo,workflow,project,read:org
printf 'GH_TOKEN=%s\n' "$(gh auth token)" >> ~/.config/fr-autopilot.env
chmod 600 ~/.config/fr-autopilot.env
```

If you prefer a separate token, create a classic personal access token at
https://github.com/settings/tokens/new with the scopes `repo`, `workflow`,
`project` and `read:org`, and put it in the file as `GH_TOKEN=…`. Classic,
because fine-grained tokens do not reliably reach organisation projects.
If your organisation enforces SSO, authorise the token for it.

Two rules: one person per token pair, and never commit the file.

## Step 2 — Get the image

The image is published for every plugin release. Use the tag your repository
pins; the two belong together:

```bash
docker pull ghcr.io/bmoers/fr-workflow-autopilot:v0.8.0
```

Or build it yourself from the same tag, without a checkout of this
repository:

```bash
docker build -t ghcr.io/bmoers/fr-workflow-autopilot:v0.8.0 \
  'https://github.com/bmoers/claude-fr-workflow.git#v0.8.0:docker'
```

The image is about 3 GB; the browser is most of it.

## Step 3 — Start the container

```bash
docker run -d --name fr-autopilot --restart unless-stopped \
  -v fr-autopilot:/home/pwuser \
  --env-file ~/.config/fr-autopilot.env \
  -e REPO=acme/shop \
  ghcr.io/bmoers/fr-workflow-autopilot:v0.8.0
```

What the parts mean:

| Part                           | Meaning                                                                                                                           |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| `-d --name fr-autopilot`       | runs in the background under this name                                                                                            |
| `--restart unless-stopped`     | Docker starts it again after a reboot, unless you stopped it yourself                                                             |
| `-v fr-autopilot:/home/pwuser` | a Docker volume for everything that must survive a restart: the clone, Claude Code's state, the plugin. Named after the container |
| `--env-file …`                 | your two tokens                                                                                                                   |
| `-e REPO=acme/shop`            | the repository, as `owner/name` on GitHub                                                                                         |

By default the container takes the FRs assigned to the GitHub login behind
`GH_TOKEN`. To run it for a different login, or for the unassigned FRs, add
`-e AUTOPILOT_ASSIGNEE=<login>` or `-e AUTOPILOT_ASSIGNEE=none`.

## Step 4 — Check that it works

```bash
docker logs -f fr-autopilot
```

Within about half a minute you should see lines like these, then nothing
more until something happens:

```
GitHub: boris, repository acme/shop
checkout: /home/pwuser/work/shop at main
local profile: autopilot_assignee boris
marketplace claude-fr-workflow: registered from bmoers/claude-fr-workflow#v0.8.0
Claude Code 2.1.319 (Claude Code)
plugin: /home/pwuser/.claude/plugins/cache/claude-fr-workflow/fr-workflow/0.8.0/scripts/fr.sh
launched autopilot as 6705cf6e (fr-autopilot): claude logs 6705cf6e
```

Press `Ctrl+C` to stop following; the container keeps running. If a line
starts with `fr-autopilot:` instead, something is missing — see
[troubleshooting](#troubleshooting).

To see the Claude sessions inside the container:

```bash
docker exec fr-autopilot claude agents --json
```

One session named `fr-autopilot` with `"status": "busy"` is the autopilot
waiting for work. To read what it is doing:

```bash
docker exec fr-autopilot claude logs <id>
```

With an empty board it reports that the queue is empty and waits; that is
correct.

## Step 5 — Give it work

Nothing in the container decides what to build. The board does:

1. Define the FR as always, with `/fr-workflow:new` — the issue with the
   label `fr` lands on the board.
2. When the specification is complete, move the card to the square the
   profile maps `defined` to — *Building / Ready* on a board with phases —
   and **assign the issue to the login the container serves**. An unassigned
   FR is for the container running with `AUTOPILOT_ASSIGNEE=none`, if there
   is one.

Within a minute the autopilot takes the FR: the local log says
`queued board <login>`, the card moves to *Running*, a branch and a worktree
appear, an implementation session starts. From there everything happens as
[the usage guide](usage.md#autopilot-fr-workflowautopilot-20-21-22-23)
describes: the ship session reviews, opens the pull request, runs the
acceptance check, and with `auto_merge: auto` asks GitHub to merge; after the
merge the autopilot cleans up and the card reaches *Done*.

You see progress in three places: the board, the pull request, and
`docker exec fr-autopilot claude agents --json`. A session that needs you —
a gate that stopped, a question — is reported by the autopilot; the profile's
`notify_command` sends it to your channel with the command to join the
session, copy-ready for your laptop (the container writes `attach_command`
for that; name the container with `ATTACH_CONTAINER=fr-autopilot` so the
command uses the name instead of the id). Point `notify_command` at a webhook
or a chat; a desktop notifier has no desktop inside a container. With
`stop_comments: on` in the profile the ask is also on the FR issue, and you
answer with a comment: `accept all`, `accept 1,3`, `fix 2` or `abort`. A
comment posted under your own token does not notify you — the chat is the
push, the issue the record.

## Step 6 — Look inside, stop, restart

| You want to                       | Command                                                          |
| --------------------------------- | ---------------------------------------------------------------- |
| see the entrypoint's log          | `docker logs -f fr-autopilot`                                    |
| list the sessions                 | `docker exec fr-autopilot claude agents --json`                  |
| read a session's transcript       | `docker exec fr-autopilot claude logs <id>`                      |
| join a session that waits for you | `docker exec -it fr-autopilot claude attach <id>`                |
| run an fr-workflow command inside | `docker exec -it fr-autopilot claude` then `/fr-workflow:status` |
| stop everything                   | `docker stop fr-autopilot`                                       |
| start it again                    | `docker start fr-autopilot`                                      |
| remove it, keep the state         | `docker rm fr-autopilot` — the volume stays                      |
| remove the state too              | `docker volume rm fr-autopilot`                                  |

Two things to know when you attach: quitting the attached session ends it.
For the autopilot that is harmless — the keep-alive starts a fresh one within
five minutes — but an implementation or ship session you quit is gone, and
the pipeline reports the FR as stalled. Leave an attached session by
detaching, not by exiting.

Stopping the container ends every session in it. Nothing is lost: an FR's
state is in git and on GitHub, the autopilot's notes in the volume. On the
next start a new autopilot reads the branches and the board as they are and
continues — a session that was in the middle of implementing is reported as
stalled, and `/fr-workflow:start <ID>` resumes it.

## Updating to a new plugin version

A plugin release brings an image with the same tag. When the repository's pin
moves to `v0.9.0`:

1. Wait until no FR of this container is in flight (board: nothing of yours
   on *Running*).
2. `docker rm -f fr-autopilot` and `docker volume rm fr-autopilot` — the
   container registered the old plugin version, and a fresh volume is the
   clean way to forget it.
3. Start it again as in step 3 with the new image tag.

## Troubleshooting

| What you see                                                         | Cause                                                                                                                                 | Fix                                                                                                    |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `fr-autopilot: GH_TOKEN is not set` (or `REPO`, or the Claude token) | the env file lacks it, or `--env-file` points elsewhere                                                                               | check the file: `grep -c = ~/.config/fr-autopilot.env` shows 2                                         |
| `fr-autopilot: GH_TOKEN is not accepted by GitHub`                   | the token is wrong, expired, or not authorised for the organisation (SSO)                                                             | `gh auth refresh`, then write the token again                                                          |
| `fr-autopilot: CLAUDE_CODE_OAUTH_TOKEN is not accepted`              | the token is wrong or revoked                                                                                                         | `claude setup-token` again                                                                             |
| `warning: … does not ignore .claude/workflow.local.md`               | the repository's `.gitignore` lacks the entry                                                                                         | add it (a `/fr-workflow:init` run proposes it); until then the profile's `autopilot_assignee` applies  |
| `fr-autopilot: fr-workflow is not installed`                         | the marketplace could not be registered — no read access to it, or the pin in `.claude/settings.json` names a tag that does not exist | check the pin, check that `GH_TOKEN` can read the plugin repository                                    |
| `launch failed (…)` repeating in the log                             | `fr.sh launch autopilot` fails — the message says why                                                                                 | `docker exec -it fr-autopilot claude` and run `/fr-workflow:status` in `~/work/<repo>`                 |
| the autopilot takes no FR                                            | the card is not on the `defined` square, or not assigned to this login                                                                | compare with `docker exec fr-autopilot claude logs <id>`: it names the square and the login it watches |
| `claude agents` shows nothing                                        | it needs a terminal                                                                                                                   | add `-it`, or use `claude agents --json`                                                               |
| a session is `waiting`                                               | it needs you — a stopped gate, a question                                                                                             | `docker exec -it fr-autopilot claude attach <id>`                                                      |

## Reference

### What is in the image

| Part        | What                                                                                                                                                                                               |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Base        | Microsoft's Playwright image (`mcr.microsoft.com/playwright:v<version>-noble`): Node, Chromium and the libraries a browser needs, Xvfb, user `pwuser`                                              |
| Claude Code | `@anthropic-ai/claude-code` pinned by build arg; updates off (`DISABLE_AUTOUPDATER=1`) — a newer Claude Code is a new image                                                                        |
| GitHub      | `gh` from its release package, checksum verified; `git`                                                                                                                                            |
| Tools       | `jq` for the entrypoint and `fr.sh`, `tini` to reap the sessions' processes                                                                                                                        |
| Entrypoint  | `/usr/local/bin/fr-autopilot` ([`docker/entrypoint.sh`](../docker/entrypoint.sh)), run under `xvfb-run` so the plugin's Playwright server has a display and the browser runs headed as on a laptop |
| Runs as     | `pwuser` (uid 1001), home `/home/pwuser` — the volume; `docker exec` lands in `/home/pwuser/work`, which is trusted                                                                                |

Nothing project-specific. A project that needs more — a runtime for its
tests, its own Playwright configuration, a notification script — builds its
own image `FROM` this one.

| Build arg             | Default   | What                                                   |
| --------------------- | --------- | ------------------------------------------------------ |
| `PLAYWRIGHT_VERSION`  | `1.65.0`  | tag of the Playwright base image                       |
| `CLAUDE_CODE_VERSION` | `2.1.319` | the Claude Code release in the image                   |
| `GH_VERSION`          | `2.103.3` | the `gh` release — `fr.sh project-status` needs ≥ 2.97 |

The workflow [`image.yml`](../.github/workflows/image.yml) builds the image
for `linux/arm64` and `linux/amd64` on every release tag and publishes it as
`ghcr.io/bmoers/fr-workflow-autopilot:<tag>` — the release tag as it is and
the commit, never a moving `latest`. Pushes and pull requests that touch
`docker/` build it without publishing.

### Environment

| Variable                  | Required | What                                                                                                                                                                                           |
| ------------------------- | -------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `REPO`                    | yes      | `owner/name` on GitHub                                                                                                                                                                         |
| `GH_TOKEN`                | yes      | token for `gh` and `git`                                                                                                                                                                       |
| `CLAUDE_CODE_OAUTH_TOKEN` | yes      | from `claude setup-token`                                                                                                                                                                      |
| `AUTOPILOT_ASSIGNEE`      | —        | the login whose FRs this container takes, `none` for unassigned ones; default: the token's login. Written to `.claude/workflow.local.md` — [per-machine values](profile.md#per-machine-values) |
| `WORKFLOW_LOCAL`          | —        | more per-machine profile lines (`key: value`, one per line), e.g. `notify_command: scripts/notify-chat.sh`                                                                                     |
| `ATTACH_CONTAINER`        | —        | the container's name on the host, used in the attach command of notifications and stop comments; default: the container id                                                                     |
| `REPO_REF`                | —        | branch to keep checked out; default: the default branch                                                                                                                                        |
| `KEEPALIVE_SECONDS`       | —        | pause between launch attempts, default `300`                                                                                                                                                   |
| `MARKETPLACE`             | —        | register this plugin marketplace instead of the ones in the repository's `.claude/settings.json` — see [testing an unreleased plugin](#testing-an-unreleased-plugin)                           |
| `AUTO_MODE_ENVIRONMENT`   | —        | extra lines for the classifier's `autoMode.environment`, one per line, written once                                                                                                            |

Commands: `run` (default) prepares and loops; `once` prepares, launches once
and exits; `check` prepares and runs `fr.sh check` — the smoke test:

```bash
docker run --rm -v fr-autopilot:/home/pwuser --env-file … -e REPO=acme/shop ghcr.io/bmoers/fr-workflow-autopilot:v0.8.0 check
```

### What the entrypoint does

Every start, in this order, each step idempotent:

1. `gh auth status` with `GH_TOKEN` — a rejected token stops here.
   `gh auth setup-git`, so git pushes with the same token; the commit identity
   from `gh api user` unless the volume already has one.
2. Clone `REPO` into `~/work/<name>`, or `fetch --prune` and `pull --ff-only`
   the existing clone. The main checkout is only read — FR work happens in
   worktrees under `.claude/worktrees/`, as everywhere.
3. `.claude/workflow.local.md` with `autopilot_assignee`, `attach_command`
   (`docker exec -it -w <clone> <container> claude attach`) and
   `WORKFLOW_LOCAL`, if the repository ignores that file; otherwise a warning
   and the profile's values apply.
4. Trust for the clone and for `~/work` in `~/.claude.json` — the dialog no
   background session can answer.
5. The plugin marketplaces named in the repository's `.claude/settings.json`
   (`extraKnownMarketplaces`, with their `ref`), registered once; the enabled
   plugins installed at project scope. A changed `.claude/settings.json`
   afterwards is reverted — the repository's pin rules.
6. `~/.claude/settings.json`, written once if absent: `autoMode.environment`
   says what this container is (host containment, the source-control
   organisation), `autoMode.allow` names `fr.sh merge` — see
   [auto mode](#auto-mode-in-the-container).
7. `claude auth status` — a rejected `CLAUDE_CODE_OAUTH_TOKEN` stops here.
8. The loop: `fr.sh launch autopilot` of the installed plugin. Exit 0 =
   launched (logged), exit 3 = one runs, anything else is logged and tried
   again after the pause. The autopilot itself works as always:
   `/fr-workflow:autopilot --loop` with the profile's model, effort and
   `session_permission_mode`.

The entrypoint never prints a token, and never writes one anywhere but the
process environment it was given.

### Auto mode in the container

A background session cannot answer a permission prompt, so the profile sets
`session_permission_mode: auto`: Claude Code's classifier decides. It blocks
*merging a pull request no human has approved* by default — `fr.sh merge` is
exactly that in its eyes, and a session without an allow rule was refused in
the sandbox. The ship skill carries its own `allowed-tools` rule for `fr.sh`,
which resolves before the classifier; the entrypoint adds, in the container's
user settings, an `autoMode.allow` entry saying what `fr.sh merge` does and
that the base branch's ruleset decides. The classifier reads `autoMode` only
from user settings — never from a repository's `.claude/settings.json`, so a
checked-in file cannot loosen it. Edit the file on the volume to change it.

### Testing an unreleased plugin

The marketplace may be a folder: mount a working copy of this repository and
name it — the repository's own marketplace entry is skipped because one with
that name is already known:

```bash
docker run --rm -v fr-autopilot-test:/home/pwuser --env-file … \
  -e REPO=bmoers/fr-workflow-sandbox \
  -v "$PWD":/mnt/claude-fr-workflow:ro -e MARKETPLACE=/mnt/claude-fr-workflow \
  fr-workflow-autopilot:dev check
```

Use a separate volume for this: a registered marketplace stays registered.
With a folder marketplace the skills run from the mounted folder itself
(`${CLAUDE_PLUGIN_ROOT}` points there), so keep the mount on every start.

### Several containers, one repository

With `autopilot_queue: project`, each container takes the FRs on the board's
*defined* square that are assigned to its `autopilot_assignee` — one container
per developer with that developer's own tokens and quota, a shared one with
`AUTOPILOT_ASSIGNEE=none` for unassigned FRs. What one container starts is on
`origin` — the branch, the FR document — and counts in every other
container's waves and overlap checks. Two containers for the same login would
race: one per login.

### Running as a pod

Same image, same entrypoint. The environment comes from a Secret, the home
from a PersistentVolumeClaim (`fsGroup: 1001`), one replica. A shared
container's GitHub identity should be a GitHub App rather than a person's
token; minting and renewing its installation token is the project's job
(a sidecar or CronJob that rewrites the Secret — the entrypoint reads
`GH_TOKEN` at start, so a rotation is a restart). The Claude token is still
one person's: a shared autopilot needs a seat of its own.

### Limits

- Playwright runs under Xvfb, headed as on a laptop; a page behind a login
  wall is still a stop, as the ship skill says.
- `claude setup-token` cannot use Remote Control or claude.ai connectors;
  MCP servers configured locally — the plugin's Playwright — work.
- The container trusts the clone and `~/work`, nothing else.
- No Docker inside the container: a `worktree_setup` that starts a compose
  stack needs another plan there (a test environment the project provides,
  reached over the network).
