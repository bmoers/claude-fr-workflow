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
  *) echo "stub gh: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$SP/stubbin/gh"
export PATH="$SP/stubbin:$PATH" STUB=$SP/stub STUB_LOG=$SP/stub.log
stub() { printf '%s\n' "$2" > "$STUB/$1"; }   # stub <file> <content>
nostub() { rm -f "$STUB/$1"; }
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
  git switch -q -c "$b" origin/main; fm "$@" > "req/feature-requests/$f"
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

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
