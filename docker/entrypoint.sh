#!/bin/bash
# fr-workflow autopilot container: prepare one repository, then keep its
# autopilot alive. Everything comes from the environment; no token is ever
# printed.
#
#   REPO                     owner/name on GitHub                       (required)
#   GH_TOKEN                 token for gh and git — a person's gh token
#                            in stage 1, an installation token later     (required)
#   CLAUDE_CODE_OAUTH_TOKEN  from `claude setup-token`                  (required)
#   REPO_REF                 branch to keep checked out      (default: the default branch)
#   MARKETPLACE              register this plugin marketplace instead of the
#                            ones the repository's .claude/settings.json
#                            names — a mounted working copy, to run an
#                            unreleased plugin against a test repository
#   KEEPALIVE_SECONDS        pause between launch attempts              (default 300)
#   AUTOPILOT_ASSIGNEE       the login whose FRs this container takes, `none`
#                            for unassigned ones          (default: GH_TOKEN's login)
#   WORKFLOW_LOCAL           more per-machine profile lines (`key: value`),
#                            e.g. notify_command, for .claude/workflow.local.md
#   ATTACH_CONTAINER         the container's name on the host, for the attach
#                            command in notifications (default: the container id)
#   AUTO_MODE_ENVIRONMENT    extra lines for autoMode.environment, one per
#                            line, written once into ~/.claude/settings.json
#
#   fr-autopilot run     prepare, then loop: launch the autopilot when none runs
#   fr-autopilot once    prepare, one launch attempt, exit
#   fr-autopilot check   prepare, run `fr.sh check`, exit — the smoke test
set -euo pipefail

mode=${1:-run}
case "$mode" in run|once|check) ;; *) echo "fr-autopilot: run | once | check, not '$mode'" >&2; exit 2 ;; esac

need() { [ -n "${!1:-}" ] || { echo "fr-autopilot: $1 is not set" >&2; exit 2; }; }
need REPO; need GH_TOKEN; need CLAUDE_CODE_OAUTH_TOKEN
case "$REPO" in */*) ;; *) echo "fr-autopilot: REPO must be owner/name, not '$REPO'" >&2; exit 2 ;; esac

say() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

# --- GitHub ---------------------------------------------------------------
gh auth status >/dev/null 2>&1 || { echo "fr-autopilot: GH_TOKEN is not accepted by GitHub (gh auth status failed)" >&2; exit 3; }
gh auth setup-git >/dev/null
login=$(gh api user --jq .login)
if [ -z "$(git config --global --get user.email || true)" ]; then
  git config --global user.name "$(gh api user --jq '.name // .login')"
  git config --global user.email "$(gh api user --jq .id)+${login}@users.noreply.github.com"
fi
say "GitHub: $login, repository $REPO"

# --- the clone ------------------------------------------------------------
dir="$HOME/work/${REPO##*/}"
if [ -d "$dir/.git" ]; then
  git -C "$dir" fetch -q --prune origin
else
  mkdir -p "$HOME/work"
  git clone -q "https://github.com/$REPO.git" "$dir"
fi
if [ -n "${REPO_REF:-}" ]; then git -C "$dir" checkout -q "$REPO_REF"; fi
git -C "$dir" pull -q --ff-only || say "warning: the checkout in $dir is not fast-forwardable; it stays as it is"
say "checkout: $dir at $(git -C "$dir" rev-parse --abbrev-ref HEAD)"

# Per-machine profile values — which login this autopilot serves, and
# whatever WORKFLOW_LOCAL adds — go beside the committed profile, where fr.sh
# reads them (docs/profile.md, "Per-machine values"). Only into a file the
# repository ignores: the clone must stay clean.
if git -C "$dir" check-ignore -q .claude/workflow.local.md 2>/dev/null; then
  # attach_command: how a person on the host joins a session in here — every
  # notification and stop comment names it, copy-ready; $HOSTNAME is the
  # container id, which docker exec accepts
  { printf -- '---\nautopilot_assignee: %s\n' "${AUTOPILOT_ASSIGNEE:-$login}"
    printf 'attach_command: docker exec -it -w %s %s claude attach\n' "$dir" "${ATTACH_CONTAINER:-$HOSTNAME}"
    [ -z "${WORKFLOW_LOCAL:-}" ] || printf '%s\n' "$WORKFLOW_LOCAL"
    printf -- '---\n'; } > "$dir/.claude/workflow.local.md"
  say "local profile: autopilot_assignee ${AUTOPILOT_ASSIGNEE:-$login}, attach via docker exec on ${ATTACH_CONTAINER:-$HOSTNAME}"
else
  say "warning: $REPO does not ignore .claude/workflow.local.md — no per-machine values, autopilot_assignee is the profile's"
fi

# --- Claude Code: trust, plugin marketplaces, auto-mode context -----------
# The trust dialog never shows here: the clone is the repository the container
# was told to work on, and ~/work (where `docker exec` lands) holds nothing else.
node -e '
  const fs = require("fs"), f = process.env.HOME + "/.claude.json";
  let c = {}; try { c = JSON.parse(fs.readFileSync(f, "utf8")); } catch (e) {}
  c.projects = c.projects || {};
  for (const p of process.argv.slice(1)) c.projects[p] = Object.assign({}, c.projects[p], { hasTrustDialogAccepted: true });
  fs.writeFileSync(f, JSON.stringify(c, null, 2));
' "$dir" "$HOME/work"

known=$(claude plugin marketplace list 2>/dev/null || true)
add_marketplace() { # <source> — skipped when a marketplace with that name is known
  local src=$1 name
  name=$(printf '%s' "$src" | sed -e 's#.*/##' -e 's/#.*//' -e 's/\.git$//')
  if printf '%s' "$known" | grep -q "❯ $name\$"; then say "marketplace $name: known"; return 0; fi
  claude plugin marketplace add "$src" >/dev/null || { echo "fr-autopilot: cannot register marketplace $src" >&2; exit 3; }
  say "marketplace $name: registered from $src"
}
if [ -n "${MARKETPLACE:-}" ]; then
  add_marketplace "$MARKETPLACE"
elif [ -f "$dir/.claude/settings.json" ]; then
  while IFS= read -r src; do [ -z "$src" ] || add_marketplace "$src"; done <<< "$(
    jq -r '.extraKnownMarketplaces // {} | to_entries[] | .value.source
           | select(.source == "github") | .repo + (if .ref then "#" + .ref else "" end)' "$dir/.claude/settings.json")"
fi
# the plugins the repository enables, installed for it — a no-op once present
while IFS= read -r p; do
  [ -z "$p" ] || claude plugin install "$p" -s project >/dev/null 2>&1 || say "warning: plugin $p not installed; sessions may install it on start"
done <<< "$(cd "$dir" && jq -r '.enabledPlugins // {} | to_entries[] | select(.value == true) | .key' .claude/settings.json 2>/dev/null || true)"
if ! (cd "$dir" && git diff --quiet -- .claude/settings.json); then
  say "warning: the plugin install changed $dir/.claude/settings.json — reverted, the repository's pin rules"
  (cd "$dir" && git checkout -q -- .claude/settings.json)
fi

# Auto mode's classifier reads autoMode only from user settings, so the
# container's own ~/.claude/settings.json names what this container is. It is
# written once; edit the file on the volume to change it.
settings="$HOME/.claude/settings.json"
if [ ! -f "$settings" ]; then
  mkdir -p "$HOME/.claude"
  AUTOPILOT_REPO=$REPO AUTOPILOT_OWNER=${REPO%%/*} AUTOPILOT_EXTRA=${AUTO_MODE_ENVIRONMENT:-} node -e '
    const extra = (process.env.AUTOPILOT_EXTRA || "").split("\n").map(s => s.trim()).filter(Boolean);
    const s = { autoMode: { environment: [
      "$defaults",
      "Host containment: the fr-workflow autopilot container; it works on github.com/" + process.env.AUTOPILOT_REPO + " only, through gh and git with the token it was given. No cloud identity, no other hosts.",
      "Source control: github.com/" + process.env.AUTOPILOT_OWNER + " and the repositories under it",
      ...extra
    ], allow: [
      "$defaults",
      "fr.sh merge: the fr-workflow plugin asks GitHub for auto-merge of an FR pull request after its own merge gate passed; the base branch ruleset decides, the session never merges by hand and never bypasses a rule"
    ] } };
    require("fs").writeFileSync(process.env.HOME + "/.claude/settings.json", JSON.stringify(s, null, 2) + "\n");
  '
  say "settings: $settings written"
fi

claude auth status 2>/dev/null | jq -e '.loggedIn == true' >/dev/null || { echo "fr-autopilot: CLAUDE_CODE_OAUTH_TOKEN is not accepted (claude auth status: not logged in)" >&2; exit 3; }
say "Claude Code $(claude --version 2>/dev/null | head -n 1)"

# fr.sh of the installed plugin, the same copy the sessions run: a mounted
# marketplace folder is used as it is (its skills run from there too), else
# the newest copy in the cache (cache/<marketplace>/fr-workflow/<version>/)
fr=""
if [ -n "${MARKETPLACE:-}" ] && [ -f "$MARKETPLACE/plugins/fr-workflow/scripts/fr.sh" ]; then fr="$MARKETPLACE/plugins/fr-workflow/scripts/fr.sh"; fi
[ -n "$fr" ] || fr=$(find "$HOME/.claude/plugins/cache" -type f -path '*/fr-workflow/*/scripts/fr.sh' 2>/dev/null | sort -V | tail -n 1 || true)
[ -n "$fr" ] || fr=$(find "$HOME/.claude/plugins/marketplaces" -type f -path '*/fr-workflow/scripts/fr.sh' 2>/dev/null | head -n 1 || true)
[ -n "$fr" ] || { echo "fr-autopilot: fr-workflow is not installed — no fr.sh under $HOME/.claude/plugins" >&2; exit 3; }
say "plugin: $fr"

cd "$dir"
if [ "$mode" = check ]; then exec "$fr" check; fi

# --- keep-alive -----------------------------------------------------------
# `fr.sh launch autopilot` starts the autopilot as a background session when
# none runs (exit 0), reports a running one (exit 3), and fails on anything
# else — logged, tried again after the pause. The sessions die with the
# container; a restart launches a new autopilot, state is derived.
stop() { say "stopping"; exit 0; }
trap stop TERM INT
pause=${KEEPALIVE_SECONDS:-300}
while :; do
  git pull -q --ff-only 2>/dev/null || true
  rc=0; out=$("$fr" launch autopilot 2>&1) || rc=$?
  case "$rc" in
    0) say "$out" ;;
    3) : ;;   # running
    *) say "launch failed ($rc): $out" ;;
  esac
  [ "$mode" = run ] || exit "$rc"
  sleep "$pause" & wait $! || true
done
