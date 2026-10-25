#!/usr/bin/env bash
# fr.sh — deterministic helpers for the fr-workflow plugin.
#
# The FR documents' frontmatter is the single source of truth for the m:n link
# between feature requests and issues. Everything this script prints or posts
# is derived from it, so it can be re-run at any time.
#
# Needs git and awk; `sync` and `check` also need an authenticated gh.
# Written for bash 3.2 (macOS default) and Git Bash on Windows: no associative
# arrays, no mapfile. Run from anywhere inside the repository.
#
# Usage:
#   fr.sh check                    prerequisites and profile
#   fr.sh list [--no-fetch]        all FRs (base branch, FR branches, local edits)
#   fr.sh next-id [--no-fetch]     next free FR id
#   fr.sh issue-frs <ref> [--no-fetch]   FRs that reference an issue
#   fr.sh sync <ref>... [--no-fetch] [--dry-run]   upsert the backlink comment
#   fr.sh sync-fr <ID>...|--all [--no-fetch] [--dry-run]
#                                  sync every issue an FR references now or
#                                  referenced earlier (from git history)
#   fr.sh overlap [<ID>...] [--no-fetch]
#                                  which candidates (default: all open FRs) may
#                                  start alongside the in-progress ones: waves
#   fr.sh lock acquire|release|status [<ID>]
#                                  ship lock for a shared test environment
#
# Issue refs: owner/repo#12, #12 or 12 (default repo), a GitHub issue URL.
# jira:KEY-123 is accepted in frontmatter but skipped by `sync` (not in v1).

set -euo pipefail

MARKER='<!-- fr-workflow:backlink -->'
PROFILE='.claude/workflow.md'

die() { echo "fr.sh: $*" >&2; exit 1; }

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$TOP"

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
DIGITS=$(cfg id_digits 3)

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

norm() {
  local r="$1"
  case "$r" in
    https://github.com/*/issues/*)
      r=$(echo "$r" | sed -E 's#^https://github\.com/([^/]+/[^/]+)/issues/([0-9]+).*$#\1\#\2#') ;;
    \#*) r="$(default_repo)$r" ;;
    [0-9]*) r="$(default_repo)#$r" ;;
  esac
  echo "$r"
}

base_ref() {
  if git rev-parse --verify -q "refs/remotes/origin/$BASE" >/dev/null; then
    echo "origin/$BASE"
  else
    echo "$BASE"
  fi
}

do_fetch() {
  if git remote get-url origin >/dev/null 2>&1; then
    git fetch --quiet --prune origin || echo "fr.sh: fetch failed, using local refs" >&2
  fi
}

# Frontmatter on stdin -> "id status pr issues title areas model effort"
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
      iss = f["issues"]; gsub(/\[/, "", iss); gsub(/\]/, "", iss); gsub(/ /, "", iss)
      ar = f["areas"]; gsub(/\[/, "", ar); gsub(/\]/, "", ar); gsub(/ /, "", ar)
      t = f["title"]; gsub(/\t/, " ", t)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f["id"], f["status"], f["pr"], iss, t, ar, f["model"], f["effort"]
    }'
}

# emit <location> <ref-for-links> <path>   (frontmatter on stdin)
emit() {
  parse_fm | awk -v loc="$1" -v ref="$2" -v p="$3" 'BEGIN { FS = OFS = "\t" }
    { print $1, $2, loc, ref, p, $3, $4, $5, $6, $7, $8 }'
}

is_fr_file() {
  awk -v pre="$PREFIX" '{ n = split($0, a, "/"); if (a[n] ~ ("^" pre "-[0-9]+.*\\.md$")) print }'
}

# Raw rows from all sources, later sources win per id:
# 1. base branch  2. FR branches whose doc differs from base  3. local edits.
collect() {
  local bref br p cur
  bref=$(base_ref)

  git ls-tree -r --name-only "$bref" -- "$FR_DIR" 2>/dev/null | is_fr_file |
    while IFS= read -r p; do
      git show "$bref:$p" | emit base "$BASE" "$p"
    done

  { git for-each-ref --format='%(refname:short)' refs/remotes/origin
    git for-each-ref --format='%(refname:short)' refs/heads |
      while IFS= read -r br; do
        git rev-parse --verify -q "refs/remotes/origin/$br" >/dev/null || echo "$br"
      done
  } | awk -v pre="$PREFIX" -v base="$BASE" '
      $0 == "origin/HEAD" || $0 == "origin" || $0 == "origin/" base || $0 == base { next }
      tolower($0) ~ ("(^|[/_-])" tolower(pre) "-?[0-9]+") { print }' |
    while IFS= read -r br; do
      git diff --name-only --diff-filter=AM "$bref...$br" -- "$FR_DIR" 2>/dev/null | is_fr_file |
        while IFS= read -r p; do
          # A squash-merged branch carries the same doc as base: base wins.
          if git cat-file -e "$bref:$p" 2>/dev/null && git diff --quiet "$bref" "$br" -- "$p"; then
            continue
          fi
          git show "$br:$p" 2>/dev/null | emit branch "${br#origin/}" "$p"
        done
    done

  cur=$(git branch --show-current)
  git status --porcelain -uall -- "$FR_DIR" | awk '{ p = substr($0, 4); sub(/.* -> /, "", p); print p }' |
    is_fr_file |
    while IFS= read -r p; do
      [ -f "$p" ] && emit local "$cur" "$p" < "$p"
    done
  return 0
}

# Deduplicated rows; "merged" is derived: a shipped FR (in-review) on base.
rows() {
  collect | awk 'BEGIN { FS = OFS = "\t" }
    { if (!($1 in seen)) order[++n] = $1; seen[$1] = 1; row[$1] = $0 }
    END {
      for (i = 1; i <= n; i++) {
        split(row[order[i]], c, "\t")
        if (c[3] == "base" && c[2] == "in-review") c[2] = "merged"
        print c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11]
      }
    }' | sort
}

want_fetch() { case " $* " in *" --no-fetch "*) ;; *) do_fetch ;; esac; }

HEADER='id\tstatus\tlocation\tref\tpath\tpr\tissues\ttitle\tareas\tmodel\teffort\n'

cmd_list() {
  want_fetch "$@"
  printf "$HEADER"
  rows
}

cmd_next_id() {
  want_fetch "$@"
  { rows | cut -f1
    git for-each-ref --format='%(refname:short)' refs/heads refs/remotes
  } | awk -v pre="$PREFIX" -v d="$DIGITS" '
      {
        s = tolower($0); p = tolower(pre)
        while (match(s, p "-?[0-9]+")) {
          m = substr(s, RSTART, RLENGTH); gsub(/[^0-9]/, "", m)
          if (m + 0 > max) max = m + 0
          s = substr(s, RSTART + RLENGTH)
        }
      }
      END { printf "%s-%0" d "d\n", pre, max + 1 }'
}

# Rows computed once per run when ROWS is set (sync loops call frs_for often).
ROWS=""
all_rows() { if [ -n "$ROWS" ]; then printf '%s\n' "$ROWS"; else rows; fi; }

# awk: canonical issue ref from #N, N, owner/repo#N or an issue URL.
NORM_AWK='
  function canon(x) {
    if (x ~ /^#/) return dr x
    if (x ~ /^[0-9]+$/) return dr "#" x
    if (x ~ /^https:\/\/github\.com\/[^\/]+\/[^\/]+\/issues\/[0-9]+/) {
      sub(/^https:\/\/github\.com\//, "", x); sub(/\/issues\//, "#", x)
      match(x, /^[^\/]+\/[^#]+#[0-9]+/); return substr(x, RSTART, RLENGTH)
    }
    return x
  }'

# FR rows referencing a normalized issue ref (short refs in docs normalized too).
frs_for() {
  local ref="$1" dr
  dr=$(default_repo)
  all_rows | awk -v ref="$ref" -v dr="$dr" "$NORM_AWK"'
    BEGIN { FS = OFS = "\t" }
    {
      n = split($7, a, ",")
      for (i = 1; i <= n; i++) if (canon(a[i]) == ref) { print; next }
    }'
}

# Issue refs an FR file listed in any committed version: hist_issues <gitref> <path>
hist_issues() {
  git log --format= -p "$1" -- "$2" 2>/dev/null | awk '
    /^[-+]issues:/ {
      s = substr($0, 2); sub(/^issues:[ \t]*/, "", s)
      gsub(/\[/, "", s); gsub(/\]/, "", s); gsub(/ /, "", s)
      n = split(s, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") print a[i]
    }'
}

cmd_issue_frs() {
  [ $# -ge 1 ] || die "usage: fr.sh issue-frs <issue-ref>"
  local ref; ref=$(norm "$1"); shift
  want_fetch "$@"
  printf "$HEADER"
  frs_for "$ref"
}

# sync_refs <dry 0|1> <ref>...   — the backlink upsert, one issue at a time
sync_refs() {
  local dry="$1"; shift
  command -v gh >/dev/null || die "gh not found"
  [ -n "$ROWS" ] || ROWS=$(rows)

  local frrepo raw ref irepo num table body id
  frrepo=$(cur_repo)
  for raw in "$@"; do
    ref=$(norm "$raw")
    case "$ref" in
      jira:*) echo "skip $ref: Jira is not supported in v1"; continue ;;
      */*#[0-9]*) ;;
      *) echo "skip $raw: not a GitHub issue ref"; continue ;;
    esac
    irepo=${ref%%#*}; num=${ref##*#}

    table=$(frs_for "$ref" | awk -v repo="$frrepo" 'BEGIN { FS = "\t" }
      {
        if ($3 == "local") print "fr.sh: warning: " $1 " is not committed and pushed, its link will not resolve" > "/dev/stderr"
        t = $8; gsub(/\|/, "\\|", t)
        pr = ($6 == "") ? "—" : repo "#" $6
        printf "| [%s](https://github.com/%s/blob/%s/%s) | %s | %s | %s |\n", $1, repo, $4, $5, t, $2, pr
      }')

    if [ -n "$table" ]; then
      body=$(printf '%s\n**Feature requests for this issue**\n\n| FR | Title | Status | PR |\n|---|---|---|---|\n%s\n\n<sub>Maintained by fr-workflow from the FR documents in %s — manual edits are overwritten.</sub>' \
        "$MARKER" "$table" "$frrepo")
    else
      body=$(printf '%s\n**Feature requests for this issue**\n\nNo feature request references this issue (any more).\n\n<sub>Maintained by fr-workflow from the FR documents in %s — manual edits are overwritten.</sub>' \
        "$MARKER" "$frrepo")
    fi

    if [ "$dry" = 1 ]; then
      printf '=== %s (dry run, nothing posted)\n%s\n' "$ref" "$body"
      continue
    fi

    id=$(gh api "repos/$irepo/issues/$num/comments" --paginate \
      --jq ".[] | select(.body | startswith(\"$MARKER\")) | .id" | head -n 1)
    if [ -n "$id" ]; then
      printf '%s updated: ' "$ref"
      gh api -X PATCH "repos/$irepo/issues/comments/$id" -f body="$body" --jq .html_url
    elif [ -n "$table" ]; then
      printf '%s created: ' "$ref"
      gh api "repos/$irepo/issues/$num/comments" -f body="$body" --jq .html_url
    else
      echo "$ref: no FR and no backlink comment — nothing to do"
    fi
  done
}

cmd_sync() {
  local refs="" a dry=0
  for a in "$@"; do
    case "$a" in
      --no-fetch) ;;
      --dry-run) dry=1 ;;
      *) refs="$refs $a" ;;
    esac
  done
  [ -n "$refs" ] || die "usage: fr.sh sync <issue-ref>... [--dry-run]"
  want_fetch "$@"
  # shellcheck disable=SC2086 # refs never contain spaces
  sync_refs "$dry" $refs
}

# All issues of the given FRs — current frontmatter plus every earlier version,
# so an issue removed from `issues:` loses its entry too. No issues: no-op.
cmd_sync_fr() {
  local ids="" a dry=0 all=0
  for a in "$@"; do
    case "$a" in
      --no-fetch) ;;
      --dry-run) dry=1 ;;
      --all) all=1 ;;
      *) ids="$ids $a" ;;
    esac
  done
  [ -n "$ids" ] || [ "$all" = 1 ] || die "usage: fr.sh sync-fr <FR-id>...|--all [--dry-run]"
  want_fetch "$@"
  ROWS=$(rows)
  [ "$all" = 1 ] && ids=$(printf '%s\n' "$ROWS" | cut -f1)

  local id row loc ref path cur gref dr iss refs=""
  dr=$(default_repo)
  for id in $ids; do
    row=$(printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id')
    if [ -z "$row" ]; then echo "$id: no such FR"; continue; fi
    loc=$(printf '%s' "$row" | cut -f3)
    ref=$(printf '%s' "$row" | cut -f4)
    path=$(printf '%s' "$row" | cut -f5)
    cur=$(printf '%s' "$row" | cut -f7)
    case "$loc" in
      base) gref=$(base_ref) ;;
      branch) if git rev-parse --verify -q "refs/remotes/origin/$ref" >/dev/null; then gref="origin/$ref"; else gref="$ref"; fi ;;
      *) gref=HEAD ;;
    esac
    iss=$({ printf '%s\n' "$cur" | tr ',' '\n'; hist_issues "$gref" "$path"; } |
      awk -v dr="$dr" "$NORM_AWK"' NF { print canon($0) }' | sort -u | tr '\n' ' ')
    if [ -z "${iss// /}" ]; then echo "$id: no linked issues — nothing to sync"; continue; fi
    refs="$refs $iss"
  done
  refs=$(printf '%s\n' $refs | sort -u | tr '\n' ' ')
  [ -n "${refs// /}" ] || return 0
  # shellcheck disable=SC2086
  sync_refs "$dry" $refs
}

# Paths an FR touches: its declared `areas` plus the files its branch (or the
# working tree, for local FRs) already changed, FR docs excluded. Nothing known
# -> "*", which overlaps with everything: parallel only when it is evident.
touched() { # <row>
  local loc ref areas gref bref
  loc=$(printf '%s' "$1" | cut -f3); ref=$(printf '%s' "$1" | cut -f4)
  areas=$(printf '%s' "$1" | cut -f9)
  bref=$(base_ref)
  { printf '%s\n' "$areas" | tr ',' '\n'
    case "$loc" in
      branch)
        if git rev-parse --verify -q "refs/remotes/origin/$ref" >/dev/null; then gref="origin/$ref"; else gref="$ref"; fi
        git diff --name-only "$bref...$gref" 2>/dev/null ;;
      local) git diff --name-only "$bref" 2>/dev/null ;;
    esac
  } | awk -v frdir="$FR_DIR" '
      { sub(/\/\*\*$/, ""); sub(/\/\*$/, ""); sub(/\/$/, "") }
      $0 == "" || $0 == frdir || index($0, frdir "/") == 1 { next }
      { print; n++ }
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
cmd_lock() {
  local sub="${1:-status}" id="${2:-}" d now holder since
  d="$(cd "$(git rev-parse --git-common-dir)" && pwd)/fr-workflow-ship.lock"
  now=$(date -u +%s)
  holder=""; since=""
  if [ -f "$d/owner" ]; then read -r holder since < "$d/owner" || true; fi
  case "$sub" in
    acquire)
      [ -n "$id" ] || die "usage: fr.sh lock acquire <ID>"
      if mkdir "$d" 2>/dev/null; then
        printf '%s %s\n' "$id" "$now" > "$d/owner"; echo "acquired by $id"
      elif [ "$holder" = "$id" ]; then
        echo "already held by $id"
      else
        echo "busy: held by ${holder:-unknown} for $(( (now - ${since:-$now}) / 60 )) min"; exit 3
      fi ;;
    release)
      [ -n "$id" ] || die "usage: fr.sh lock release <ID>"
      if [ ! -d "$d" ]; then echo "free"
      elif [ "$holder" = "$id" ]; then rm -f "$d/owner"; rmdir "$d"; echo "released by $id"
      else echo "not released: held by ${holder:-unknown}, not $id"; exit 3
      fi ;;
    status)
      if [ -d "$d" ]; then echo "held by ${holder:-unknown} for $(( (now - ${since:-$now}) / 60 )) min"; else echo "free"; fi ;;
    *) die "usage: fr.sh lock acquire|release|status [<ID>]" ;;
  esac
}

cmd_check() {
  local ok=1
  echo "repo:     $(cur_repo 2>/dev/null || echo 'MISSING origin remote')"
  if [ -f "$PROFILE" ]; then echo "profile:  $PROFILE"; else echo "profile:  MISSING ($PROFILE) — run /fr-workflow:init"; ok=0; fi
  echo "fr_dir:   $FR_DIR   prefix: $PREFIX   base: $BASE"
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
  next-id) cmd_next_id "$@" ;;
  issue-frs) cmd_issue_frs "$@" ;;
  sync) cmd_sync "$@" ;;
  sync-fr) cmd_sync_fr "$@" ;;
  overlap) cmd_overlap "$@" ;;
  lock) cmd_lock "$@" ;;
  *) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
