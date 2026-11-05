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
  "issue view"*"--json body"*) answer body ;;
  "issue view"*) answer meta ;;
  "api repos/"*/sub_issues*) answer subs ;;
  "api repos/"*/timeline*) answer timeline ;;
  "api repos/"*) answer self ;;
  "project list"*) [ ! -f "$STUB/project-list-fails" ] || { echo "missing scope: project" >&2; exit 1; }; answer projects ;;
  "project item-add"*) [ ! -f "$STUB/item-add-fails" ] || { echo "could not resolve to a node with the global id" >&2; exit 1; } ;;
  "project item-edit"*) [ ! -f "$STUB/item-edit-fails" ] || { echo "option 'Complete' not found for field 'Status'" >&2; exit 1; } ;;
  "--version") answer version ;;
  "pr list"*) answer prlist ;;
  "pr view"*) [ ! -f "$STUB/prview-fails" ] || exit 1; answer prview ;;
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
printf -- '---\nsession_permission_mode: "auto --dangerously-skip-permissions"\n---\n' > .claude/workflow.md
stub agents "$(agents "$SIDAP" idle)"; : > "$CLAUDE_LOG"
"$FR" launch autopilot > "$SP/l.out" 2>&1; rc=$?
check "launch autopilot: a bad session_permission_mode stops before anything is stopped or forgotten" '[ "$rc" = 1 ] && grep -q "one word" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ] && [ -f "$SEEN" ]' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
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
check "launch: session_permission_mode is one word, or the launch stops before any session is stopped" '[ "$rc" = 1 ] && grep -q "one word" "$SP/l.out" && [ ! -s "$CLAUDE_LOG" ] && kill -0 "$(cat "$STUB/session.pid")" 2>/dev/null' "exit $rc: $(cat "$SP/l.out" "$CLAUDE_LOG")"
if [ -f "$STUB/session.pid" ]; then kill "$(cat "$STUB/session.pid")" 2>/dev/null; rm -f "$STUB/session.pid"; fi

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
