#!/bin/bash
# Regression tests for scripts/fr.sh — run before every release:
#   bash tests/fr-sh.sh
# Builds throwaway repos with a local bare "origin" in a temp dir; `gh` is a
# stub, nothing reaches GitHub. On macOS /bin/bash is 3.2, the version fr.sh must
# support; run it with that shell there.
set -u
FR="$(cd "$(dirname "$0")/.." && pwd)/plugins/fr-workflow/scripts/fr.sh"
SP=$(mktemp -d "${TMPDIR:-/tmp}/fr-sh-test.XXXXXX")
trap 'rm -rf "$SP"' EXIT
S=$SP/regress
# commits must work on machines without a git identity (CI)
export GIT_AUTHOR_NAME=fr-sh-test GIT_AUTHOR_EMAIL=fr-sh-test@example.invalid
export GIT_COMMITTER_NAME=fr-sh-test GIT_COMMITTER_EMAIL=fr-sh-test@example.invalid
# portable in-place edit (BSD and GNU sed differ on -i)
sub() { sed "$1" "$2" > "$2.tmp" && mv "$2.tmp" "$2"; }
pass=0; fail=0
ok()   { echo "PASS  $1"; pass=$((pass + 1)); }
bad()  { echo "FAIL  $1 — $2"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "$3"; fi; }

# stub gh, always first in PATH: logs every call and answers from files in
# $STUB — lines as fr.sh's --jq expressions would print them. Nothing reaches
# GitHub, also not by accident through the real gh.
mkdir -p "$SP/stubbin" "$SP/stub"
cat > "$SP/stubbin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
answer() { if [ -f "$STUB/$1" ]; then cat "$STUB/$1"; fi; }
case "$*" in
  "auth status") exit 0 ;;
  "issue list"*) [ ! -f "$STUB/list-fails" ] || exit 1; answer issues ;;
  "issue view"*"--json body"*) if [ -f "$STUB/body-$3" ]; then answer "body-$3"; else answer body; fi ;;   # gh issue view <n> -R …
  "issue view"*"--json assignees"*) answer assignees ;;
  "issue view"*"--json comments"*) answer comments ;;
  "issue comment"*) cat > "$STUB/comment.in" ;;
  "api user"*) answer user ;;
  "issue view"*) answer meta ;;
  "api repos/"*/sub_issues*) answer subs ;;
  "api repos/"*/timeline*) answer timeline ;;
  "api -X GET repos/"*"/deployments -f sha="*) [ ! -f "$STUB/deployments-fails" ] || exit 1; answer deployments-sha ;;
  "api -X GET repos/"*"/deployments -f ref="*) answer deployments-ref ;;
  "api repos/"*"/deployments/"*"/statuses"*) answer "statuses-$(printf '%s' "$*" | sed -n 's#.*/deployments/\([0-9]*\)/statuses.*#\1#p')" ;;
  "api repos/"*"/commits/"*) [ ! -f "$STUB/commits-fails" ] || { echo "API rate limit exceeded" >&2; exit 1; }; answer "commit-$(printf '%s' "$*" | sed -n 's#.*/commits/\([0-9a-f]*\).*#\1#p' | cut -c1-7)" ;;
  "api repos/"*"/compare/"*) answer compare ;;
  "api repos/"*"/collaborators/"*"/permission"*) l=$(printf '%s' "$*" | sed -n 's#.*/collaborators/\([^/]*\)/permission.*#\1#p'); [ ! -f "$STUB/perm-$l-fails" ] || { echo "API rate limit exceeded" >&2; exit 1; }; if [ -f "$STUB/perm-$l" ]; then cat "$STUB/perm-$l"; else echo "HTTP 404: Not Found" >&2; exit 1; fi ;;
  "api repos/"*) answer self ;;
  "project list"*) [ ! -f "$STUB/project-list-fails" ] || { echo "missing scope: project" >&2; exit 1; }; answer projects ;;
  "project item-add"*) [ ! -f "$STUB/item-add-fails" ] || { echo "could not resolve to a node with the global id" >&2; exit 1; } ;;
  "project item-edit"*) [ ! -f "$STUB/item-edit-fails" ] || { echo "option 'Complete' not found for field 'Status'" >&2; exit 1; } ;;
  "--version") answer version ;;
  "pr list"*) answer prlist ;;
  "pr view"*"--json title,body"*) answer prtitle ;;
  "pr view"*"--json state,headRefOid"*) answer prhead ;;
  "pr view"*) [ ! -f "$STUB/prview-fails" ] || exit 1; answer prview ;;
  "pr merge"*) [ ! -f "$STUB/merge-fails" ] || { echo "GraphQL: Pull request is not mergeable (enablePullRequestAutoMerge)" >&2; exit 1; }; echo "✓ Pull request $2 will be automatically merged" ;;
  "api graphql --paginate -f query="*) [ ! -f "$STUB/items-fails" ] || { echo "Could not resolve to a ProjectV2" >&2; exit 1; }; answer items ;;
  "api graphql -f query="*"workflows(first"*) answer workflows ;;
  "api graphql -f query=mutation { deleteProjectV2Workflow"*) answer deleted ;;
  "api graphql -f query="*) answer options ;;
  "api graphql --input -"*) cat > "$STUB/mutation.in"; [ ! -f "$STUB/mutation-fails" ] || { echo "Field 'singleSelectOptions' nope" >&2; exit 1; }; answer mutated ;;
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$SP/stubbin/gh"
# stub claude: logs every call; `stop` ends the session the test pretends runs
# (its pid in $STUB/session.pid); `agents --json` answers from $STUB/agents
# (nothing listed without it, unavailable with $STUB/agents-fails); a launch
# prints a session id like claude --bg
cat > "$SP/stubbin/claude" <<'EOF'
#!/bin/bash
if [ "$1" = agents ]; then
  [ ! -f "$STUB/agents-fails" ] || exit 1
  if [ -f "$STUB/agents" ]; then cat "$STUB/agents"; else echo '[]'; fi
  exit 0
fi
echo "$*" >> "$CLAUDE_LOG"
if [ "$1" = stop ]; then
  if [ -f "$STUB/session.pid" ]; then kill "$(cat "$STUB/session.pid")" 2>/dev/null; rm -f "$STUB/session.pid"; fi
  exit 0
fi
[ ! -f "$STUB/claude-untrusted" ] || { echo "Workspace not trusted" >&2; exit 1; }
echo "Started background session ses$(wc -l < "$CLAUDE_LOG" | tr -d ' ')0a. Attach with: claude attach ses$(wc -l < "$CLAUDE_LOG" | tr -d ' ')0a"
EOF
chmod +x "$SP/stubbin/claude"
export PATH="$SP/stubbin:$PATH" STUB=$SP/stub STUB_LOG=$SP/stub.log CLAUDE_LOG=$SP/claude.log
stub() { printf '%s\n' "$2" > "$STUB/$1"; }   # stub <file> <content>
nostub() { rm -f "$STUB/$1"; }
stub version "gh version 2.98.0 (2026-08-20)"   # new enough for project-status
# an issue body: lines joined by \037, as fr.sh's jq prints them
body() { local IFS=$'\037'; printf '%s' "$*"; }

newrepo() { # newrepo <dir> <origin-url>
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q --bare origin.git; git clone -q origin.git w 2>/dev/null; cd w
  git remote set-url origin "$2"; git config url."$1/origin.git".insteadOf "$2"
  git switch -q -c main; mkdir -p .claude req/feature-requests src
}
fm() { printf -- '---\nid: %s\ntitle: %s\nstatus: %s\nrequests: [%s]\nareas: [%s]\n---\n' "$@"; }
branch_fr() { # branch_fr <branch> <file> <fm args...>
  local b=$1 f=$2; shift 2
  git switch -q -c "$b" origin/main; mkdir -p req/feature-requests; fm "$@" > "req/feature-requests/$f"
  git add -A; git commit -qm "$b"; git push -q -u origin HEAD 2>/dev/null; git switch -q main
}

newrepo "$S" git@github.com:Acme/Shop.git
printf -- '---\nshared_paths: [db/migrations]\n---\n' > .claude/workflow.md
fm FR-001 One open "#3" "src/a" > req/feature-requests/FR-001-one.md
fm FR-002 "Über" open "" "" > "req/feature-requests/FR-002-über.md"
echo x > src/App.vue
git add -A; git commit -qm init; git push -q -u origin main

out=$("$FR" list --no-fetch)
check "umlaut file name is listed" 'printf "%s" "$out" | grep -q "^FR-002"' "FR-002-über.md missing"

# --- rename on branch: no duplicate warning, branch version wins
git switch -q -c feat/fr-001-one origin/main
git mv req/feature-requests/FR-001-one.md req/feature-requests/FR-001-better-name.md
sub 's/^status: open/status: in-progress/' req/feature-requests/FR-001-better-name.md
git commit -qam rename; git push -q -u origin HEAD 2>/dev/null; git switch -q main
check "renamed doc on branch wins" '"$FR" list --no-fetch 2>/dev/null | grep "^FR-001" | grep -q in-progress' "$("$FR" list --no-fetch 2>&1 | grep FR-001)"
check "rename gives no duplicate warning" '! "$FR" list --no-fetch 2>&1 >/dev/null | grep -q "FR-001"' "$("$FR" list --no-fetch 2>&1 >/dev/null)"

# --- same id on base and on a branch (planned concurrently): warning
branch_fr feat/fr-002-other FR-002-other.md FR-002 Other open "" "src/o"
check "base/branch id clash warns" '"$FR" list --no-fetch 2>&1 >/dev/null | grep -q "FR-002 is on main"' "no warning"

# --- two branches with one id
for b in feat/fr-005-a feat/fr-005-b; do branch_fr "$b" "FR-005-${b##*-}.md" FR-005 "$b" open "" "src/x"; done
check "duplicate id on two branches warns" '"$FR" list --no-fetch 2>&1 >/dev/null | grep -q "FR-005 exists on two branches"' "no warning"

# --- overlap: globs and unpushed commits
branch_fr feat/fr-006-vue FR-006-vue.md FR-006 Vue open "" "src/*.vue"
git switch -q -c feat/fr-007-app origin/main; fm FR-007 App in-progress "" "" > req/feature-requests/FR-007-app.md
git add -A; git commit -qm f7; git push -q -u origin HEAD 2>/dev/null
echo change >> src/App.vue; git commit -qam "unpushed implementation commit"; git switch -q main
check "glob area overlaps a file of an unpushed commit" '"$FR" overlap FR-006 --no-fetch 2>/dev/null | grep -q "conflict.*FR-00[67].*FR-00[67]"' "$("$FR" overlap FR-006 --no-fetch 2>&1)"
branch_fr feat/fr-008-comp FR-008-comp.md FR-008 Comp open "" "src/comp*"
branch_fr feat/fr-009-compx FR-009-compx.md FR-009 CompX open "" "src/components/x.vue"
check "src/comp* overlaps src/components/x.vue" '"$FR" overlap FR-008 FR-009 --no-fetch 2>/dev/null | grep -q "conflict.*FR-008.*FR-009"' "$("$FR" overlap FR-008 FR-009 --no-fetch 2>&1)"

# --- local FR doc with a space in its name
fm FR-060 "Neu" open "" "" > "req/feature-requests/FR-060 neu.md"
check "uncommitted doc with space in name is listed" '"$FR" list --no-fetch 2>/dev/null | grep -q "^FR-060"' "missing"
rm -f "req/feature-requests/FR-060 neu.md"

# --- lock without owner
LD="$(git rev-parse --git-common-dir)/fr-workflow-ship.lock"; mkdir -p "$LD"
check "lock without owner is reported stale" '"$FR" lock status | grep -q stale' "$("$FR" lock status)"
"$FR" lock acquire FR-001 >/dev/null; rc=$?
check "acquire on stale lock is busy (exit 3)" '[ "$rc" = 3 ]' "exit $rc"
"$FR" lock break >/dev/null
check "break removes it" '[ "$("$FR" lock status)" = free ]' "$("$FR" lock status)"
"$FR" lock acquire FR-001 >/dev/null; "$FR" lock acquire FR-002 >/dev/null; rc=$?
check "second acquire is busy" '[ "$rc" = 3 ]' "exit $rc"
"$FR" lock release FR-001 >/dev/null

# --- round 3: renames on base, local doc edits, globs, lock break
# base renames FR-010's doc while its branch edits it at the old path
fm FR-010 Ten open "" "lib" > req/feature-requests/FR-010-ten.md; git add -A; git commit -qm "add FR-010"; git push -q
git switch -q -c feat/fr-010-ten origin/main; sub 's/^status: open/status: in-progress/' req/feature-requests/FR-010-ten.md
mkdir -p lib; echo y > lib/core.js; git add -A; git commit -qm "f10"; git push -q -u origin HEAD 2>/dev/null; git switch -q main
git mv req/feature-requests/FR-010-ten.md req/feature-requests/FR-010-zehn.md; git commit -qm "rename on base"; git push -q
check "rename on base gives no duplicate warning" '! "$FR" list --no-fetch 2>&1 >/dev/null | grep -q "FR-010"' "$("$FR" list --no-fetch 2>&1 >/dev/null | grep FR-010)"

# FR-010's doc edited in the main checkout: its branch changes still count
branch_fr feat/fr-011-lib FR-011-lib.md FR-011 Lib open "" "lib"
echo "local edit" >> req/feature-requests/FR-010-zehn.md
check "doc edit on main does not mask the FR branch (stays in-progress)" '"$FR" list --no-fetch 2>/dev/null | grep "^FR-010" | grep -q "in-progress"' "$("$FR" list --no-fetch 2>/dev/null | grep '^FR-010')"
check "local doc edit keeps the branch diff for overlap" '"$FR" overlap FR-011 --no-fetch 2>/dev/null | grep -q "conflict.*FR-01[01].*FR-01[01]"' "$("$FR" overlap FR-011 --no-fetch 2>&1)"
git checkout -q -- req/feature-requests/FR-010-zehn.md

branch_fr feat/fr-012-all FR-012-all.md FR-012 All open "" "."
branch_fr feat/fr-013-brace FR-013-brace.md FR-013 Brace open "" "src/{api,web}/**"
branch_fr feat/fr-014-api FR-014-api.md FR-014 Api open "" "src/api/x.ts"
check "areas [.] overlaps everything" '"$FR" overlap FR-012 FR-014 --no-fetch 2>/dev/null | grep -q "conflict.*FR-012.*FR-014"' "$("$FR" overlap FR-012 FR-014 --no-fetch 2>&1)"
check "brace glob overlaps src/api/x.ts" '"$FR" overlap FR-013 FR-014 --no-fetch 2>/dev/null | grep -q "conflict.*FR-013.*FR-014"' "$("$FR" overlap FR-013 FR-014 --no-fetch 2>&1)"

# a branch without merge base must not abort overlap
git checkout -q --orphan feat/fr-015-orphan; git rm -rq --cached . ; fm FR-015 Orphan open "" "x" > o.md; git add o.md; git commit -qm orphan
git push -q -u origin HEAD 2>/dev/null; git checkout -q -f main; git clean -qfd
"$FR" overlap FR-014 --no-fetch >/dev/null 2>&1; rc=$?
check "overlap survives a branch without merge base" '[ "$rc" = 0 ]' "exit $rc"
branch_fr feat/fr-016-after FR-016-after.md FR-016 After open "" "y"
check "a branch without merge base hides no FR branch sorted after it" '"$FR" list --no-fetch 2>/dev/null | grep -q "^FR-016"' "FR-016 missing"

LD="$(git rev-parse --git-common-dir)/fr-workflow-ship.lock"; mkdir -p "$LD"; touch "$LD/.DS_Store"
"$FR" lock break >/dev/null 2>&1; rc=$?
check "lock break removes a dir with a stray file" '[ "$rc" = 0 ] && [ ! -d "$LD" ]' "exit $rc, dir present: $([ -d "$LD" ] && echo yes)"

# --- FR issues not started yet: rows from the issue's Planning section
PLAN=$(body '## Problem / motivation' '' 'Coupons.' '' '## Planning' '' '- Areas: `src/checkout`, src/api/orders' \
  '- Size: M' '- **Model:** sonnet' '- Effort: medium' '- Based on: 3f2a9c1' '- Requests: #12, Acme/Shop#15')
stub issues "$(printf '47\tCoupons in checkout\t%s\n48\tCart\t%s' "$PLAN" "$(body '## Planning' '- Areas: src/a/b')")"
row=$("$FR" list --no-fetch 2>/dev/null | grep "^FR-47")
check "open FR issue is a row with location issue" 'printf "%s" "$row" | grep -q "^FR-47	open	issue	acme/shop#47	"' "$row"
check "areas from Planning, without backticks and blanks" '[ "$(printf "%s" "$row" | cut -f10)" = "src/checkout,src/api/orders" ]' "$(printf "%s" "$row" | cut -f10)"
check "requests made canonical" '[ "$(printf "%s" "$row" | cut -f8)" = "acme/shop#12,acme/shop#15" ]' "$(printf "%s" "$row" | cut -f8)"
check "bold Planning key is read" '[ "$(printf "%s" "$row" | cut -f11)" = sonnet ]' "$(printf "%s" "$row" | cut -f11)"
check "issue FR overlaps a running FR by its areas" '"$FR" overlap FR-48 --no-fetch 2>/dev/null | grep -q "^wave	2	FR-48"' "$("$FR" overlap FR-48 --no-fetch 2>&1)"
branch_fr feat/fr-47-coupons FR-47-coupons.md FR-47 Coupons in-progress "acme/shop#12" "src/checkout"
check "a started FR's doc overrides its issue row" '"$FR" list --no-fetch 2>/dev/null | grep "^FR-47" | grep -q "in-progress	branch"' "$("$FR" list --no-fetch 2>&1 | grep FR-47)"
touch "$STUB/list-fails"
"$FR" list --no-fetch > "$SP/list.out" 2> "$SP/list.err"; rc=$?
check "unreadable FR issues: warning, docs still listed" '[ "$rc" = 0 ] && grep -q "could not read the FR issues" "$SP/list.err" && grep -q "^FR-002" "$SP/list.out"' "exit $rc"
rm -f "$STUB/list-fails"

# --- spec: the FR doc from the issue, and the readiness gate
cat > "$STUB/body" <<'EOF'
## Problem / motivation

Coupons.

## Acceptance criteria

- [ ] A coupon code lowers the total

## Technical notes

```bash
# not a heading
```

## Open questions

None.

## Planning

- Areas: src/checkout
- Model: opus
- Based on: 3f2a9c1
- Requests: #12

<details><summary>Original request</summary>

Customer wrote: CUSTOMER-DATA
<details><summary>log</summary>
inner
</details>
STILL-ORIGINAL

</details>
EOF
stub meta "$(printf 'OPEN\tfr,enhancement\tCoupons in checkout')"
"$FR" spec 47 > "$SP/spec.out" 2>/dev/null; rc=$?
check "spec of a ready issue exits 0" '[ "$rc" = 0 ]' "exit $rc"
check "spec frontmatter from title and Planning" 'grep -qx "id: FR-47" "$SP/spec.out" && grep -qx "issue: acme/shop#47" "$SP/spec.out" && grep -qx "requests: \[acme/shop#12\]" "$SP/spec.out" && grep -qx "areas: \[src/checkout\]" "$SP/spec.out" && grep -qx "based_on: 3f2a9c1" "$SP/spec.out" && grep -qx "status: in-progress" "$SP/spec.out"' "$(head -14 "$SP/spec.out")"
check "spec keeps the sections, a # line in a code block too" 'grep -qx "# FR-47: Coupons in checkout" "$SP/spec.out" && grep -qx "# not a heading" "$SP/spec.out" && grep -qx "## Acceptance check" "$SP/spec.out"' "$(cat "$SP/spec.out")"
check "spec drops Planning and the whole original request" '! grep -q "CUSTOMER-DATA\|STILL-ORIGINAL\|## Planning\|Based on:" "$SP/spec.out"' "$(cat "$SP/spec.out")"
: > "$STUB_LOG"
"$FR" spec FR-47 >/dev/null 2>&1; "$FR" spec https://github.com/Acme/Shop/issues/47 >/dev/null 2>&1
check "FR-47 and an issue URL name acme/shop#47" '[ "$(grep -c "issue view 47 -R acme/shop" "$STUB_LOG")" = 4 ]' "$(cat "$STUB_LOG")"
(cd src && "$FR" spec 47 out/FR-47.md >/dev/null 2>&1)
check "spec writes a relative path from the caller's directory" '[ -f src/out/FR-47.md ]' "missing"
(cd src && "$FR" spec 47 out/FR-47.md >/dev/null 2>&1); rc=$?
check "spec never overwrites a file" '[ "$rc" != 0 ]' "exit $rc"
rm -rf src/out

notready() { # notready <name> <meta> <body sed> <expected message>
  stub meta "$2"; sed "$3" "$STUB/body" > "$STUB/body.ok"; mv "$STUB/body" "$STUB/body.keep"; mv "$STUB/body.ok" "$STUB/body"
  "$FR" spec 47 > /dev/null 2> "$SP/spec.err"; rc=$?
  mv "$STUB/body.keep" "$STUB/body"
  msg=$4; check "$1" '[ "$rc" = 4 ] && grep -q "$msg" "$SP/spec.err"' "exit $rc: $(cat "$SP/spec.err")"
}
notready "not ready: open questions" "$(printf 'OPEN\tfr\tX')" 's/^None\.$/- Which coupon types?/' "open question"
notready "not ready: no label fr" "$(printf 'OPEN\tfr-request\tX')" 's/x/x/' "no label fr"
notready "not ready: closed" "$(printf 'CLOSED\tfr\tX')" 's/x/x/' "is closed"
notready "not ready: template criteria" "$(printf 'OPEN\tfr\tX')" 's/^- \[ \] A coupon.*/- [ ] Criterion 1/' "no acceptance criteria"

# --- issue-frs: the request itself, sub-issues, FR issues listing it under Requests
stub self "$(printf 'https://github.com/acme/shop/issues/12\topen\t\tfr-request\tCoupons\t')"
stub subs "$(printf 'https://github.com/acme/shop/issues/47\tclosed\tcompleted\tfr\tCoupon field\t\nhttps://github.com/acme/shop/issues/49\topen\t\t\tManual task\t')"
stub timeline "$(printf '%s\n' \
  "$(printf 'https://github.com/acme/shop/issues/50\topen\t\tfr\tJoined\t%s' "$(body '## Planning' '- Requests: #15, #12')")" \
  "$(printf 'https://github.com/acme/shop/issues/51\topen\t\tfr\tMentions only\t%s' "$(body 'See #12.' '## Planning' '- Requests: #15')")" \
  "$(printf 'https://github.com/acme/shop/issues/52\topen\t\tbug\tNo FR\t%s' "$(body '## Planning' '- Requests: #12')")" \
  "$(printf 'https://github.com/acme/shop/issues/47\tclosed\tcompleted\tfr\tCoupon field\t%s' "$(body '## Planning' '- Requests: #12')")")"
"$FR" issue-frs '#12' > "$SP/frs.out" 2>&1; rc=$?
check "issue-frs: sub-issues and FRs listing it, each once" '[ "$rc" = 0 ] && [ "$(tail -n +2 "$SP/frs.out" | cut -f1 | tr "\n" " ")" = "acme/shop#47 acme/shop#49 acme/shop#50 " ]' "$(cat "$SP/frs.out")"
check "issue-frs: state, reason and via" 'grep -q "^acme/shop#47	closed	completed	sub	" "$SP/frs.out" && grep -q "^acme/shop#50	open		requests	" "$SP/frs.out"' "$(cat "$SP/frs.out")"
stub self "$(printf 'https://github.com/acme/shop/issues/12\topen\t\tfr\tCoupons\t')"; nostub subs; nostub timeline
check "issue-frs: a request that is an FR serves itself" '"$FR" issue-frs 12 2>/dev/null | grep -q "^acme/shop#12	open		self"' "$("$FR" issue-frs 12 2>&1)"
: > "$STUB_LOG"
"$FR" issue-frs "1password/x#3" >/dev/null 2>&1; "$FR" issue-frs "ACME/SHOP#12" >/dev/null 2>&1
check "digit-led owner is kept" 'grep -q "api repos/1password/x/issues/3 " "$STUB_LOG"' "$(cat "$STUB_LOG")"
check "upper-case ref is made canonical" 'grep -q "api repos/acme/shop/issues/12 " "$STUB_LOG"' "$(cat "$STUB_LOG")"

# --- check without origin
git remote remove origin
"$FR" check > "$SP/check.out" 2>&1; rc=$?
check "check fails without origin" '[ "$rc" != 0 ] && grep -q MISSING "$SP/check.out"' "exit $rc"

# --- prefix containing a digit, issues in another repository
newrepo "$SP/regress-r2" git@github.com:acme/r2.git
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\n---\n' > .claude/workflow.md
git add -A; git commit -qm init; git push -q -u origin main
stub issues "$(printf '47\tFrom the request repo\t%s' "$(body '## Planning' '- Areas: lib')")"
check "issue rows come from issue_repo, id R2-47" '"$FR" list --no-fetch 2>/dev/null | grep -q "^R2-47	open	issue	acme/requests#47	"' "$("$FR" list --no-fetch 2>&1)"
branch_fr feat/r2-47-x R2-47-x.md R2-47 X in-progress "" "lib"
check "R2 branch doc overrides the issue row" '"$FR" list --no-fetch 2>/dev/null | grep "^R2-47" | grep -q "in-progress	branch"' "$("$FR" list --no-fetch 2>&1)"
stub meta "$(printf 'OPEN\tfr\tFrom the request repo')"; : > "$STUB_LOG"
"$FR" spec r2-47 >/dev/null 2>&1
check "spec r2-47 reads acme/requests#47" 'grep -q "issue view 47 -R acme/requests" "$STUB_LOG"' "$(cat "$STUB_LOG")"

# --- project-status: the board column from project_status, best effort
: > "$STUB_LOG"
"$FR" project-status 47 running > "$SP/ps.out" 2>&1; rc=$?
check "project-status: not configured is a no-op, exit 0" '[ "$rc" = 0 ] && grep -q "not configured" "$SP/ps.out" && ! grep -q "^project" "$STUB_LOG"' "exit $rc: $(cat "$SP/ps.out")"
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\nproject: Shop roadmap\nproject_status: "defined=Ready, running=Running, input=Waiting for Input, done=Complete"\n---\n' > .claude/workflow.md
stub projects "$(printf '3\tShop roadmap\n7\tOther board')"
: > "$STUB_LOG"
"$FR" project-status 47 input > "$SP/ps.out" 2>&1; rc=$?
check "project-status: resolves project by title, adds the issue, then one edit, value with spaces" '[ "$rc" = 0 ] && grep -qx "project item-add 3 --owner acme --url https://github.com/acme/requests/issues/47" "$STUB_LOG" && grep -qx "project item-edit 3 --owner acme --url https://github.com/acme/requests/issues/47 --field Status --value Waiting for Input" "$STUB_LOG" && [ "$(grep -c "^project item-" "$STUB_LOG")" = 2 ]' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
check "project-status: reports what it wrote" 'grep -q "acme/requests#47 → Waiting for Input (Shop roadmap)" "$SP/ps.out"' "$(cat "$SP/ps.out")"
: > "$STUB_LOG"
"$FR" project-status R2-47 failed > "$SP/ps.out" 2>&1; rc=$?
check "project-status: event without a value writes nothing, exit 0" '[ "$rc" = 0 ] && ! grep -q "item-" "$STUB_LOG" && grep -q "no value for" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out")"
"$FR" project-status 47 shipped > "$SP/ps.out" 2>&1; rc=$?
check "project-status: unknown event is a usage error" '[ "$rc" = 1 ] && grep -q "unknown event" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out")"
"$FR" project-status 47 > "$SP/ps.out" 2>&1; rc=$?
check "project-status: missing event is a usage error" '[ "$rc" = 1 ]' "exit $rc"
stub item-edit-fails ""; : > "$STUB_LOG"
"$FR" project-status 47 done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: value the board does not know → exit 5 with gh's reason" '[ "$rc" = 5 ] && grep -q "not written for acme/requests#47 — option .Complete. not found" "$SP/ps.out" && [ "$(grep -c "^project item-" "$STUB_LOG")" = 2 ]' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
nostub item-edit-fails
stub item-add-fails ""; : > "$STUB_LOG"
"$FR" project-status 47 done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: issue cannot be added → exit 5 with gh's reason, no edit" '[ "$rc" = 5 ] && grep -q "cannot add acme/requests#47 to .Shop roadmap. — could not resolve" "$SP/ps.out" && ! grep -q "item-edit" "$STUB_LOG"' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
nostub item-add-fails
stub version "gh version 2.95.0 (2026-01-01)"; : > "$STUB_LOG"
"$FR" project-status 47 done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: gh older than 2.97 → exit 5, says so, nothing called" '[ "$rc" = 5 ] && grep -q "gh 2.95.0 is older than 2.97" "$SP/ps.out" && ! grep -q "^project" "$STUB_LOG"' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
"$FR" check > "$SP/check.out" 2>&1
check "check: gh older than 2.97 with project_status → NOT written" 'grep -q "status column: Status, NOT written — gh 2.95.0 is older than 2.97" "$SP/check.out"' "$(cat "$SP/check.out")"
stub version "gh version 2.98.0 (2026-08-20)"
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\nproject: Nope\nproject_status: "done=Complete"\n---\n' > .claude/workflow.md
"$FR" project-status 47 done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: unknown project title → exit 5 with reason" '[ "$rc" = 5 ] && grep -q "no project .Nope. under acme" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out")"
stub project-list-fails ""
"$FR" project-status 47 done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: no project scope → exit 5, hint to refresh" '[ "$rc" = 5 ] && grep -q "gh auth refresh -s project" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out")"
nostub project-list-fails
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\nproject_status: "done=Complete"\n---\n' > .claude/workflow.md
"$FR" project-status 47 done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: mapping without project → exit 5" '[ "$rc" = 5 ] && grep -q "project is empty" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out")"
"$FR" check > "$SP/check.out" 2>&1
check "check: project_status without project → warning line" 'grep -q "project:  NONE — project_status is set but project is empty" "$SP/check.out"' "$(cat "$SP/check.out")"
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\nproject: shop ROADMAP\nproject_status_field: Stand\nproject_status: running=Läuft,done = Fertig\n---\n' > .claude/workflow.md
: > "$STUB_LOG"
"$FR" project-status 'https://github.com/acme/requests/issues/47' done > "$SP/ps.out" 2>&1; rc=$?
check "project-status: title regardless of case, own field name, unquoted mapping, spaces around =, URL ref" '[ "$rc" = 0 ] && grep -qx "project item-edit 3 --owner acme --url https://github.com/acme/requests/issues/47 --field Stand --value Fertig" "$STUB_LOG"' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
"$FR" check > "$SP/check.out" 2>&1
check "check shows the project and its status column" 'grep -q "project:  shop ROADMAP   status column: Stand, written by the skills" "$SP/check.out"' "$(cat "$SP/check.out")"

# --- project-options: the status column gets the mapping's values
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\nproject: Shop roadmap\nproject_status: "defined=Ready, running=Running, input=Waiting for Input, approval=Waiting for Input, done=Complete"\n---\n' > .claude/workflow.md
stub projects "$(printf '3\tShop roadmap\thttps://github.com/users/acme/projects/3\n7\tOther board\thttps://github.com/users/acme/projects/7')"
stub options "$(printf 'PVTSSF_x\nf75\tGREEN\tReady\tThis item has not been started\n47f\tYELLOW\tRunning\t')"
stub mutated "Ready, Running, Waiting for Input, Complete"
nostub mutation.in; : > "$STUB_LOG"
"$FR" project-options > "$SP/po.out" 2>&1; rc=$?
check "project-options: adds the missing values once, existing ones go back with id, colour and text" '[ "$rc" = 0 ] && grep -q "added Waiting for Input, Complete to .Status. of .Shop roadmap. — now: Ready, Running, Waiting for Input, Complete" "$SP/po.out" && grep -q "^api graphql -f query={ repositoryOwner(login: \"acme\") { ... on ProjectV2Owner { projectV2(number: 3) { field(name: \"Status\")" "$STUB_LOG" && grep -qF "\"fieldId\":\"PVTSSF_x\",\"singleSelectOptions\":[{\"id\":\"f75\",\"name\":\"Ready\",\"color\":\"GREEN\",\"description\":\"This item has not been started\"},{\"id\":\"47f\",\"name\":\"Running\",\"color\":\"YELLOW\",\"description\":\"\"},{\"name\":\"Waiting for Input\",\"color\":\"GRAY\",\"description\":\"\"},{\"name\":\"Complete\",\"color\":\"GRAY\",\"description\":\"\"}]" "$STUB/mutation.in"' "exit $rc: $(cat "$SP/po.out"; cat "$STUB/mutation.in" 2>/dev/null)"
check "project-options: names the workflows page of the project" 'grep -q "https://github.com/users/acme/projects/3/workflows" "$SP/po.out"' "$(cat "$SP/po.out")"
nostub mutation.in; : > "$STUB_LOG"
"$FR" project-options ready > "$SP/po.out" 2>&1; rc=$?
check "project-options: a value the column has (case does not matter) changes nothing" '[ "$rc" = 0 ] && grep -q "has every value — Ready, Running" "$SP/po.out" && [ ! -f "$STUB/mutation.in" ]' "exit $rc: $(cat "$SP/po.out")"
"$FR" project-options Blocked 'Say "hi"' > "$SP/po.out" 2>&1; rc=$?
check "project-options: explicit values, JSON escaping" '[ "$rc" = 0 ] && grep -qF "{\"name\":\"Blocked\",\"color\":\"GRAY\",\"description\":\"\"},{\"name\":\"Say \\\"hi\\\"\",\"color\":\"GRAY\",\"description\":\"\"}]" "$STUB/mutation.in"' "exit $rc: $(cat "$SP/po.out"; cat "$STUB/mutation.in" 2>/dev/null)"
stub mutation-fails ""
"$FR" project-options Blocked > "$SP/po.out" 2>&1; rc=$?
check "project-options: failed mutation → exit 5 with gh's reason" '[ "$rc" = 5 ] && grep -q "options not added to .Status. of .Shop roadmap. — Field" "$SP/po.out"' "exit $rc: $(cat "$SP/po.out")"
nostub mutation-fails
stub options ""
"$FR" project-options Blocked > "$SP/po.out" 2>&1; rc=$?
check "project-options: column missing or not single-select → exit 5" '[ "$rc" = 5 ] && grep -q "no single-select column .Status." "$SP/po.out"' "exit $rc: $(cat "$SP/po.out")"
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\nproject: Shop roadmap\n---\n' > .claude/workflow.md
"$FR" project-options > "$SP/po.out" 2>&1; rc=$?
check "project-options: nothing to add from → usage error" '[ "$rc" = 1 ] && grep -q "no values" "$SP/po.out"' "exit $rc: $(cat "$SP/po.out")"
printf -- '---\nfr_prefix: R2\nissue_repo: Acme/Requests\n---\n' > .claude/workflow.md
"$FR" project-options Ready > "$SP/po.out" 2>&1; rc=$?
check "project-options: no project in the profile → usage error" '[ "$rc" = 1 ] && grep -q "no project in the profile" "$SP/po.out"' "exit $rc: $(cat "$SP/po.out")"

# --- worktree hooks: environment, failure, guards
newrepo "$SP/regress-hook" git@github.com:acme/hook.git
printf '.claude/worktrees/\n' > .gitignore
printf -- '---\n---\n' > .claude/workflow.md
git add -A; git commit -qm init; git push -q -u origin main
branch_fr feat/fr-80-x FR-80-x.md FR-80 Eighty in-progress "" "src/x"
git worktree add -q .claude/worktrees/fr-80-x feat/fr-80-x
WT=$(cd .claude/worktrees/fr-80-x && pwd -P)   # physical: FR_WORKTREE is, so docker and co. see one path
"$FR" hook setup FR-80 "$WT" > "$SP/h.out" 2>&1; rc=$?
check "hook: no worktree_setup in the profile → nothing to run, exit 0" '[ "$rc" = 0 ] && grep -q "no worktree_setup in the profile" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" hook teardown FR-80 .claude/worktrees/gone > "$SP/h.out" 2>&1; rc=$?
check "hook: no hook configured and no worktree → still nothing to run, exit 0" '[ "$rc" = 0 ] && grep -q "no worktree_teardown in the profile" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
# the hook records its environment, its cwd and whether stdin is open; the
# profile value ends in a comment, as any frontmatter value may
printf -- '---\nworktree_setup: env | grep ^FR_ | sort > "$STUB/hook.env"; pwd >> "$STUB/hook.env"; if read -r x; then echo stdin >> "$STUB/hook.env"; else echo nostdin >> "$STUB/hook.env"; fi; echo "up on 3080"   # per worktree\n---\n' > .claude/workflow.md
"$FR" hook setup '#80' .claude/worktrees/fr-80-x > "$SP/h.out" 2>&1; rc=$?
check "hook setup: runs in the worktree with FR_ID, FR_NUMBER, FR_BRANCH, FR_WORKTREE, without stdin; output passes through" '[ "$rc" = 0 ] && [ "$(paste -sd " " "$STUB/hook.env")" = "FR_BRANCH=feat/fr-80-x FR_ID=FR-80 FR_NUMBER=80 FR_WORKTREE=$WT $WT nostdin" ] && grep -q "^up on 3080" "$SP/h.out" && grep -q "^worktree_setup done for FR-80" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out"; cat "$STUB/hook.env" 2>/dev/null)"
# a quoted value keeps a " #" inside it; the comment starts after the quote
cat > .claude/workflow.md <<'EOF'
---
worktree_setup: "echo 'PORT=3080 # dev' > $STUB/env.out"   # quoted, so the # inside stays
---
EOF
"$FR" hook setup 80 "$WT" > "$SP/h.out" 2>&1; rc=$?
check "hook setup: a quoted command may contain ' #'" '[ "$rc" = 0 ] && [ "$(cat "$STUB/env.out")" = "PORT=3080 # dev" ]' "exit $rc: $(cat "$SP/h.out"; cat "$STUB/env.out" 2>/dev/null)"
# the command comes from the main checkout's profile, never from the worktree's
# copy on the FR branch — also when fr.sh is run from inside the worktree
printf -- '---\nworktree_setup: echo smuggled > "$STUB/env.out"\n---\n' > "$WT/.claude/workflow.md"
(cd "$WT" && "$FR" hook setup 80 .) > "$SP/h.out" 2>&1; rc=$?
check "hook: the command is read from the main checkout's profile, not the worktree's" '[ "$rc" = 0 ] && [ "$(cat "$STUB/env.out")" = "PORT=3080 # dev" ]' "exit $rc: $(cat "$SP/h.out"; cat "$STUB/env.out" 2>/dev/null)"
git -C "$WT" checkout -q -- .claude/workflow.md
printf -- '---\nworktree_setup: echo boom >&2; exit 7\nworktree_teardown: rm -f "$STUB/hook.env"; echo torn\n---\n' > .claude/workflow.md
"$FR" hook setup 80 "$WT" > "$SP/h.out" 2>&1; rc=$?
check "hook setup: a failing hook → exit 6, its output and exit code in the report" '[ "$rc" = 6 ] && grep -q "^boom" "$SP/h.out" && grep -q "worktree_setup failed (exit 7) for FR-80" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" hook teardown 80 "$WT" > "$SP/h.out" 2>&1; rc=$?
check "hook teardown: runs worktree_teardown" '[ "$rc" = 0 ] && [ ! -f "$STUB/hook.env" ] && grep -q "^torn" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" check > "$SP/check.out" 2>&1
check "check shows the hooks" 'grep -q "hooks:    setup: echo boom >&2; exit 7   teardown: rm -f" "$SP/check.out"' "$(cat "$SP/check.out")"
# guards: a hook never runs anywhere but at the root of an FR worktree of this clone
"$FR" hook teardown 80 .claude/worktrees/gone > "$SP/h.out" 2>&1; rc=$?
check "hook: worktree gone → exit 1 with the command to run by hand" '[ "$rc" = 1 ] && grep -q "no such directory" "$SP/h.out" && grep -q "FR_ID=FR-80 FR_NUMBER=80 bash -c .rm -f" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
git worktree add -q --detach .claude/worktrees/_drop-fr-80 origin/feat/fr-80-x
"$FR" hook teardown 80 .claude/worktrees/_drop-fr-80 > "$SP/h.out" 2>&1; rc=$?
check "hook: temporary _drop- worktrees get no hook" '[ "$rc" = 1 ] && grep -q "temporary worktrees get no hook" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
git worktree remove .claude/worktrees/_drop-fr-80
"$FR" hook teardown 80 . > "$SP/h.out" 2>&1; rc=$?
check "hook: the main checkout is refused" '[ "$rc" = 1 ] && grep -q "is the main checkout" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" hook teardown 80 .claude/worktrees/fr-80-x/req > "$SP/h.out" 2>&1; rc=$?
check "hook: a directory inside a worktree is refused" '[ "$rc" = 1 ] && grep -q "not the root of a worktree" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" hook setup 80 "$SP" > "$SP/h.out" 2>&1; rc=$?
check "hook: a directory outside git is refused" '[ "$rc" = 1 ] && grep -q "not inside a git worktree" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" hook setup 80 "$SP/regress/w" > "$SP/h.out" 2>&1; rc=$?
check "hook: another clone is refused" '[ "$rc" = 1 ] && grep -q "not a worktree of this repository" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
"$FR" hook up 80 "$WT" > "$SP/h.out" 2>&1; rc=$?
check "hook: unknown kind → usage error" '[ "$rc" = 1 ] && grep -q "setup or teardown" "$SP/h.out"' "exit $rc: $(cat "$SP/h.out")"
# an empty value followed by a comment is empty — the template is full of them
printf -- '---\nfr_prefix:                  # empty, comment only\nworktree_setup:             # none\nproject: "Shop roadmap"   # quoted, then a comment\n---\n' > .claude/workflow.md
"$FR" check > "$SP/check.out" 2>&1
check "cfg: an empty value followed by a comment is empty; a quoted value ends at its quote" 'grep -q "prefix: FR " "$SP/check.out" && ! grep -q "hooks:" "$SP/check.out" && grep -q "^project:  Shop roadmap " "$SP/check.out"' "$(cat "$SP/check.out")"

# --- autopilot: queue, pipeline, launch, fix loop
newrepo "$SP/regress-ap" git@github.com:acme/ap.git
printf -- '---\nautopilot_sessions: 2\n---\n' > .claude/workflow.md
printf '.claude/worktrees/\n' > .gitignore
git add -A; git commit -qm init; git push -q -u origin main
stub issues "$(printf '70\tSeventy\t%s\n71\tSeventy-one\t%s\n72\tSeventy-two\t%s\n73\tSeventy-three\t%s' \
  "$(body '## Planning' '- Areas: src/a')" "$(body '## Planning' '- Areas: src/a/x')" \
  "$(body '## Planning' '- Areas: src/b')" "$(body '## Planning' '- Areas: src/c')")"
stub prlist ""; nostub prview; : > "$CLAUDE_LOG"
"$FR" queue add 70 '#71' FR-72 fr-73 FR-70 > "$SP/q.out" 2>&1
check "queue: ids made canonical, each once" '[ "$(paste -sd " " "$SP/q.out")" = "FR-70 FR-71 FR-72 FR-73" ]' "$(cat "$SP/q.out")"
"$FR" pipeline --no-fetch > "$SP/p.out" 2>&1
check "pipeline: wave 1 starts" 'grep -q "^FR-70	queued	start" "$SP/p.out" && grep -q "^FR-72	queued	start" "$SP/p.out"' "$(cat "$SP/p.out")"
check "pipeline: an overlapping FR waits, with the reason" 'grep -q "^FR-71	queued	wait	wave 2: FR-70 src/a ~ src/a/x" "$SP/p.out"' "$(cat "$SP/p.out")"
check "pipeline: starts beyond autopilot_sessions wait" 'grep -q "^FR-73	queued	wait	session limit" "$SP/p.out"' "$(cat "$SP/p.out")"

# FR-70 started, its session alive in the worktree (lock names a live pid)
branch_fr feat/fr-70-a FR-70-a.md FR-70 Seventy in-progress "" "src/a"
git worktree add -q .claude/worktrees/fr-70-a feat/fr-70-a
{ sleep 300 & } 2>/dev/null; echo $! > "$STUB/session.pid"; disown $!
git worktree lock --reason "claude session (pid $(cat "$STUB/session.pid"))" .claude/worktrees/fr-70-a
"$FR" pipeline --no-fetch > "$SP/p.out" 2>&1
check "pipeline: a live session without reports is implementing" 'grep -q "^FR-70	implementing	none" "$SP/p.out"' "$(cat "$SP/p.out")"
check "pipeline: FR-71 still waits for the running FR-70" 'grep -q "^FR-71	queued	wait" "$SP/p.out"' "$(cat "$SP/p.out")"
"$FR" project-status 70 failed "CI red" > "$SP/ps.out" 2>&1; rc=$?
check "project-status: a gate is one word" '[ "$rc" = 1 ] && grep -q "one lowercase word" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out")"
"$FR" project-status 70 implemented > "$SP/ps.out" 2>&1; rc=$?
LOG70="$(git rev-parse --git-common-dir)/fr-workflow/FR-70.log"
check "project-status: logs the event locally, board not configured" '[ "$rc" = 0 ] && grep -q " event implemented$" "$LOG70"' "exit $rc: $(cat "$SP/ps.out" "$LOG70" 2>&1)"
check "pipeline: implemented → ship, says the worktree is still held" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	implemented	ship	a session still holds"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" launch ship FR-70 > "$SP/l.out" 2>&1; rc=$?
check "launch: an unknown live session is never stopped (exit 3)" '[ "$rc" = 3 ] && grep -q "did not start holds fr-70-a" "$SP/l.out" && ! grep -q "^stop" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
"$FR" launch ship FR-70 --replace sesMANUAL1 > "$SP/l.out" 2>&1; rc=$?
check "launch: --replace stops that session, then the ship session with ship_model" '[ "$rc" = 0 ] && grep -qx "stop sesMANUAL1" "$CLAUDE_LOG" && grep -qx -- "-w fr-70-a --bg --model opus --effort high -n FR-70 ship /fr-workflow:ship FR-70" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
check "launch: records the session id" 'grep -qE " launch ship ses[0-9]+0a$" "$LOG70"' "$(cat "$LOG70")"
check "launch ship: the hand-off to review is logged before the launch" '[ "$(grep -n " event review$" "$LOG70" | cut -d: -f1)" -lt "$(grep -n " launch ship " "$LOG70" | tail -n 1 | cut -d: -f1)" ]' "$(cat "$LOG70")"
check "pipeline: launched but no session holds the worktree → stalled" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	stalled	report	the ship session"' "$("$FR" pipeline --no-fetch 2>&1)"
{ sleep 300 & } 2>/dev/null; echo $! > "$STUB/session.pid"; disown $!
git worktree unlock .claude/worktrees/fr-70-a; git worktree lock --reason "claude session (pid $(cat "$STUB/session.pid"))" .claude/worktrees/fr-70-a
# the lock's pid is alive, but the launched session's own state decides: claude
# agents lists it busy, waiting (a prompt nobody answers in the background) or
# idle (its turn ended without a result — the process and its lock linger)
SID70=$(sed -n 's/.* launch ship //p' "$LOG70" | tail -n 1)
agents() { printf '[{"sessionId":"%s-0000-full","status":"%s","pid":%s}]' "$1" "$2" "${3:-1}"; }   # agents <id prefix> <status> [pid]
LOCKPID=$(cat "$STUB/session.pid")
stub agents "$(agents "$SID70" busy "$LOCKPID")"
check "pipeline: launched and busy → shipping" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	shipping	none	$SID70"' "$("$FR" pipeline --no-fetch 2>&1)"
stub agents "$(agents "$SID70" waiting "$LOCKPID")"
check "pipeline: launched and waiting at a prompt → waiting, claude attach" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	waiting	report	the ship session $SID70 waits for you: claude attach $SID70"' "$("$FR" pipeline --no-fetch 2>&1)"
stub agents "$(agents "$SID70" idle "$LOCKPID")"
check "pipeline: launched, its own lock alive, session idle → stalled" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	stalled	report	the ship session $SID70 ended"' "$("$FR" pipeline --no-fetch 2>&1)"
stub agents-fails ""
check "pipeline: claude agents unavailable → the lock decides" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	shipping	none"' "$("$FR" pipeline --no-fetch 2>&1)"
nostub agents-fails
# after the hand-over, the lingering lock of the session that reported is no
# sign of life; a lock with another pid is someone's session in the worktree
"$FR" project-status 70 implemented >/dev/null 2>&1
check "pipeline: implemented, only the finished session's own lock → ship, nothing holds it" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	implemented	ship	$"' "$("$FR" pipeline --no-fetch 2>&1)"
stub agents "$(agents "$SID70" idle 1)"
check "pipeline: implemented, another pid holds the lock → ship, says the worktree is held" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	implemented	ship	a session still holds"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" project-status 70 running >/dev/null 2>&1
check "pipeline: running, another pid holds the lock → shipping" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	shipping	none"' "$("$FR" pipeline --no-fetch 2>&1)"
stub agents "$(agents "$SID70" idle "$LOCKPID")"
check "pipeline: running, only the finished session's own lock → stalled" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	stalled	report	no session works on it"' "$("$FR" pipeline --no-fetch 2>&1)"
stub agents "$(agents "$SID70" busy 1)"
"$FR" project-status 70 failed ci >/dev/null 2>&1
check "pipeline: red CI with fix_loop off → report" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	failed	report	ci (fix_loop: off)"' "$("$FR" pipeline --no-fetch 2>&1)"
printf -- '---\nautopilot_sessions: 2\nfix_loop: checks\nfix_attempts: 1\nfix_skip_checks: [CodeQL, gitleaks]\n---\n' > .claude/workflow.md
check "pipeline: red CI with fix_loop checks → fix" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	failed	fix	ci, attempt 1/1"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prlist "91"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncheck\tbuild\tfail\ncheck\tcodeql\tfail\ncheck\tlint\tpass')"
check "pipeline: a red check from fix_skip_checks never goes to the fix loop" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	failed	report	ci: codeql never"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" fix-brief FR-70 > "$SP/fb.out" 2>&1
check "fix-brief: names the red checks, marks the skipped one" 'grep -q "^red check: build" "$SP/fb.out" && grep -q "not for the fix loop: codeql" "$SP/fb.out" && grep -q "attempt: 1/1" "$SP/fb.out"' "$(cat "$SP/fb.out")"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncheck\tbuild\tfail')"
# the lock's pid is not the recorded session's: someone else's session, never stopped
: > "$CLAUDE_LOG"
"$FR" launch fix 70 > "$SP/l.out" 2>&1; rc=$?
check "launch: the lock belongs to another pid than the recorded session → exit 3, nothing stopped" '[ "$rc" = 3 ] && grep -q "did not start holds fr-70-a" "$SP/l.out" && ! grep -q "^stop" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
stub agents "$(agents "$SID70" busy "$LOCKPID")"
: > "$CLAUDE_LOG"
"$FR" launch fix 70 > "$SP/l.out" 2>&1; rc=$?
check "launch fix: stops the autopilot's own session, implement in fix mode with the FR's model" '[ "$rc" = 0 ] && grep -qE "^stop ses[0-9]+0a$" "$CLAUDE_LOG" && grep -qx -- "-w fr-70-a --bg --model opus --effort high -n FR-70 fix 1 /fr-workflow:implement FR-70 fix" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
"$FR" launch fix 70 > "$SP/l.out" 2>&1; rc=$?
check "launch fix: beyond fix_attempts → exit 3" '[ "$rc" = 3 ] && grep -q "used its 1 fix attempts" "$SP/l.out"' "exit $rc: $(cat "$SP/l.out")"
"$FR" project-status 70 failed ci >/dev/null 2>&1
check "pipeline: attempts used up → report" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	failed	report	ci, fix attempts used up (1/1)"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" project-status 70 failed security >/dev/null 2>&1
check "pipeline: security findings never go to the fix loop" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-70	failed	report	security$"' "$("$FR" pipeline --no-fetch 2>&1)"
if [ -f "$STUB/session.pid" ]; then kill "$(cat "$STUB/session.pid")" 2>/dev/null; rm -f "$STUB/session.pid"; fi

# FR-72 in review: the PR decides
# (branch_fr commits uncommitted changes onto the FR branch: profile edits come after it)
branch_fr feat/fr-72-b FR-72-b.md FR-72 Seventy-two in-review "" "src/b"
printf -- '---\nautopilot_sessions: 2\nfix_loop: checks\n---\n' > .claude/workflow.md
stub prlist "92"
# its ship session reported approval and is still listed, lock alive: the PR
# decides from here, not the process
git worktree add -q .claude/worktrees/fr-72-b feat/fr-72-b
{ sleep 300 & } 2>/dev/null; echo $! > "$STUB/session72.pid"; disown $!
git worktree lock --reason "claude session (pid $(cat "$STUB/session72.pid"))" .claude/worktrees/fr-72-b
LOG72="$(git rev-parse --git-common-dir)/fr-workflow/FR-72.log"
printf '%s launch ship sesSHIP72\n' "$(date -u +%s)" >> "$LOG72"
stub agents "$(agents sesSHIP72 busy)"
check "pipeline: launched ship, no event yet, lock alive, listed busy → shipping" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	shipping	none	sesSHIP72"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" project-status 72 approval >/dev/null 2>&1
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncheck\tbuild\tpass\ncomment\t1\tMEMBER\tboris\thttps://x/1\ncomment\t4102444800\tNONE\tstranger\thttps://x/2')"
check "pipeline: green PR, only old or untrusted comments → waits for the merge" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	none	PR #92 waits for your merge"' "$("$FR" pipeline --no-fetch 2>&1)"
stub perm-boris write
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tCOLLABORATOR\tboris\thttps://x/3')"
check "pipeline: a collaborator's new comment, fix_loop checks → report" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	report	PR #92: comments by boris (fix_loop: checks)"' "$("$FR" pipeline --no-fetch 2>&1)"
printf -- '---\nautopilot_sessions: 2\nfix_loop: checks+comments\nfix_comment_bots: [claude[bot]]\n---\n' > .claude/workflow.md
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tNONE\tapp/claude\treview CHANGES_REQUESTED')"
check "pipeline: a listed bot's review, checks+comments → fix" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by app/claude, attempt 1/2"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" fix-brief 72 > "$SP/fb.out" 2>&1
check "fix-brief: lists the trusted comments" 'grep -q "^comment by app/claude: review CHANGES_REQUESTED" "$SP/fb.out"' "$(cat "$SP/fb.out")"
check "pr_of: asks only for PRs of this repository, not of forks" 'grep -q "^pr list -R acme/ap --head feat/fr-72-b --state open --json number,isCrossRepository " "$STUB_LOG"' "$(grep "^pr list" "$STUB_LOG" | tail -1)"
# the fix loop's settings come from the main checkout's profile, also when
# fr.sh runs inside a worktree whose branch carries another profile
printf -- '---\nfix_loop: off\n---\n' > .claude/worktrees/fr-70-a/.claude/workflow.md
(cd .claude/worktrees/fr-70-a && "$FR" fix-brief 72) > "$SP/fb.out" 2>&1
check "fix-brief from inside a worktree: settings from the main checkout's profile" 'grep -q "^comment by app/claude: review CHANGES_REQUESTED" "$SP/fb.out"' "$(cat "$SP/fb.out")"
git -C .claude/worktrees/fr-70-a checkout -q -- .claude/workflow.md
# a plain login never matches a listed bot, however it is spelled
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tNONE\tclaude\thttps://x/4\ncomment\t4102444800\tNONE\tClaude-Bot\thttps://x/5')"
check "pipeline: a user named like a listed bot is not trusted" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	none	PR #92 waits for your merge"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tNONE\tClaude[bot]\thttps://x/6')"
check "pipeline: the bot form matches regardless of case" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by Claude\[bot\], attempt 1/2"' "$("$FR" pipeline --no-fetch 2>&1)"
# comment trust is GitHub's collaborator permission, not the association (0.7.1):
# MEMBER is any member of the organization, COLLABORATOR may read only
stub perm-reader read
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tMEMBER\treader\thttps://x/7')"
check "pipeline: a MEMBER with read permission is not trusted" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	none	PR #92 waits for your merge"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tCOLLABORATOR\tnobody\thttps://x/8')"
check "pipeline: a COLLABORATOR whose permission cannot be read (404) is not trusted" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	none	PR #92 waits for your merge"' "$("$FR" pipeline --no-fetch 2>&1)"
stub perm-admin admin
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tMEMBER\tadmin\thttps://x/9\ncomment\t4102444800\tMEMBER\tadmin\thttps://x/10')"
check "pipeline: a MEMBER with admin permission is trusted, looked up once for two comments" 'n0=$(grep -c "collaborators/admin/permission" "$STUB_LOG"); "$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by admin, attempt 1/2" && [ "$(( $(grep -c "collaborators/admin/permission" "$STUB_LOG") - n0 ))" = 1 ]' "$(grep -c "collaborators/admin/permission" "$STUB_LOG") lookups so far"
PERMCACHE="$(git rev-parse --git-common-dir)/fr-workflow/perm.cache"
check "pipeline: the next tick takes the permission from the state dir's cache, no lookup" 'n0=$(grep -c "collaborators/admin/permission" "$STUB_LOG"); "$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by admin" && [ "$(grep -c "collaborators/admin/permission" "$STUB_LOG")" = "$n0" ] && grep -q "^acme/ap	admin	admin	" "$PERMCACHE"' "$(cat "$PERMCACHE")"
sub "s/^\(acme\/ap\tadmin\tadmin\t\).*/\11/" "$PERMCACHE"
check "pipeline: a cache entry older than PERM_TTL is looked up again" 'n0=$(grep -c "collaborators/admin/permission" "$STUB_LOG"); "$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by admin" && [ "$(( $(grep -c "collaborators/admin/permission" "$STUB_LOG") - n0 ))" = 1 ]' "$(cat "$PERMCACHE")"
touch "$STUB/perm-limited-fails"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tMEMBER\tlimited\thttps://x/16')"
"$FR" pipeline --no-fetch > "$SP/p.out" 2> "$SP/p.err"
check "pipeline: a lookup that fails (rate limit) trusts nobody, says so on stderr and caches nothing" 'grep -q "^FR-72	review	none	PR #92 waits for your merge" "$SP/p.out" && grep -q "cannot read the permission of limited in acme/ap.*rate limit" "$SP/p.err" && ! grep -q "limited" "$PERMCACHE"' "$(cat "$SP/p.out" "$SP/p.err")"
stub perm-ghost null
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tCOLLABORATOR\tghost\thttps://x/17')"
"$FR" pipeline --no-fetch > "$SP/p.out" 2> "$SP/p.err"
check "pipeline: a null permission is no permission, nothing on stderr, nothing cached" 'grep -q "^FR-72	review	none	PR #92 waits for your merge" "$SP/p.out" && [ ! -s "$SP/p.err" ] && ! grep -q "ghost" "$PERMCACHE"' "$(cat "$SP/p.out" "$SP/p.err")"
stub perm-driveby write
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tCONTRIBUTOR\tdriveby\thttps://x/11')"
check "pipeline: NONE/CONTRIBUTOR authors are never looked up — they cannot have write access" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	none	PR #92 waits for your merge" && ! grep -q "collaborators/driveby/permission" "$STUB_LOG"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tOWNER\tacme-owner\thttps://x/12')"
check "pipeline: the repository's OWNER is trusted without a lookup" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by acme-owner, attempt 1/2" && ! grep -q "collaborators/acme-owner/permission" "$STUB_LOG"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tMEMBER\t../x\thttps://x/13')"
check "pipeline: a login that is not a GitHub login is neither trusted nor looked up" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	none	PR #92 waits for your merge" && ! grep -q "collaborators/\.\./x/permission" "$STUB_LOG"' "$("$FR" pipeline --no-fetch 2>&1)"
stub perm-emu_user write
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tMEMBER\temu_user\thttps://x/18')"
check "pipeline: an Enterprise Managed User login with an underscore is looked up and trusted" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	fix	PR #92: comments by emu_user, attempt 1/2"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\ncomment\t4102444800\tMEMBER\treader\thttps://x/14\ncomment\t4102444800\tMEMBER\tadmin\thttps://x/15')"
"$FR" fix-brief 72 > "$SP/fb.out" 2>&1
check "fix-brief: lists the comment of the admin, not the reader's" 'grep -q "^comment by admin: https://x/15" "$SP/fb.out" && ! grep -q "reader" "$SP/fb.out"' "$(cat "$SP/fb.out")"
rm -f "$STUB"/perm-* "$PERMCACHE"
stub prview "$(printf 'pr\tOPEN\tCONFLICTING\tDIRTY')"
check "pipeline: a conflicting PR → ship again" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	ship	PR #92 conflicts"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tCLOSED\tUNKNOWN\tUNKNOWN')"
check "pipeline: a PR closed unmerged → report" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-72	review	report	PR #92 closed"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN')"
kill "$(cat "$STUB/session72.pid")" 2>/dev/null; rm -f "$STUB/session72.pid"

# --wait: wakes at once on news, otherwise only after --max
"$FR" pipeline --no-fetch --wait 1 --max 30 > "$SP/w1.out" 2>&1
t0=$(date +%s); "$FR" pipeline --no-fetch --wait 1 --max 3 > "$SP/w2.out" 2>&1; dt=$(( $(date +%s) - t0 ))
check "pipeline --wait: same result → waits until --max" '[ "$dt" -ge 2 ] && cmp -s "$SP/w1.out" "$SP/w2.out"' "dt=$dt"
"$FR" queue rm FR-73 >/dev/null
t0=$(date +%s); "$FR" pipeline --no-fetch --wait 1 --max 30 > "$SP/w3.out" 2>&1; dt=$(( $(date +%s) - t0 ))
check "pipeline --wait: a change wakes it at once" '[ "$dt" -le 2 ] && ! grep -q "^FR-73" "$SP/w3.out"' "dt=$dt $(cat "$SP/w3.out")"
SEEN="$(git rev-parse --git-common-dir)/fr-workflow/autopilot.seen"; printf 'stale\n' > "$SEEN"
t0=$(date +%s); "$FR" pipeline --no-fetch --wait 0 > "$SP/w4.out" 2>&1; dt=$(( $(date +%s) - t0 ))
check "pipeline --wait 0: returns at once and remembers the result" '[ "$dt" -le 1 ] && cmp -s "$SP/w4.out" "$SEEN"' "dt=$dt"

# launches: a title from the issue never reaches the shell; the autopilot itself
git stash -q -u 2>/dev/null || true
branch_fr feat/fr-74-c FR-74-c.md FR-74 'Say "hi" $HOME `x`' in-progress "" "src/d"
git worktree add -q .claude/worktrees/fr-74-c feat/fr-74-c
: > "$CLAUDE_LOG"
"$FR" launch implement FR-74 > "$SP/l.out" 2>&1; rc=$?
check "launch implement: title without quotes, \$ or backticks in the session name" '[ "$rc" = 0 ] && grep -qx -- "-w fr-74-c --bg --model opus --effort high -n FR-74 Say hi HOME x /fr-workflow:implement FR-74" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
touch "$STUB/claude-untrusted"
"$FR" launch ship FR-74 > "$SP/l.out" 2>&1; rc=$?
check "launch: claude fails → exit 1 with its message, nothing logged" '[ "$rc" = 1 ] && grep -q "Workspace not trusted" "$SP/l.out" && ! grep -q "launch ship" "$(git rev-parse --git-common-dir)/fr-workflow/FR-74.log"' "exit $rc: $(cat "$SP/l.out")"
rm -f "$STUB/claude-untrusted"
# session_permission_mode reaches every launched session as a flag — a
# background session inherits no environment and nobody answers its prompts
printf -- '---\nsession_permission_mode: auto\n---\n' > .claude/workflow.md
: > "$CLAUDE_LOG"
"$FR" launch implement FR-74 > "$SP/l.out" 2>&1; rc=$?
check "launch: session_permission_mode becomes --permission-mode" '[ "$rc" = 0 ] && grep -qx -- "-w fr-74-c --bg --model opus --effort high --permission-mode auto -n FR-74 Say hi HOME x /fr-workflow:implement FR-74" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
: > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: background session with autopilot_model and the permission mode, id kept, says how to read its log" '[ "$rc" = 0 ] && grep -qx -- "--bg -n fr-autopilot --model sonnet --effort medium --permission-mode auto /fr-workflow:autopilot --loop" "$CLAUDE_LOG" && "$FR" queue session | grep -qE "^ses[0-9]+0a$" && grep -q "claude logs ses" "$SP/l.out"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
# a second autopilot never starts beside a running one; one whose loop ended
# (listed idle) is stopped and replaced, and the new one starts with nothing seen
SIDAP=$("$FR" queue session)
SEEN="$(git rev-parse --git-common-dir)/fr-workflow/autopilot.seen"; printf 'seen\n' > "$SEEN"
stub agents "$(agents "$SIDAP" busy)"; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: the recorded one runs → exit 3, nothing started" '[ "$rc" = 3 ] && grep -q "runs as $SIDAP (busy)" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ] && [ "$("$FR" queue session)" = "$SIDAP" ] && [ -f "$SEEN" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
stub agents-fails ""; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: claude agents gives no answer → exit 1, no second autopilot" '[ "$rc" = 1 ] && grep -q "cannot tell whether the autopilot $SIDAP" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ] && [ -f "$SEEN" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
nostub agents-fails
# a record without status and pid — the old container's session after a restart — is gone: a new one starts
stub agents "[{\"sessionId\":\"$SIDAP-0000-full\",\"state\":\"blocked\"}]"; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: the recorded one is listed without status and pid → gone, a new one starts" '[ "$rc" = 0 ] && grep -q -- "--bg -n fr-autopilot" "$CLAUDE_LOG" && grep -q "^launched autopilot as" "$SP/l.out"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
SIDAP=$("$FR" queue session); printf 'seen\n' > "$SEEN"
stub agents "[{\"sessionId\":\"$SIDAP-0000-full\",\"status\":null,\"pid\":$$}]"; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: no status but a live pid → cannot tell, exit 1" '[ "$rc" = 1 ] && grep -q "cannot tell whether the autopilot $SIDAP" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
printf -- '---\nsession_permission_mode: "auto --dangerously-skip-permissions"\n---\n' > .claude/workflow.md
stub agents "$(agents "$SIDAP" idle)"; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: a bad session_permission_mode stops before anything is stopped or forgotten" '[ "$rc" = 1 ] && grep -q "never bypassPermissions" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ] && [ -f "$SEEN" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
printf -- '---\nsession_permission_mode: auto\n---\n' > .claude/workflow.md
stub agents "$(agents "$SIDAP" idle)"; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: the recorded one is idle → stopped and replaced, nothing seen yet" '[ "$rc" = 0 ] && grep -qx "stop $SIDAP" "$CLAUDE_LOG" && [ "$("$FR" queue session)" != "$SIDAP" ] && [ ! -f "$SEEN" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
nostub agents; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: the recorded one is gone → a new one, nothing stopped" '[ "$rc" = 0 ] && ! grep -q "^stop" "$CLAUDE_LOG"' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
# a bad value stops the launch before the session holding the worktree is stopped
LOG74="$(git rev-parse --git-common-dir)/fr-workflow/FR-74.log"
SID74=$(sed -n 's/.* launch implement //p' "$LOG74" | tail -n 1)
{ sleep 300 & } 2>/dev/null; echo $! > "$STUB/session.pid"; disown $!
git worktree lock --reason "claude session (pid $(cat "$STUB/session.pid"))" .claude/worktrees/fr-74-c
stub agents "$(agents "$SID74" idle "$(cat "$STUB/session.pid")")"
printf -- '---\nsession_permission_mode: "auto --dangerously-skip-permissions"\n---\n' > .claude/workflow.md
: > "$CLAUDE_LOG"
"$FR" launch ship FR-74 > "$SP/l.out" 2>&1; rc=$?
check "launch: session_permission_mode outside the allowed modes stops the launch before any session is stopped" '[ "$rc" = 1 ] && grep -q "never bypassPermissions" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ] && kill -0 "$(cat "$STUB/session.pid")" 2>/dev/null' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
printf -- '---\nsession_permission_mode: bypassPermissions\n---\n' > .claude/workflow.md
: > "$CLAUDE_LOG"
"$FR" launch ship FR-74 > "$SP/l.out" 2>&1; rc=$?
check "launch: bypassPermissions is refused, also from a committed profile" '[ "$rc" = 1 ] && grep -q "never bypassPermissions" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
if [ -f "$STUB/session.pid" ]; then kill "$(cat "$STUB/session.pid")" 2>/dev/null; rm -f "$STUB/session.pid"; fi

# --- deployment: the newest GitHub deployment of the PR's commit (deploy_signal: deployment)
newrepo "$SP/regress-dep" git@github.com:acme/dep.git
printf -- '---\ndeploy_environment: "test-slot-*"\n---\n' > .claude/workflow.md
git add -A; git commit -qm init; git push -q -u origin main
HEAD=$(printf 'a%.0s' $(seq 1 40)); MERGE=$(printf 'b%.0s' $(seq 1 40)); OTHER=$(printf 'c%.0s' $(seq 1 40)); OLDMERGE=$(printf 'd%.0s' $(seq 1 40)); OLDHEAD=$(printf 'e%.0s' $(seq 1 40))
# rows as fr.sh's --jq prints them. ?sha= : 7 production 10:00 and 3 test-slot-1 08:00, both the head.
# ?ref=refs/pull/91/merge : 5 test-slot-2 09:00 (merge of the head), 4 test-slot-2 06:00 (merge of an older head)
stub deployments-sha "$(printf '7\tproduction\t%s\t2026-11-05T10:00:00Z\n3\ttest-slot-1\t%s\t2026-11-05T08:00:00Z' "$HEAD" "$HEAD")"
stub deployments-ref "$(printf '5\ttest-slot-2\t%s\t2026-11-05T09:00:00Z\n4\ttest-slot-2\t%s\t2026-11-05T06:00:00Z' "$MERGE" "$OLDMERGE")"
stub "commit-$(printf '%s' "$MERGE" | cut -c1-7)" "$(printf '%s\t%s' "$OTHER" "$HEAD")"
stub "commit-$(printf '%s' "$OLDMERGE" | cut -c1-7)" "$(printf '%s\t%s' "$OTHER" "$OLDHEAD")"
stub compare "ahead"
stub statuses-5 "$(printf 'success\thttps://slot2.test.example\t2026-11-05T09:05:00Z')"
stub statuses-3 "$(printf 'pending\t\t')"   # what the --jq prints for a deployment without statuses
: > "$STUB_LOG"
"$FR" deployment "$HEAD" --pr 91 > "$SP/d.out" 2>&1; rc=$?
check "deployment: the newest deployment in a matching environment — the merge commit of the head, deployed under refs/pull/N/merge" '[ "$rc" = 0 ] && [ "$(cat "$SP/d.out")" = "$(printf "success\ttest-slot-2\thttps://slot2.test.example\t5\t%s\t2026-11-05T09:05:00Z" "$MERGE")" ]' "exit $rc: $(cat "$SP/d.out")"
check "deployment: both lists filtered by the API, production skipped by the glob, one commit read, statuses for the pick only" 'grep -q "^api -X GET repos/acme/dep/deployments -f sha=$HEAD -f per_page=100 --jq" "$STUB_LOG" && grep -q "^api -X GET repos/acme/dep/deployments -f ref=refs/pull/91/merge -f per_page=100 --jq" "$STUB_LOG" && [ "$(grep -c "/commits/" "$STUB_LOG")" = 1 ] && grep -q "deployments/5/statuses" "$STUB_LOG" && ! grep -q "deployments/[37]/statuses" "$STUB_LOG"' "$(cat "$STUB_LOG")"
stub compare "diverged"
"$FR" deployment "$HEAD" --pr 91 > "$SP/d.out" 2>&1; rc=$?
check "deployment: a merge whose other parent is not on the base branch is not this PR's → the next one; no statuses yet = pending" '[ "$rc" = 0 ] && [ "$(cat "$SP/d.out")" = "$(printf "pending\ttest-slot-1\t\t3\t%s\t" "$HEAD")" ]' "exit $rc: $(cat "$SP/d.out")"
stub compare "ahead"
# the newest merge deployment belongs to an older head: skipped, the head's own deployment counts
stub deployments-ref "$(printf '4\ttest-slot-2\t%s\t2026-11-05T09:30:00Z' "$OLDMERGE")"
check "deployment: a merge commit of an older head does not count" '"$FR" deployment "$HEAD" --pr 91 2>/dev/null | cut -f1,2,4 | grep -qx "pending	test-slot-1	3"' "$("$FR" deployment "$HEAD" --pr 91 2>&1)"
stub deployments-ref "$(printf '5\ttest-slot-2\t%s\t2026-11-05T09:00:00Z' "$MERGE")"
check "deployment: without --pr only the head's own deployments are looked at" '"$FR" deployment "$HEAD" 2>/dev/null | cut -f4 | grep -qx 3 && ! grep -q "deployments -f ref=" <(tail -n 3 "$STUB_LOG")' "$("$FR" deployment "$HEAD" 2>&1)"
stub statuses-3 "$(printf 'inactive\thttps://slot1.test.example\t2026-11-05T08:30:00Z')"
check "deployment: the latest status counts — inactive" '"$FR" deployment "$HEAD" 2>/dev/null | cut -f1,4 | grep -qx "inactive	3"' "$("$FR" deployment "$HEAD" 2>&1)"
"$FR" deployment "$(printf "%s" "$HEAD" | cut -c1-7)" > "$SP/d.out" 2>&1; rc=$?
check "deployment: a short head sha is refused — the API filters by the full one" '[ "$rc" = 1 ] && grep -q "full 40-hex" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
printf -- '---\ndeploy_environment: test-slot-2\n---\n' > .claude/workflow.md
: > "$STUB_LOG"
check "deployment: an exact environment name goes to the API as an encoded query field" '"$FR" deployment "$HEAD" --pr 91 2>/dev/null | cut -f4 | grep -qx 5 && grep -q "deployments -f sha=$HEAD -f per_page=100 -f environment=test-slot-2 --jq" "$STUB_LOG"' "$(cat "$STUB_LOG")"
printf -- '---\ndeploy_environment: "pr-{pr}"\n---\n' > .claude/workflow.md
"$FR" deployment "$HEAD" > "$SP/d.out" 2>&1; rc=$?
check "deployment: {pr} in the environment needs --pr" '[ "$rc" = 1 ] && grep -q "pass --pr" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
check "deployment: no deployment in the environment → none" '[ "$("$FR" deployment "$HEAD" --pr 91 2>/dev/null)" = "$(printf "none\t\t\t\t\t")" ]' "$("$FR" deployment "$HEAD" --pr 91 2>&1)"
printf -- '---\n---\n' > .claude/workflow.md
: > "$STUB_LOG"
"$FR" deployment "$HEAD" > "$SP/d.out" 2>&1; rc=$?
check "deployment: deploy_environment is required — the newest deployment may be production; nothing is asked" '[ "$rc" = 1 ] && grep -q "may be production" "$SP/d.out" && ! grep -q "deployments" "$STUB_LOG"' "exit $rc: $(cat "$SP/d.out" "$STUB_LOG")"
printf -- '---\ndeploy_environment: "test-slot-*"\n---\n' > .claude/workflow.md
"$FR" deployment nothex > "$SP/d.out" 2>&1; rc=$?
check "deployment: the head must be a sha" '[ "$rc" = 1 ] && grep -q "usage" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
"$FR" deployment "$HEAD" --pr > "$SP/d.out" 2>&1; rc=$?
check "deployment: --pr without a number says so" '[ "$rc" = 1 ] && grep -q "needs the PR number" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
"$FR" pipeline --no-fetch --wait > "$SP/d.out" 2>&1; rc=$?
check "pipeline: --wait without seconds says so" '[ "$rc" = 1 ] && grep -q "needs seconds" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
stub deployments-fails ""
"$FR" deployment "$HEAD" > "$SP/d.out" 2>&1; rc=$?
check "deployment: a failing list is an error, not none" '[ "$rc" = 1 ] && grep -q "cannot list" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
nostub deployments-fails
stub commits-fails ""
"$FR" deployment "$HEAD" --pr 91 > "$SP/d.out" 2>&1; rc=$?
check "deployment: a failing commit lookup (rate limit) is an error, never a 'not this PR'" '[ "$rc" = 1 ] && grep -q "cannot read commit" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
nostub commits-fails
# pr-commit: the same rule for the skills' other signals
check "pr-commit: the head itself, also by prefix" '"$FR" pr-commit "$HEAD" "$(printf "%s" "$HEAD" | cut -c1-7)" >/dev/null 2>&1' "$("$FR" pr-commit "$HEAD" "$HEAD" 2>&1)"
check "pr-commit: a merge commit of the head whose other parent is on the base branch" '"$FR" pr-commit "$MERGE" "$HEAD" 2>/dev/null | grep -q "^this PR"' "$("$FR" pr-commit "$MERGE" "$HEAD" 2>&1)"
"$FR" pr-commit "$OLDMERGE" "$HEAD" > "$SP/d.out" 2>&1; rc=$?
check "pr-commit: a merge of another head → exit 1" '[ "$rc" = 1 ] && grep -q "^not this PR" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
stub compare "diverged"
"$FR" pr-commit "$MERGE" "$HEAD" > "$SP/d.out" 2>&1; rc=$?
check "pr-commit: the other parent off the base branch → exit 1" '[ "$rc" = 1 ]' "exit $rc: $(cat "$SP/d.out")"
"$FR" bogus > "$SP/d.out" 2>&1; rc=$?
check "usage: an unknown command prints the whole header, Issue refs included" '[ "$rc" = 2 ] && grep -q "^Issue refs:" "$SP/d.out" && grep -q "fr.sh pr-commit" "$SP/d.out"' "exit $rc: $(tail -n 3 "$SP/d.out")"

# --- notify: the project's notify_command, for what needs the user
newrepo "$SP/regress-ntf" git@github.com:acme/ntf.git
printf '.claude/worktrees/\n' > .gitignore
printf -- '---\n---\n' > .claude/workflow.md
git add -A; git commit -qm init; git push -q -u origin main
"$FR" notify FR-90 failed "ci (fix_loop: off)" > "$SP/n.out" 2>&1; rc=$?
check "notify: no notify_command → nothing, exit 0" '[ "$rc" = 0 ] && [ ! -s "$SP/n.out" ]' "exit $rc: $(cat "$SP/n.out")"
branch_fr feat/fr-90-n FR-90-n.md FR-90 Ninety in-progress "" "src/n"
# (branch_fr commits uncommitted changes onto the FR branch: profile edits come after it)
printf -- '---\nnotify_command: env | grep ^FR_ | sort > "$STUB/notify.env"; pwd >> "$STUB/notify.env"; if read -r x; then echo stdin >> "$STUB/notify.env"; else echo nostdin >> "$STUB/notify.env"; fi; echo sent   # test\n---\n' > .claude/workflow.md
MAIN=$(pwd -P)
"$FR" notify '#90' failed "ci (fix_loop: off)" > "$SP/n.out" 2>&1; rc=$?
check "notify: runs the command in the main checkout with FR_ID, FR_PHASE, FR_DETAIL, FR_SESSION, FR_REPO, FR_MESSAGE, without stdin" '[ "$rc" = 0 ] && [ "$(paste -sd "|" "$STUB/notify.env")" = "FR_DETAIL=ci (fix_loop: off)|FR_ID=FR-90|FR_MESSAGE=FR-90 failed: ci (fix_loop: off)|FR_PHASE=failed|FR_REPO=acme/ntf|FR_SESSION=|$MAIN|nostdin" ] && grep -qx sent "$SP/n.out"' "exit $rc: $(cat "$SP/n.out"; cat "$STUB/notify.env" 2>/dev/null)"
"$FR" notify autopilot done > "$SP/n.out" 2>&1; rc=$?
check "notify: the autopilot's own line, without detail" '[ "$rc" = 0 ] && grep -qx "FR_ID=autopilot" "$STUB/notify.env" && grep -qx "FR_MESSAGE=autopilot done" "$STUB/notify.env" && grep -qx "FR_DETAIL=" "$STUB/notify.env"' "exit $rc: $(cat "$STUB/notify.env" 2>/dev/null)"
LOG90="$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log"
"$FR" queue add FR-90 >/dev/null
"$FR" project-status 90 failed ci >/dev/null 2>&1
printf '%s launch ship sesN90\n' "$(date -u +%s)" >> "$LOG90"
"$FR" project-status 90 failed review >/dev/null 2>&1
"$FR" notify FR-90 failed review >/dev/null 2>&1
check "notify: FR_SESSION is the session the autopilot launched last" 'grep -qx "FR_SESSION=sesN90" "$STUB/notify.env"' "$(cat "$STUB/notify.env" 2>/dev/null)"
printf -- '---\nnotify_command: exit 3\n---\n' > .claude/workflow.md
"$FR" notify FR-90 failed review > "$SP/n.out" 2>&1; rc=$?
check "notify: a failing command → exit 6 with the line it was about" '[ "$rc" = 6 ] && grep -q "notify_command failed (exit 3) for: FR-90 failed: review" "$SP/n.out"' "exit $rc: $(cat "$SP/n.out")"
"$FR" notify FR-90 > "$SP/n.out" 2>&1; rc=$?
check "notify: needs a phase" '[ "$rc" = 1 ] && grep -q usage "$SP/n.out"' "exit $rc: $(cat "$SP/n.out")"
# pipeline --wait: every row that needs the user and is new since the last result is notified once
printf -- '---\nnotify_command: echo "$FR_MESSAGE" >> "$STUB/notified"\n---\n' > .claude/workflow.md
rm -f "$STUB/notified" "$(git rev-parse --git-common-dir)/fr-workflow/autopilot.seen"
"$FR" pipeline --no-fetch --wait 0 > "$SP/w.out" 2>&1; rc=$?
check "pipeline --wait: a report row goes to notify_command, with how to go on" '[ "$rc" = 0 ] && [ "$(cat "$STUB/notified")" = "FR-90 failed: review — the ship session ended: /fr-workflow:ship FR-90 runs the gate again" ]' "exit $rc: $(cat "$SP/w.out"; cat "$STUB/notified" 2>/dev/null)"
"$FR" pipeline --no-fetch --wait 0 >/dev/null 2>&1
check "pipeline --wait: the same row is not notified twice" '[ "$(wc -l < "$STUB/notified" | tr -d " ")" = 1 ]' "$(cat "$STUB/notified")"
"$FR" project-status 90 blocked conflict >/dev/null 2>&1
"$FR" pipeline --no-fetch --wait 0 >/dev/null 2>&1
check "pipeline --wait: a changed row is notified again" '[ "$(tail -n 1 "$STUB/notified")" = "FR-90 blocked: conflict" ]' "$(cat "$STUB/notified")"
"$FR" pipeline --no-fetch >/dev/null 2>&1
check "pipeline without --wait never notifies (status is read-only)" '[ "$(wc -l < "$STUB/notified" | tr -d " ")" = 2 ]' "$(cat "$STUB/notified")"
# notify_repeat: a row that stays is notified again after that many minutes, with how long it waits
N="$(git rev-parse --git-common-dir)/fr-workflow/autopilot.notified"
awk -F '\t' -v OFS='\t' -v t="$(( $(date -u +%s) - 7300 ))" '{ $1 = t; $2 = t; print }' "$N" > "$N.tmp" && mv "$N.tmp" "$N"
"$FR" pipeline --no-fetch --wait 0 >/dev/null 2>&1
check "pipeline --wait: a row still there after notify_repeat minutes is notified again, with the time it waits" '[ "$(tail -n 1 "$STUB/notified")" = "FR-90 blocked: conflict — still waiting after 2h01m" ] && [ "$(wc -l < "$STUB/notified" | tr -d " ")" = 3 ]' "$(cat "$STUB/notified")"
printf -- '---\nnotify_command: echo "$FR_MESSAGE" >> "$STUB/notified"\nnotify_repeat: 0\n---\n' > .claude/workflow.md
awk -F '\t' -v OFS='\t' -v t="$(( $(date -u +%s) - 7300 ))" '{ $1 = t; $2 = t; print }' "$N" > "$N.tmp" && mv "$N.tmp" "$N"
"$FR" pipeline --no-fetch --wait 0 >/dev/null 2>&1
check "pipeline --wait: notify_repeat 0 notifies once" '[ "$(wc -l < "$STUB/notified" | tr -d " ")" = 3 ]' "$(cat "$STUB/notified")"
printf -- '---\nnotify_command: exit 3\n---\n' > .claude/workflow.md
"$FR" project-status 90 failed security >/dev/null 2>&1
"$FR" pipeline --no-fetch --wait 0 > "$SP/w.out" 2>&1; rc=$?
check "pipeline --wait: a failing notify_command is reported on stderr, the result still comes" '[ "$rc" = 0 ] && grep -q "^FR-90	failed	report	security" "$SP/w.out" && grep -q "notify_command failed" "$SP/w.out"' "exit $rc: $(cat "$SP/w.out")"
# stop comments: the body, who should look, how to answer; only with stop_comments on
printf -- '---\nnotify_command: echo "$FR_MESSAGE" >> "$STUB/notified"\nstop_comments: on\n---\n' > .claude/workflow.md
printf -- '---\nattach_command: docker exec -it -w /work/ntf box claude attach\n---\n' > .claude/workflow.local.md
echo "$(date -u +%s) launch ship ses90ship" >> "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log"
"$FR" project-status 90 failed review >/dev/null 2>&1
stub user boris; stub assignees "$(printf 'boris\nflorian')"
printf 'Review gestoppt: 5 Befunde.\n\n| # | Befund |\n| - | ------ |\n| 1 | x |\n' > "$SP/body.md"
: > "$STUB_LOG"; rm -f "$STUB/comment.in"
"$FR" stop-comment FR-90 review "$SP/body.md" > "$SP/sc.out" 2>&1; rc=$?
check "stop-comment: posts the body with the other assignees and this machine's attach command, logs it" '[ "$rc" = 0 ] && grep -q "^issue comment 90 -R acme/ntf --body-file -" "$STUB_LOG" && grep -q "^Review gestoppt: 5 Befunde" "$STUB/comment.in" && grep -qx "@florian · \`docker exec -it -w /work/ntf box claude attach ses90ship\`" "$STUB/comment.in" && grep -q " comment stop review$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log" && grep -q "posted on acme/ntf#90 for @florian" "$SP/sc.out"' "exit $rc: $(cat "$SP/sc.out" "$STUB/comment.in" 2>/dev/null)"
check "pipeline: a failed gate with a stop comment says to answer on the issue, or where to attach" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-90	failed	report	review — answer on the issue (accept all | accept 1,3 | fix 2 | abort), or docker exec -it -w /work/ntf box claude attach ses90ship$"' "$("$FR" pipeline --no-fetch 2>&1)"
printf -- '---\nnotify_command: echo "$FR_MESSAGE" >> "$STUB/notified"\n---\n' > .claude/workflow.md
: > "$STUB_LOG"
"$FR" stop-comment FR-90 review "$SP/body.md" > "$SP/sc.out" 2>&1; rc=$?
check "stop-comment: stop_comments off → nothing posted, exit 0" '[ "$rc" = 0 ] && grep -q "nothing posted" "$SP/sc.out" && ! grep -q "issue comment" "$STUB_LOG"' "exit $rc: $(cat "$SP/sc.out")"
# decisions by comment: after the stop comment, from a trusted author, first line a command
now=$(date -u +%s)
stub comments "$(printf 'comment\t%s\tOWNER\tboris\taccept all\ncomment\t%s\tNONE\tstranger\tabort\ncomment\t%s\tOWNER\tboris\tAccept 1, 3' "$((now - 500))" "$((now + 5))" "$((now + 10))")"
"$FR" decision FR-90 > "$SP/d.out" 2>&1; rc=$?
check "decision: the newest trusted command after the stop comment, items normalised; older and untrusted ones ignored" '[ "$rc" = 0 ] && [ "$(cat "$SP/d.out")" = "$(printf "accept\t1,3\tboris")" ] && grep -q " decision accept 1,3 by boris$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log"' "exit $rc: $(cat "$SP/d.out")"
"$FR" decision FR-90 >/dev/null 2>&1
check "decision: a second call finding the same decision logs it only once" '[ "$(grep -c " decision accept 1,3 by boris$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log")" = 1 ]' "$(tail -n 3 "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log")"
stub comments "$(printf 'comment\t%s\tOWNER\tboris\t/fr abort' "$((now + 20))")"
check "decision: abort, with a /fr prefix" '[ "$("$FR" decision FR-90 2>/dev/null)" = "$(printf "abort\t-\tboris")" ]' "$("$FR" decision FR-90 2>&1)"
stub comments "$(printf 'comment\t%s\tOWNER\tboris\tFix 1; accept 2, 4 and abort' "$((now + 20))")"
check "decision: several clauses, separated by ; or and → one line each" '[ "$("$FR" decision FR-90 2>/dev/null)" = "$(printf "fix\t1\tboris\naccept\t2,4\tboris\nabort\t-\tboris")" ] && grep -q " decision accept 2,4 by boris$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log"' "$("$FR" decision FR-90 2>&1)"
stub comments "$(printf 'comment\t%s\tOWNER\tboris\tfix 1; and then we see' "$((now + 20))")"
"$FR" decision FR-90 > "$SP/d.out" 2>&1; rc=$?
check "decision: a line with a clause that is no command is no decision" '[ "$rc" = 4 ]' "exit $rc: $(cat "$SP/d.out")"
stub comments "$(printf 'comment\t%s\tOWNER\tboris\tlooks good, accept all of it' "$((now + 20))")"
"$FR" decision FR-90 > "$SP/d.out" 2>&1; rc=$?
check "decision: prose is no command → exit 4" '[ "$rc" = 4 ] && grep -q "no decision" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
"$FR" decision FR-90 --wait 1 --max 1 > "$SP/d.out" 2>&1; rc=$?
check "decision --wait: gives up after --max with exit 4" '[ "$rc" = 4 ] && grep -q "within 1 s" "$SP/d.out"' "exit $rc: $(cat "$SP/d.out")"
nostub comments; nostub user; nostub assignees; rm -f .claude/workflow.local.md
# a PR that waits for the merge needs the user too
printf -- '---\nnotify_command: echo "$FR_MESSAGE" >> "$STUB/notified"\n---\n' > .claude/workflow.md
branch_fr feat/fr-91-r FR-91-r.md FR-91 Ninety-one in-review "" "src/r"
printf -- '---\nnotify_command: echo "$FR_MESSAGE" >> "$STUB/notified"\n---\n' > .claude/workflow.md
"$FR" queue add FR-91 >/dev/null
stub prlist "95"; stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\ncheck\tbuild\tpass')"
"$FR" project-status 91 approval >/dev/null 2>&1
"$FR" pipeline --no-fetch --wait 0 >/dev/null 2>&1
check "pipeline --wait: a PR waiting for the merge is notified" 'grep -qx "FR-91 review: PR #95 waits for your merge" "$STUB/notified"' "$(cat "$STUB/notified")"
nostub prlist; nostub prview

# --- spec model: delta validation, fingerprints, Base lines at the start
newrepo "$SP/regress-spec" git@github.com:acme/spec.git
printf '.claude/worktrees/\n' > .gitignore
printf -- '---\nspec_dir: specs\n---\n' > .claude/workflow.md
mkdir -p specs/talent-onboarding
cat > specs/talent-onboarding/spec.md <<'EOF'
# Talent onboarding

## Purpose

Onboard talents with their CV.

## Requirements

### Requirement: CV upload
The system SHALL accept a PDF CV up to 10 MB.

#### Scenario: valid PDF
- WHEN a talent uploads a 2 MB PDF
- THEN the upload is accepted
- Evidence: check on test

#### Scenario: too large
- WHEN a talent uploads a 12 MB PDF
- THEN the upload is refused with a size message
- Evidence: unit test

### Requirement: Remember me
The system SHALL offer a remember-me option at login.

#### Scenario: ticked
- WHEN the box is ticked
- THEN the session lasts 30 days
- Evidence: unit test

### Requirement: Login
The system SHALL let a talent log in with e-mail and password.

#### Scenario: wrong password
- WHEN the password is wrong
- THEN the login is refused
- Evidence: unit test
EOF
git add -A; git commit -qm init; git push -q -u origin main
FP_CV=$("$FR" fingerprint talent-onboarding "CV upload" 2>&1); FP_RM=$("$FR" fingerprint talent-onboarding "remember  me" 2>&1); FP_LOGIN=$("$FR" fingerprint talent-onboarding Login 2>&1)
check "fingerprint: 8 hex of the requirement's text, found by name regardless of case and spacing" 'printf "%s" "$FP_CV" | grep -qE "^[0-9a-f]{8}$" && printf "%s" "$FP_RM" | grep -qE "^[0-9a-f]{8}$" && [ "$FP_CV" != "$FP_RM" ]' "$FP_CV / $FP_RM / $FP_LOGIN"
"$FR" fingerprint talent-onboarding Nope > "$SP/s.out" 2>&1; rc=$?
check "fingerprint: an unknown requirement → exit 1" '[ "$rc" = 1 ] && grep -q "no requirement" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
"$FR" fingerprint nope "CV upload" > "$SP/s.out" 2>&1; rc=$?
check "fingerprint: an unknown capability → exit 1" '[ "$rc" = 1 ]' "exit $rc: $(cat "$SP/s.out")"
cat > "$SP/delta-ok.md" <<EOF
## Problem / motivation

Something.

## Spec delta

Specs: talent-onboarding, crm-sync

### ADDED crm-sync: Contact mapping
The system SHALL map a talent to a CRM contact.

#### Scenario: new talent
- WHEN a talent is created
- THEN a CRM contact is created with the same e-mail
- Evidence: eval — fixtures/crm-sync.json

### MODIFIED talent-onboarding: CV upload
Base: $FP_CV
The system SHALL accept a PDF or DOCX CV up to 10 MB.

#### Scenario: valid PDF
- WHEN a talent uploads a 2 MB PDF
- THEN the upload is accepted
- Evidence: check on test

#### Scenario: too large
- GIVEN a 12 MB file
- WHEN a talent uploads it
- THEN the upload is refused with a size message
- AND nothing is stored
- Evidence: unit test

#### Scenario: valid DOCX
- WHEN a talent uploads a DOCX
- THEN the upload is accepted
- Evidence: Check on test (staging)

### REMOVED talent-onboarding: Remember me
Base: $FP_RM
Reason: replaced by passkeys

### RENAMED talent-onboarding: Login -> Sign in
Base: $FP_LOGIN

## Planning

- Areas: src/a
EOF
"$FR" validate "$SP/delta-ok.md" > "$SP/s.out" 2>&1; rc=$?
check "validate: a complete delta against origin/main passes; a new capability may be ADDED to" '[ "$rc" = 0 ] && grep -q "^ok: 4 requirement changes, 4 scenarios" "$SP/s.out" && ! grep -q "^error" "$SP/s.out" && ! grep -q "^warning" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
# variants of the valid delta, one defect each
variant() { sed "$1" "$SP/delta-ok.md" > "$SP/d.md"; "$FR" validate "$SP/d.md" > "$SP/s.out" 2>&1; rc=$?; }
variant 's/^### ADDED crm-sync: Contact mapping$/### ADDED talent-onboarding: cv   upload/'
check "validate: ADDED of an existing requirement (case, spacing) → error" '[ "$rc" = 4 ] && grep -q "^error: ADDED talent-onboarding: cv   upload — exists" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^### MODIFIED talent-onboarding: CV upload$/### MODIFIED talent-onboarding: Nope/'
check "validate: MODIFIED of an unknown requirement → error" '[ "$rc" = 4 ] && grep -q "^error: MODIFIED talent-onboarding: Nope — no such requirement" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant '/^- Evidence: eval/d'
check "validate: a scenario without evidence → error naming it" '[ "$rc" = 4 ] && grep -q "^error: scenario .new talent. has no .- Evidence" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^- Evidence: eval.*$/- Evidence: manual/'
check "validate: an evidence outside unit test | eval | check on test → error" '[ "$rc" = 4 ] && grep -q "evidence must be unit test, eval or check on test" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant '/^- THEN a CRM contact/d'
check "validate: a scenario without THEN → error" '[ "$rc" = 4 ] && grep -q "^error: scenario .new talent. has no .- THEN" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^- WHEN a talent is created$/- SOMETIMES a talent is created/'
check "validate: a scenario line that is not GIVEN/WHEN/THEN/AND/Evidence → error" '[ "$rc" = 4 ] && grep -q "not a GIVEN/WHEN/THEN/AND/Evidence line" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant '/^#### Scenario: new talent$/,/^- Evidence: eval/d'
check "validate: ADDED without a scenario → error" '[ "$rc" = 4 ] && grep -q "^error: ADDED crm-sync: Contact mapping — no scenario" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant '/^#### Scenario: too large$/,/^- Evidence: unit test$/d'
check "validate: MODIFIED that drops a base scenario → a warning with its name, not an error" '[ "$rc" = 0 ] && grep -q "^warning: MODIFIED talent-onboarding: CV upload drops the scenario .too large." "$SP/s.out" && grep -q "^ok: 4 requirement changes, 3 scenarios" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant "s/^Base: $FP_CV$/Base: deadbeef/"
check "validate: a Base fingerprint that no longer matches → error, the base moved" '[ "$rc" = 4 ] && grep -q "^error: MODIFIED talent-onboarding: CV upload — the requirement changed since the definition (Base: deadbeef, now $FP_CV)" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^Specs: talent-onboarding, crm-sync$/Specs: talent-onboarding, crm-sync\
Some stray sentence./'
check "validate: text outside a requirement block → error" '[ "$rc" = 4 ] && grep -q "^error: text outside a requirement block: Some stray" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^### REMOVED talent-onboarding: Remember me$/### Something else/'
check "validate: a ### that is not a delta heading → error" '[ "$rc" = 4 ] && grep -q "^error: not a delta heading" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^#### Scenario: valid DOCX$/#### Notes/'
check "validate: an unknown heading inside the delta → error" '[ "$rc" = 4 ] && grep -q "^error: unknown heading in the spec delta: #### Notes" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant '/^Specs: /d'
check "validate: no Specs line → error" '[ "$rc" = 4 ] && grep -q "^error: no .Specs:. line" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^Specs: talent-onboarding, crm-sync$/Specs: talent-onboarding/'
check "validate: a block whose capability is not in the Specs line → error" '[ "$rc" = 4 ] && grep -q "^error: ADDED crm-sync: Contact mapping — crm-sync is not in the Specs line" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^Specs: talent-onboarding, crm-sync$/Specs: talent-onboarding, crm-sync, billing/'
check "validate: a listed capability nothing changes in → warning" '[ "$rc" = 0 ] && grep -q "^warning: billing is in the Specs line but no requirement of it changes" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^Specs: talent-onboarding, crm-sync$/Specs: Talent Onboarding, crm-sync/'
check "validate: a capability that is not a slug → error" '[ "$rc" = 4 ] && grep -q "is not a slug" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^### RENAMED talent-onboarding: Login -> Sign in$/### RENAMED talent-onboarding: Login/'
check "validate: RENAMED without old -> new → error" '[ "$rc" = 4 ] && grep -q "RENAMED needs old -> new" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^### RENAMED talent-onboarding: Login -> Sign in$/### RENAMED talent-onboarding: Login -> CV Upload/'
check "validate: RENAMED to a name that exists → error" '[ "$rc" = 4 ] && grep -q "^error: RENAMED talent-onboarding: Login -> CV Upload — .CV Upload. exists" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant '/^Reason: replaced by passkeys$/d'
check "validate: REMOVED without a Reason → warning" '[ "$rc" = 0 ] && grep -q "^warning: REMOVED talent-onboarding: Remember me — no .Reason:. line" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^### REMOVED talent-onboarding: Remember me$/### MODIFIED talent-onboarding: CV upload/'
check "validate: the same requirement twice → error" '[ "$rc" = 4 ] && grep -q "appears twice in the delta" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
variant 's/^## Problem \/ motivation$/## Acceptance criteria\
\
- [ ] something/'
check "validate: acceptance criteria and a spec delta in one document → error" '[ "$rc" = 4 ] && grep -q "^error: both ## Acceptance criteria and ## Spec delta" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
printf '## Problem\n\nx\n\n## Acceptance criteria\n\n- [ ] a\n' > "$SP/d.md"
"$FR" validate "$SP/d.md" > "$SP/s.out" 2>&1; rc=$?
check "validate: no spec delta → error (the legacy criteria are not its business)" '[ "$rc" = 4 ] && grep -q "^error: no ## Spec delta" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
cat > "$SP/d.md" <<'EOF'
## Spec delta

Specs: none

#### Scenario: build is green
- WHEN the pipeline runs
- THEN it passes
- Evidence: check on test
EOF
"$FR" validate "$SP/d.md" > "$SP/s.out" 2>&1; rc=$?
check "validate: Specs: none with scenarios only → ok" '[ "$rc" = 0 ] && grep -q "^ok: 0 requirement changes, 1 scenarios" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
printf '\n### ADDED billing: Invoice\nText.\n\n#### Scenario: s\n- WHEN x\n- THEN y\n- Evidence: eval\n' >> "$SP/d.md"
"$FR" validate "$SP/d.md" > "$SP/s.out" 2>&1; rc=$?
check "validate: Specs: none with a requirement change → error" '[ "$rc" = 4 ] && grep -q "allows scenarios only" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
printf '## Spec delta\n\nSpecs: none\n' > "$SP/d.md"
"$FR" validate "$SP/d.md" > "$SP/s.out" 2>&1; rc=$?
check "validate: Specs: none without any scenario → error" '[ "$rc" = 4 ] && grep -q "needs at least one scenario" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
# --local reads the working tree's specs: the base moved there
sub 's/up to 10 MB/up to 20 MB/' specs/talent-onboarding/spec.md
FP_LOCAL=$("$FR" fingerprint talent-onboarding "CV upload" --local 2>&1)
check "fingerprint --local: the working tree's text, a different fingerprint" 'printf "%s" "$FP_LOCAL" | grep -qE "^[0-9a-f]{8}$" && [ "$FP_LOCAL" != "$FP_CV" ] && [ "$("$FR" fingerprint talent-onboarding "CV upload" --rev origin/main)" = "$FP_CV" ]' "$FP_LOCAL vs $FP_CV"
"$FR" validate "$SP/delta-ok.md" --local > "$SP/s.out" 2>&1; rc=$?
check "validate --local: the pinned Base no longer matches the working tree → error" '[ "$rc" = 4 ] && grep -q "changed since the definition (Base: $FP_CV, now $FP_LOCAL)" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
git checkout -q -- specs
# the delta in an issue: readiness without criteria, Base lines pinned by spec
sed '/^Base: /d' "$SP/delta-ok.md" > "$STUB/body"
stub meta "$(printf 'OPEN\tfr\tCV upload for CRM')"
"$FR" spec 50 > "$SP/s.out" 2>&1; rc=$?
check "spec: an issue with a valid spec delta is ready without acceptance criteria" '[ "$rc" = 0 ] && grep -q "^## Spec delta" "$SP/s.out" && ! grep -q "not ready" "$SP/s.out"' "exit $rc: $(head -20 "$SP/s.out")"
check "spec: Base lines pinned under MODIFIED, REMOVED and RENAMED, none under ADDED" '[ "$(grep -A1 "^### MODIFIED talent-onboarding: CV upload" "$SP/s.out" | tail -n 1)" = "Base: $FP_CV" ] && [ "$(grep -A1 "^### REMOVED" "$SP/s.out" | tail -n 1)" = "Base: $FP_RM" ] && [ "$(grep -A1 "^### RENAMED" "$SP/s.out" | tail -n 1)" = "Base: $FP_LOGIN" ] && [ "$(grep -A1 "^### ADDED" "$SP/s.out" | tail -n 1)" = "The system SHALL map a talent to a CRM contact." ]' "$(grep -A1 "^### " "$SP/s.out")"
"$FR" spec 50 > "$SP/s2.out" 2>&1
check "spec: a stale Base line in the issue is replaced, not doubled" '[ "$(grep -c "^Base:" "$SP/s2.out")" = 3 ]' "$(grep -n "^Base:" "$SP/s2.out")"
sed "s/^Base: $FP_RM$/\\
Base: $FP_RM/" "$SP/delta-ok.md" > "$STUB/body"
"$FR" spec 50 > "$SP/s2.out" 2>&1
check "spec: a Base line further down the block is dropped — one pinned line, right under the heading" '[ "$(grep -c "^Base:" "$SP/s2.out")" = 3 ] && [ "$(grep -A1 "^### REMOVED" "$SP/s2.out" | tail -n 1)" = "Base: $FP_RM" ]' "$(grep -n -B2 "^Base:" "$SP/s2.out")"
sed 's/^- Evidence: eval.*$/- Evidence: manual/' "$STUB/body" > "$STUB/body.tmp"; mv "$STUB/body.tmp" "$STUB/body"
"$FR" spec 50 > "$SP/s.out" 2>&1; rc=$?
check "spec: an invalid delta → not ready, exit 4, with the errors" '[ "$rc" = 4 ] && grep -q "the spec delta has errors" "$SP/s.out" && grep -q "^error: scenario" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
sed '/^Base: /d' "$SP/delta-ok.md" > "$STUB/body"
printf -- '---\n---\n' > .claude/workflow.md
"$FR" spec 50 > "$SP/s.out" 2>&1; rc=$?
check "spec: a delta but no spec_dir in the profile → not ready, says so" '[ "$rc" = 4 ] && grep -q "no spec_dir" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
"$FR" validate "$SP/delta-ok.md" > "$SP/s.out" 2>&1; rc=$?
check "validate: without spec_dir → exit 1, the spec model is off" '[ "$rc" = 1 ] && grep -q "spec model is off" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
printf -- '---\nspec_dir: specs\n---\n' > .claude/workflow.md
# validate by FR id: the doc checked out in a worktree
branch_fr feat/fr-50-cv FR-50-cv.md FR-50 "CV upload for CRM" in-progress "" "src/a"
printf -- '---\nspec_dir: specs\n---\n' > .claude/workflow.md
git worktree add -q .claude/worktrees/fr-50-cv feat/fr-50-cv
( cd .claude/worktrees/fr-50-cv && { cat req/feature-requests/FR-50-cv.md; printf '\n'; sed -n '/^## Spec delta/,/^## Planning/p' "$SP/delta-ok.md" | sed '$d'; } > doc.tmp && mv doc.tmp req/feature-requests/FR-50-cv.md && git add -A && git commit -qm "delta" )
( cd .claude/worktrees/fr-50-cv && "$FR" validate FR-50 ) > "$SP/s.out" 2>&1; rc=$?
check "validate FR-50: the FR doc of the worktree, against origin/main" '[ "$rc" = 0 ] && grep -q "^ok: 4 requirement changes" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
"$FR" validate FR-50 > "$SP/s.out" 2>&1; rc=$?
check "validate FR-50 from the main checkout: the doc is not here → says so" '[ "$rc" = 1 ] && grep -q "no FR doc checked out here" "$SP/s.out"' "exit $rc: $(cat "$SP/s.out")"
nostub meta; rm -f "$STUB/body"

# --- fold: the delta into the spec files of this checkout
"$FR" fold "$SP/delta-ok.md" --dry-run > "$SP/f.out" 2>&1; rc=$?
check "fold --dry-run: lists the operations, writes nothing" '[ "$rc" = 0 ] && grep -q "^would fold MODIFIED talent-onboarding: CV upload" "$SP/f.out" && grep -q "^would fold RENAMED talent-onboarding: Login -> Sign in" "$SP/f.out" && [ -z "$(git status --porcelain specs)" ]' "exit $rc: $(cat "$SP/f.out"; git status --porcelain specs)"
"$FR" fold "$SP/delta-ok.md" > "$SP/f.out" 2>&1; rc=$?
check "fold: reports every operation and the changed files" '[ "$rc" = 0 ] && grep -q "^folded ADDED crm-sync: Contact mapping" "$SP/f.out" && grep -q "^changed: specs/talent-onboarding/spec.md" "$SP/f.out" && grep -q "^changed: specs/crm-sync/spec.md" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out")"
check "fold ADDED: a new capability gets a spec file with title, Purpose and Requirements" '[ "$(grep -E "^#" specs/crm-sync/spec.md | paste -sd "|" -)" = "# Crm Sync|## Purpose|## Requirements|### Requirement: Contact mapping|#### Scenario: new talent" ]' "$(cat specs/crm-sync/spec.md)"
check "fold ADDED: the requirement text and its scenario lines are copied" 'grep -qxF "The system SHALL map a talent to a CRM contact." specs/crm-sync/spec.md && grep -qxF -- "- Evidence: eval — fixtures/crm-sync.json" specs/crm-sync/spec.md' "$(cat specs/crm-sync/spec.md)"
check "fold MODIFIED: the requirement body is replaced, scenarios included" 'grep -qx "The system SHALL accept a PDF or DOCX CV up to 10 MB." specs/talent-onboarding/spec.md && ! grep -q "accept a PDF CV up to 10 MB" specs/talent-onboarding/spec.md && grep -qx "#### Scenario: valid DOCX" specs/talent-onboarding/spec.md && [ "$(grep -c "^#### Scenario:" specs/talent-onboarding/spec.md)" = 4 ]' "$(cat specs/talent-onboarding/spec.md)"
check "fold REMOVED and RENAMED: the requirement is gone, the other has its new heading and its old body" '! grep -q "Remember me" specs/talent-onboarding/spec.md && grep -qx "### Requirement: Sign in" specs/talent-onboarding/spec.md && ! grep -q "^### Requirement: Login" specs/talent-onboarding/spec.md && grep -qx "#### Scenario: wrong password" specs/talent-onboarding/spec.md' "$(cat specs/talent-onboarding/spec.md)"
check "fold: the file keeps its shape — one blank line between blocks, Purpose untouched, no blank lines at the end" '[ "$(grep -c "^### Requirement:" specs/talent-onboarding/spec.md)" = 2 ] && grep -qx "Onboard talents with their CV." specs/talent-onboarding/spec.md && [ -n "$(tail -n 1 specs/talent-onboarding/spec.md)" ] && ! grep -qE "^$" <(awk "/^$/ { b++; next } { b = 0 } b > 1 { print \"double\" }" specs/talent-onboarding/spec.md)' "$(cat -n specs/talent-onboarding/spec.md)"
check "fold: the folded spec reads back — fingerprints exist for the new state" '"$FR" fingerprint talent-onboarding "Sign in" --local >/dev/null 2>&1 && "$FR" fingerprint crm-sync "Contact mapping" --local >/dev/null 2>&1' "$("$FR" fingerprint talent-onboarding "Sign in" --local 2>&1)"
"$FR" fold "$SP/delta-ok.md" > "$SP/f.out" 2>&1; rc=$?
check "fold twice: the second run finds every change in place — already folded, exit 0, nothing written" '[ "$rc" = 0 ] && grep -q "^already folded" "$SP/f.out" && ! grep -q "^folded" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out")"
git checkout -q -- specs/talent-onboarding/spec.md
"$FR" fold "$SP/delta-ok.md" > "$SP/f.out" 2>&1; rc=$?
check "fold: partly folded (one capability reverted) → exit 4, finish by hand" '[ "$rc" = 4 ] && grep -q "of 4 changes are folded already" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out")"
git checkout -q -- specs; rm -rf specs/crm-sync
printf '## Spec delta\n\nSpecs: none\n\n#### Scenario: green\n- WHEN it runs\n- THEN it passes\n- Evidence: check on test\n' > "$SP/d.md"
"$FR" fold "$SP/d.md" > "$SP/f.out" 2>&1; rc=$?
check "fold: Specs: none → nothing to fold, exit 0" '[ "$rc" = 0 ] && grep -q "^nothing to fold" "$SP/f.out" && [ -z "$(git status --porcelain specs)" ]' "exit $rc: $(cat "$SP/f.out")"
sed "s/^Base: $FP_CV$/Base: deadbeef/" "$SP/delta-ok.md" > "$SP/d.md"
"$FR" fold "$SP/d.md" > "$SP/f.out" 2>&1; rc=$?
check "fold: an invalid delta writes nothing" '[ "$rc" = 4 ] && [ -z "$(git status --porcelain specs)" ] && [ ! -d specs/crm-sync ]' "exit $rc: $(cat "$SP/f.out"; git status --porcelain)"
# a replaced block keeps one blank line before the next requirement
printf '## Spec delta\n\nSpecs: talent-onboarding\n\n### MODIFIED talent-onboarding: CV upload\nBase: %s\nThe system SHALL accept any CV.\n\n#### Scenario: any\n- WHEN a CV comes\n- THEN it is accepted\n- Evidence: unit test\n' "$FP_CV" > "$SP/d.md"
"$FR" fold "$SP/d.md" > "$SP/f.out" 2>&1; rc=$?
check "fold MODIFIED: one blank line between the new body and the next requirement" '[ "$rc" = 0 ] && [ "$(awk "/^- Evidence: unit test$/ { f = NR } f && NR == f + 1 { a = \$0 } f && NR == f + 2 { b = \$0; exit } END { print a \"|\" b }" specs/talent-onboarding/spec.md)" = "|### Requirement: Remember me" ]' "exit $rc: $(cat -n specs/talent-onboarding/spec.md | sed -n 5,16p)"
git checkout -q -- specs
# a requirement section followed by another section: ADDED goes before it
cat > specs/talent-onboarding/spec.md <<'EOF'
# Talent onboarding

## Requirements

### Requirement: CV upload
The system SHALL accept a PDF CV up to 10 MB.

#### Scenario: valid PDF
- WHEN a talent uploads a 2 MB PDF
- THEN the upload is accepted
- Evidence: check on test

## Notes

Keep this section.
EOF
printf '## Spec delta\n\nSpecs: talent-onboarding\n\n### ADDED talent-onboarding: Export\nThe system SHALL export a CV as JSON.\n\n#### Scenario: export\n- WHEN export is requested\n- THEN JSON is returned\n- Evidence: unit test\n' > "$SP/d.md"
"$FR" fold "$SP/d.md" > "$SP/f.out" 2>&1; rc=$?
check "fold ADDED: appended to the Requirements section, before a following section" '[ "$rc" = 0 ] && [ "$(grep -E "^### Requirement: Export|^## Notes" specs/talent-onboarding/spec.md | paste -sd "|" -)" = "### Requirement: Export|## Notes" ] && awk "/^$/ { b++; if (b > 1) bad = 1; next } { b = 0 } END { exit bad }" specs/talent-onboarding/spec.md && grep -qx "Keep this section." specs/talent-onboarding/spec.md' "exit $rc: $(cat "$SP/f.out"; cat -n specs/talent-onboarding/spec.md)"
git checkout -q -- specs

# --- overlap by requirement: two FRs on one requirement never run in parallel
# FR-50 (branch, areas src/a) changes talent-onboarding: CV upload; #51 (open, src/b) the same requirement, #52 (open, src/c) another one
mkbody() { printf '## Spec delta\n\nSpecs: talent-onboarding\n\n### %s\n%s\n\n#### Scenario: s\n- WHEN x\n- THEN y\n- Evidence: eval\n\n## Planning\n\n- Areas: %s\n' "$1" "$2" "$3"; }
stub issues "$(printf '51\tFifty-one\t%s\n52\tFifty-two\t%s' "$(mkbody 'MODIFIED talent-onboarding: cv  UPLOAD' 'Base: x' src/b | tr '\n' '\037')" "$(mkbody 'ADDED talent-onboarding: Export' 'The system SHALL export.' src/c | tr '\n' '\037')")"
mkbody 'MODIFIED talent-onboarding: cv  UPLOAD' 'Base: x' src/b > "$STUB/body-51"
mkbody 'ADDED talent-onboarding: Export' 'The system SHALL export.' src/c > "$STUB/body-52"
"$FR" overlap --no-fetch > "$SP/o.out" 2>&1; rc=$?
check "overlap: two FRs on the same requirement conflict, named by capability and requirement" '[ "$rc" = 0 ] && grep -q "^conflict	FR-50	FR-51	spec talent-onboarding: cv upload" "$SP/o.out"' "exit $rc: $(cat "$SP/o.out")"
check "overlap: another requirement of the same capability does not conflict — wave 1 for both" 'grep -q "^wave	1	FR-52" "$SP/o.out" && ! grep -q "^conflict	FR-50	FR-52" "$SP/o.out" && ! grep -q "^conflict	FR-51	FR-52" "$SP/o.out"' "$(cat "$SP/o.out")"
check "overlap: FR-50 is in progress, so FR-51 waits for it" 'grep -q "^running	FR-50" "$SP/o.out" && grep -q "^wave	2	FR-51" "$SP/o.out"' "$(cat "$SP/o.out")"
printf -- '---\n---\n' > .claude/workflow.md
"$FR" overlap --no-fetch > "$SP/o.out" 2>&1
check "overlap: without spec_dir the requirements play no part" '! grep -q "spec talent-onboarding" "$SP/o.out" && grep -q "^wave	1	FR-51" "$SP/o.out"' "$(cat "$SP/o.out")"
printf -- '---\nspec_dir: specs\n---\n' > .claude/workflow.md
nostub issues; rm -f "$STUB/body-51" "$STUB/body-52"
check "list: the specs column names the requirements an FR's delta changes" '[ "$("$FR" list --no-fetch 2>/dev/null | awk -F "\t" "\$1 == \"FR-50\" { print \$13 }")" = "crm-sync:contact mapping;talent-onboarding:cv upload;talent-onboarding:remember me;talent-onboarding:login" ]' "$("$FR" list --no-fetch 2>&1 | grep FR-50)"
check "check: names the spec folder and its capabilities" '"$FR" check 2>/dev/null | grep -q "^specs:    specs (1 capabilities"' "$("$FR" check 2>&1)"

# text from a delta reaches awk through the environment, never -v: a backslash sequence in a requirement name stays literal
branch_fr feat/fr-53-win FR-53-win.md FR-53 "Windows paths" open "" "src/d"
git switch -q feat/fr-53-win && printf '\n## Spec delta\n\nSpecs: talent-onboarding\n\n### ADDED talent-onboarding: Path C:\\temp\\new\nThe system SHALL accept it.\n\n#### Scenario: s\n- WHEN x\n- THEN y\n- Evidence: eval\n' >> req/feature-requests/FR-53-win.md && git commit -qam "win" && git push -q origin HEAD 2>/dev/null; git switch -q main
L53=$("$FR" list --no-fetch 2>/dev/null | awk -F "\t" '$1 == "FR-53"')
check "list: \\t and \\n in a requirement name stay two characters each — no forged column or row" '[ "$(printf "%s\n" "$L53" | wc -l | tr -d " ")" = 1 ] && [ "$(printf "%s\n" "$L53" | cut -f13)" = "talent-onboarding:path c:\\temp\\new" ]' "$L53"
mkdir -p specs/win-paths && printf '# Win paths\n\n## Requirements\n\n### Requirement: Path C:\\temp\nThe system SHALL accept C:\\temp.\n' > specs/win-paths/spec.md
FP_WIN=$("$FR" fingerprint win-paths 'Path C:\temp' --local 2>&1); rc=$?
check "fingerprint: a requirement name with a backslash is found — the name is not escape-processed" '[ "$rc" = 0 ] && printf "%s" "$FP_WIN" | grep -qE "^[0-9a-f]{8}$"' "exit $rc: $FP_WIN"
rm -rf specs/win-paths

# --- 0.8: phases on the board, the queue from the board, merge gate, merge, finish
newrepo "$SP/regress-m8" git@github.com:acme/m8.git
cat > .claude/workflow.md <<'EOP'
---
project: Product Factory
project_status_field: Status
project_phase_field: Phase
project_status: "planning=Planning/Running, defined=Building/Ready, input=Waiting for Input, running=Building/Running, implemented=Building/Complete, review=Review/Ready, shipping=Review/Running, failed=Failed, blocked=Blocked, approval=Review/Waiting for Approval, done=Done/Complete"
autopilot_queue: project
autopilot_assignee: boris
autopilot_finish: on
auto_merge: auto
---
EOP
printf '.claude/worktrees/\n' > .gitignore
mkdir -p src && echo 'x' > src/a.ts && echo 'test("a", () => {})' > src/a.test.ts
git add -A; git commit -qm init; git push -q -u origin main
stub projects "$(printf '2\tProduct Factory\thttps://github.com/orgs/acme/projects/2')"
stub issues ""; stub prlist ""; nostub prview; nostub agents; : > "$STUB_LOG"; : > "$CLAUDE_LOG"
"$FR" project-status 47 defined > "$SP/ps.out" 2>&1; rc=$?
check "project-status: Phase/Status writes the status, then the phase" '[ "$rc" = 0 ] && grep -qx "project item-edit 2 --owner acme --url https://github.com/acme/m8/issues/47 --field Status --value Ready" "$STUB_LOG" && grep -qx "project item-edit 2 --owner acme --url https://github.com/acme/m8/issues/47 --field Phase --value Building" "$STUB_LOG" && grep -q "acme/m8#47 → Building / Ready (Product Factory)" "$SP/ps.out"' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
: > "$STUB_LOG"
"$FR" project-status 47 input > "$SP/ps.out" 2>&1; rc=$?
check "project-status: a status alone leaves the phase as it is" '[ "$rc" = 0 ] && [ "$(grep -c "^project item-edit" "$STUB_LOG")" = 1 ] && grep -q -- "--field Status --value Waiting for Input" "$STUB_LOG" && ! grep -q -- "--field Phase" "$STUB_LOG"' "exit $rc: $(cat "$SP/ps.out" "$STUB_LOG")"
for e in planning review shipping; do "$FR" project-status 47 $e > "$SP/ps.out" 2>&1 || { echo "FAIL  project-status: event $e — $(cat "$SP/ps.out")"; fail=$((fail + 1)); }; done
check "project-status: planning, review and shipping are events" 'grep -q "acme/m8#47 → Review / Running" "$SP/ps.out"' "$(cat "$SP/ps.out")"
sub '/^project_phase_field:/d' .claude/workflow.md
"$FR" project-status 47 defined > "$SP/ps.out" 2>&1; rc=$?
check "project-status: Phase/Status without project_phase_field → exit 5, nothing written" '[ "$rc" = 5 ] && grep -q "no project_phase_field" "$SP/ps.out" && ! grep -q "Building" "$STUB_LOG"' "exit $rc: $(cat "$SP/ps.out")"
git checkout -q .claude/workflow.md

# queue sync: the board's Building / Ready square, this repo's open FR issues, the assignee
stub items "$(printf '80\tacme/m8\tOPEN\tfr\tReady\tBuilding\tboris\n81\tacme/m8\tOPEN\tfr\tReady\tBuilding\tflorian\n82\tacme/m8\tOPEN\tfr\tReady\tPlanning\tboris\n83\tacme/m8\tOPEN\tfr-request\tReady\tBuilding\tboris\n84\tacme/other\tOPEN\tfr\tReady\tBuilding\tboris\n85\tacme/m8\tCLOSED\tfr\tReady\tBuilding\tboris\n86\tacme/m8\tOPEN\tfr,bug\tready\tbuilding\tBoris,florian\n87\tacme/m8\tOPEN\tfr\tReady\tBuilding\t-\n88\tacme/m8\tOPEN\tfr\tReady\tBuilding\tboris')"
fm FR-88 Eighty-eight in-review "" "src/z" > req/feature-requests/FR-88-eighty-eight.md
git add -A; git commit -qm "FR-88 merged"; git push -q origin main
: > "$STUB_LOG"
"$FR" queue sync > "$SP/q.out" 2>&1; rc=$?
check "queue sync: takes the open FR issues of this repo on Building / Ready assigned to boris, not merged ones" '[ "$rc" = 0 ] && [ "$("$FR" queue list | paste -sd " " -)" = "FR-80 FR-86" ] && grep -q "added from the board — FR-80, FR-86" "$SP/q.out"' "exit $rc: $(cat "$SP/q.out"; "$FR" queue list)"
check "queue sync: asks the board with the project number and the status and phase fields" 'grep -q "^api graphql --paginate -f query=.*projectV2(number: 2).*fieldValueByName(name: \"Status\").*fieldValueByName(name: \"Phase\")" "$STUB_LOG"' "$(cat "$STUB_LOG")"
check "queue sync: logs where the FR came from" 'grep -q " queued board boris$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-80.log"' "$(cat "$(git rev-parse --git-common-dir)/fr-workflow/FR-80.log" 2>&1)"
# the per-machine profile: autopilot_assignee beside the committed profile wins; other keys there are ignored
had_gitignore=0; [ ! -e .gitignore ] || had_gitignore=1
printf -- '---\nautopilot_assignee: florian\nauto_merge: off\n---\n' > .claude/workflow.local.md
"$FR" queue sync > "$SP/q.out" 2>&1
check "local profile: autopilot_assignee in .claude/workflow.local.md overrides the profile's" 'grep -q "added from the board — FR-81" "$SP/q.out" && grep -q " queued board florian$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-81.log"' "$(cat "$SP/q.out")"
"$FR" check > "$SP/c.out" 2>&1 || true
check "check: names the local profile, its per-machine keys, the ignored others and the missing .gitignore entry" 'grep -q "^local:    .claude/workflow.local.md — autopilot_assignee=florian   not per-machine keys, ignored: auto_merge$" "$SP/c.out" && grep -q "NOT ignored by git" "$SP/c.out"' "$(cat "$SP/c.out")"
echo ".claude/workflow.local.md" >> .gitignore
"$FR" check > "$SP/c.out" 2>&1 || true
check "check: an ignored local profile gets no warning" '! grep -q "NOT ignored" "$SP/c.out"' "$(cat "$SP/c.out")"
rm .claude/workflow.local.md; [ "$had_gitignore" = 1 ] || rm .gitignore
"$FR" queue rm FR-81 > /dev/null
"$FR" queue sync > "$SP/q.out" 2>&1
check "queue sync: a second run adds nothing" 'grep -q "nothing new on the board" "$SP/q.out"' "$(cat "$SP/q.out")"
sub 's/^autopilot_assignee: boris/autopilot_assignee: none/' .claude/workflow.md
"$FR" queue sync > "$SP/q.out" 2>&1
check "queue sync: autopilot_assignee none takes the unassigned FR" 'grep -q "added from the board — FR-87" "$SP/q.out"' "$(cat "$SP/q.out")"
sub '/^autopilot_assignee:/d' .claude/workflow.md
"$FR" queue sync > "$SP/q.out" 2>&1
check "queue sync: without autopilot_assignee every assignment counts" 'grep -q "added from the board — FR-81" "$SP/q.out"' "$(cat "$SP/q.out")"
git checkout -q .claude/workflow.md
stub items-fails ""
"$FR" queue sync > "$SP/q.out" 2>&1; rc=$?
check "queue sync: an unreadable board is reported, exit 0, the queue stays" '[ "$rc" = 0 ] && grep -q "board not read" "$SP/q.out" && "$FR" queue list | grep -qx "FR-80"' "exit $rc: $(cat "$SP/q.out")"
nostub items-fails
sub 's/^autopilot_queue: project/autopilot_queue: manual/' .claude/workflow.md
"$FR" queue sync > "$SP/q.out" 2>&1; rc=$?
check "queue sync: manual queue → says so, exit 0" '[ "$rc" = 0 ] && grep -q "autopilot_queue is manual" "$SP/q.out"' "exit $rc: $(cat "$SP/q.out")"
git checkout -q .claude/workflow.md
"$FR" queue clear; : > "$STUB_LOG"
"$FR" pipeline --no-fetch > "$SP/p.out" 2>&1
check "pipeline: with autopilot_queue project it syncs the queue from the board first" 'grep -q "^api graphql --paginate" "$STUB_LOG" && grep -q "^FR-80	" "$SP/p.out"' "$(cat "$SP/p.out" "$STUB_LOG")"
"$FR" queue clear

# merge-gate: an FR in review on its branch with a clean PR and a recorded acceptance check
git switch -q -c feat/fr-90-m origin/main
{ fm FR-90 Ninety in-review "" "src/m"; printf '\n## Acceptance check\n\n2026-11-07, PR #5 at abc1234\n\n- the field shows — passed\n'; } > req/feature-requests/FR-90-m.md
echo 'test("m", () => {})' > src/m.test.ts; echo 'm' > src/m.ts
git add -A; git commit -qm "feat: m (FR-90)"; git push -q -u origin HEAD 2>/dev/null; git switch -q main
stub prlist "5"; stub prtitle "$(printf 'feat: m (FR-90)\nCloses #90')"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\t-\ncheck\tbuild\tpass\ncheck\tlint\tpending')"
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: in review, PR open and clean, acceptance recorded, tests intact → ok" '[ "$rc" = 0 ] && grep -q "^merge-gate: FR-90 PR #5 ok — 1 checks green, 1 pending" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\t-\ncheck\tbuild\tfail\ncheck\tcodeql\tfail')"
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: red checks → exit 4, named" '[ "$rc" = 4 ] && grep -q "red checks on PR #5: build, codeql" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
stub prview "$(printf 'pr\tOPEN\tCONFLICTING\tDIRTY\t-')"
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a conflicting PR → exit 4" '[ "$rc" = 4 ] && grep -q "conflicts with the base branch" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
stub prview "$(printf 'pr\tMERGED\tUNKNOWN\tUNKNOWN\t-')"
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a PR that is not open → exit 4" '[ "$rc" = 4 ] && grep -q "PR #5 is MERGED, not open" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\t-\ncheck\tbuild\tpass')"
stub prtitle "$(printf 'feat: m [skip ci]\nbody')"
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a CI skip marker in the PR title → exit 4" '[ "$rc" = 4 ] && grep -q "CI skip marker in the PR title or body" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
stub prtitle "$(printf 'feat: m (FR-90)\nCloses #90')"
"$FR" project-status 90 failed ci >/dev/null 2>&1
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: the log's last event is a stopped gate → exit 4" '[ "$rc" = 4 ] && grep -q "last event is failed ci" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
"$FR" project-status 90 shipping >/dev/null 2>&1
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: shipping after the stop passes again" '[ "$rc" = 0 ]' "exit $rc: $(cat "$SP/mg.out")"
git switch -q feat/fr-90-m
printf -- '- the button — unverified\n' >> req/feature-requests/FR-90-m.md; git commit -qam "docs(fr): unverified"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: an unverified criterion nobody accepted → exit 4" '[ "$rc" = 4 ] && grep -q "unverified criterion nobody accepted: - the button — unverified" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
sub 's/^- the button — unverified$/- the button — unverified, accepted by boris/' req/feature-requests/FR-90-m.md; git commit -qam "docs(fr): accepted"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: unverified but accepted by the user passes" '[ "$rc" = 0 ]' "exit $rc: $(cat "$SP/mg.out")"
printf -- '- the link — failed: 404\n' >> req/feature-requests/FR-90-m.md; git commit -qam "docs(fr): failed"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a failed criterion in the acceptance check → exit 4" '[ "$rc" = 4 ] && grep -q "records a failure: - the link — failed: 404" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
git reset -q --hard HEAD~1; git push -q -f origin HEAD 2>/dev/null
echo 'test.only("m", () => {})' > src/m.test.ts; git commit -qam "test: focus"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a focused test added on the branch → exit 4" '[ "$rc" = 4 ] && grep -q "focused or skipped test added on the branch: src/m.test.ts: test.only" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
git reset -q --hard HEAD~1; git push -q -f origin HEAD 2>/dev/null
echo 'const n = items.skip(2)' > src/m.ts; git commit -qam "feat: skip in source"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: .skip( outside a test file is no marker" '[ "$rc" = 0 ]' "exit $rc: $(cat "$SP/mg.out")"
git rm -q src/a.test.ts; git commit -qm "test: drop a"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a test file deleted on the branch → exit 4" '[ "$rc" = 4 ] && grep -q "test files deleted on the branch: src/a.test.ts" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
git reset -q --hard HEAD~1; git push -q -f origin HEAD 2>/dev/null
git commit -q --allow-empty -m "chore: tidy [ci skip]"; git push -q origin HEAD 2>/dev/null
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: a CI skip marker in a commit message → exit 4" '[ "$rc" = 4 ] && grep -q "CI skip marker in a commit message" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
git reset -q --hard HEAD~1; git push -q -f origin HEAD 2>/dev/null; git switch -q main
stub prlist ""
"$FR" merge-gate FR-90 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: no open PR → exit 4" '[ "$rc" = 4 ] && grep -q "no open PR of this repository" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"
stub prlist "5"
"$FR" merge-gate FR-88 --no-fetch > "$SP/mg.out" 2>&1; rc=$?
check "merge-gate: an FR not on its branch → exit 4" '[ "$rc" = 4 ] && grep -q "not in-review\|not on its FR branch" "$SP/mg.out"' "exit $rc: $(cat "$SP/mg.out")"

# merge: the gate, then gh pr merge --auto — GitHub decides
: > "$STUB_LOG"
"$FR" merge FR-90 > "$SP/m.out" 2>&1; rc=$?
check "merge: after the gate, gh pr merge --auto --squash, logged" '[ "$rc" = 0 ] && grep -qx "pr merge 5 -R acme/m8 --auto --squash" "$STUB_LOG" && grep -q " merge auto 5$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log" && grep -q "handed to GitHub (squash)" "$SP/m.out"' "exit $rc: $(cat "$SP/m.out" "$STUB_LOG")"
printf 'merge_method: merge\n' >> .claude/workflow.md; sub '/^---$/{x;s/^/x/;/^xx$/{x;d;};x;}' .claude/workflow.md 2>/dev/null || true
git checkout -q .claude/workflow.md; sub 's/^auto_merge: auto/auto_merge: auto\nmerge_method: merge/' .claude/workflow.md
: > "$STUB_LOG"
"$FR" merge FR-90 > "$SP/m.out" 2>&1; rc=$?
check "merge: merge_method is passed through" '[ "$rc" = 0 ] && grep -qx "pr merge 5 -R acme/m8 --auto --merge" "$STUB_LOG"' "exit $rc: $(cat "$SP/m.out" "$STUB_LOG")"
git checkout -q .claude/workflow.md
stub merge-fails ""
"$FR" merge FR-90 > "$SP/m.out" 2>&1; rc=$?
check "merge: GitHub refuses → exit 4 with its reason, logged as refused" '[ "$rc" = 4 ] && grep -q "did not take the merge request for PR #5 — GraphQL" "$SP/m.out" && grep -q " merge refused 5$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-90.log"' "exit $rc: $(cat "$SP/m.out")"
nostub merge-fails
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\t-\ncheck\tbuild\tfail')"
: > "$STUB_LOG"
"$FR" merge FR-90 > "$SP/m.out" 2>&1; rc=$?
check "merge: a red gate asks GitHub nothing" '[ "$rc" = 4 ] && ! grep -q "^pr merge" "$STUB_LOG" && grep -q "red checks" "$SP/m.out"' "exit $rc: $(cat "$SP/m.out")"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\t-\ncheck\tbuild\tpass')"
sub 's/^auto_merge: auto/auto_merge: off/' .claude/workflow.md
"$FR" merge FR-90 > "$SP/m.out" 2>&1; rc=$?
check "merge: auto_merge off → exit 4, the merge is the user's, GitHub not asked" '[ "$rc" = 4 ] && grep -q "auto_merge is off" "$SP/m.out" && ! grep -q "^pr merge" "$STUB_LOG"' "exit $rc: $(cat "$SP/m.out")"
git checkout -q .claude/workflow.md

# pipeline: a PR with auto-merge enabled is merging, not waiting for the user
"$FR" queue add FR-90 >/dev/null
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tBLOCKED\tauto\ncheck\tbuild\tpending')"
check "pipeline: auto-merge enabled → merging, no report" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-90	merging	none	PR #5: auto-merge enabled"' "$("$FR" pipeline --no-fetch 2>&1)"
stub prview "$(printf 'pr\tOPEN\tMERGEABLE\tCLEAN\t-\ncheck\tbuild\tpass')"
check "pipeline: without auto-merge the PR waits for the user" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-90	review	none	PR #5 waits for your merge"' "$("$FR" pipeline --no-fetch 2>&1)"
"$FR" queue clear

# project workflows: read-only notes at setup, and the one removal GitHub's API allows
stub workflows "$(printf 'true\tItem added to project\tPWF_a\ntrue\tItem closed\tPWF_c\ntrue\tAuto-close issue\tPWF_x\ntrue\tAuto-add to project\tPWF_d')"
stub options "$(printf 'PVTSSF_m8
o1	GREEN	Ready	')"
stub mutated "Ready, Running"
"$FR" project-options Ready Running > "$SP/po.out" 2>&1; rc=$?
check "project-options: lists the board's workflows and warns when Auto-close issue shares done's status value with an earlier event" '[ "$rc" = 0 ] && grep -q "^workflow on : Auto-close issue" "$SP/po.out" && grep -q "WARNING: Auto-close issue is on and implemented share(s) done.s status value .Complete." "$SP/po.out" && grep -q "fr.sh project-workflow auto-close off" "$SP/po.out"' "exit $rc: $(cat "$SP/po.out")"
: > "$STUB_LOG"; stub deleted '{"data":{"deleteProjectV2Workflow":{"deletedWorkflowId":"PWF_x"}}}'
"$FR" project-workflow auto-close off > "$SP/pw.out" 2>&1; rc=$?
check "project-workflow auto-close off: deletes the Auto-close issue workflow by its id" '[ "$rc" = 0 ] && grep -q "deleteProjectV2Workflow(input: { workflowId: \"PWF_x\" })" "$STUB_LOG" && grep -q "Auto-close issue removed from .Product Factory." "$SP/pw.out"' "exit $rc: $(cat "$SP/pw.out" "$STUB_LOG")"
stub workflows "$(printf 'true\tItem added to project\tPWF_a\ntrue\tItem closed\tPWF_c')"; : > "$STUB_LOG"
"$FR" project-workflow auto-close off > "$SP/pw.out" 2>&1; rc=$?
check "project-workflow auto-close off: nothing to do without the workflow, no mutation" '[ "$rc" = 0 ] && grep -q "nothing to do" "$SP/pw.out" && ! grep -q deleteProjectV2Workflow "$STUB_LOG"' "exit $rc: $(cat "$SP/pw.out")"
"$FR" project-workflow auto-close on > "$SP/pw.out" 2>&1; rc=$?
check "project-workflow: only auto-close off exists — GitHub's API has no switch" '[ "$rc" = 1 ] && grep -q usage "$SP/pw.out"' "exit $rc: $(cat "$SP/pw.out")"
nostub workflows; nostub deleted; nostub options; nostub mutated
# finish: after the merge — hook, worktree, local branch, board, queue
git switch -q -c feat/fr-91-x origin/main
fm FR-91 Ninety-one in-review "" "src/x" > req/feature-requests/FR-91-x.md
git add -A; git commit -qm "feat: x (FR-91)"; git push -q -u origin HEAD 2>/dev/null; git switch -q main
git merge -q --no-ff feat/fr-91-x -m "merge FR-91" 2>/dev/null; git push -q origin main
git worktree add -q .claude/worktrees/fr-91-x feat/fr-91-x 2>/dev/null
"$FR" queue add FR-91 >/dev/null
check "pipeline: a merged FR with autopilot_finish on → finish" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-91	merged	finish	$"' "$("$FR" pipeline --no-fetch 2>&1)"
sub 's/^autopilot_finish: on/autopilot_finish: off/' .claude/workflow.md
check "pipeline: autopilot_finish off → merged FRs need nothing" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-91	merged	none	$"' "$("$FR" pipeline --no-fetch 2>&1)"
git checkout -q .claude/workflow.md
echo dirty > .claude/worktrees/fr-91-x/src/x.ts
"$FR" finish FR-91 > "$SP/f.out" 2>&1; rc=$?
check "finish: uncommitted changes in the worktree → exit 3, worktree kept, logged" '[ "$rc" = 3 ] && [ -d .claude/worktrees/fr-91-x ] && grep -q " finish worktree not removed" "$(git rev-parse --git-common-dir)/fr-workflow/FR-91.log"' "exit $rc: $(cat "$SP/f.out")"
check "pipeline: a failed finish is reported, not retried" '"$FR" pipeline --no-fetch 2>/dev/null | grep -q "^FR-91	merged	report	finish failed: worktree not removed"' "$("$FR" pipeline --no-fetch 2>&1)"
rm .claude/worktrees/fr-91-x/src/x.ts
sub 's/^autopilot_finish: on/worktree_teardown: exit 7/' .claude/workflow.md
"$FR" finish FR-91 > "$SP/f.out" 2>&1; rc=$?
check "finish: a failing teardown hook → exit 3, blocked teardown on the board, worktree kept" '[ "$rc" = 3 ] && [ -d .claude/worktrees/fr-91-x ] && grep -q "worktree_teardown failed" "$SP/f.out" && grep -q -- "--value Blocked" "$STUB_LOG"' "exit $rc: $(cat "$SP/f.out")"
git checkout -q .claude/workflow.md
{ sleep 300 & } 2>/dev/null; echo $! > "$STUB/session91.pid"; disown $!
git worktree lock --reason "claude session (pid $(cat "$STUB/session91.pid"))" .claude/worktrees/fr-91-x
"$FR" finish FR-91 > "$SP/f.out" 2>&1; rc=$?
check "finish: a live session that is not the autopilot's holds the worktree → exit 3" '[ "$rc" = 3 ] && grep -q "a session still holds" "$SP/f.out" && [ -d .claude/worktrees/fr-91-x ]' "exit $rc: $(cat "$SP/f.out")"
kill "$(cat "$STUB/session91.pid")" 2>/dev/null; git worktree unlock .claude/worktrees/fr-91-x
# the ship session the autopilot launched lingers idle in the worktree, and the
# lock names the launcher's pid, which is gone (claude --bg in a container):
# the session is ended, the stale lock lifted, the worktree removed
git worktree lock --reason "claude session fr-91-x (pid 2147483647 start 1)" .claude/worktrees/fr-91-x
echo "$(date +%s) launch ship ses91ship" >> "$(git rev-parse --git-common-dir)/fr-workflow/FR-91.log"
stub agents "$(agents ses91ship idle 4242)"
: > "$STUB_LOG"; : > "$CLAUDE_LOG"
"$FR" finish FR-91 > "$SP/f.out" 2>&1; rc=$?
check "finish: own idle session ended, stale lock lifted, worktree removed, local branch deleted, board done, out of the queue" '[ "$rc" = 0 ] && grep -q "^stop ses91ship" "$CLAUDE_LOG" && [ ! -d .claude/worktrees/fr-91-x ] && ! git show-ref --verify --quiet refs/heads/feat/fr-91-x && grep -q -- "--field Phase --value Done" "$STUB_LOG" && ! "$FR" queue list | grep -q FR-91 && grep -q " event done$" "$(git rev-parse --git-common-dir)/fr-workflow/FR-91.log" && grep -q "^finished FR-91" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out" "$STUB_LOG" "$CLAUDE_LOG")"
nostub agents
"$FR" finish FR-90 > "$SP/f.out" 2>&1; rc=$?
check "finish: an FR that is not merged → exit 4" '[ "$rc" = 4 ] && grep -q "is in-review, not merged" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out")"
# finish after a squash merge with GitHub's delete-branch-on-merge: git's -d
# refuses once origin/<branch> is gone; the merged PR's head decides instead
nostub prlist
git switch -q -c feat/fr-92-x origin/main
fm FR-92 Ninety-two in-review "" "src/x" | awk 'NR == 2 { print; print "pr: 92"; next } 1' > req/feature-requests/FR-92-x.md
git add -A; git commit -qm "feat: x (FR-92)"; git push -q -u origin HEAD 2>/dev/null; git switch -q main
git merge -q --squash feat/fr-92-x >/dev/null 2>&1; git commit -qm "feat: x (FR-92) (#92)"; git push -q origin main
git push -q origin --delete feat/fr-92-x 2>/dev/null
git worktree add -q .claude/worktrees/fr-92-x feat/fr-92-x 2>/dev/null
stub prhead "$(git rev-parse feat/fr-92-x)"
: > "$STUB_LOG"
"$FR" finish FR-92 > "$SP/f.out" 2>&1; rc=$?
check "finish: squash merge, remote branch gone, tip = the merged PR's head → -D" '[ "$rc" = 0 ] && ! git show-ref --verify --quiet refs/heads/feat/fr-92-x && [ ! -d .claude/worktrees/fr-92-x ] && grep -q "head of the merged PR #92" "$SP/f.out" && grep -q "pr view 92 .*--json state,headRefOid" "$STUB_LOG"' "exit $rc: $(cat "$SP/f.out")"
git switch -q -c feat/fr-93-x origin/main
fm FR-93 Ninety-three in-review "" "src/x" | awk 'NR == 2 { print; print "pr: 93"; next } 1' > req/feature-requests/FR-93-x.md
git add -A; git commit -qm "feat: x (FR-93)"; git push -q -u origin HEAD 2>/dev/null; git switch -q main
git merge -q --squash feat/fr-93-x >/dev/null 2>&1; git commit -qm "feat: x (FR-93) (#93)"; git push -q origin main
git push -q origin --delete feat/fr-93-x 2>/dev/null
stub prhead "$(git rev-parse feat/fr-93-x)"
git worktree add -q .claude/worktrees/fr-93-x feat/fr-93-x 2>/dev/null
echo more > .claude/worktrees/fr-93-x/more.txt; git -C .claude/worktrees/fr-93-x add more.txt; git -C .claude/worktrees/fr-93-x commit -qm "more"
"$FR" finish FR-93 > "$SP/f.out" 2>&1; rc=$?
check "finish: a local commit beyond the merged PR's head → branch kept, worktree still removed" '[ "$rc" = 0 ] && git show-ref --verify --quiet refs/heads/feat/fr-93-x && [ ! -d .claude/worktrees/fr-93-x ] && grep -q "^branch feat/fr-93-x kept" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out")"
stub prhead ""
"$FR" finish FR-93 > "$SP/f.out" 2>&1; rc=$?
check "finish: GitHub does not call the PR merged → the branch is kept" '[ "$rc" = 0 ] && git show-ref --verify --quiet refs/heads/feat/fr-93-x && grep -q "^branch feat/fr-93-x kept" "$SP/f.out"' "exit $rc: $(cat "$SP/f.out")"

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
