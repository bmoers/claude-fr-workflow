#!/usr/bin/env bash
# fr.sh — deterministic helpers for the fr-workflow plugin.
#
# Until an FR is started, its GitHub issue (label `fr`) is the spec; `start`
# turns it into the FR document on the FR's branch, the source from then on.
# Everything this script prints is derived from those two, so it can be re-run
# at any time.
#
# Needs git, awk and an authenticated gh. Written for bash 3.2 (macOS default)
# and Git Bash on Windows: no associative arrays, no mapfile. Run from anywhere
# inside the repository.
#
# Usage:
#   fr.sh check                    prerequisites and profile
#   fr.sh list [--no-fetch]        all FRs: open FR issues not started yet, FR
#                                  docs on the base branch, FR branches, local
#   fr.sh spec <issue> [<file>]    the FR doc of an FR issue, to stdout or into a
#                                  new <file>; exit 4 if the issue is not ready
#   fr.sh issue-frs <issue>        the FRs that serve a request issue
#   fr.sh overlap [<ID>...] [--no-fetch]
#                                  which candidates (default: all open FRs) may
#                                  start alongside the in-progress ones: waves
#   fr.sh lock acquire|release|break|status [<ID>]
#                                  ship lock for a shared test environment
#   fr.sh deployment <head sha> [--pr <N>]
#                                  newest GitHub deployment of the PR's commit in
#                                  a deploy_environment: state, environment, url,
#                                  id, sha, time — or none (deploy_signal: deployment)
#   fr.sh pr-commit <sha> <head sha>
#                                  exit 0 if <sha> is the head or a merge commit
#                                  of it into the base branch — this PR's commit
#   fr.sh project-status <issue> <event> [<gate>]
#                                  record the event in the local FR log, then the
#                                  FR's status column in the GitHub project, per
#                                  project_status; exit 5 if not written
#   fr.sh queue add|rm|sync|list|clear|session [<ID>...]
#                                  sync: FRs the board holds ready (autopilot_queue: project)
#                                  the autopilot's FRs; session = its session id
#   fr.sh pipeline [--no-fetch] [--wait <s> [--max <s>]]
#                                  per queued FR: phase, next action, detail
#   fr.sh launch implement|fix|ship <ID> [--replace <session>]
#   fr.sh launch autopilot         start a background session for the FR or the
#                                  autopilot itself; prints the session id
#   fr.sh fix-brief <ID>           what the next fix session is to fix
#   fr.sh merge-gate <ID> [--no-fetch]  the checks before a merge request; exit 4 with reasons
#   fr.sh merge <ID>               after the gate, gh pr merge --auto (auto_merge: auto)
#   fr.sh finish <ID>              after the merge: hook, worktree, branch, board, queue
#   fr.sh hook setup|teardown <ID> <path>
#                                  the profile's worktree_setup / worktree_teardown
#                                  in that worktree, the FR in its environment;
#                                  exit 6 if the hook failed
#   fr.sh notify <ID|autopilot> <phase> [<detail>]
#                                  the profile's notify_command with FR_ID, FR_PHASE,
#                                  FR_DETAIL, FR_SESSION, FR_REPO, FR_MESSAGE in its
#                                  environment; nothing without the key; exit 6 if it failed
#   fr.sh project-options [<value>...]
#                                  add the values of project_status (or the given
#                                  ones) that the status column does not have yet
#   fr.sh validate <issue|ID|file> [--rev <rev> | --local]
#                                  the spec delta against the base branch's specs
#                                  (spec_dir): error/warning lines; exit 4 on errors
#   fr.sh fingerprint <capability> <requirement> [--rev <rev> | --local]
#                                  what a MODIFIED/REMOVED/RENAMED block pins as Base:
#   fr.sh fold <ID|file> [--dry-run]
#                                  apply the FR's spec delta to the spec files of
#                                  this checkout; nothing on errors (exit 4)
#
# Issue refs: owner/repo#12, #12, 12 or FR-12 (issue repo), a GitHub issue URL.

set -euo pipefail

PROFILE='.claude/workflow.md'
# Per-machine values beside the profile, ignored by git: which login this
# machine's autopilot serves, how it notifies, which permission mode its
# sessions run in. Only these keys are read from it — everything else about
# the project stays in the committed profile.
PROFILE_LOCAL='.claude/workflow.local.md'
LOCAL_KEYS=' autopilot_assignee notify_command session_permission_mode autopilot_model autopilot_effort '
ISSUE_LIMIT=1000

die() { echo "fr.sh: $*" >&2; exit 1; }

CALLER=$PWD
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$TOP"

# git for path-listing commands: without core.quotePath=false git quotes paths
# with non-ASCII characters ("FR-002-\303\274ber.md") and they no longer match.
g() { git -c core.quotePath=false "$@"; }

# A path argument as the caller meant it: fr.sh runs from the repository root,
# so a relative path is resolved against the directory it was called from.
caller_path() { case "$1" in /*) echo "$1" ;; *) echo "$CALLER/$1" ;; esac; }

# Flat `key: value` lookup in the profile frontmatter, with a default.
cfg_in() { # <file> <key> — the key's value in that file's frontmatter
  awk -v k="$2" '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    {
      i = index($0, ":"); if (i == 0) next
      if (substr($0, 1, i - 1) != k) next
      v = substr($0, i + 1); sub(/^[ \t]+/, "", v)
      # a quoted value ends at its closing quote — a " #" inside it is part of
      # the value; unquoted, " #" starts a comment
      if (substr(v, 1, 1) == "\"" && (q = index(substr(v, 2), "\"")) > 0) v = substr(v, 2, q - 1)
      else { sub(/^#.*$/, "", v); sub(/[ \t]+#.*$/, "", v); sub(/[ \t]+$/, "", v) }
      print v; exit
    }' "$1"
}

cfg() {
  local v=""
  case "$LOCAL_KEYS" in *" $1 "*) [ ! -f "$PROFILE_LOCAL" ] || v=$(cfg_in "$PROFILE_LOCAL" "$1") ;; esac
  if [ -z "$v" ] && [ -f "$PROFILE" ]; then v=$(cfg_in "$PROFILE" "$1"); fi
  if [ -n "$v" ]; then echo "$v"; else echo "$2"; fi
}

FR_DIR=$(cfg fr_dir req/feature-requests)
PREFIX=$(cfg fr_prefix FR)
BASE=$(cfg base_branch main)

# owner/repo of origin. Reads the raw config value: `git remote get-url`
# applies url.*.insteadOf rewrites and can return a non-GitHub URL.
cur_repo() {
  local u r
  u=$(git config --get remote.origin.url) || die "no 'origin' remote"
  r=$(echo "$u" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##; s#/$##')
  case "$r" in
    */*/*|/*|*:*|"") r=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) ||
      die "origin is not a GitHub repository: $u" ;;
  esac
  echo "$r"
}

default_repo() {
  local r; r=$(cfg issue_repo "")
  if [ -n "$r" ]; then echo "$r"; else cur_repo; fi
}

# Default repo for short refs, lowercased; computed once per run (set DR in the
# parent shell before loops — subshells inherit it).
DR=""
dr_init() { [ -n "$DR" ] || DR=$(default_repo | tr '[:upper:]' '[:lower:]'); }

# awk: the one canonical issue ref — owner/repo#N, owner/repo lowercased (GitHub
# names are case-insensitive). Accepts #N, N, <prefix>-N, owner/repo#N, issue
# URLs; anything else passes through unchanged. Needs -v dr=<default repo> and
# -v pre=<fr_prefix>.
NORM_AWK='
  function canon(x,   i) {
    if (x ~ /^#[0-9]+$/) x = dr x
    else if (x ~ /^[0-9]+$/) x = dr "#" x
    else if (toupper(x) ~ ("^" toupper(pre) "-[0-9]+$")) x = dr "#" substr(x, length(pre) + 2)
    else if (x ~ /^https:\/\/github\.com\/[^\/]+\/[^\/]+\/issues\/[0-9]+/) {
      sub(/^https:\/\/github\.com\//, "", x); sub(/\/issues\//, "#", x)
      match(x, /^[^\/]+\/[^#]+#[0-9]+/); x = substr(x, RSTART, RLENGTH)
    }
    if (x ~ /^[^\/#]+\/[^\/#]+#[0-9]+$/) { i = index(x, "#"); x = tolower(substr(x, 1, i - 1)) substr(x, i) }
    return x
  }'

norm() {
  dr_init
  printf '%s\n' "$1" | awk -v dr="$DR" -v pre="$PREFIX" "$NORM_AWK"'{ print canon($0) }'
}

# owner/repo#N of a GitHub issue argument, or die: issue_ref <arg>
issue_ref() {
  local r; r=$(norm "$1")
  case "$r" in
    */*#[0-9]*) echo "$r" ;;
    *) die "not a GitHub issue: $1" ;;
  esac
}

base_ref() {
  if git rev-parse --verify -q "refs/remotes/origin/$BASE" >/dev/null; then
    echo "origin/$BASE"
  else
    echo "$BASE"
  fi
}

# Lowercase regex for FR branch names (without "origin/"), from branch_pattern.
# With the default "{type}/{id-lower}-{slug}" the first segment must be a branch
# type, so i18n/fr-2024-cleanup is not an FR branch. Used by fr_branches.
fr_branch_re() {
  local p bp
  p=$(printf '%s' "$PREFIX" | tr '[:upper:]' '[:lower:]')
  bp=$(cfg branch_pattern "{type}/{id-lower}-{slug}")
  case "$bp" in
    "{type}/"*) echo "^(feat|feature|fix|bugfix|hotfix|docs|chore|refactor|perf|test|build|ci|style|revert)/$p-[0-9]+(-|\$)" ;;
    *) echo "(^|/)$p-[0-9]+(-|\$)" ;;
  esac
}

# The ref to read an FR branch from: the local branch when it is ahead of (or
# equal to) origin's — implementation sessions commit without pushing — else
# origin's. pick_ref <branch name without origin/>
pick_ref() {
  if git rev-parse -q --verify "refs/heads/$1" >/dev/null; then
    if git rev-parse -q --verify "refs/remotes/origin/$1" >/dev/null &&
       ! git merge-base --is-ancestor "origin/$1" "$1" 2>/dev/null; then
      echo "origin/$1"
    else
      echo "$1"
    fi
  else
    echo "origin/$1"
  fi
}

do_fetch() {
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch --quiet --prune origin || echo "fr.sh: fetch failed, using local refs" >&2
  fi
}

# Frontmatter on stdin -> "id status pr issue requests title areas model effort"
# (tab-separated). Prints nothing for files without frontmatter or an id.
parse_fm() {
  awk '
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { done = 1; exit }
    {
      i = index($0, ":"); if (i == 0) next
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
      f[k] = v
    }
    END {
      if (!done || f["id"] == "") exit
      rq = f["requests"]; gsub(/\[/, "", rq); gsub(/\]/, "", rq); gsub(/ /, "", rq)
      ar = f["areas"]; gsub(/\[/, "", ar); gsub(/\]/, "", ar); gsub(/ /, "", ar)
      t = f["title"]; gsub(/\t/, " ", t)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f["id"], f["status"], f["pr"], f["issue"], rq, t, ar, f["model"], f["effort"]
    }'
}

# emit <location> <ref> <path>   (frontmatter on stdin)
emit() {
  local doc items
  doc=$(cat)
  items=$(printf '%s\n' "$doc" | awk "$NN_AWK$ITEMS_AWK"'{ b = b (NR > 1 ? "\n" : "") $0 } END { print delta_items(b, "\n") }')
  # items through the environment: awk -v would turn a \t or \n in a requirement name into a column or a row
  printf '%s\n' "$doc" | parse_fm | items="$items" awk -v loc="$1" -v ref="$2" -v p="$3" 'BEGIN { FS = OFS = "\t"; items = ENVIRON["items"] }
    { print $1, $2, loc, ref, p, $3, $4, $5, $6, $7, $8, $9, items }'
}

# awk: planning(body, sep) reads the `## Planning` section of an FR issue body,
# its lines joined by sep, into P["areas"], P["model"], P["effort"],
# P["based on"], P["requests"], … (lowercase keys). csv() drops the blanks of a
# comma list; reqs() also makes each entry canonical (needs NORM_AWK).
PLAN_AWK='
  function planning(b, sep,   L, n, i, on, fence, l, j, k, v) {
    split("", P); n = split(b, L, sep)
    for (i = 1; i <= n; i++) {
      l = L[i]; sub(/\r$/, "", l)
      if (l ~ /^ *(```|~~~)/) fence = !fence
      if (!fence && l ~ /^#+ /) { on = (tolower(l) ~ /^## +planning *$/); continue }
      if (l ~ /^<details/) on = 0
      if (!on || l !~ /^[-*] +[^:]+:/) continue
      sub(/^[-*] +/, "", l); j = index(l, ":")
      k = tolower(substr(l, 1, j - 1)); v = substr(l, j + 1)
      gsub(/[*_`]/, "", k); sub(/^\*+/, "", v); gsub(/`/, "", v)
      sub(/^[ \t]+/, "", k); sub(/[ \t]+$/, "", k); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      if (v == "-" || v == "—" || tolower(v) == "none") v = ""
      P[k] = v
    }
  }
  function csv(v) { gsub(/[ \t]/, "", v); return v }
  function reqs(v,   a, n, i, o) {
    n = split(csv(v), a, ","); o = ""
    for (i = 1; i <= n; i++) if (a[i] != "") o = o (o == "" ? "" : ",") canon(a[i])
    return o
  }'

# awk: nn(s) — a requirement name as compared everywhere: lowercase, one space
# between words. delta_items(b, sep) — the requirements an FR's spec delta
# changes, "capability:name;…", from a body whose lines are joined by sep;
# the thirteenth column of a row, so overlap never reads a body twice.
NN_AWK='function nn(s) { s = tolower(s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s); return s }
'
ITEMS_AWK='
  function delta_items(b, sep,   L, n, i, l, on, fence, h, cap, name, out) {
    n = split(b, L, sep); out = ""; on = 0; fence = 0
    for (i = 1; i <= n; i++) {
      l = L[i]; sub(/\r$/, "", l)
      if (l ~ /^ *(```|~~~)/) fence = !fence
      if (fence) continue
      if (l ~ /^## /) { h = tolower(l); sub(/^## +/, "", h); sub(/ +$/, "", h); on = (h == "spec delta"); continue }
      if (!on || l !~ /^### +(ADDED|MODIFIED|REMOVED|RENAMED) +[a-z0-9][a-z0-9-]*: *[^ ]/) continue
      h = l; sub(/^### +[A-Z]+ +/, "", h); cap = h; sub(/:.*$/, "", cap); name = h; sub(/^[^:]*: */, "", name)
      if (l ~ /^### +RENAMED /) sub(/ -> .*$/, "", name)
      out = out (out == "" ? "" : ";") cap ":" nn(name)
    }
    return out
  }'

# jq: one issue per line, fields tab-separated, the body's lines joined by \037
# (unit separator) — unambiguous, unlike @tsv's escapes. J_ROW for
# `gh issue list` (number title body), J_REST for REST issue objects
# (url state reason labels title body).
J_BODY='((.body // "") | gsub("\r"; "") | gsub("\t"; " ") | gsub("\n"; "\u001f"))'
J_TITLE='(.title | gsub("[\t\n\r]"; " "))'
J_ROW="[(.number | tostring), $J_TITLE, $J_BODY] | join(\"\t\")"
J_REST="[.html_url, .state, (.state_reason // \"\"), ([.labels[].name] | join(\",\")), $J_TITLE, $J_BODY] | join(\"\t\")"

tag() { awk -v t="$1" '{ print t "\t" $0 }'; }

# Open FR issues (label fr) as rows with location "issue" — FRs not started
# yet. A doc with the same id (base, branch, local) overrides the row in rows().
issue_rows() {
  local repo out
  repo=$(default_repo)
  if ! command -v gh >/dev/null ||
     ! out=$(gh issue list -R "$repo" --label fr --state open --limit "$ISSUE_LIMIT" \
       --json number,title,body --jq ".[] | $J_ROW" 2>/dev/null); then
    echo "fr.sh: warning: could not read the FR issues of $repo — FRs not started yet are missing" >&2
    return 0
  fi
  [ -n "$out" ] || return 0
  if [ "$(printf '%s\n' "$out" | wc -l)" -ge "$ISSUE_LIMIT" ]; then
    echo "fr.sh: warning: $ISSUE_LIMIT open FR issues or more — the list is cut" >&2
  fi
  dr_init
  printf '%s\n' "$out" | awk -v dr="$DR" -v pre="$PREFIX" "$NORM_AWK$PLAN_AWK$NN_AWK$ITEMS_AWK"'
    BEGIN { FS = OFS = "\t" }
    {
      planning($3, "\037"); r = canon("#" $1)
      print pre "-" $1, "open", "issue", r, "", "", r, reqs(P["requests"]), $2, csv(P["areas"]), P["model"], P["effort"], delta_items($3, "\037")
    }'
}

is_fr_file() {
  awk -v pre="$PREFIX" '{ n = split($0, a, "/"); if (a[n] ~ ("^" pre "-[0-9]+.*\\.md$")) print }'
}

# A branch doc whose id is already on base under another path is either the
# same FR renamed on its branch (the old path existed at the fork point and the
# branch removed it) or a second FR with the same id — warn about the latter.
same_id_on_base() { # <row> <branch-ref> <path> <baserows> <bref>
  local id q mb
  id=$(printf '%s' "$1" | cut -f1)
  q=$(printf '%s\n' "$4" | awk -F '\t' -v id="$id" '$1 == id { print $5; exit }')
  [ -n "$q" ] && [ "$q" != "$3" ] || return 0
  mb=$(git merge-base "$5" "$2" 2>/dev/null) || mb=""
  if [ -n "$mb" ]; then
    # renamed on the branch: the base path existed at the fork point, the branch dropped it
    if git cat-file -e "$mb:$q" 2>/dev/null && ! git cat-file -e "$2:$q" 2>/dev/null; then return 0; fi
    # renamed on base: the branch path existed at the fork point
    if git cat-file -e "$mb:$3" 2>/dev/null; then return 0; fi
  fi
  echo "fr.sh: warning: $id is on $BASE ($q) and on branch ${2#origin/} ($3) — two FRs with one id, renumber the branch one" >&2
}

# Names (without origin/) of all local and remote FR branches, each once.
fr_branches() {
  local re; re=$(fr_branch_re)
  { git for-each-ref --format='%(refname:short)' refs/remotes/origin | sed 's#^origin/##'
    git for-each-ref --format='%(refname:short)' refs/heads
  } | awk -v base="$BASE" -v re="$re" '
      $0 == "HEAD" || $0 == "origin" || $0 == base { next }
      tolower($0) ~ re { print }' | sort -u
}

# Raw rows from all sources, later sources win per id: 1. open FR issues
# 2. base branch  3. FR branches whose doc differs from base  4. local edits.
collect() {
  local bref br name p cur baserows row
  bref=$(base_ref)
  issue_rows

  baserows=$(g ls-tree -r --name-only "$bref" -- "$FR_DIR" 2>/dev/null | is_fr_file |
    while IFS= read -r p; do
      git show "$bref:$p" | emit base "$BASE" "$p"
    done)
  [ -z "$baserows" ] || printf '%s\n' "$baserows"

  # FR branches by name, each read from pick_ref (local when ahead, else origin)
  fr_branches |
    while IFS= read -r name; do
      br=$(pick_ref "$name")
      # --no-renames: a doc renamed on its branch shows up as added (A), not R.
      # A branch without merge base fails the diff — without `|| true` that
      # would end the loop and hide every FR branch sorted after it.
      { g diff --name-only --no-renames --diff-filter=AM "$bref...$br" -- "$FR_DIR" 2>/dev/null || true; } | is_fr_file |
        while IFS= read -r p; do
          # A squash-merged branch carries the same doc as base: base wins.
          if git cat-file -e "$bref:$p" 2>/dev/null && git diff --quiet "$bref" "$br" -- "$p"; then
            continue
          fi
          row=$(git show "$br:$p" 2>/dev/null | emit branch "$name" "$p")
          [ -n "$row" ] || continue
          same_id_on_base "$row" "$br" "$p" "$baserows" "$bref"
          printf '%s\n' "$row"
        done
    done

  # -z: unquoted paths, also with spaces; a rename entry is followed by its old path
  cur=$(git branch --show-current)
  g status --porcelain -z -uall -- "$FR_DIR" | tr '\0' '\n' | awk '
      skip { skip = 0; next }
      { if (substr($0, 1, 2) ~ /[RC]/) skip = 1; print substr($0, 4) }' |
    is_fr_file |
    while IFS= read -r p; do
      [ -f "$p" ] && emit local "$cur" "$p" < "$p"
    done
  return 0
}

# Deduplicated rows; "merged" is derived: a shipped FR (in-review) on base.
# Two FR branches carrying the same id (planned concurrently) are a conflict
# the user must resolve — warn instead of silently keeping one.
rows() {
  collect | awk 'BEGIN { FS = OFS = "\t" }
    {
      # an edit in another checkout (e.g. main) must not mask the FR branch
      if ($3 == "local" && ($1 in br) && br[$1] != $4) next
      if (!($1 in seen)) order[++n] = $1; seen[$1] = 1; row[$1] = $0
      if ($3 == "branch") {
        if (($1 in br) && br[$1] != $4)
          print "fr.sh: warning: " $1 " exists on two branches (" br[$1] ", " $4 ") — renumber one" > "/dev/stderr"
        br[$1] = $4
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        split(row[order[i]], c, "\t")
        if (c[3] == "base" && c[2] == "in-review") c[2] = "merged"
        print c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12], c[13]
      }
    }' | sort
}

want_fetch() { case " $* " in *" --no-fetch "*) ;; *) do_fetch ;; esac; }

HEADER='id\tstatus\tlocation\tref\tpath\tpr\tissue\trequests\ttitle\tareas\tmodel\teffort\tspecs\n'

cmd_list() {
  want_fetch "$@"
  printf "$HEADER"
  rows
}

# The FR doc of an FR issue, for `start`: frontmatter from the issue's title and
# its `## Planning` section, the spec sections verbatim — without Planning and
# without the original request kept in <details> (it may hold customer data,
# which never goes into a commit). Not ready — closed, no label fr, no
# acceptance criteria, open questions left — prints why and exits 4.
cmd_spec() {
  [ $# -ge 1 ] || die "usage: fr.sh spec <issue> [<file>]"
  command -v gh >/dev/null || die "gh not found"
  local ref out="${2:-}" meta body doc rc=0
  local PROFILE="$(main_worktree)/$PROFILE"   # spec_dir as validate and fold read it
  ref=$(issue_ref "$1")
  if [ -n "$out" ]; then
    out=$(caller_path "$out")
    [ ! -e "$out" ] || die "$out exists — not overwritten"
  fi
  meta=$(gh issue view "${ref##*#}" -R "${ref%%#*}" --json state,labels,title \
    --jq "[.state, ([.labels[].name] | join(\",\")), $J_TITLE] | join(\"\t\")") || die "cannot read $ref"
  body=$(gh issue view "${ref##*#}" -R "${ref%%#*}" --json body --jq '.body // ""') || die "cannot read $ref"
  dr_init
  doc=$(printf '%s\n' "$body" | meta="$meta" awk -v ref="$ref" -v dr="$DR" -v pre="$PREFIX" \
      -v today="$(date +%Y-%m-%d)" "$NORM_AWK$PLAN_AWK"'
    function opens(s) { return gsub(/<details/, "&", s) }
    function closes(s) { return gsub(/<\/details>/, "&", s) }
    function fail(m) { bad = bad "\n  - " m }
    # the original request (<details><summary>Original request…) is skipped as a
    # whole, nested <details> included; returns 1 for every line inside it
    function original(l) {
      if (d > 0) { d += opens(l) - closes(l); return 1 }
      if (l ~ /^<details> *<summary> *Original request/) { d = opens(l) - closes(l); return 1 }
      return 0
    }
    { sub(/\r$/, ""); L[++n] = $0; all = all (n > 1 ? "\n" : "") $0 }
    END {
      split(ENVIRON["meta"], M, "\t"); num = ref; sub(/^.*#/, "", num)   # the title is issue text: no -v, no escape processing
      if (M[1] != "OPEN") fail("the issue is closed")
      if (("," M[2] ",") !~ /,fr,/) fail("no label fr — not defined yet: /fr-workflow:new " ref)
      # pass 1: criteria and open questions; # lines in code blocks are no headings
      for (i = 1; i <= n; i++) {
        l = L[i]
        if (original(l)) continue
        if (l ~ /^ *(```|~~~)/) fence = !fence
        if (!fence && l ~ /^#+ /) { sec = tolower(l); sub(/^#+ +/, "", sec); sub(/ +$/, "", sec); if (sec == "spec delta") delta = 1; continue }
        if (sec == "acceptance criteria" && l ~ /^[-*] \[[ xX]\] +[^ ]/ && l !~ /\] +Criterion [0-9]+ *$/) crit++
        if (sec == "open questions" && l ~ /^([-*]|[0-9]+\.) +[^ ]/) oq++
      }
      if (!crit && !delta) fail("no acceptance criteria (- [ ] lines under ## Acceptance criteria) and no ## Spec delta")
      if (crit && delta) fail("both ## Acceptance criteria and ## Spec delta — one of them")
      if (oq) fail(oq " open question(s) under ## Open questions")
      if (bad != "") { print "fr.sh: " ref " is not ready to start:" bad > "/dev/stderr"; exit 4 }
      planning(all, "\n")
      if (P["areas"] == "") print "fr.sh: warning: " ref " names no areas — it overlaps every other FR" > "/dev/stderr"
      if (P["based on"] !~ /^[0-9a-f]+$/) print "fr.sh: warning: " ref " has no Based on commit — changes since its definition cannot be checked" > "/dev/stderr"
      ar = csv(P["areas"]); gsub(/,/, ", ", ar); rq = reqs(P["requests"]); gsub(/,/, ", ", rq)
      printf "---\nid: %s-%s\nissue: %s\ntitle: %s\nstatus: in-progress\nrequests: [%s]\nareas: [%s]\n", pre, num, ref, M[3], rq, ar
      printf "model: %s\neffort: %s\nbased_on: %s\npr:\nstarted: %s\n---\n\n", P["model"], P["effort"], P["based on"], today
      printf "# %s-%s: %s\n\nSpecified in %s. From the start on this document is the source: decisions\nand deviations go here, the issue is not updated.\n", pre, num, M[3], ref
      # pass 2: the spec verbatim, without Planning and the original request;
      # blank lines kept between content, dropped at the end
      d = 0; fence = 0; plan = 0; blanks = 0; started = 0
      for (i = 1; i <= n; i++) {
        l = L[i]
        if (original(l)) continue
        if (l ~ /^ *(```|~~~)/) fence = !fence
        if (!fence && l ~ /^#+ /) plan = (tolower(l) ~ /^## +planning *$/)
        if (plan) continue
        if (l ~ /^[ \t]*$/) { blanks++; continue }
        if (!started) { blanks = 1; started = 1 }
        for (; blanks > 0; blanks--) print ""
        print l
      }
      printf "\n## Acceptance check\n\nFilled in by `/fr-workflow:ship`.\n"
    }') || rc=$?
  [ "$rc" = 0 ] || exit "$rc"
  # a spec delta: valid against the base branch's specs, and pinned to them
  if printf '%s\n' "$body" | grep -qiE '^## +spec delta *$'; then
    local vout
    SPEC_DIR=$(cfg spec_dir "")
    [ -n "$SPEC_DIR" ] || { echo "fr.sh: $ref is not ready to start: it has a spec delta, but the profile has no spec_dir" >&2; exit 4; }
    if ! vout=$(validate_text "$body" "$(base_ref)"); then
      printf '%s\n' "$vout" >&2; echo "fr.sh: $ref is not ready to start: the spec delta has errors" >&2; exit 4
    fi
    printf '%s\n' "$vout" | grep '^warning' >&2 || true
    doc=$(printf '%s\n' "$doc" | add_base_lines "$(base_ref)")
  fi
  if [ -z "$out" ]; then printf '%s\n' "$doc"; return 0; fi
  mkdir -p "$(dirname "$out")"
  printf '%s\n' "$doc" > "$out"
  echo "wrote $out"
}

# The FRs serving a request issue: the issue itself when it is an FR (label
# fr), its sub-issues, and FR issues whose Planning lists it under Requests —
# found through its timeline, where GitHub records every mention. Prints
# ref state reason via title; reason completed|not_planned|duplicate when closed.
cmd_issue_frs() {
  [ $# -ge 1 ] || die "usage: fr.sh issue-frs <issue>"
  command -v gh >/dev/null || die "gh not found"
  local ref repo num self
  ref=$(issue_ref "$1"); repo=${ref%%#*}; num=${ref##*#}
  self=$(gh api "repos/$repo/issues/$num" --jq "$J_REST") || die "cannot read $ref"
  dr_init
  printf 'ref\tstate\treason\tvia\ttitle\n'
  { printf '%s\n' "$self" | tag self
    gh api "repos/$repo/issues/$num/sub_issues" --paginate --jq ".[] | $J_REST" | tag sub ||
      echo "fr.sh: warning: could not read the sub-issues of $ref" >&2
    gh api "repos/$repo/issues/$num/timeline" --paginate \
      --jq ".[] | select(.event == \"cross-referenced\") | .source.issue | select(.pull_request == null) | $J_REST" |
      tag requests || echo "fr.sh: warning: could not read the timeline of $ref" >&2
  } | awk -v ref="$ref" -v dr="$DR" -v pre="$PREFIX" "$NORM_AWK$PLAN_AWK"'
    BEGIN { FS = OFS = "\t" }
    {
      r = canon($2); if (r in seen) next
      fr = (("," $5 ",") ~ /,fr,/)
      if ($1 == "self" && !fr) next
      if ($1 == "requests") {
        if (!fr) next
        planning($7, "\037"); k = split(reqs(P["requests"]), a, ","); hit = 0
        for (i = 1; i <= k; i++) if (a[i] == ref) hit = 1
        if (!hit) next
      }
      seen[r] = 1; print r, $3, $4, $1, $6
    }'
}

# Paths an FR touches: its declared `areas` plus the files its branch (or the
# working tree, for local FRs) already changed, FR docs excluded. Nothing known
# -> "*", which overlaps with everything: parallel only when it is evident.
# Each diff tolerates failure (`|| true`): a branch without merge base must not
# abort the overlap run under set -e.
branch_diff() { # branch_diff <name> — pushed and local commits of an FR branch
  local r l bref; bref=$(base_ref)
  r=$(git rev-parse -q --verify "refs/remotes/origin/$1^{commit}" 2>/dev/null) || r=""
  [ -z "$r" ] || g diff --name-only --no-renames "$bref...$r" 2>/dev/null || true
  # the local ref only when it differs — implementation sessions commit without pushing
  if l=$(git rev-parse -q --verify "refs/heads/$1^{commit}" 2>/dev/null) && [ "$l" != "$r" ]; then
    g diff --name-only --no-renames "$bref...$l" 2>/dev/null || true
  fi
}

touched() { # <row>
  local id loc ref areas bref mb idl name
  id=$(printf '%s' "$1" | cut -f1)
  loc=$(printf '%s' "$1" | cut -f3); ref=$(printf '%s' "$1" | cut -f4)
  areas=$(printf '%s' "$1" | cut -f10)
  bref=$(base_ref)
  idl=$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')
  { printf '%s\n' "$areas" | tr ',' '\n'
    case "$loc" in
      branch) branch_diff "$ref" ;;
      local)
        # the doc is edited in this checkout: count the FR's own branches, and
        # this checkout's changes only when it is the FR's branch — otherwise
        # unrelated changes would be attributed to the FR
        fr_branches | awk -v idl="$idl" 'tolower($0) ~ ("(^|/)" idl "(-|$)")' |
          while IFS= read -r name; do branch_diff "$name"; done
        if git branch --show-current | tr '[:upper:]' '[:lower:]' | grep -qF -- "$idl"; then
          if mb=$(git merge-base "$bref" HEAD 2>/dev/null); then
            g diff --name-only --no-renames "$mb" 2>/dev/null || true
          fi
          g ls-files --others --exclude-standard 2>/dev/null || true
        fi ;;
    esac
    true
  } | awk -v frdir="$FR_DIR" '
      {
        # a glob is cut back to the directory before it: src/comp* -> src,
        # src/{api,web}/** -> src (more overlap, never less); "." is everything
        x = $0; sub(/^\.\//, "", x); glob = 0
        if (x == ".") { print "*"; n++; next }
        p = 0
        for (k = 1; k <= length(x); k++) if (index("*?[{}", substr(x, k, 1))) { p = k; break }
        if (p) { x = substr(x, 1, p - 1); sub(/[^\/]*$/, "", x); glob = 1 }
        sub(/\/+$/, "", x)
        if (x == "" && glob) { print "*"; n++; next }
        if (x == "" || x == frdir || index(x, frdir "/") == 1) next
        if (x == ".claude/worktrees" || index(x, ".claude/worktrees/") == 1) next
        print x; n++
      }
      END { if (!n) print "*" }'
}

# Every in-progress FR is running context; candidates are the given ids (default:
# all open FRs). Wave 1 = candidates that overlap neither a running FR nor each
# other — those can start now. Output: running, conflict and wave lines.
cmd_overlap() {
  local ids="" a
  for a in "$@"; do [ "$a" = "--no-fetch" ] || ids="$ids $a"; done
  want_fetch "$@"
  [ -n "${ROWS:-}" ] || ROWS=$(rows)
  local running cands shared id row
  running=$(printf '%s\n' "$ROWS" | awk -F '\t' '$2 == "in-progress" { print $1 }')
  if [ -z "$ids" ]; then
    ids=$(printf '%s\n' "$ROWS" | awk -F '\t' '$2 == "open" { print $1 }')
  fi
  # (no `case` inside $(...): bash 3.2 misparses its `)`)
  cands=$(for id in $ids; do printf '%s\n' "$running" | grep -qxF "$id" || echo "$id"; done)
  shared=$(cfg shared_paths "" | tr -d '[] ' | tr ',' ' ')
  { for id in $running; do echo "R $id"; done; for id in $cands; do echo "C $id"; done; } |
  while read -r role id; do
    row=$(printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id')
    if [ -z "$row" ]; then echo "fr.sh: no such FR: $id" >&2; continue; fi
    { touched "$row"; spec_items "$row"; } | awk -v id="$id" -v role="$role" '{ print role "\t" id "\t" $0 }'
  done | awk -v shared="$shared" '
    function rel(a, b) { return a == b || index(b, a "/") == 1 || index(a, b "/") == 1 }
    function isspec(a) { return substr(a, 1, 5) == "spec:" }
    function under(p, s) { return p == s || index(p, s "/") == 1 }
    BEGIN { FS = OFS = "\t"; ns = split(shared, sh, " ") }
    { if (!($2 in seen)) { order[++n] = $2; seen[$2] = 1; role[$2] = $1 }; paths[$2] = paths[$2] "\n" $3 }
    END {
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
        A = order[i]; B = order[j]; why = ""
        na = split(substr(paths[A], 2), pa, "\n"); nb = split(substr(paths[B], 2), pb, "\n")
        for (x = 1; x <= na && why == ""; x++) for (y = 1; y <= nb && why == ""; y++) {
          if (pa[x] == "*" || pb[y] == "*") why = "areas unknown"
          else if (isspec(pa[x]) || isspec(pb[y])) {
            # the same requirement of a spec; a requirement never relates to a path
            if (pa[x] == pb[y]) { why = pa[x]; sub(/^spec:/, "spec ", why); sub(/:/, ": ", why) }
          }
          else if (rel(pa[x], pb[y])) why = pa[x] " ~ " pb[y]
          else for (s = 1; s <= ns && why == ""; s++)
            if (under(pa[x], sh[s]) && under(pb[y], sh[s])) why = "shared " sh[s]
        }
        if (why != "") { print "conflict", A, B, why; c[A, B] = c[B, A] = 1 }
      }
      for (i = 1; i <= n; i++) if (role[order[i]] == "R") { wave[order[i]] = 0; print "running", order[i] }
      for (i = 1; i <= n; i++) {
        F = order[i]; if (role[F] == "R") continue
        blocked = 0
        for (k = 1; k <= n; k++) if (role[order[k]] == "R" && ((F, order[k]) in c)) blocked = 1
        for (w = (blocked ? 2 : 1); ; w++) {
          ok = 1
          for (k = 1; k < i; k++) if (role[order[k]] == "C" && wave[order[k]] == w && ((F, order[k]) in c)) { ok = 0; break }
          if (ok) { wave[F] = w; break }
        }
        print "wave", wave[F], F
      }
    }'
}

# A lock in the git dir shared by all worktrees of this clone: on a shared test
# environment only one FR may be between its deploying push and its recorded
# acceptance check. It protects parallel sessions on this machine only.
# A lock dir without owner file (killed between mkdir and write) has no holder
# and no age: it is reported as stale and only `break` removes it — after the
# user confirmed that no ship is running.
cmd_lock() {
  local sub="${1:-status}" id="${2:-}" d holder since held
  d="$(cd "$(git rev-parse --git-common-dir)" && pwd)/fr-workflow-ship.lock"

  # Read the holder only when the lock dir exists — and after a failed mkdir:
  # a fresh acquire sits between mkdir and writing its owner for a moment, so an
  # owner still missing after a short wait is what "stale" means.
  read_holder() {
    holder=""; since=""
    [ -d "$d" ] && [ ! -s "$d/owner" ] && sleep 2
    if [ -f "$d/owner" ]; then read -r holder since < "$d/owner" || true; fi
    if [ -n "$holder" ] && [ -n "$since" ]; then
      held="held by $holder for $(( ($(date -u +%s) - since) / 60 )) min"
    else
      held="held without owner — stale; after checking no ship runs: fr.sh lock break"
    fi
  }

  case "$sub" in
    acquire)
      [ -n "$id" ] || die "usage: fr.sh lock acquire <ID>"
      if mkdir "$d" 2>/dev/null; then
        printf '%s %s\n' "$id" "$(date -u +%s)" > "$d/owner"; echo "acquired by $id"
        return 0
      fi
      read_holder
      if [ "$holder" = "$id" ]; then echo "already held by $id"; else echo "busy: $held"; exit 3; fi ;;
    release)
      [ -n "$id" ] || die "usage: fr.sh lock release <ID>"
      [ -d "$d" ] || { echo "free"; return 0; }
      read_holder
      if [ "$holder" = "$id" ]; then rm -f "$d/owner"; rmdir "$d"; echo "released by $id"
      else echo "not released: $held"; exit 3
      fi ;;
    break)
      rm -rf "$d"   # only the lock dir itself (stray files like .DS_Store included)
      if [ -d "$d" ]; then echo "fr.sh: could not remove $d" >&2; exit 1; fi
      echo "lock removed" ;;
    status)
      if [ -d "$d" ]; then read_holder; echo "$held"; else echo "free"; fi ;;
    *) die "usage: fr.sh lock acquire|release|break|status [<ID>]" ;;
  esac
}

# This PR's commit? <sha> is the head (or starts with it), or a merge commit of
# the head into the base branch — what `pull_request` workflows build and
# deploy: its parents are the head and a commit the base branch contains
# (compare status ahead or identical), which keeps out another branch that
# merely merged this one. Exit 1 when it is not; an API failure is an error,
# never a "no".
pr_commit() { # <repo> <sha> <head> <base>
  local parents other status
  case "$2" in "$3"*) return 0 ;; esac
  parents=$(gh api "repos/$1/commits/$2" --jq '[.parents[].sha] | join("\t")') || die "cannot read commit $2 of $1"
  case "$parents" in *"$3"*) ;; *) return 1 ;; esac
  other=$(printf '%s\n' "$parents" | tr '\t' '\n' | grep -v "^$3" | head -n 1)
  [ -n "$other" ] || return 1
  status=$(gh api "repos/$1/compare/$other...$4" --jq .status) || die "cannot compare $other with $4"
  case "$status" in ahead|identical) return 0 ;; *) return 1 ;; esac
}

cmd_pr_commit() {
  [ $# -eq 2 ] || die "usage: fr.sh pr-commit <sha> <head sha>"
  local PROFILE="$(main_worktree)/$PROFILE"   # the base branch's settings, like deployment
  if pr_commit "$(cur_repo)" "$1" "$2" "$(cfg base_branch main)"; then echo "this PR's commit"; else echo "not this PR's commit"; exit 1; fi
}

J_DEPLOY='.[] | [(.id | tostring), .environment, .sha, .created_at] | join("\t")'

# The newest GitHub deployment of a PR's commit, for `deploy_signal:
# deployment`. Deployments are read, never created. Two lists, both filtered
# by the API: the head's own deployments (?sha=), and — with the PR number —
# those of GitHub's test merge commit, which pull_request workflows deploy
# under refs/pull/N/merge (?ref=); a merge commit still has to pass pr_commit,
# an older head's merge does not. deploy_environment is required: the newest
# deployment of a commit may well be production. A glob is matched here, an
# exact name by the API. Prints one line — state, environment, url, id, sha,
# time of the latest status; the state is that status's, `pending` when there
# is none yet — or `none`. The skill polls it: success → the url is the test
# URL; failure or error → blocked deploy; inactive during the acceptance check
# → the slot was given to another deployment. Settings from the main
# checkout's profile, like hook, pipeline and launch.
cmd_deployment() {
  local head="" pr="" repo base glob list more row id env sha created st state url updated
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) [ $# -ge 2 ] || die "--pr needs the PR number"; pr="$2"; shift ;;
      -*) die "usage: fr.sh deployment <head sha> [--pr <N>]" ;;
      *) head="$1" ;;
    esac
    shift
  done
  printf '%s' "$head" | grep -qE '^[0-9a-f]{40}$' || die "usage: fr.sh deployment <head sha> [--pr <N>] — the full 40-hex sha, the API filters by it"
  [ -z "$pr" ] || printf '%s' "$pr" | grep -qE '^[0-9]+$' || die "--pr needs the PR number"
  local PROFILE="$(main_worktree)/$PROFILE"
  repo=$(cur_repo); base=$(cfg base_branch main)
  glob=$(cfg deploy_environment "")
  [ -n "$glob" ] || die "deploy_environment is empty: deploy_signal deployment needs the test environment's name (a glob is fine) — the newest deployment of a commit may be production"
  case "$glob" in
    *"{pr}"*) [ -n "$pr" ] || die "deploy_environment names {pr}: pass --pr <N>"; glob=$(printf '%s' "$glob" | sed "s/{pr}/$pr/g") ;;
  esac
  # an exact name is a query field (gh encodes it), a glob is matched here
  case "$glob" in *[\*\?\[]*) set -- ;; *) set -- -f "environment=$glob" ;; esac
  list=$(gh api -X GET "repos/$repo/deployments" -f "sha=$head" -f per_page=100 "$@" --jq "$J_DEPLOY") || die "cannot list the deployments of $repo"
  if [ -n "$pr" ]; then
    more=$(gh api -X GET "repos/$repo/deployments" -f "ref=refs/pull/$pr/merge" -f per_page=100 "$@" --jq "$J_DEPLOY") || die "cannot list the deployments of $repo"
    list=$(printf '%s\n%s\n' "$list" "$more")
  fi
  # newest first; a merge commit is checked only until the first match
  row=""
  while IFS=$'\t' read -r id env sha created; do
    [ -n "$id" ] || continue
    case "$env" in $glob) ;; *) continue ;; esac
    pr_commit "$repo" "$sha" "$head" "$base" || continue
    row=$(printf '%s\t%s\t%s' "$id" "$env" "$sha"); break
  done <<EOF
$(printf '%s\n' "$list" | awk -F '\t' 'NF >= 4 && !seen[$1]++' | sort -t "$(printf '\t')" -k4,4r)
EOF
  [ -n "$row" ] || { printf 'none\t\t\t\t\t\n'; return 0; }
  id=$(printf '%s' "$row" | cut -f1); env=$(printf '%s' "$row" | cut -f2); sha=$(printf '%s' "$row" | cut -f3)
  st=$(gh api "repos/$repo/deployments/$id/statuses?per_page=100" \
    --jq 'sort_by(.created_at) | if length == 0 then "pending\t\t" else (last | [.state, (.environment_url // ""), .updated_at] | join("\t")) end') ||
    die "cannot read the statuses of deployment $id"
  [ -n "$st" ] || st=$(printf 'pending\t\t')
  state=$(printf '%s' "$st" | cut -f1); url=$(printf '%s' "$st" | cut -f2); updated=$(printf '%s' "$st" | cut -f3)
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$state" "$env" "$url" "$id" "$sha" "$updated"
}

# The status column of the GitHub project (`project` in the profile) for an
# FR issue. `project_status` maps the plugin's events to the project's own
# values ("defined=Ready, running=In progress, …"); an event without a value
# writes nothing. The project belongs to the owner of the issue repository —
# the same place `gh issue create --project` looks, and like it the title is
# matched regardless of case. The issue is added to the project first —
# idempotent, GitHub returns the existing item — so FR issues written by hand
# or without the project scope land on the board too; then one edit, by names
# (--url --field --value), which gh has since 2.97. Best effort by design: the
# board never stops a skill — exit 5 when the status could not be written, the
# reason on stderr, and the skill mentions it in its report.
PS_EVENTS='planning defined input running implemented review shipping failed blocked approval done'
GH_MIN=2.97

gh_version() { gh --version 2>/dev/null | awk 'NR == 1 { print $3 }' || true; }

# gh_older_than <major.minor> <version>: true when the version is older. A
# version that does not start with a number (DEV builds) counts as new enough.
gh_older_than() {
  printf '%s\n' "$2" | awk -F. -v min="$1" '
    BEGIN { split(min, m, "."); old = 1 }
    $1 ~ /^[0-9]+$/ { old = ($1 + 0 < m[1] + 0 || ($1 + 0 == m[1] + 0 && $2 + 0 < m[2] + 0)) ? 0 : 1 }
    END { exit old }'
}

# project_lookup <owner> <title>: PROJ_NUM and PROJ_URL of the open project with
# that title under the owner — case does not matter, like `gh issue create
# --project`. Exit 5 with the reason when the list fails or nothing matches.
PROJ_NUM=""; PROJ_URL=""
project_lookup() {
  local out
  if ! out=$(gh project list --owner "$1" --limit 100 --format json \
        --jq '.projects[] | [(.number | tostring), .title, .url] | join("\t")' 2>&1); then
    echo "fr.sh: cannot list the projects of $1 — $out (gh auth refresh -s project?)" >&2; exit 5
  fi
  PROJ_NUM=$(printf '%s\n' "$out" | awk -F '\t' -v t="$2" 'tolower($2) == tolower(t) { print $1; exit }')
  PROJ_URL=$(printf '%s\n' "$out" | awk -F '\t' -v t="$2" 'tolower($2) == tolower(t) { print $3; exit }')
  if [ -z "$PROJ_NUM" ]; then echo "fr.sh: no project '$2' under $1" >&2; exit 5; fi
}

# The value project_status maps an event to: "k=v, k=v", records split at
# commas, the key before the first "=". Empty when the event has none.
ps_value() { # <event> <map>
  printf '%s' "$2" | awk -v e="$1" 'BEGIN { RS = "," }
    {
      i = index($0, "="); if (i == 0) next
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      gsub(/^[ \t\n]+|[ \t\n]+$/, "", k); gsub(/^[ \t\n]+|[ \t\n]+$/, "", v)
      if (k == e) { print v; exit }
    }'
}

cmd_project_status() {
  [ $# -eq 2 ] || [ $# -eq 3 ] || die "usage: fr.sh project-status <issue> <event> [<gate>]"
  local ref event="$2" gate="${3:-}" map title field owner url value out num ver pfield phase
  case " $PS_EVENTS " in
    *" $event "*) ;;
    *) die "unknown event '$event' — one of: $PS_EVENTS" ;;
  esac
  if [ -n "$gate" ] && ! printf '%s' "$gate" | grep -qE '^[a-z][a-z0-9-]*$'; then
    die "gate must be one lowercase word, e.g. ci — got '$gate'"
  fi
  ref=$(issue_ref "$1")
  # the local log first: the autopilot reads it, the board may be off or fail
  log_line "$PREFIX-${ref##*#}" "event $event${gate:+ $gate}" ||
    echo "fr.sh: warning: event not recorded in the local FR log" >&2
  map=$(cfg project_status "")
  if [ -z "$map" ]; then echo "project status: not configured (no project_status in the profile)"; return 0; fi
  title=$(cfg project "")
  if [ -z "$title" ]; then echo "fr.sh: project_status is set but project is empty — status not written" >&2; exit 5; fi
  value=$(ps_value "$event" "$map")
  if [ -z "$value" ]; then echo "project status: no value for '$event' in project_status — nothing written"; return 0; fi
  # "Phase/Status" writes two single-select fields; "Status" alone leaves the
  # phase as it is (input, failed, blocked belong to whatever phase runs)
  pfield=$(cfg project_phase_field ""); phase=""
  case "$value" in
    */*)
      phase=${value%%/*}; value=${value#*/}
      phase=$(printf '%s' "$phase" | sed 's/[[:space:]]*$//'); value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//')
      if [ -z "$pfield" ]; then echo "fr.sh: project_status maps '$event' to '$phase/$value' but the profile has no project_phase_field — status not written" >&2; exit 5; fi
      [ -n "$phase" ] && [ -n "$value" ] || die "project_status: '$event' needs Phase/Status, got '$phase/$value'" ;;
  esac
  if ! command -v gh >/dev/null; then echo "fr.sh: gh not found — project status not written" >&2; exit 5; fi
  ver=$(gh_version)
  if gh_older_than "$GH_MIN" "$ver"; then echo "fr.sh: gh $ver is older than $GH_MIN — project status not written; upgrade gh" >&2; exit 5; fi
  field=$(cfg project_status_field Status)
  owner=${ref%%/*}
  url="https://github.com/${ref%%#*}/issues/${ref##*#}"
  project_lookup "$owner" "$title"; num=$PROJ_NUM
  if ! out=$(gh project item-add "$num" --owner "$owner" --url "$url" 2>&1); then
    echo "fr.sh: cannot add $ref to '$title' — $out" >&2; exit 5
  fi
  if ! out=$(gh project item-edit "$num" --owner "$owner" --url "$url" --field "$field" --value "$value" 2>&1); then
    echo "fr.sh: project status not written for $ref — $out" >&2; exit 5
  fi
  if [ -n "$phase" ]; then
    if ! out=$(gh project item-edit "$num" --owner "$owner" --url "$url" --field "$pfield" --value "$phase" 2>&1); then
      echo "fr.sh: project status written for $ref ($value), but not its phase — $out" >&2; exit 5
    fi
    echo "project status: $ref → $phase / $value ($title)"
  else
    echo "project status: $ref → $value ($title)"
  fi
}

# The values of the status column. GitHub's `updateProjectV2Field` replaces the
# whole option list, so every existing option goes back with its id, colour and
# text: items keep their values and the project's workflows keep their targets.
# New options are grey; the user colours them on the board. The workflows
# themselves (Item added, Item closed, Auto-add) have no API — the report names
# the page. Exit 5 = nothing changed, the reason on stderr.
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }

cmd_project_options() {
  local title field owner values v q fid existing names missing keep new_json body out
  local oid ocolor oname odesc
  title=$(cfg project "")
  [ -n "$title" ] || die "no project in the profile"
  field=$(cfg project_status_field Status)
  if [ $# -gt 0 ]; then
    values=$(printf '%s\n' "$@")
  else
    # every value of "k=v, k=v", once, in order
    values=$(printf '%s' "$(cfg project_status "")" | awk 'BEGIN { RS = "," }
      {
        i = index($0, "="); if (i == 0) next
        v = substr($0, i + 1); gsub(/^[ \t\n]+|[ \t\n]+$/, "", v)
        if (v != "" && !(v in seen)) { seen[v]; print v }
      }')
  fi
  [ -n "$values" ] || die "no values: give them as arguments, or set project_status in the profile"
  command -v gh >/dev/null || die "gh not found"
  dr_init; owner=${DR%%/*}
  project_lookup "$owner" "$title"
  # the column's options with everything the update must send back; the
  # description comes last — it may be empty, a name cannot
  if ! q=$(gh api graphql -f query="{ repositoryOwner(login: $(json_str "$owner")) { ... on ProjectV2Owner { projectV2(number: $PROJ_NUM) { field(name: $(json_str "$field")) { ... on ProjectV2SingleSelectField { id options { id name color description } } } } } } }" \
        --jq '.data.repositoryOwner.projectV2.field | select(.id != null) | .id, (.options[] | [.id, .color, .name, .description] | join("\t"))' 2>&1) || [ -z "$q" ]; then
    echo "fr.sh: no single-select column '$field' in project '$title' — $q" >&2; exit 5
  fi
  fid=$(printf '%s\n' "$q" | sed -n '1p')
  existing=$(printf '%s\n' "$q" | sed '1d')
  names=$(printf '%s\n' "$existing" | cut -f3)
  missing=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if ! printf '%s\n' "$names" | grep -qixF -- "$v"; then missing="$missing$v"$'\n'; fi
  done <<EOF
$values
EOF
  if [ -z "$missing" ]; then
    echo "project options: '$field' of '$title' has every value — $(printf '%s\n' "$names" | paste -sd ',' - | sed 's/,/, /g')"
    return 0
  fi
  keep=""
  while IFS=$'\t' read -r oid ocolor oname odesc; do
    [ -n "$oid" ] || continue
    keep="$keep${keep:+,}{\"id\":$(json_str "$oid"),\"name\":$(json_str "$oname"),\"color\":$(json_str "$ocolor"),\"description\":$(json_str "$odesc")}"
  done <<EOF
$existing
EOF
  new_json=""
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    new_json="$new_json${new_json:+,}{\"name\":$(json_str "$v"),\"color\":\"GRAY\",\"description\":\"\"}"
  done <<EOF
$missing
EOF
  body="{\"query\":\"mutation(\$input: UpdateProjectV2FieldInput!) { updateProjectV2Field(input: \$input) { projectV2Field { ... on ProjectV2SingleSelectField { options { name } } } } }\",\"variables\":{\"input\":{\"fieldId\":$(json_str "$fid"),\"singleSelectOptions\":[${keep}${keep:+,}${new_json}]}}}"
  if ! out=$(printf '%s' "$body" | gh api graphql --input - --jq '[.data.updateProjectV2Field.projectV2Field.options[].name] | join(", ")' 2>&1); then
    echo "fr.sh: options not added to '$field' of '$title' — $out" >&2; exit 5
  fi
  echo "project options: added $(printf '%s' "$missing" | paste -sd ',' - | sed 's/,/, /g') to '$field' of '$title' — now: $out"
  echo "workflows have no API — set them on $PROJ_URL/workflows: Item added to project → the 'defined' value, Item closed → the 'done' value, Auto-add to project with is:issue label:fr"
}

# --- worktree hooks -----------------------------------------------------------
#
# A project may need more than the checkout in every FR worktree — a dev stack
# per worktree so FRs can be tested in parallel, installed dependencies, an .env
# with this worktree's ports. The profile names one command for each end of the
# worktree's life: `worktree_setup` runs after :start added or resumed it,
# `worktree_teardown` in :done before anything removes it — `claude rm` included,
# which deletes a finished session's worktree. The plugin knows nothing else
# about them: the command runs in the worktree through `bash -c`, without stdin,
# with the FR in its environment; its output passes through, its exit code
# decides. Exit 6 = the hook failed; the skill leaves the worktree as it is and
# the user decides. Setup runs on every start of an FR, resume included, so the
# command must be idempotent. A hook runs only at the root of a linked worktree
# of this clone — never in the main checkout, never in a directory inside a
# worktree, never for the temporary `_drop-` worktrees. A worktree already gone
# gets the command printed for running by hand: a teardown such as
# `docker compose down -v` must not run anywhere else.
HOOK_FAILED=6

cmd_hook() {
  [ $# -eq 3 ] || die "usage: fr.sh hook setup|teardown <ID> <worktree path>"
  local kind="$1" key ref num dir top main common branch cmd rc
  case "$kind" in
    setup) key=worktree_setup ;;
    teardown) key=worktree_teardown ;;
    *) die "unknown hook '$kind': setup or teardown" ;;
  esac
  ref=$(issue_ref "$2"); num=${ref##*#}
  # the command comes from the main checkout's profile — the base branch's,
  # reviewed in PRs — never from the copy on an FR branch, wherever we run
  main=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
  local PROFILE="$main/$PROFILE"
  cmd=$(cfg "$key" "")
  if [ -z "$cmd" ]; then echo "no $key in the profile — nothing to run"; return 0; fi
  dir=$(caller_path "$3")
  if [ ! -d "$dir" ]; then
    echo "fr.sh: no such directory: $3 — a hook runs only in its worktree. By hand, if needed:" >&2
    echo "  FR_ID=$PREFIX-$num FR_NUMBER=$num bash -c '$cmd'" >&2
    exit 1
  fi
  dir=$(cd "$dir" && pwd -P)
  case "$(basename "$dir")" in
    _drop-*) die "temporary worktrees get no hook: $dir" ;;
  esac
  top=$(cd "$dir" && git rev-parse --show-toplevel 2>/dev/null) || die "$3 is not inside a git worktree"
  [ "$(cd "$top" && pwd -P)" = "$dir" ] || die "$3 is not the root of a worktree (that is $top)"
  [ "$(cd "$main" && pwd -P)" != "$dir" ] || die "$3 is the main checkout — hooks run only in FR worktrees"
  common=$(cd "$dir" && cd "$(git rev-parse --git-common-dir)" && pwd -P)
  [ "$common" = "$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" ] ||
    die "$3 is not a worktree of this repository"
  branch=$(cd "$dir" && git branch --show-current 2>/dev/null) || branch=""
  echo "$key for $PREFIX-$num in $dir: $cmd"
  if (cd "$dir" && FR_ID="$PREFIX-$num" FR_NUMBER="$num" FR_BRANCH="$branch" FR_WORKTREE="$dir" \
        bash -c "$cmd" </dev/null); then
    echo "$key done for $PREFIX-$num"
  else
    rc=$?
    echo "fr.sh: $key failed (exit $rc) for $PREFIX-$num in $dir" >&2
    exit "$HOOK_FAILED"
  fi
}

# A line for the user through the project's notify_command. A background
# session has no terminal, and Claude Code tells about one that waits only
# while `claude agents` is open — so the autopilot's `pipeline --wait` calls
# this for every row that needs the user, and the autopilot for its summary.
# The command gets FR_ID (or `autopilot`), FR_PHASE, FR_DETAIL, FR_SESSION (the
# session the autopilot launched last for the FR, if any), FR_REPO and
# FR_MESSAGE (one line of all of it) in its environment — to be used quoted:
# the detail carries text from GitHub. Runs in the main checkout, without
# stdin, with the main checkout's profile. No command → nothing, exit 0; the
# command fails → its output and exit 6 — never a reason for the caller to stop.
cmd_notify() { # <ID|autopilot> <phase> [<detail>]
  [ $# -ge 2 ] && [ $# -le 3 ] || die "usage: fr.sh notify <ID|autopilot> <phase> [<detail>]"
  local id="$1" phase="$2" detail="${3:-}" main cmd sess="" msg rc
  local el ev eg ll lk ls nf ap
  main=$(main_worktree)
  case "$PROFILE" in /*) ;; *) local PROFILE="$main/$PROFILE" ;; esac   # pipeline has switched already
  cmd=$(cfg notify_command "")
  [ -n "$cmd" ] || return 0
  if [ "$id" != autopilot ]; then
    id=$(fr_id "$id"); read_facts "$id"
    [ "$ls" = "-" ] || sess=$ls
  fi
  if [ -n "$detail" ]; then msg="$id $phase: $detail"; else msg="$id $phase"; fi
  if (cd "$main" && FR_ID="$id" FR_PHASE="$phase" FR_DETAIL="$detail" FR_SESSION="$sess"         FR_REPO="$(cur_repo 2>/dev/null || true)" FR_MESSAGE="$msg" bash -c "$cmd" </dev/null); then
    return 0
  else
    rc=$?
    echo "fr.sh: notify_command failed (exit $rc) for: $msg" >&2
    return "$HOOK_FAILED"   # a return, not an exit: pipeline --wait goes on after a failed notification
  fi
}

# --- spec model ---------------------------------------------------------------
#
# With `spec_dir` in the profile a project keeps one living spec per
# capability, `<spec_dir>/<capability>/spec.md`, in OpenSpec's shape: `# Title`,
# `## Purpose`, `## Requirements`, `### Requirement: Name` with a SHALL sentence,
# `#### Scenario: Name` with GIVEN/WHEN/THEN/AND lines. An FR then carries a
# **spec delta** instead of acceptance criteria — in the issue before the start,
# in the FR doc after — flat, one requirement per heading, English keywords
# because this script parses them:
#
#   ## Spec delta
#   Specs: talent-onboarding, crm-sync          Specs: none = scenarios only
#   ### ADDED <capability>: <requirement>       the full requirement text + scenarios
#   ### MODIFIED <capability>: <requirement>    Base: <fingerprint>, the full new text
#   ### REMOVED <capability>: <requirement>     Base: <fingerprint>, Reason: …
#   ### RENAMED <capability>: <old> -> <new>    Base: <fingerprint>
#   #### Scenario: <name>                       - WHEN … - THEN … - Evidence: unit test | eval | check on test
#
# The scenarios are the acceptance check, each naming its evidence. `validate`
# checks a delta against the base branch's specs; `fingerprint` hashes a
# requirement so the FR doc pins what MODIFIED/REMOVED/RENAMED refer to (`spec`
# writes the Base lines at the start, `validate` stops when the base moved);
# `fold` applies the delta to the spec files. Settings from the main checkout's
# profile.

EVIDENCE_RE='^(unit test|eval|check on test)([ :(-].*)?$'

# the delta of a markdown text (stdin) as records: specs<T>list · block<T>n<T>op<T>cap<T>name<T>new
# · base<T>n<T>fp · text<T>n<T>line (the block's content, Base excluded) · scen<T>n<T>name<T>evidence
# <T>whens<T>thens (evidence "-" = none) · err<T>message · nodelta · criteria (a ## Acceptance criteria section exists)
DELTA_AWK='
BEGIN { n = 0; none = 0; sn = 0; found = 0; crit = 0; fence = 0; d = 0 }
function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
function opens(s) { return gsub(/<details/, "&", s) }
function closes(s) { return gsub(/<\/details>/, "&", s) }
function original(l) {
  if (d > 0) { d += opens(l) - closes(l); return 1 }
  if (l ~ /^<details> *<summary> *Original request/) { d = opens(l) - closes(l); return 1 }
  return 0
}
function flush_scen() { if (sn) printf "scen\t%s\t%s\t%s\t%s\t%s\n", n, sname, (ev == "" ? "-" : ev), whens, thens; sn = 0 }
{
  sub(/\r$/, "")
  if (original($0)) next
  if ($0 ~ /^ *(```|~~~)/) { fence = !fence; if (insec && n) printf "text\t%s\t%s\n", n, $0; next }
  if (fence) { if (insec && n) printf "text\t%s\t%s\n", n, $0; next }
  if ($0 ~ /^## /) {
    s = tolower(trim(substr($0, 4))); flush_scen()
    insec = (s == "spec delta"); if (insec) found = 1
    if (s == "acceptance criteria") crit = 1
    next
  }
  if (!insec) next
  if ($0 ~ /^#### +Scenario:/) {
    flush_scen()
    if (!n && !none) { printf "err\ta scenario before any requirement block: %s\n", $0; next }
    sn = 1; sname = trim(substr($0, index($0, ":") + 1)); ev = ""; whens = 0; thens = 0
    if (n) printf "text\t%s\t%s\n", n, $0
    next
  }
  if ($0 ~ /^### /) {
    flush_scen(); h = trim(substr($0, 5)); n++
    if (h ~ /^(ADDED|MODIFIED|REMOVED|RENAMED) +[a-z0-9][a-z0-9-]*: *[^ ]/) {
      op = h; sub(/ .*$/, "", op); rest = trim(substr(h, length(op) + 1))
      cap = rest; sub(/:.*$/, "", cap); name = trim(substr(rest, index(rest, ":") + 1)); new = ""
      if (op == "RENAMED") {
        if (name ~ / -> /) { new = name; sub(/^.* -> /, "", new); sub(/ -> .*$/, "", name); new = trim(new); name = trim(name) }
        else printf "err\tRENAMED needs old -> new: %s\n", $0
      }
      printf "block\t%s\t%s\t%s\t%s\t%s\n", n, op, cap, name, new
    } else printf "err\tnot a delta heading (### ADDED|MODIFIED|REMOVED|RENAMED <capability>: <requirement>): %s\n", $0
    next
  }
  if ($0 ~ /^#+ /) { printf "err\tunknown heading in the spec delta: %s\n", $0; next }
  if ($0 ~ /^[ \t]*$/) { if (n) printf "text\t%s\t\n", n; next }
  if (!n && !sn) {
    if ($0 ~ /^Specs: */) { v = trim(substr($0, 7)); printf "specs\t%s\n", v; if (tolower(v) == "none") none = 1; next }
    printf "err\ttext outside a requirement block: %s\n", $0; next
  }
  if (sn) {
    if ($0 ~ /^- *[Ee]vidence:/) {
      e = tolower(trim(substr($0, index($0, ":") + 1)))
      if (e ~ EVRE) ev = e; else printf "err\tscenario %s: the evidence must be unit test, eval or check on test: %s\n", sname, $0
    } else if ($0 ~ /^- *WHEN /) whens++
    else if ($0 ~ /^- *THEN /) thens++
    else if ($0 !~ /^- *(GIVEN|AND) /) printf "err\tscenario %s: not a GIVEN/WHEN/THEN/AND/Evidence line: %s\n", sname, $0
    if (n) printf "text\t%s\t%s\n", n, $0
    next
  }
  if ($0 ~ /^Base: */) { printf "base\t%s\t%s\n", n, trim(substr($0, 6)); next }
  printf "text\t%s\t%s\n", n, $0
}
END { flush_scen(); if (!found) print "nodelta"; if (crit) print "criteria" }'

# a spec file (stdin) as records: req<T>name · scen<T>name · line<T>text (the requirement body) · end
SPEC_AWK='
function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
{
  sub(/\r$/, "")
  if ($0 ~ /^ *(```|~~~)/) fence = !fence
  if (!fence && $0 ~ /^### +Requirement:/) { if (inreq) print "end"; inreq = 1; print "req\t" trim(substr($0, index($0, ":") + 1)); next }
  if (!fence && $0 ~ /^##? /) { if (inreq) print "end"; inreq = 0; next }
  if (inreq) { if (!fence && $0 ~ /^#### +Scenario:/) print "scen\t" trim(substr($0, index($0, ":") + 1)); print "line\t" $0 }
}
END { if (inreq) print "end" }'

SPEC_DIR=""
spec_profile() { # the main checkout's profile, spec_dir into SPEC_DIR; dies without one
  SPEC_DIR=$(cfg spec_dir "")
  [ -n "$SPEC_DIR" ] || die "no spec_dir in the profile — the spec model is off"
}
nname() { s="$1" awk "$NN_AWK"'BEGIN { print nn(ENVIRON["s"]) }'; }   # not -v: it would process backslash escapes in the name
# the fingerprint of a requirement's body (stdin): 8 hex of its text with the
# lines trimmed and blank lines dropped — spacing never changes it, words do
fp() { awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 != "") print }' | git hash-object --stdin | cut -c1-8; }
# the spec of a capability at <rev>, or in the working tree with `-`
spec_file() { # <rev|-> <cap>
  if [ "$1" = "-" ]; then
    local top; top=$(git rev-parse --show-toplevel)
    [ -f "$top/$SPEC_DIR/$2/spec.md" ] || return 1
    cat "$top/$SPEC_DIR/$2/spec.md"
  else
    git show "$1:$SPEC_DIR/$2/spec.md" 2>/dev/null
  fi
}
# the requirements of a capability's spec: name<T>normalized name<T>fingerprint<T>scenario names (\036-joined)
spec_reqs() { # <rev|-> <cap>
  local src kind rest name="" body="" scen="" us
  us=$(printf '\036')
  src=$(spec_file "$1" "$2") || return 1
  printf '%s\n' "$src" | awk "$SPEC_AWK" | {
    while IFS=$'\t' read -r kind rest; do
      case "$kind" in
        req) name=$rest; body=""; scen="" ;;
        scen) scen="$scen${scen:+$us}$rest" ;;
        line) body="$body$rest"$'\n' ;;
        end) printf '%s\t%s\t%s\t%s\n' "$name" "$(nname "$name")" "$(printf '%s' "$body" | fp)" "$scen" ;;
      esac
    done
  }
}

cmd_fingerprint() { # <cap> <requirement> [--rev <rev> | --local]
  local cap="" name="" rev="" row
  while [ $# -gt 0 ]; do
    case "$1" in
      --rev) [ $# -ge 2 ] || die "--rev needs a revision"; rev="$2"; shift ;;
      --local) rev="-" ;;
      -*) die "usage: fr.sh fingerprint <capability> <requirement> [--rev <rev> | --local]" ;;
      *) if [ -z "$cap" ]; then cap="$1"; elif [ -z "$name" ]; then name="$1"; else die "usage: fr.sh fingerprint <capability> <requirement> [--rev <rev> | --local]"; fi ;;
    esac
    shift
  done
  [ -n "$cap" ] && [ -n "$name" ] || die "usage: fr.sh fingerprint <capability> <requirement> [--rev <rev> | --local]"
  local PROFILE="$(main_worktree)/$PROFILE"
  spec_profile
  [ -n "$rev" ] || rev=$(base_ref)
  row=$(spec_reqs "$rev" "$cap" | n="$(nname "$name")" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $2 == n && !f { print; f = 1 }') || true
  [ -n "$row" ] || die "no requirement '$name' in $cap at ${rev/-/the working tree}"
  printf '%s\n' "$row" | cut -f3
}

# validate_text <text> <rev|->: error:/warning:/ok: lines; return 4 on errors
validate_text() {
  local text="$1" rev="$2" recs errs=0 nblk nscen specs="" none=0 caps=" " used=" " seen=" " n op cap name new base reqs row fpnow bscen s ns k c us
  us=$(printf '\036')
  recs=$(printf '%s\n' "$text" | awk -v EVRE="$EVIDENCE_RE" "$DELTA_AWK")
  if printf '%s\n' "$recs" | grep -qx nodelta; then echo "error: no ## Spec delta section"; return 4; fi
  if printf '%s\n' "$recs" | grep -qx criteria; then echo "error: both ## Acceptance criteria and ## Spec delta — one of them"; errs=$((errs + 1)); fi
  while IFS=$'\t' read -r k rest; do
    if [ "$k" = err ]; then echo "error: $rest"; errs=$((errs + 1)); fi
  done <<EOF
$recs
EOF
  specs=$(printf '%s\n' "$recs" | awk -F '\t' '$1 == "specs" && !f { print $2; f = 1 }')
  if [ -z "$specs" ]; then echo "error: no 'Specs:' line — the capabilities the delta touches, or 'Specs: none'"; errs=$((errs + 1))
  elif [ "$(nname "$specs")" = none ]; then none=1
  else
    for c in $(printf '%s' "$specs" | tr ',' ' '); do
      case "$c" in
        [a-z0-9]*) printf '%s' "$c" | grep -qE '^[a-z0-9][a-z0-9-]*$' || { echo "error: capability '$c' is not a slug (lowercase letters, digits, -)"; errs=$((errs + 1)); } ;;
        *) echo "error: capability '$c' is not a slug (lowercase letters, digits, -)"; errs=$((errs + 1)) ;;
      esac
      caps="$caps$c "
    done
  fi
  while IFS=$'\t' read -r k n op cap name new; do
    [ "$k" = block ] || continue
    if [ "$none" = 1 ]; then echo "error: $op $cap: $name — 'Specs: none' allows scenarios only, no requirement changes"; errs=$((errs + 1)); continue; fi
    case "$caps" in *" $cap "*) ;; *) echo "error: $op $cap: $name — $cap is not in the Specs line"; errs=$((errs + 1)) ;; esac
    used="$used$cap "
    case "$seen" in *" $cap:$(nname "$name") "*) echo "error: $op $cap: $name — the requirement appears twice in the delta"; errs=$((errs + 1)) ;; esac
    seen="$seen$cap:$(nname "$name") "
    reqs=$(spec_reqs "$rev" "$cap") || reqs=""
    row=$(printf '%s\n' "$reqs" | n="$(nname "$name")" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $2 == n && !f { print; f = 1 }')
    base=$(printf '%s\n' "$recs" | n="$n" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $1 == "base" && $2 == n && !f { print $3; f = 1 }')
    case "$op" in
      ADDED)
        [ -z "$row" ] || { echo "error: ADDED $cap: $name — exists in $cap already (as '$(printf '%s' "$row" | cut -f1)'); MODIFIED?"; errs=$((errs + 1)); } ;;
      MODIFIED|REMOVED|RENAMED)
        if [ -z "$reqs" ]; then echo "error: $op $cap: $name — no spec $SPEC_DIR/$cap/spec.md at ${rev/-/the working tree}"; errs=$((errs + 1))
        elif [ -z "$row" ]; then echo "error: $op $cap: $name — no such requirement in $cap"; errs=$((errs + 1))
        else
          fpnow=$(printf '%s' "$row" | cut -f3)
          if [ -n "$base" ] && [ "$base" != "$fpnow" ]; then
            echo "error: $op $cap: $name — the requirement changed since the definition (Base: $base, now $fpnow): redo the delta against the current spec"; errs=$((errs + 1))
          fi
          if [ "$op" = MODIFIED ]; then
            bscen=$(printf '%s' "$row" | cut -f4)
            if [ -n "$bscen" ]; then
              printf '%s\n' "$bscen" | tr "$us" '\n' | while IFS= read -r s; do
                [ -n "$s" ] || continue
                printf '%s\n' "$recs" | n="$n" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $1 == "scen" && $2 == n { print $3 }' | while IFS= read -r ns; do nname "$ns"; echo; done | grep -xF "$(nname "$s")" >/dev/null ||
                  echo "warning: MODIFIED $cap: $name drops the scenario '$s' of the base requirement — on purpose?"
              done
            fi
          fi
          if [ "$op" = RENAMED ]; then
            if [ -z "$new" ]; then echo "error: RENAMED $cap: $name — needs 'old -> new'"; errs=$((errs + 1))
            elif printf '%s\n' "$reqs" | n="$(nname "$new")" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $2 == n { f = 1 } END { exit !f }'; then
              echo "error: RENAMED $cap: $name -> $new — '$new' exists in $cap already"; errs=$((errs + 1))
            fi
          fi
          if [ "$op" = REMOVED ] && ! printf '%s\n' "$recs" | n="$n" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $1 == "text" && $2 == n && $3 ~ /^Reason:/ { f = 1 } END { exit !f }'; then
            echo "warning: REMOVED $cap: $name — no 'Reason:' line"
          fi
        fi ;;
    esac
    if [ "$op" = ADDED ] || [ "$op" = MODIFIED ]; then
      if ! printf '%s\n' "$recs" | n="$n" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $1 == "scen" && $2 == n { f = 1 } END { exit !f }'; then
        echo "error: $op $cap: $name — no scenario (#### Scenario: … with WHEN, THEN and Evidence)"; errs=$((errs + 1))
      fi
    fi
  done <<EOF
$recs
EOF
  # every scenario needs its evidence, a WHEN and a THEN
  while IFS=$'\t' read -r k n name ev whens thens; do
    [ "$k" = scen ] || continue
    [ "$ev" != "-" ] || { echo "error: scenario '$name' has no '- Evidence: unit test | eval | check on test' line"; errs=$((errs + 1)); }
    [ "${whens:-0}" -gt 0 ] || { echo "error: scenario '$name' has no '- WHEN' line"; errs=$((errs + 1)); }
    [ "${thens:-0}" -gt 0 ] || { echo "error: scenario '$name' has no '- THEN' line"; errs=$((errs + 1)); }
  done <<EOF
$recs
EOF
  if [ "$none" = 1 ] && ! printf '%s\n' "$recs" | grep -q '^scen	'; then echo "error: 'Specs: none' needs at least one scenario"; errs=$((errs + 1)); fi
  for c in $caps; do case "$used" in *" $c "*) ;; *) echo "warning: $c is in the Specs line but no requirement of it changes" ;; esac; done
  if [ "$errs" = 0 ]; then
    nblk=$(printf '%s\n' "$recs" | grep -c '^block	' || true); nscen=$(printf '%s\n' "$recs" | grep -c '^scen	' || true)
    echo "ok: $nblk requirement changes, $nscen scenarios"
    return 0
  fi
  return 4
}

# the text whose delta is meant: a file, an FR id (its doc, checked out here), or an issue
delta_source() {
  local path row top
  if [ -f "$(caller_path "$1")" ]; then cat "$(caller_path "$1")"; return 0; fi
  if printf '%s' "$1" | grep -qE "^$PREFIX-[0-9]+$"; then
    row=$(rows | awk -F '\t' -v id="$1" '$1 == id') || true
    [ -n "$row" ] || die "no such FR: $1"
    path=$(printf '%s' "$row" | cut -f5); top=$(git rev-parse --show-toplevel)
    [ -n "$path" ] && [ -f "$top/$path" ] || die "$1 has no FR doc checked out here — run this in its worktree, or name the issue"
    cat "$top/$path"; return 0
  fi
  local ref; ref=$(issue_ref "$1")
  gh issue view "${ref##*#}" -R "${ref%%#*}" --json body --jq '.body // ""' || die "cannot read $ref"
}

cmd_validate() { # <issue|ID|file> [--rev <rev> | --local]
  local what="" rev="" text out rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --rev) [ $# -ge 2 ] || die "--rev needs a revision"; rev="$2"; shift ;;
      --local) rev="-" ;;
      -*) die "usage: fr.sh validate <issue|ID|file> [--rev <rev> | --local]" ;;
      *) what="$1" ;;
    esac
    shift
  done
  [ -n "$what" ] || die "usage: fr.sh validate <issue|ID|file> [--rev <rev> | --local]"
  local PROFILE="$(main_worktree)/$PROFILE"
  spec_profile
  [ -n "$rev" ] || rev=$(base_ref)
  text=$(delta_source "$what")
  out=$(validate_text "$text" "$rev") || rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

# Base: <fingerprint> under every MODIFIED/REMOVED/RENAMED heading of a doc
# (stdin), replacing one that is there: what the delta refers to at <rev>
add_base_lines() { # <rev>
  local line insec=0 inblk=0 h op cap name new f
  while IFS= read -r line; do
    case "$line" in
      "## "*) insec=0; inblk=0; [ "$(nname "${line#\#\# }")" = "spec delta" ] && insec=1 ;;
      "### "*) inblk=0 ;;
      Base:*) [ "$inblk" = 0 ] || continue ;;   # a stale pin anywhere in the block: replaced by the new one
    esac
    printf '%s\n' "$line"
    [ "$insec" = 1 ] || continue
    case "$line" in
      "### MODIFIED "*|"### REMOVED "*|"### RENAMED "*)
        h=${line#\#\#\# }; op=${h%% *}; h=${h#* }; cap=${h%%:*}; name=${h#*:}; name=$(printf '%s' "$name" | sed 's/^ *//; s/ *$//')
        [ "$op" != RENAMED ] || name=$(printf '%s' "$name" | sed 's/ -> .*$//; s/ *$//')
        # no early exit in the consumer: under pipefail it would kill spec_reqs and empty f
        f=$(spec_reqs "$1" "$cap" | n="$(nname "$name")" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $2 == n && !f { print $3; f = 1 }') || f=""
        [ -z "$f" ] || printf 'Base: %s\n' "$f"
        inblk=1 ;;
    esac
  done
}

# spec:<capability>:<requirement> for every requirement the FR's delta changes —
# the row's specs column, overlap items beside the paths; nothing without spec_dir
spec_items() { # <row>
  [ -n "$(cfg spec_dir "")" ] || return 0
  printf '%s' "$1" | cut -f13 | tr ';' '\n' | awk 'NF { print "spec:" $0 }'
}

# One operation on a spec file: ADDED appends the requirement to the
# Requirements section, MODIFIED replaces its body, REMOVED drops it, RENAMED
# renames its heading. The new text comes from <textfile>.
spec_apply() { # <file> <op> <name> <new> <textfile>
  local out
  out=$(name="$3" want="$(nname "$3")" newname="$4" awk -v op="$2" -v tf="$5" "$NN_AWK"'
    function trim(s) { gsub(/^[ \t]+/, "", s); gsub(/[ \t]+$/, "", s); return s }
    function body(   l, blank) {
      # the delta text: blank lines as authored, one before every scenario, none at the end
      while ((getline l < tf) > 0) {
        if (l ~ /^[ \t]*$/) { blank = 1; continue }
        if (l ~ /^#### +Scenario:/ || blank) print ""
        blank = 0; print l
      }
      close(tf)
    }
    function add() { if (!lastblank) print ""; print "### Requirement: " name; body(); done = 1; lastblank = 0 }
    BEGIN { skip = 0; done = 0; inreq = 0; fence = 0; lastblank = 1; name = ENVIRON["name"]; want = ENVIRON["want"]; newname = ENVIRON["newname"] }
    {
      if ($0 ~ /^ *(```|~~~)/) fence = !fence
      # one blank line before every heading — also after a replaced or removed block
      if (!fence && $0 ~ /^### +Requirement:/) {
        skip = 0
        if (!lastblank) { print ""; lastblank = 1 }
        if (nn(trim(substr($0, index($0, ":") + 1))) == want) {
          done = 1
          if (op == "MODIFIED") { print; body(); skip = 1; lastblank = 0; next }
          if (op == "REMOVED") { skip = 1; next }
          if (op == "RENAMED") { print "### Requirement: " newname; lastblank = 0; next }
        }
        inreq = 1
      } else if (!fence && $0 ~ /^## /) {
        if (op == "ADDED" && inreq && !done) add()
        inreq = ($0 ~ /^## +Requirements/); skip = 0
        if (!lastblank) { print ""; lastblank = 1 }
      } else if (!fence && $0 ~ /^# /) { skip = 0 }
      if (skip) next
      print; lastblank = ($0 ~ /^[ \t]*$/)
    }
    END { if (op == "ADDED" && !done) add() }' "$1") || return 1
  # one trailing newline, no blank lines at the end
  printf '%s\n' "$out" | awk '{ L[++n] = $0 } END { while (n > 0 && L[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print L[i] }' > "$1"
}

# Fold the delta of an FR into the spec files of this checkout — the FR's
# worktree, after the base branch was merged: ADDED appends, MODIFIED replaces,
# REMOVED deletes, RENAMED renames; a new capability gets a new spec file with
# a Purpose to write. Validated against the working tree's specs first; on
# errors nothing is written (exit 4). Prints what it did; ship commits it.
cmd_fold() { # <ID|file> [--dry-run]
  local what="" dry=0 text vout recs top file tmp k n op cap name new changed="" title rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) dry=1 ;;
      -*) die "usage: fr.sh fold <ID|file> [--dry-run]" ;;
      *) what="$1" ;;
    esac
    shift
  done
  [ -n "$what" ] || die "usage: fr.sh fold <ID|file> [--dry-run]"
  local PROFILE="$(main_worktree)/$PROFILE"
  spec_profile
  text=$(delta_source "$what")
  recs=$(printf '%s\n' "$text" | awk -v EVRE="$EVIDENCE_RE" "$DELTA_AWK")
  # folded already? Every change is in the working tree's specs — a re-ship of a
  # branch that carries the fold commit — then there is nothing to do
  local applied=0 total=0 reqs fpnew
  while IFS=$'\t' read -r k n op cap name new; do
    [ "$k" = block ] || continue
    total=$((total + 1))
    reqs=$(spec_reqs - "$cap") || reqs=""
    case "$op" in
      ADDED|MODIFIED)
        fpnew=$(printf '%s\n' "$recs" | n="$n" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $1 == "text" && $2 == n { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' | fp)
        if printf '%s\n' "$reqs" | n="$(nname "$name")" awk -F '\t' -v f="$fpnew" 'BEGIN { n = ENVIRON["n"] } $2 == n && $3 == f { ok = 1 } END { exit !ok }'; then applied=$((applied + 1)); fi ;;
      REMOVED)
        if ! printf '%s\n' "$reqs" | n="$(nname "$name")" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $2 == n { ok = 1 } END { exit !ok }'; then applied=$((applied + 1)); fi ;;
      RENAMED)
        if printf '%s\n' "$reqs" | awk -F '\t' -v o="$(nname "$name")" -v w="$(nname "$new")" '$2 == w { has = 1 } $2 == o { old = 1 } END { exit !(has && !old) }'; then applied=$((applied + 1)); fi ;;
    esac
  done <<EOF
$recs
EOF
  if [ "$total" = 0 ]; then
    printf '%s\n' "$recs" | grep -qx nodelta && die "no ## Spec delta in $what"
    echo "nothing to fold: the delta changes no requirement (Specs: none)"; return 0
  fi
  if [ "$applied" = "$total" ]; then echo "already folded: every change of the delta is in the specs"; return 0; fi
  if [ "$applied" != 0 ]; then echo "fr.sh: $applied of $total changes are folded already, the others are not — finish by hand and commit" >&2; exit 4; fi
  if ! vout=$(validate_text "$text" "-"); then
    printf '%s\n' "$vout"; echo "fr.sh: nothing folded — the delta does not fit the working tree's specs (the base moved: redo the delta)" >&2; exit 4
  fi
  printf '%s\n' "$vout" | grep '^warning' || true
  top=$(git rev-parse --show-toplevel); tmp=$(mktemp)
  while IFS=$'\t' read -r k n op cap name new; do
    [ "$k" = block ] || continue
    file="$top/$SPEC_DIR/$cap/spec.md"
    printf '%s\n' "$recs" | n="$n" awk -F '\t' 'BEGIN { n = ENVIRON["n"] } $1 == "text" && $2 == n { sub(/^[^\t]*\t[^\t]*\t/, ""); print }' > "$tmp"
    if [ "$dry" = 1 ]; then echo "would fold $op $cap: $name${new:+ -> $new}"; continue; fi
    if [ ! -f "$file" ]; then
      title=$(printf '%s' "$cap" | tr '-' ' ' | awk '{ for (i = 1; i <= NF; i++) $i = toupper(substr($i, 1, 1)) substr($i, 2) } 1')
      mkdir -p "$(dirname "$file")"
      printf '# %s\n\n## Purpose\n\n_Describe the capability — written when its first requirement was folded in._\n\n## Requirements\n' "$title" > "$file"
    fi
    spec_apply "$file" "$op" "$name" "$new" "$tmp" || { rm -f "$tmp"; die "could not fold $op $cap: $name into $file"; }
    echo "folded $op $cap: $name${new:+ -> $new}"
    case " $changed " in *" $cap "*) ;; *) changed="$changed $cap" ;; esac
  done <<EOF
$recs
EOF
  rm -f "$tmp"
  [ "$dry" = 1 ] || for cap in $changed; do echo "changed: $SPEC_DIR/$cap/spec.md"; done
}

# --- autopilot ----------------------------------------------------------------
#
# The autopilot drives the FRs in its queue through start → implement → ship,
# runs the opt-in fix loop (`fix_loop`) and starts the next wave after a merge.
# `pipeline` decides; `launch` starts the sessions. Phases are derived from what
# fr.sh derives anyway — FR doc, branch, worktree lock, PR and checks — plus two
# facts neither git nor GitHub has: the events the sessions reported (written by
# project-status) and the sessions the autopilot launched. Both are appended to
# a log per FR in the git dir that all worktrees of this clone share, like the
# ship lock: a record of what happened here, never a source of truth.

CLAUDE_BIN=${FR_CLAUDE:-claude}

state_dir() {
  local d
  d="$(cd "$(git rev-parse --git-common-dir)" && pwd)/fr-workflow"
  mkdir -p "$d" && echo "$d"
}

log_line() { printf '%s %s\n' "$(date -u +%s)" "$2" >> "$(state_dir)/$1.log"; }

fr_id() { local r; r=$(issue_ref "$1"); echo "$PREFIX-${r##*#}"; }

# Facts from an FR's log, tab-separated: line of the last event, the event, its
# gate; line of the last launch, its kind, its session; fix launches; time of
# the last `approval`. Line numbers, not times, decide what came last.
log_facts() {
  local f; f="$(state_dir)/$1.log"
  [ -f "$f" ] || { printf '0\t-\t-\t0\t-\t-\t0\t0\n'; return 0; }
  awk '
    BEGIN { el = 0; ev = "-"; eg = "-"; ll = 0; lk = "-"; ls = "-"; nf = 0; ap = 0 }
    $2 == "event"  { el = NR; ev = $3; eg = ($4 == "" ? "-" : $4); if ($3 == "approval") ap = $1 }
    $2 == "launch" { ll = NR; lk = $3; ls = ($4 == "" ? "-" : $4); if ($3 == "fix") nf++ }
    END { printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", el, ev, eg, ll, lk, ls, nf, ap }' "$f"
}

# log_facts into the variables el ev eg ll lk ls nf ap of the caller
read_facts() {
  local facts; facts=$(log_facts "$1")
  el=$(printf '%s' "$facts" | cut -f1); ev=$(printf '%s' "$facts" | cut -f2); eg=$(printf '%s' "$facts" | cut -f3)
  ll=$(printf '%s' "$facts" | cut -f4); lk=$(printf '%s' "$facts" | cut -f5); ls=$(printf '%s' "$facts" | cut -f6)
  nf=$(printf '%s' "$facts" | cut -f7); ap=$(printf '%s' "$facts" | cut -f8)
}

# "path<TAB>lock reason" of the worktree that has <branch> checked out
wt_of() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    function out() { if (br == b && !f) { print p "\t" lk; f = 1 } }
    /^worktree / { out(); p = substr($0, 10); br = ""; lk = ""; next }
    /^branch /   { br = substr($0, 8); next }
    /^locked/    { lk = substr($0, 8); if (lk == "") lk = "locked"; next }
    END          { out() }'
}

# A Claude session holds the worktree: Claude Code locks it with a reason that
# names the pid. A lock whose pid is gone is stale — no session. A lock without
# a pid counts as held: never start a second session beside an unknown one.
lock_pid() { printf '%s' "$1" | sed -n 's/.*pid \([0-9][0-9]*\).*/\1/p'; }   # <lock reason>
held() { # <lock reason>
  local pid
  [ -n "$1" ] || return 1
  pid=$(lock_pid "$1")
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null
}

# What a session the autopilot launched is doing, from `claude agents --json`:
# busy; waiting (a permission prompt or a question — nobody answers it in the
# background); idle (its turn ended — the process and its worktree lock linger,
# so the lock alone would call it live); gone (not listed: stopped); unknown
# (claude agents unavailable, or no status for it). Loaded once per run.
AGENTS_JSON=""
load_agents() { AGENTS_JSON=$("$CLAUDE_BIN" agents --json 2>/dev/null) || AGENTS_JSON=""; }
session_state() { # <session id, or the prefix claude --bg printed>
  [ -n "$AGENTS_JSON" ] && [ -n "$1" ] || { echo unknown; return 0; }
  printf '%s' "$AGENTS_JSON" | jq -r --arg s "$1" '
    [.[] | select((.sessionId // "") | startswith($s))]
    | if length == 0 then "gone" else (.[0].status // "unknown") end' 2>/dev/null || echo unknown
}
session_pid() { # <session id, or its prefix> → the pid claude agents lists, or nothing
  [ -n "$AGENTS_JSON" ] && [ -n "$1" ] || return 0
  printf '%s' "$AGENTS_JSON" | jq -r --arg s "$1" '
    [.[] | select((.sessionId // "") | startswith($s))]
    | if length == 0 then "" else ((.[0].pid // "") | tostring) end' 2>/dev/null || true
}
# the pipeline row of a launched session that waits at a prompt (lk, ls of the caller)
waiting_row() { printf 'waiting\treport\tthe %s session %s waits for you: claude attach %s\n' "$lk" "$ls" "$ls"; }

# --permission-mode for the sessions launch starts, from the profile's
# session_permission_mode, or nothing — then the user's own default applies.
# Only modes that keep Claude Code's checks: the profile is a committed file,
# and no commit may switch every launched session to bypassPermissions.
pm_args() {
  local pm; pm=$(cfg session_permission_mode "")
  [ -n "$pm" ] || return 0
  case "$pm" in
    default|acceptEdits|auto|dontAsk) ;;
    *) die "session_permission_mode must be default, acceptEdits, auto or dontAsk — never bypassPermissions; not '$pm'" ;;
  esac
  printf -- '--permission-mode\n%s\n' "$pm"
}

queue_file() { echo "$(state_dir)/autopilot.queue"; }
queue_ids() { local q; q=$(queue_file); if [ -f "$q" ]; then cat "$q"; fi; }

# The board's square an FR waits on for the autopilot: Status (and Phase) as
# project_status maps `defined`. Prints the open FR issues of the issue
# repository standing there whose assignees fit autopilot_assignee — a login,
# `none` for unassigned ones, empty for any — as "number<TAB>logins". Exit 5
# when the board cannot be read, with the reason.
board_ready() {
  local title owner map value pfield phase pq out
  title=$(cfg project ""); [ -n "$title" ] || { echo "fr.sh: autopilot_queue is project, but the profile has no project" >&2; return 5; }
  map=$(cfg project_status "")
  value=$(ps_value defined "$map")
  [ -n "$value" ] || { echo "fr.sh: autopilot_queue is project, but project_status maps no 'defined' value — the board has no square for ready FRs" >&2; return 5; }
  pfield=$(cfg project_phase_field ""); phase=""
  case "$value" in
    */*) phase=$(printf '%s' "${value%%/*}" | sed 's/[[:space:]]*$//'); value=$(printf '%s' "${value#*/}" | sed 's/^[[:space:]]*//')
         [ -n "$pfield" ] || { echo "fr.sh: project_status maps 'defined' to '$phase/$value' but the profile has no project_phase_field" >&2; return 5; } ;;
  esac
  command -v gh >/dev/null || { echo "fr.sh: gh not found — board not read" >&2; return 5; }
  dr_init; owner=${DR%%/*}
  project_lookup "$owner" "$title"
  pq=""; [ -z "$pfield" ] || pq="phase: fieldValueByName(name: $(json_str "$pfield")) { ... on ProjectV2ItemFieldSingleSelectValue { name } }"
  # one page of 100 per call; --paginate follows pageInfo
  if ! out=$(gh api graphql --paginate -f query="query(\$endCursor: String) { repositoryOwner(login: $(json_str "$owner")) { ... on ProjectV2Owner { projectV2(number: $PROJ_NUM) { items(first: 100, after: \$endCursor) { pageInfo { hasNextPage endCursor } nodes { content { ... on Issue { number state repository { nameWithOwner } labels(first: 30) { nodes { name } } assignees(first: 10) { nodes { login } } } } status: fieldValueByName(name: $(json_str "$(cfg project_status_field Status)")) { ... on ProjectV2ItemFieldSingleSelectValue { name } } $pq } } } } } }" \
        --jq '.data.repositoryOwner.projectV2.items.nodes[] | select(.content.number != null) | [(.content.number | tostring), (.content.repository.nameWithOwner | ascii_downcase), .content.state, ([.content.labels.nodes[].name] | join(",")), (.status.name // "-"), (.phase.name // "-"), (([.content.assignees.nodes[].login] | join(",")) | if . == "" then "-" else . end)] | join("\t")' 2>&1); then
    echo "fr.sh: cannot read the items of '$title' — $out" >&2; return 5
  fi
  printf '%s\n' "$out" | repo="$DR" st="$value" ph="$phase" who="$(cfg autopilot_assignee "")" awk -F '\t' '
    BEGIN { repo = ENVIRON["repo"]; st = tolower(ENVIRON["st"]); ph = tolower(ENVIRON["ph"]); who = tolower(ENVIRON["who"]) }
    $2 != repo || $3 != "OPEN" { next }
    { n = split($4, L, ","); ok = 0; for (i = 1; i <= n; i++) if (L[i] == "fr") ok = 1; if (!ok) next }
    tolower($5) != st { next }
    ph != "" && tolower($6) != ph { next }
    {
      a = tolower($7)
      if (who == "none") { if (a != "-") next }
      else if (who != "") { n = split(a, A, ","); ok = 0; for (i = 1; i <= n; i++) if (A[i] == who) ok = 1; if (!ok) next }
      print $1 "\t" $7
    }'
}

# queue sync: every FR the board holds ready for the autopilot (board_ready)
# that is not queued and not merged or dropped joins the queue. Exit 0 with the
# board unreadable too — the pipeline runs on; the reason goes to stderr.
queue_sync() {
  local ready q id added="" line num who ROWS st
  [ "$(cfg autopilot_queue manual)" = project ] || { echo "queue: autopilot_queue is manual — nothing to sync (fr.sh queue add <ID>)"; return 0; }
  ready=$(board_ready) || { echo "queue: board not read — the queue is as it was" >&2; return 0; }
  q=$(queue_file); ROWS=$(rows 2>/dev/null) || ROWS=""
  while IFS=$'\t' read -r num who; do
    [ -n "$num" ] || continue
    id="$PREFIX-$num"
    if [ -f "$q" ] && grep -qxF "$id" "$q"; then continue; fi
    st=$(printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id { print $2; exit }')
    case "$st" in merged|dropped) continue ;; esac
    echo "$id" >> "$q"; log_line "$id" "queued board${who:+ $who}"
    added="$added${added:+, }$id"
  done <<EOF
$ready
EOF
  if [ -n "$added" ]; then echo "queue: added from the board — $added"; else echo "queue: nothing new on the board"; fi
}

cmd_queue() {
  local sub="${1:-list}" q a id
  [ $# -gt 0 ] && shift
  q=$(queue_file)
  case "$sub" in
    add)
      [ $# -gt 0 ] || die "usage: fr.sh queue add <ID>..."
      for a in "$@"; do
        id=$(fr_id "$a")
        if [ -f "$q" ] && grep -qxF "$id" "$q"; then continue; fi
        echo "$id" >> "$q"
      done
      queue_ids ;;
    rm)
      [ $# -gt 0 ] || die "usage: fr.sh queue rm <ID>..."
      for a in "$@"; do
        id=$(fr_id "$a")
        [ -f "$q" ] || break
        grep -vxF "$id" "$q" > "$q.tmp" || true
        mv "$q.tmp" "$q"
      done
      queue_ids ;;
    clear) rm -f "$q" "$(state_dir)/autopilot.seen" ;;
    sync) queue_sync ;;
    list) queue_ids ;;
    session) if [ -f "$(state_dir)/autopilot.session" ]; then cat "$(state_dir)/autopilot.session"; fi ;;
    *) die "usage: fr.sh queue add|rm|sync|list|clear|session [<ID>...]" ;;
  esac
}

# A profile list "[a, b]" as one item per line — only the outer brackets go,
# a bot's name keeps its own: [claude[bot]] is claude[bot]
cfg_list() {
  cfg "$1" "" | sed 's/^[[:space:]]*\[//; s/\][[:space:]]*$//' | tr ',' '\n' |
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | awk 'NF'
}

fix_allows() { # <checks|comments>
  case "$(cfg fix_loop off)" in
    checks) [ "$1" = checks ] ;;
    checks+comments|comments+checks) return 0 ;;
    *) return 1 ;;
  esac
}

# The open PR of an FR branch — the FR doc's `pr` is committed only at the end
# of ship — else the doc's.
pr_of() { # <branch> <doc pr>
  local n
  # only PRs from this repository: a fork may name its branch like ours
  n=$(gh pr list -R "$(cur_repo)" --head "$1" --state open --json number,isCrossRepository \
    --jq '[.[] | select(.isCrossRepository | not)][0].number // empty' 2>/dev/null) || n=""
  if [ -n "$n" ]; then echo "$n"; else echo "$2"; fi
}

# One PR as lines: "pr state mergeable mergeStateStatus", "check name
# fail|pending|pass", "comment epoch association login url" — comments, and
# reviews that say something (a body, or changes requested).
J_PR='"pr\t\(.state)\t\(.mergeable)\t\(.mergeStateStatus)\t\(if .autoMergeRequest then "auto" else "-" end)",
  (.statusCheckRollup[]? | "check\t\((.name // .context // "?") | gsub("\t"; " "))\t\(
     if ((.conclusion // .state // "") | IN("FAILURE","ERROR","TIMED_OUT","CANCELLED","ACTION_REQUIRED","STARTUP_FAILURE")) then "fail"
     elif ((.status // "") | IN("QUEUED","IN_PROGRESS","PENDING","WAITING","REQUESTED")) or ((.state // "") == "PENDING") then "pending"
     else "pass" end)"),
  (.comments[]? | "comment\t\(.createdAt | fromdateiso8601)\t\(.authorAssociation)\t\(.author.login)\t\(.url)"),
  (.reviews[]? | select(.submittedAt != null and (.state == "CHANGES_REQUESTED" or (.body // "") != ""))
     | "comment\t\(.submittedAt | fromdateiso8601)\t\(.authorAssociation)\t\(.author.login)\treview \(.state)")'

pr_facts() { gh pr view "$1" -R "$(cur_repo)" --json state,mergeable,mergeStateStatus,autoMergeRequest,statusCheckRollup,comments,reviews --jq "$J_PR"; }

# Failing checks of the PR facts on stdin: "skip<TAB>name" for those in
# fix_skip_checks (they always stop), "fix<TAB>name" for the others.
failing_checks() {
  awk -F '\t' -v skip="$(cfg_list fix_skip_checks | tr '\n' '\037')" '
    BEGIN { n = split(skip, s, "\037"); for (i = 1; i <= n; i++) if (s[i] != "") S[tolower(s[i])] = 1 }
    $1 == "check" && $3 == "fail" { print ((tolower($2) in S) ? "skip" : "fix") "\t" $2 }'
}

# Comments after <epoch> that may brief a fix session: "login<TAB>url". From
# people with write access to the repository, as GitHub's collaborator
# permission says (admin or write; a maintainer reads as write, triage as
# read). authorAssociation alone is not enough: MEMBER is any member of the
# organization, COLLABORATOR may have read access only. The repository's OWNER
# needs no lookup; NONE, CONTRIBUTOR and first-timers cannot have write access
# and get none. One lookup per login, kept for PERM_TTL seconds in the state
# dir's perm.cache — the pipeline asks every tick for every FR with such
# comments, and a revoked permission still lapses within the quarter hour. A
# permission that cannot be read — a rate limit, a token without the scope —
# is no permission, said once on stderr, never cached. A bot counts only when
# listed in fix_comment_bots, in bot form. Everyone else's comment is ignored
# — it is never an instruction to a session.
PERM_TTL=900
trusted_comments() { # <epoch>  (PR facts on stdin)
  local repo verdict login url perm out cache now seen=" "
  repo=$(cur_repo); cache="$(state_dir)/perm.cache"; now=$(date +%s)
  awk -F '\t' -v since="$1" -v bots="$(cfg_list fix_comment_bots | tr '\n' '\037')" '
    function bare(x) { x = tolower(x); sub(/^app\//, "", x); sub(/\[bot\]$/, "", x); return x }
    # an author counts as a listed bot only in bot form, app/<name> or
    # <name>[bot]: a plain login never matches, whatever it is called
    function isbot(x) { x = tolower(x); return x ~ /^app\// || x ~ /\[bot\]$/ }
    BEGIN { n = split(bots, b, "\037"); for (i = 1; i <= n; i++) if (b[i] != "") B[bare(b[i])] = 1 }
    $1 == "comment" && $2 + 0 > since + 0 {
      if ($3 == "OWNER" || (isbot($4) && (bare($4) in B))) print "yes\t" $4 "\t" $5
      else if (($3 == "MEMBER" || $3 == "COLLABORATOR") && $4 ~ /^[A-Za-z0-9_-]+$/) print "ask\t" $4 "\t" $5
    }' |
  while IFS=$'\t' read -r verdict login url; do
    if [ "$verdict" = ask ]; then
      case "$seen" in
        *" $login=yes "*) ;;
        *" $login=no "*) continue ;;
        *)
          # the cache first: repo, login, permission, time of the lookup
          perm=$([ -f "$cache" ] && awk -F '\t' -v r="$repo" -v l="$login" -v now="$now" -v ttl="$PERM_TTL" \
            '$1 == r && $2 == l && now - $4 < ttl { v = $3 } END { print v }' "$cache" || true)
          if [ -z "$perm" ]; then
            if out=$(gh api "repos/$repo/collaborators/$login/permission" --jq .permission 2>&1 </dev/null); then
              case "$out" in
                admin|write|read|none) perm=$out; printf '%s\t%s\t%s\t%s\n' "$repo" "$login" "$perm" "$now" >> "$cache" ;;
                *) perm=none ;;   # null or something new: not write access, not worth keeping
              esac
            else
              echo "fr.sh: cannot read the permission of $login in $repo — the comment is not trusted: $out" >&2
              perm=none
            fi
          fi
          case "$perm" in
            admin|write) seen="$seen$login=yes " ;;
            *) seen="$seen$login=no "; continue ;;
          esac ;;
      esac
    fi
    printf '%s\t%s\n' "$login" "$url"
  done
}

# The verdict on a gate a fix session could address: "fix" or "report", and why
fix_verdict() { # <what> <class> <nf>
  local max; max=$(cfg fix_attempts 2)
  if ! fix_allows "$2"; then printf 'report\t%s (fix_loop: %s)\n' "$1" "$(cfg fix_loop off)"
  elif [ "$3" -ge "$max" ]; then printf 'report\t%s, fix attempts used up (%s/%s)\n' "$1" "$3" "$max"
  else printf 'fix\t%s, attempt %s/%s\n' "$1" "$(($3 + 1))" "$max"; fi
}

# "phase<TAB>action<TAB>detail" of one FR — the heart of the autopilot.
# Actions: start, ship, fix, report, wait, none.
phase_of() { # <row> <wave> <conflicts>
  local id status loc ref docpr el ev eg ll lk ls nf ap wt reason own live sst spid lpid pr facts fails skips cmts fin
  id=$(printf '%s' "$1" | cut -f1); status=$(printf '%s' "$1" | cut -f2)
  loc=$(printf '%s' "$1" | cut -f3); ref=$(printf '%s' "$1" | cut -f4); docpr=$(printf '%s' "$1" | cut -f6)
  read_facts "$id"
  case "$status" in
    merged)
      if [ "$(cfg autopilot_finish off)" = on ]; then
        fin=$(awk '$2 == "finish" { $1 = ""; $2 = ""; sub(/^  /, ""); f = $0 } END { print f }' "$(state_dir)/$id.log" 2>/dev/null)
        if [ -n "$fin" ]; then printf 'merged\treport\tfinish failed: %s\n' "$fin"; else printf 'merged\tfinish\t\n'; fi
      else printf 'merged\tnone\t\n'; fi
      return 0 ;;
    dropped) printf 'dropped\tnone\t\n'; return 0 ;;
    open)
      if [ "$ev" = input ]; then printf 'waiting\treport\tthe start needs your decision: /fr-workflow:start %s\n' "$id"
      elif [ "$2" = 1 ]; then printf 'queued\tstart\t\n'
      else printf 'queued\twait\twave %s: %s\n' "${2:-?}" "${3:-}"; fi
      return 0 ;;
    in-progress|in-review) ;;
    *) printf 'unknown\treport\tstatus %s\n' "$status"; return 0 ;;
  esac
  # who works on it: the session the autopilot launched (own), by its state —
  # busy or waiting is live, idle or gone has ended. The worktree lock then still
  # counts when another pid holds it (the user's own session, between turns
  # too), not when it is the lingering lock of the session that ended; and it
  # decides alone when claude agents says nothing.
  own=0; live=0; sst=unknown; spid=""
  if [ "$ls" != "-" ]; then sst=$(session_state "$ls"); spid=$(session_pid "$ls"); fi
  case "$sst" in busy|waiting) own=1; live=1 ;; esac
  if [ "$live" = 0 ] && [ "$loc" = branch ]; then
    wt=$(wt_of "$ref"); reason=$(printf '%s' "$wt" | cut -f2)
    if [ -n "$wt" ] && held "$reason"; then
      lpid=$(lock_pid "$reason")
      case "$sst" in
        idle|gone) if [ -z "$lpid" ] || [ "$lpid" != "$spid" ]; then live=1; fi ;;
        *) own=1; live=1 ;;   # claude agents said nothing: the lock holder is taken for the launched session
      esac
    fi
  fi
  # the ship session reported approval: the PR decides, however long its process lingers
  if [ "$ev" = approval ] && [ "$ll" -le "$el" ]; then own=0; live=0; sst=done; fi
  # a launch after the last event: that session has not reported yet
  if [ "$ll" -gt "$el" ]; then
    if [ "$sst" = waiting ]; then waiting_row
    elif [ "$own" = 1 ]; then
      if [ "$lk" = ship ]; then printf 'shipping\tnone\t%s\n' "$ls"; else printf 'implementing\tnone\t%s %s\n' "$lk" "$ls"; fi
    else
      printf 'stalled\treport\tthe %s session %s ended without a result: claude logs %s\n' "$lk" "$ls" "$ls"
    fi
    return 0
  fi
  case "$ev" in
    # the detail changes when the session holding the worktree ends: a launch
    # refused for it is retried once the user closed it
    implemented)
      if [ "$live" = 1 ]; then printf 'implemented\tship\ta session still holds the worktree\n'
      else printf 'implemented\tship\t\n'; fi
      return 0 ;;
    input)   printf 'waiting\treport\t%s: claude attach %s\n' "$eg" "$ls"; return 0 ;;
    blocked) printf 'blocked\treport\t%s\n' "$eg"; return 0 ;;
    failed)
      if [ "$eg" = checks ] || [ "$eg" = ci ]; then
        skips=""
        if [ "$eg" = ci ]; then
          pr=$(pr_of "$ref" "$docpr")
          if [ -n "$pr" ] && facts=$(pr_facts "$pr" 2>/dev/null); then
            skips=$(printf '%s\n' "$facts" | failing_checks | awk -F '\t' '$1 == "skip" { print $2 }' | paste -sd ',' -)
          fi
        fi
        if [ -n "$skips" ]; then printf 'failed\treport\tci: %s never goes to the fix loop\n' "$skips"
        else printf 'failed\t%s\n' "$(fix_verdict "$eg" checks "$nf")"; fi
      else
        printf 'failed\treport\t%s\n' "$eg"
      fi
      return 0 ;;
  esac
  if [ "$sst" = waiting ]; then waiting_row; return 0; fi
  if [ "$live" = 1 ]; then
    if [ "$lk" = ship ]; then printf 'shipping\tnone\t\n'; else printf 'implementing\tnone\t\n'; fi
    return 0
  fi
  if [ "$status" = in-progress ]; then
    printf 'stalled\treport\tno session works on it and none reported a result\n'; return 0
  fi
  # in review: the PR decides — merged soon, conflicting, red, or commented on
  pr=$(pr_of "$ref" "$docpr")
  [ -n "$pr" ] || { printf 'review\treport\tin-review without an open PR\n'; return 0; }
  facts=$(pr_facts "$pr" 2>/dev/null) || { printf 'review\twait\tPR #%s not readable\n' "$pr"; return 0; }
  case "$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "pr" { print $2 "/" $3 }')" in
    MERGED/*) printf 'review\twait\tPR #%s merged, waiting for the base branch\n' "$pr"; return 0 ;;
    CLOSED/*) printf 'review\treport\tPR #%s closed without merge\n' "$pr"; return 0 ;;
    */CONFLICTING) printf 'review\tship\tPR #%s conflicts with the base branch\n' "$pr"; return 0 ;;
  esac
  fails=$(printf '%s\n' "$facts" | failing_checks)
  if [ -n "$fails" ]; then
    skips=$(printf '%s\n' "$fails" | awk -F '\t' '$1 == "skip" { print $2 }' | paste -sd ',' -)
    fails=$(printf '%s\n' "$fails" | cut -f2 | paste -sd ',' -)
    if [ -n "$skips" ]; then printf 'review\treport\tPR #%s red: %s, never to the fix loop\n' "$pr" "$skips"
    else printf 'review\t%s\n' "$(fix_verdict "PR #$pr red: $fails" checks "$nf")"; fi
    return 0
  fi
  if [ "$ap" != 0 ]; then
    cmts=$(printf '%s\n' "$facts" | trusted_comments "$ap" | cut -f1 | sort -u | paste -sd ',' -)
    if [ -n "$cmts" ]; then
      printf 'review\t%s\n' "$(fix_verdict "PR #$pr: comments by $cmts" comments "$nf")"; return 0
    fi
  fi
  if [ "$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "pr" { print $5 }')" = auto ]; then
    printf 'merging\tnone\tPR #%s: auto-merge enabled, GitHub merges when the base branch rules are met\n' "$pr"
  else
    printf 'review\tnone\tPR #%s waits for your merge\n' "$pr"
  fi
}

pipeline_once() {
  local ids open ov id row wave conf active limit ph
  if [ "$(cfg autopilot_queue manual)" = project ]; then queue_sync >/dev/null || true; fi
  ids=$(queue_ids)
  printf 'id\tphase\taction\tdetail\n'
  [ -n "$ids" ] || return 0
  ROWS=$(rows); load_agents
  open=$(for id in $ids; do printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id && $2 == "open" { print id }'; done)
  ov=""
  if [ -n "$open" ]; then ov=$(cmd_overlap $open --no-fetch 2>/dev/null) || ov=""; fi
  ph=$(for id in $ids; do
    row=$(printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id')
    if [ -z "$row" ]; then printf '%s\tunknown\treport\tno open FR issue and no FR doc\n' "$id"; continue; fi
    wave=$(printf '%s\n' "$ov" | awk -F '\t' -v id="$id" '$1 == "wave" && $3 == id { print $2 }')
    conf=$(printf '%s\n' "$ov" | awk -F '\t' -v id="$id" '
      $1 == "conflict" && ($2 == id || $3 == id) { o = ($2 == id ? $3 : $2); s = s (s == "" ? "" : "; ") o " " $4 }
      END { print s }')
    printf '%s\t%s\n' "$id" "$(phase_of "$row" "$wave" "$conf")"
  done)
  # at most autopilot_sessions FR sessions at a time; starts beyond it wait
  limit=$(cfg autopilot_sessions 3)
  active=$(printf '%s\n' "$ph" | awk -F '\t' '$2 == "implementing" || $2 == "shipping" || $3 == "ship" || $3 == "fix" { n++ } END { print n + 0 }')
  printf '%s\n' "$ph" | awk -F '\t' -v free=$((limit - active)) 'BEGIN { OFS = "\t" }
    $3 == "start" { if (free > 0) free--; else { $3 = "wait"; $4 = "session limit (autopilot_sessions)" } }
    { print }'
}

# --wait <s>: block until the result differs from the one the autopilot saw
# last, checking every <s> seconds (fetch included); --max <s> ends the wait
# anyway; --wait 0 returns at once and records what it returned, for a first
# look. The autopilot wakes for changes, not for every check.
cmd_pipeline() {
  local wait="" max=0 nofetch="" out seen t0 id phase action detail
  # the autopilot's settings come from the main checkout's profile — the base
  # branch's — wherever this runs; never from the copy on an FR branch
  local PROFILE="$(main_worktree)/$PROFILE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-fetch) nofetch=1 ;;
      --wait) [ $# -ge 2 ] || die "--wait needs seconds"; wait="$2"; shift ;;
      --max) [ $# -ge 2 ] || die "--max needs seconds"; max="$2"; shift ;;
      *) die "usage: fr.sh pipeline [--no-fetch] [--wait <s> [--max <s>]]" ;;
    esac
    shift
  done
  [ -z "$wait" ] || printf '%s' "$wait" | grep -qE '^[0-9]+$' || die "--wait needs seconds"
  printf '%s' "$max" | grep -qE '^[0-9]+$' || die "--max needs seconds"
  [ -n "$nofetch" ] || do_fetch
  if [ -z "$wait" ]; then pipeline_once; return 0; fi
  seen="$(state_dir)/autopilot.seen"; t0=$(date -u +%s)
  while :; do
    out=$(pipeline_once)
    # --wait 0 returns at once and still remembers the result, like every --wait
    if [ "$wait" = 0 ] || [ ! -f "$seen" ] || [ "$out" != "$(cat "$seen")" ]; then break; fi
    if [ "$max" -gt 0 ] && [ $(( $(date -u +%s) - t0 + wait )) -gt "$max" ]; then break; fi
    sleep "$wait"
    [ -n "$nofetch" ] || do_fetch
  done
  # rows that need the user — reports, and a PR waiting for the merge — and are
  # new since the last result go to the profile's notify_command
  if [ -n "$(cfg notify_command "")" ]; then
    printf '%s\n' "$out" | awk -F '\t' 'NR > 1 && ($3 == "report" || ($2 == "review" && $3 == "none"))' |
      while IFS=$'\t' read -r id phase action detail; do
        if [ -f "$seen" ] && grep -qxF "$(printf '%s\t%s\t%s\t%s' "$id" "$phase" "$action" "$detail")" "$seen"; then continue; fi
        cmd_notify "$id" "$phase" "$detail" || true
      done
  fi
  printf '%s\n' "$out" > "$seen"
  printf '%s\n' "$out"
}

# The session id `claude --bg` prints: the first token of its output that looks
# like one — six or more letters, digits, - or _, at least one digit.
bg_session_id() { tr -s ' \t\r' '\n' | tr -d '.,;:()[]`' | grep -E '^[A-Za-z0-9][A-Za-z0-9_-]{5,}$' | grep '[0-9]' | head -n 1; }

main_worktree() { git worktree list --porcelain | sed -n '1s/^worktree //p'; }

launch_autopilot() {
  local out sid prev st pm
  pm=$(pm_args)   # a bad profile value stops here, before anything is stopped or forgotten
  cd "$(main_worktree)"
  # the autopilot recorded here: running → it picks the queue up by itself
  # (exit 3); its loop ended and the process lingers idle → replaced; gone →
  # nothing to do; no answer from claude agents → no second one beside what may
  # be a running one.
  prev=$(cmd_queue session)
  if [ -n "$prev" ]; then
    load_agents; st=$(session_state "$prev")
    case "$st" in
      busy|waiting) echo "fr.sh: the autopilot runs as $prev ($st) and picks the queue up by itself; /fr-workflow:autopilot stop ends it" >&2; exit 3 ;;
      idle) "$CLAUDE_BIN" stop "$prev" >/dev/null 2>&1 || true ;;
      gone) ;;
      *) die "cannot tell whether the autopilot $prev still runs (claude agents --json gave no answer): look at 'claude agents' — running → it picks the queue up by itself; gone → launch again" ;;
    esac
  fi
  # a new autopilot has seen nothing: its first `pipeline --wait` returns at once
  rm -f "$(state_dir)/autopilot.seen"
  set -- $pm
  out=$("$CLAUDE_BIN" --bg -n fr-autopilot --model "$(cfg autopilot_model sonnet)" \
    --effort "$(cfg autopilot_effort medium)" "$@" '/fr-workflow:autopilot --loop' 2>&1) || { printf '%s\n' "$out" >&2; exit 1; }
  sid=$(printf '%s\n' "$out" | bg_session_id)
  [ -n "$sid" ] || { printf '%s\n' "$out" >&2; die "no session id in the output of claude --bg"; }
  printf '%s\n' "$sid" > "$(state_dir)/autopilot.session"
  echo "launched autopilot as $sid (fr-autopilot): claude logs $sid"
}

# One background session for a started FR, in its worktree, with the model the
# kind calls for. The prompt is a fixed slash command — no text from the issue.
cmd_launch() {
  [ $# -ge 1 ] || die "usage: fr.sh launch implement|fix|ship <ID> [--replace <session>] | fr.sh launch autopilot"
  local kind="$1" id row status loc ref title model effort wt name reason stop n sname prompt out sid i pm spid lpid
  local el ev eg ll lk ls nf ap
  local PROFILE="$(main_worktree)/$PROFILE"   # the main checkout's settings, see cmd_pipeline
  pm=$(pm_args)   # a bad profile value stops here, before any session is stopped
  shift
  if [ "$kind" = autopilot ]; then launch_autopilot; return 0; fi
  case "$kind" in implement|fix|ship) ;; *) die "unknown launch '$kind': implement, fix, ship or autopilot" ;; esac
  [ $# -ge 1 ] || die "usage: fr.sh launch $kind <ID> [--replace <session>]"
  id=$(fr_id "$1"); shift
  stop=""
  if [ "${1:-}" = --replace ]; then stop="${2:-}"; [ -n "$stop" ] || die "--replace needs a session id"; fi
  row=$(rows | awk -F '\t' -v id="$id" '$1 == id')
  [ -n "$row" ] || die "no such FR: $id"
  status=$(printf '%s' "$row" | cut -f2); loc=$(printf '%s' "$row" | cut -f3); ref=$(printf '%s' "$row" | cut -f4)
  case "$status" in in-progress|in-review) ;; *) die "$id is $status: only a started FR gets a session" ;; esac
  [ "$loc" = branch ] || die "$id is not on its FR branch here (location $loc)"
  wt=$(wt_of "$ref")
  [ -n "$wt" ] || die "no worktree of $ref on this machine: /fr-workflow:start $id prepares it"
  name=$(basename "$(printf '%s' "$wt" | cut -f1)"); reason=$(printf '%s' "$wt" | cut -f2)
  if [ "$kind" = ship ]; then
    model=$(cfg ship_model opus); effort=$(cfg ship_effort high)
  else
    model=$(printf '%s' "$row" | cut -f11); effort=$(printf '%s' "$row" | cut -f12)
    [ -n "$model" ] || model=$(cfg impl_model opus)
    [ -n "$effort" ] || effort=$(cfg impl_effort high)
  fi
  read_facts "$id"
  n=$((nf + 1))
  if [ "$kind" = fix ] && [ "$n" -gt "$(cfg fix_attempts 2)" ]; then
    echo "fr.sh: $id has used its $(cfg fix_attempts 2) fix attempts" >&2; exit 3
  fi
  # one session per worktree: a live one is stopped first — the autopilot's own
  # (the lock names its pid; when claude agents says nothing, the recorded
  # session is taken for the holder), or the one named with --replace; any
  # other is never touched
  if held "$reason"; then
    if [ -z "$stop" ] && [ "$ls" != "-" ]; then
      load_agents; spid=$(session_pid "$ls"); lpid=$(lock_pid "$reason")
      if [ -z "$AGENTS_JSON" ] || [ -z "$lpid" ] || [ "$lpid" = "$spid" ]; then stop=$ls; fi
    fi
    if [ -z "$stop" ]; then
      echo "fr.sh: a session the autopilot did not start holds $name ($reason): end it, or pass its id from 'claude agents' with --replace" >&2
      exit 3
    fi
    "$CLAUDE_BIN" stop "$stop" >/dev/null 2>&1 || die "cannot stop session $stop"
    i=0
    while held "$(wt_of "$ref" | cut -f2)"; do
      i=$((i + 1))
      if [ "$i" -gt 30 ]; then echo "fr.sh: $name is still held after stopping $stop" >&2; exit 3; fi
      sleep 1
    done
  fi
  # the title comes from a customer-written issue: session name only, without
  # quotes, backticks, $ or backslashes
  title=$(printf '%s' "$row" | cut -f9 | tr -d "'\"\`\$\\\\" | cut -c1-60)
  case "$kind" in
    implement) sname="$id $title"; prompt="/fr-workflow:implement $id" ;;
    fix)       sname="$id fix $n";  prompt="/fr-workflow:implement $id fix" ;;
    ship)      sname="$id ship";    prompt="/fr-workflow:ship $id" ;;
  esac
  # the hand-off to the review phase: on the board (best effort) and in the log
  if [ "$kind" = ship ]; then (cmd_project_status "$id" review) || true; fi
  cd "$(main_worktree)"
  set -- $pm
  out=$("$CLAUDE_BIN" -w "$name" --bg --model "$model" --effort "$effort" "$@" -n "$sname" "$prompt" 2>&1) ||
    { printf '%s\n' "$out" >&2; exit 1; }
  sid=$(printf '%s\n' "$out" | bg_session_id)
  [ -n "$sid" ] || { printf '%s\n' "$out" >&2; die "no session id in the output of claude --bg"; }
  log_line "$id" "launch $kind $sid"
  echo "launched $kind $id as $sid ($sname, $model/$effort)"
}

# What the next fix session is to fix: the gate that stopped the ship, or the
# red checks and the trusted comments on the PR since the last approval.
# Test files, for the merge gate: deleting one, or focusing or skipping a test,
# never passes unnoticed. The living specs (spec_dir) are not tests.
is_test_file() { grep -E '(^|/)(tests?|__tests__)/|\.(test|spec)\.[A-Za-z0-9]+$|_test\.(go|py|rb|rs)$|(^|/)test_[^/]*\.py$' || true; }
TEST_MARKERS='\.only\(|\.skip\(|[^A-Za-z0-9_](xit|xdescribe|xtest|fit|fdescribe|ftest|iit|ddescribe)\(|@pytest\.mark\.skip|@unittest\.skip|@Disabled|@Ignore[^A-Za-z0-9_]|t\.Skip\('
CI_SKIP='\[(skip ci|ci skip|no ci|skip actions|actions skip)\]|skip-checks:'

# merge-gate <ID> [--no-fetch]: the deterministic checks before the ship session
# asks GitHub to merge — exit 4 with every reason when one does not hold. The
# FR is in review on its branch with an open PR of this repository that is not
# conflicting and has no red check; the local log's last event is no stopped
# gate; the FR doc records the acceptance check with nothing failed and nothing
# unverified that the user did not accept; the branch deletes no test file and
# adds no focused or skipped test; no CI skip marker anywhere. Pending checks
# are fine — auto-merge waits for them.
cmd_merge_gate() {
  [ $# -ge 1 ] || die "usage: fr.sh merge-gate <ID> [--no-fetch]"
  local id row status loc ref path docpr pr facts bad="" fails pend bref br sect f marks del skipm ev eg el ll lk ls nf ap n
  id=$(fr_id "$1"); shift
  [ "${1:-}" = --no-fetch ] || do_fetch
  row=$(rows | awk -F '\t' -v id="$id" '$1 == id')
  [ -n "$row" ] || die "no such FR: $id"
  status=$(printf '%s' "$row" | cut -f2); loc=$(printf '%s' "$row" | cut -f3)
  ref=$(printf '%s' "$row" | cut -f4); path=$(printf '%s' "$row" | cut -f5); docpr=$(printf '%s' "$row" | cut -f6)
  [ "$status" = in-review ] || bad="$bad"$'\n'"- the FR doc says status: $status, not in-review (the acceptance check is not recorded)"
  [ "$loc" = branch ] || bad="$bad"$'\n'"- $id is not on its FR branch ($loc)"
  pr=""; n=0; pend=0
  if [ "$loc" = branch ]; then
    pr=$(pr_of "$ref" "$docpr")
    if [ -z "$pr" ]; then bad="$bad"$'\n'"- no open PR of this repository for $ref"
    elif ! facts=$(pr_facts "$pr" 2>/dev/null); then bad="$bad"$'\n'"- PR #$pr not readable"
    else
      case "$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "pr" { print $2 "/" $3 }')" in
        OPEN/CONFLICTING) bad="$bad"$'\n'"- PR #$pr conflicts with the base branch" ;;
        OPEN/*) ;;
        *) bad="$bad"$'\n'"- PR #$pr is $(printf '%s\n' "$facts" | awk -F '\t' '$1 == "pr" { print $2 }'), not open" ;;
      esac
      fails=$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "check" && $3 == "fail" { print $2 }' | paste -sd ',' - | sed 's/,/, /g')
      [ -z "$fails" ] || bad="$bad"$'\n'"- red checks on PR #$pr: $fails"
      n=$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "check" && $3 == "pass" { n++ } END { print n + 0 }')
      pend=$(printf '%s\n' "$facts" | awk -F '\t' '$1 == "check" && $3 == "pending" { n++ } END { print n + 0 }')
      skipm=$(gh pr view "$pr" -R "$(cur_repo)" --json title,body --jq '.title, .body' 2>/dev/null | grep -iE "$CI_SKIP" | head -n 1) || skipm=""
      [ -z "$skipm" ] || bad="$bad"$'\n'"- a CI skip marker in the PR title or body: $skipm"
    fi
  fi
  read_facts "$id"
  case "$ev" in failed|blocked|input) bad="$bad"$'\n'"- the local log's last event is $ev${eg:+ $eg}: a gate stopped and nothing passed since" ;; esac
  if [ "$loc" = branch ]; then
    bref=$(base_ref); br=$(pick_ref "$ref")
    sect=$(git show "$br:$path" 2>/dev/null | awk '/^## /{ p = ($0 ~ /^## Acceptance check/) } p')
    if [ -z "$sect" ]; then bad="$bad"$'\n'"- the FR doc has no ## Acceptance check section"
    else
      f=$(printf '%s\n' "$sect" | grep -iE 'unverified' | grep -viE 'accepted by' | head -n 1) || f=""
      [ -z "$f" ] || bad="$bad"$'\n'"- an unverified criterion nobody accepted: $f"
      f=$(printf '%s\n' "$sect" | grep -iE '(^|[^a-z])failed([^a-z]|$)' | head -n 1) || f=""
      [ -z "$f" ] || bad="$bad"$'\n'"- the acceptance check records a failure: $f"
    fi
    del=$({ g diff --name-only --diff-filter=D "$bref...$br" 2>/dev/null || true; } | is_test_file | paste -sd ',' - | sed 's/,/, /g')
    [ -z "$del" ] || bad="$bad"$'\n'"- test files deleted on the branch: $del"
    marks=$({ g diff --name-only --diff-filter=AM "$bref...$br" 2>/dev/null || true; } | is_test_file |
      while IFS= read -r f; do
        { g diff "$bref...$br" -- "$f" 2>/dev/null | grep '^+' | grep -v '^+++' | grep -E "$TEST_MARKERS" | head -n 1 |
          f="$f" awk '{ print ENVIRON["f"] ": " substr($0, 2) }'; } || true
      done | head -n 3 | paste -sd ';' - | sed 's/;/; /g')
    [ -z "$marks" ] || bad="$bad"$'\n'"- a focused or skipped test added on the branch: $marks"
    skipm=$(git log --format=%B "$bref..$br" 2>/dev/null | grep -iE "$CI_SKIP" | head -n 1) || skipm=""
    [ -z "$skipm" ] || bad="$bad"$'\n'"- a CI skip marker in a commit message: $skipm"
  fi
  if [ -n "$bad" ]; then
    echo "fr.sh: $id is not ready to merge:$bad" >&2; exit 4
  fi
  echo "merge-gate: $id PR #$pr ok — $n checks green, $pend pending; acceptance check recorded, no stopped gate, tests intact"
}

# merge <ID>: with auto_merge: auto, after the merge gate, ask GitHub to merge
# the PR — `gh pr merge --auto`: merged at once when the base branch's rules are
# already met, otherwise when they are. The rules decide, never this command;
# no --admin, no bypass. Exit 4 = not asked, with the reason.
cmd_merge() {
  [ $# -eq 1 ] || die "usage: fr.sh merge <ID>"
  local id mode method out pr
  id=$(fr_id "$1")
  mode=$(cfg auto_merge off)
  case "$mode" in
    auto) ;;
    off) echo "fr.sh: auto_merge is off — the merge is the user's" >&2; exit 4 ;;
    *) die "auto_merge must be off or auto, not '$mode'" ;;
  esac
  method=$(cfg merge_method squash)
  case "$method" in squash|merge|rebase) ;; *) die "merge_method must be squash, merge or rebase, not '$method'" ;; esac
  out=$(cmd_merge_gate "$id") || exit $?
  echo "$out"
  pr=$(printf '%s\n' "$out" | sed -n 's/^merge-gate: .* PR #\([0-9][0-9]*\) ok.*/\1/p')
  [ -n "$pr" ] || die "merge-gate named no PR"
  if ! out=$(gh pr merge "$pr" -R "$(cur_repo)" --auto "--$method" 2>&1); then
    log_line "$id" "merge refused $pr"
    echo "fr.sh: GitHub did not take the merge request for PR #$pr — $out" >&2; exit 4
  fi
  log_line "$id" "merge auto $pr"
  echo "merge: PR #$pr handed to GitHub ($method) — merged when the base branch's rules are met: ${out:-auto-merge enabled}"
}

# The FR branch of an id, by name (fr_branch_re), local or on origin — a
# merged FR's row points at the base branch, its branch may still be here.
branch_of_id() { # <ID>
  local idl; idl=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  fr_branches | awk -v id="$idl" 'index(tolower($0), id) {
      s = tolower($0); i = index(s, id); b = (i == 1 ? "" : substr(s, i - 1, 1)); a = substr(s, i + length(id), 1)
      if ((b == "" || b == "/" || b == "-") && (a == "" || a == "/" || a == "-")) print }' | head -n 1
}

# finish <ID>: after the merge, what needs no decision — the worktree hook,
# the worktree, the local branch, the board, the queue. Issues and requests
# stay with /fr-workflow:done. Exit 3 = not finished, with the reason, logged
# so the pipeline reports it once instead of retrying.
# The local branch ends exactly at the head of the merged PR: every commit on
# it is in what GitHub merged, and -D loses nothing. git's -d cannot tell after
# a squash merge once GitHub deleted the remote branch (delete-branch-on-merge).
at_merged_pr_head() { # <pr> <branch>
  local head
  case "$1" in ""|-) return 1 ;; esac
  head=$(gh pr view "$1" -R "$(cur_repo)" --json state,headRefOid --jq 'select(.state == "MERGED") | .headRefOid' 2>/dev/null) || return 1
  [ -n "$head" ] || return 1
  [ "$head" = "$(git rev-parse --verify --quiet "refs/heads/$2")" ]
}

cmd_finish() {
  [ $# -eq 1 ] || die "usage: fr.sh finish <ID>"
  local id row status docpr ref wt path reason st rc out i el ev eg ll lk ls nf ap
  id=$(fr_id "$1")
  row=$(rows | awk -F '\t' -v id="$id" '$1 == id')
  [ -n "$row" ] || die "no such FR: $id"
  status=$(printf '%s' "$row" | cut -f2); docpr=$(printf '%s' "$row" | cut -f6)
  if [ "$status" != merged ]; then echo "fr.sh: $id is $status, not merged — nothing to finish" >&2; exit 4; fi
  # the row of a merged FR points at the base branch; the FR branch by its name
  ref=$(branch_of_id "$id")
  if [ -z "$ref" ] || [ "$ref" = "$BASE" ]; then
    (cmd_project_status "$id" done) || true
    cmd_queue rm "$id" >/dev/null
    echo "finished $id: no FR branch here, board done, out of the queue — issues and requests: /fr-workflow:done $id"
    return 0
  fi
  wt=$(wt_of "$ref")
  if [ -n "$wt" ]; then
    path=$(printf '%s' "$wt" | cut -f1); reason=$(printf '%s' "$wt" | cut -f2)
    # The session the autopilot launched for this FR, lingering idle once the
    # FR is merged, is ended — its work is done; anyone else's session is not.
    # The lock may name a pid that is not the session's: `claude --bg` writes
    # it from the launcher, which has exited by now in a container.
    read_facts "$id"; load_agents; st=unknown
    if [ "$ls" != "-" ]; then st=$(session_state "$ls"); fi
    if [ "$st" = idle ]; then
      "$CLAUDE_BIN" stop "$ls" >/dev/null 2>&1 || true
      i=0; while held "$(wt_of "$ref" | cut -f2)"; do i=$((i + 1)); [ "$i" -le 30 ] || break; sleep 1; done
    fi
    reason=$(wt_of "$ref" | cut -f2)
    if held "$reason"; then
      log_line "$id" "finish a session still holds the worktree ($reason)"
      echo "fr.sh: $id not finished — a session still holds $path ($reason): end it, or /fr-workflow:done $id" >&2; exit 3
    elif [ -n "$reason" ]; then
      # a lock whose process is gone is stale: lifted, like :done does by hand
      git worktree unlock "$path" 2>/dev/null || true
    fi
    rc=0; out=$( (cmd_hook teardown "$id" "$path") 2>&1 ) || rc=$?
    printf '%s\n' "$out"
    if [ "$rc" = "$HOOK_FAILED" ]; then
      (cmd_project_status "$id" blocked teardown) || true
      log_line "$id" "finish worktree_teardown failed"
      echo "fr.sh: $id not finished — worktree_teardown failed; the worktree stays: /fr-workflow:done $id after a look" >&2; exit 3
    fi
    if ! out=$(git worktree remove "$path" 2>&1); then
      log_line "$id" "finish worktree not removed: $(printf '%s' "$out" | head -n 1)"
      echo "fr.sh: $id not finished — $out" >&2; exit 3
    fi
  fi
  if git show-ref --verify --quiet "refs/heads/$ref"; then
    if git branch -d "$ref" >/dev/null 2>&1; then echo "branch $ref deleted locally"
    elif at_merged_pr_head "$docpr" "$ref" && git branch -D "$ref" >/dev/null 2>&1; then
      echo "branch $ref deleted locally — its tip is the head of the merged PR #$docpr"
    else echo "branch $ref kept: git refuses -d (origin/$ref gone, or unmerged commits) — /fr-workflow:done $id decides"
    fi
  fi
  (cmd_project_status "$id" done) || true
  cmd_queue rm "$id" >/dev/null
  echo "finished $id: ${wt:+worktree removed, }board done, out of the queue — issues and requests: /fr-workflow:done $id"
}

cmd_fix_brief() {
  [ $# -eq 1 ] || die "usage: fr.sh fix-brief <ID>"
  local id row ref docpr pr facts el ev eg ll lk ls nf ap
  local PROFILE="$(main_worktree)/$PROFILE"   # the main checkout's settings, see cmd_pipeline
  id=$(fr_id "$1")
  row=$(rows | awk -F '\t' -v id="$id" '$1 == id')
  [ -n "$row" ] || die "no such FR: $id"
  ref=$(printf '%s' "$row" | cut -f4); docpr=$(printf '%s' "$row" | cut -f6)
  read_facts "$id"
  echo "FR: $id   branch: $ref   attempt: $((nf + 1))/$(cfg fix_attempts 2)"
  if [ "$ev" = failed ] && [ "$eg" = checks ]; then
    echo "gate: local checks: the ship's *Local checks before commit* failed. Run them, fix what fails."
    return 0
  fi
  pr=$(pr_of "$ref" "$docpr")
  if [ -z "$pr" ]; then echo "gate: $ev $eg, no open PR"; return 0; fi
  facts=$(pr_facts "$pr") || die "cannot read PR #$pr"
  echo "PR: #$pr"
  printf '%s\n' "$facts" | failing_checks | awk -F '\t' -v pr="$pr" '
    $1 == "fix"  { print "red check: " $2 "   (gh pr checks " pr "; gh run view <run-id> --log-failed)" }
    $1 == "skip" { print "red check, not for the fix loop: " $2 }'
  if [ "$ap" != 0 ] && fix_allows comments; then
    printf '%s\n' "$facts" | trusted_comments "$ap" | awk -F '\t' '{ print "comment by " $1 ": " $2 }'
  fi
}

cmd_check() {
  local ok=1 repo project ver note k v local_set local_other
  # cur_repo exits its subshell on failure, so test the assignment itself
  if repo=$(cur_repo 2>/dev/null) && [ -n "$repo" ]; then
    echo "repo:     $repo"
  else
    echo "repo:     MISSING — no GitHub 'origin' remote"; ok=0
  fi
  if [ -f "$PROFILE" ]; then echo "profile:  $PROFILE"; else echo "profile:  MISSING ($PROFILE) — run /fr-workflow:init"; ok=0; fi
  if [ -f "$PROFILE_LOCAL" ]; then
    local_set=""; for k in $LOCAL_KEYS; do v=$(cfg_in "$PROFILE_LOCAL" "$k"); [ -z "$v" ] || local_set="$local_set $k=$v"; done
    local_other=$(LK="$LOCAL_KEYS" awk 'NR == 1 { next } $0 == "---" { exit } /^[A-Za-z_]+:/ { k = $0; sub(/:.*/, "", k); if (index(ENVIRON["LK"], " " k " ") == 0) printf " %s", k }' "$PROFILE_LOCAL")
    echo "local:    $PROFILE_LOCAL —${local_set:- nothing set}${local_other:+   not per-machine keys, ignored:$local_other}"
    git check-ignore -q "$PROFILE_LOCAL" 2>/dev/null || echo "          NOT ignored by git — add $PROFILE_LOCAL to .gitignore"
  fi
  echo "issues:   $(cfg issue_repo "${repo:-?}")"
  echo "fr_dir:   $FR_DIR   prefix: $PREFIX   base: $BASE"
  if [ -n "$(cfg worktree_setup "")" ] || [ -n "$(cfg worktree_teardown "")" ]; then
    echo "hooks:    setup: $(cfg worktree_setup "—")   teardown: $(cfg worktree_teardown "—")"
  fi
  if [ -n "$(cfg spec_dir "")" ]; then
    echo "specs:    $(cfg spec_dir "") ($(ls -d "$(cfg spec_dir "")"/*/spec.md 2>/dev/null | wc -l | tr -d ' ') capabilities, spec deltas instead of acceptance criteria)"
  fi
  project=$(cfg project "")
  if [ -n "$project" ]; then
    if [ -n "$(cfg project_status "")" ]; then
      note="written by the skills"
      if command -v gh >/dev/null; then
        ver=$(gh_version)
        if gh_older_than "$GH_MIN" "$ver"; then note="NOT written — gh $ver is older than $GH_MIN, upgrade gh"; fi
      fi
      echo "project:  $project   status column: $(cfg project_status_field Status), $note"
    else
      echo "project:  $project   status column: left to GitHub's workflows"
    fi
  elif [ -n "$(cfg project_status "")" ]; then
    echo "project:  NONE — project_status is set but project is empty, the status is not written"
  fi
  if command -v gh >/dev/null; then
    if gh auth status >/dev/null 2>&1; then echo "gh:       ok"; else echo "gh:       NOT LOGGED IN — gh auth login"; ok=0; fi
  else
    echo "gh:       MISSING — https://cli.github.com"; ok=0
  fi
  [ "$ok" = 1 ]
}

cmd="${1:-}"; [ $# -gt 0 ] && shift
case "$cmd" in
  check) cmd_check ;;
  list) cmd_list "$@" ;;
  spec) cmd_spec "$@" ;;
  issue-frs) cmd_issue_frs "$@" ;;
  overlap) cmd_overlap "$@" ;;
  lock) cmd_lock "$@" ;;
  deployment) cmd_deployment "$@" ;;
  pr-commit) cmd_pr_commit "$@" ;;
  project-status) cmd_project_status "$@" ;;
  project-options) cmd_project_options "$@" ;;
  queue) cmd_queue "$@" ;;
  pipeline) cmd_pipeline "$@" ;;
  launch) cmd_launch "$@" ;;
  fix-brief) cmd_fix_brief "$@" ;;
  merge-gate) cmd_merge_gate "$@" ;;
  merge) cmd_merge "$@" ;;
  finish) cmd_finish "$@" ;;
  hook) cmd_hook "$@" ;;
  notify) cmd_notify "$@" ;;
  validate) cmd_validate "$@" ;;
  fingerprint) cmd_fingerprint "$@" ;;
  fold) cmd_fold "$@" ;;
  *) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
