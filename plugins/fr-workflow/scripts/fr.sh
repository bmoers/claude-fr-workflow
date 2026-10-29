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
#   fr.sh project-status <issue> <event>
#                                  the FR's status column in the GitHub project,
#                                  per project_status; exit 5 if not written
#   fr.sh project-options [<value>...]
#                                  add the values of project_status (or the given
#                                  ones) that the status column does not have yet
#
# Issue refs: owner/repo#12, #12, 12 or FR-12 (issue repo), a GitHub issue URL.

set -euo pipefail

PROFILE='.claude/workflow.md'
ISSUE_LIMIT=1000

die() { echo "fr.sh: $*" >&2; exit 1; }

CALLER=$PWD
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$TOP"

# git for path-listing commands: without core.quotePath=false git quotes paths
# with non-ASCII characters ("FR-002-\303\274ber.md") and they no longer match.
g() { git -c core.quotePath=false "$@"; }

# Flat `key: value` lookup in the profile frontmatter, with a default.
cfg() {
  local v=""
  if [ -f "$PROFILE" ]; then
    v=$(awk -v k="$1" '
      { sub(/\r$/, "") }
      NR == 1 { if ($0 != "---") exit; next }
      $0 == "---" { exit }
      {
        i = index($0, ":"); if (i == 0) next
        if (substr($0, 1, i - 1) != k) next
        v = substr($0, i + 1)
        sub(/[ \t]+#.*$/, "", v); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
        if (v ~ /^".*"$/) v = substr(v, 2, length(v) - 2)
        print v; exit
      }' "$PROFILE")
  fi
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
  parse_fm | awk -v loc="$1" -v ref="$2" -v p="$3" 'BEGIN { FS = OFS = "\t" }
    { print $1, $2, loc, ref, p, $3, $4, $5, $6, $7, $8, $9 }'
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
  printf '%s\n' "$out" | awk -v dr="$DR" -v pre="$PREFIX" "$NORM_AWK$PLAN_AWK"'
    BEGIN { FS = OFS = "\t" }
    {
      planning($3, "\037"); r = canon("#" $1)
      print pre "-" $1, "open", "issue", r, "", "", r, reqs(P["requests"]), $2, csv(P["areas"]), P["model"], P["effort"]
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
        print c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12]
      }
    }' | sort
}

want_fetch() { case " $* " in *" --no-fetch "*) ;; *) do_fetch ;; esac; }

HEADER='id\tstatus\tlocation\tref\tpath\tpr\tissue\trequests\ttitle\tareas\tmodel\teffort\n'

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
  ref=$(issue_ref "$1")
  if [ -n "$out" ]; then
    case "$out" in /*) ;; *) out="$CALLER/$out" ;; esac
    [ ! -e "$out" ] || die "$out exists — not overwritten"
  fi
  meta=$(gh issue view "${ref##*#}" -R "${ref%%#*}" --json state,labels,title \
    --jq "[.state, ([.labels[].name] | join(\",\")), $J_TITLE] | join(\"\t\")") || die "cannot read $ref"
  body=$(gh issue view "${ref##*#}" -R "${ref%%#*}" --json body --jq '.body // ""') || die "cannot read $ref"
  dr_init
  doc=$(printf '%s\n' "$body" | awk -v meta="$meta" -v ref="$ref" -v dr="$DR" -v pre="$PREFIX" \
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
      split(meta, M, "\t"); num = ref; sub(/^.*#/, "", num)
      if (M[1] != "OPEN") fail("the issue is closed")
      if (("," M[2] ",") !~ /,fr,/) fail("no label fr — not defined yet: /fr-workflow:new " ref)
      # pass 1: criteria and open questions; # lines in code blocks are no headings
      for (i = 1; i <= n; i++) {
        l = L[i]
        if (original(l)) continue
        if (l ~ /^ *(```|~~~)/) fence = !fence
        if (!fence && l ~ /^#+ /) { sec = tolower(l); sub(/^#+ +/, "", sec); sub(/ +$/, "", sec); continue }
        if (sec == "acceptance criteria" && l ~ /^[-*] \[[ xX]\] +[^ ]/ && l !~ /\] +Criterion [0-9]+ *$/) crit++
        if (sec == "open questions" && l ~ /^([-*]|[0-9]+\.) +[^ ]/) oq++
      }
      if (!crit) fail("no acceptance criteria (- [ ] lines under ## Acceptance criteria)")
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
  ROWS=$(rows)
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
    touched "$row" | awk -v id="$id" -v role="$role" '{ print role "\t" id "\t" $0 }'
  done | awk -v shared="$shared" '
    function rel(a, b) { return a == b || index(b, a "/") == 1 || index(a, b "/") == 1 }
    function under(p, s) { return p == s || index(p, s "/") == 1 }
    BEGIN { FS = OFS = "\t"; ns = split(shared, sh, " ") }
    { if (!($2 in seen)) { order[++n] = $2; seen[$2] = 1; role[$2] = $1 }; paths[$2] = paths[$2] "\n" $3 }
    END {
      for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) {
        A = order[i]; B = order[j]; why = ""
        na = split(substr(paths[A], 2), pa, "\n"); nb = split(substr(paths[B], 2), pb, "\n")
        for (x = 1; x <= na && why == ""; x++) for (y = 1; y <= nb && why == ""; y++) {
          if (pa[x] == "*" || pb[y] == "*") why = "areas unknown"
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
PS_EVENTS='defined input running failed blocked approval done'
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

cmd_project_status() {
  [ $# -eq 2 ] || die "usage: fr.sh project-status <issue> <event>"
  local ref event="$2" map title field owner url value out num ver
  case " $PS_EVENTS " in
    *" $event "*) ;;
    *) die "unknown event '$event' — one of: $PS_EVENTS" ;;
  esac
  ref=$(issue_ref "$1")
  map=$(cfg project_status "")
  if [ -z "$map" ]; then echo "project status: not configured (no project_status in the profile)"; return 0; fi
  title=$(cfg project "")
  if [ -z "$title" ]; then echo "fr.sh: project_status is set but project is empty — status not written" >&2; exit 5; fi
  # "k=v, k=v": records split at commas, the key before the first "="
  value=$(printf '%s' "$map" | awk -v e="$event" 'BEGIN { RS = "," }
    {
      i = index($0, "="); if (i == 0) next
      k = substr($0, 1, i - 1); v = substr($0, i + 1)
      gsub(/^[ \t\n]+|[ \t\n]+$/, "", k); gsub(/^[ \t\n]+|[ \t\n]+$/, "", v)
      if (k == e) { print v; exit }
    }')
  if [ -z "$value" ]; then echo "project status: no value for '$event' in project_status — nothing written"; return 0; fi
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
  echo "project status: $ref → $value ($title)"
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

cmd_check() {
  local ok=1 repo project ver note
  # cur_repo exits its subshell on failure, so test the assignment itself
  if repo=$(cur_repo 2>/dev/null) && [ -n "$repo" ]; then
    echo "repo:     $repo"
  else
    echo "repo:     MISSING — no GitHub 'origin' remote"; ok=0
  fi
  if [ -f "$PROFILE" ]; then echo "profile:  $PROFILE"; else echo "profile:  MISSING ($PROFILE) — run /fr-workflow:init"; ok=0; fi
  echo "issues:   $(cfg issue_repo "${repo:-?}")"
  echo "fr_dir:   $FR_DIR   prefix: $PREFIX   base: $BASE"
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
  project-status) cmd_project_status "$@" ;;
  project-options) cmd_project_options "$@" ;;
  *) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
