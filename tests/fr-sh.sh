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

# stub gh: logs calls; lists the comment ids in $STUB_IDS
mkdir -p "$SP/stubbin"
cat > "$SP/stubbin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  "auth status") exit 0 ;;
  *--paginate*) for i in $STUB_IDS; do echo "$i"; done ;;
  *"-X PATCH"*) echo "https://github.com/x/y/issues/1#issuecomment-1" ;;
  *"-X DELETE"*) ;;
  *) echo "https://github.com/x/y/issues/1#issuecomment-new" ;;
esac
EOF
chmod +x "$SP/stubbin/gh"
export STUB_LOG=$SP/stub.log

newrepo() { # newrepo <dir> <origin-url>
  rm -rf "$1"; mkdir -p "$1"; cd "$1"
  git init -q --bare origin.git; git clone -q origin.git w 2>/dev/null; cd w
  git remote set-url origin "$2"; git config url."$1/origin.git".insteadOf "$2"
  git switch -q -c main; mkdir -p .claude req/feature-requests src
}
fm() { printf -- '---\nid: %s\ntitle: %s\nstatus: %s\nissues: [%s]\nareas: [%s]\n---\n' "$@"; }
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
check "next-id after umlaut doc is FR-003" '[ "$("$FR" next-id --no-fetch)" = FR-003 ]' "got $("$FR" next-id --no-fetch)"
check "issue ref matches case-insensitively" '"$FR" issue-frs acme/shop#3 --no-fetch | grep -q "^FR-001"' "lowercase ref did not match"
check "upper-case query matches too" '"$FR" issue-frs ACME/SHOP#3 --no-fetch | grep -q "^FR-001"' "upper-case ref did not match"
check "digit-led owner is kept" '"$FR" sync "1password/x#3" --no-fetch --dry-run | grep -q "^=== 1password/x#3"' "mangled"

# --- sync for real, against the stub gh: exit code and duplicate handling
: > "$STUB_LOG"
STUB_IDS="111" PATH="$SP/stubbin:$PATH" "$FR" sync '#3' --no-fetch >/dev/null 2>&1; rc=$?
check "sync with one backlink exits 0" '[ "$rc" = 0 ]' "exit $rc"
check "sync PATCHed comment 111" 'grep -q "X PATCH repos/acme/shop/issues/comments/111" "$STUB_LOG"' "$(cat "$STUB_LOG")"
: > "$STUB_LOG"
STUB_IDS="111 222" PATH="$SP/stubbin:$PATH" "$FR" sync-fr FR-001 --no-fetch >/dev/null 2>&1; rc=$?
check "sync-fr with duplicates exits 0" '[ "$rc" = 0 ]' "exit $rc"
check "duplicate 222 deleted, 111 kept" 'grep -q "X DELETE repos/acme/shop/issues/comments/222" "$STUB_LOG" && ! grep -q "DELETE.*111" "$STUB_LOG"' "$(cat "$STUB_LOG")"

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

# --- next-id: empty FR branch counts, i18n/fr-2024 does not
git branch i18n/fr-2024 main
git branch feat/fr-050-new main
check "empty FR branch counts for next-id (FR-051)" '[ "$("$FR" next-id --no-fetch 2>/dev/null)" = FR-051 ]' "got $("$FR" next-id --no-fetch 2>/dev/null)"
git branch -D feat/fr-050-new -q

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

# --- round 3: branch names, renames on base, local doc edits, globs, lock break
git branch i18n/fr-2024-cleanup main
check "i18n/fr-2024-cleanup does not move next-id" '[ "$("$FR" next-id --no-fetch 2>/dev/null)" = FR-010 ]' "got $("$FR" next-id --no-fetch 2>/dev/null)"
git branch -D i18n/fr-2024-cleanup -q

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

LD="$(git rev-parse --git-common-dir)/fr-workflow-ship.lock"; mkdir -p "$LD"; touch "$LD/.DS_Store"
"$FR" lock break >/dev/null 2>&1; rc=$?
check "lock break removes a dir with a stray file" '[ "$rc" = 0 ] && [ ! -d "$LD" ]' "exit $rc, dir present: $([ -d "$LD" ] && echo yes)"

: > "$STUB_LOG"
cat > "$SP/stubbin/gh" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in
  *--paginate*) for i in $STUB_IDS; do echo "$i"; done ;;
  *"-X PATCH"*) echo "https://github.com/x/y/issues/1#issuecomment-1" ;;
  *"-X DELETE"*) echo "HTTP 404" >&2; exit 1 ;;
  *) echo "https://github.com/x/y/issues/1#issuecomment-new" ;;
esac
EOF
STUB_IDS="111 222" PATH="$SP/stubbin:$PATH" "$FR" sync '#3' '#4' --no-fetch >/dev/null 2>&1; rc=$?
check "failed DELETE does not abort the sync" '[ "$rc" = 0 ] && grep -q "issues/4/comments" "$STUB_LOG"' "exit $rc"

# --- check without origin
git remote remove origin
"$FR" check > "$SP/check.out" 2>&1; rc=$?
check "check fails without origin" '[ "$rc" != 0 ] && grep -q MISSING "$SP/check.out"' "exit $rc"

# --- prefix containing a digit
newrepo "$SP/regress-r2" git@github.com:acme/r2.git
printf -- '---\nfr_prefix: R2\n---\n' > .claude/workflow.md
for n in 001 014; do fm "R2-$n" "t$n" open "" "" > "req/feature-requests/R2-$n-x.md"; done
git add -A; git commit -qm init; git push -q -u origin main
check "prefix R2: next-id is R2-015" '[ "$("$FR" next-id --no-fetch)" = R2-015 ]' "got $("$FR" next-id --no-fetch)"
fm "r2-020" lower open "" "" > req/feature-requests/R2-020-lower.md
check "prefix compared case-insensitively (r2-020 -> R2-021)" '[ "$("$FR" next-id --no-fetch)" = R2-021 ]' "got $("$FR" next-id --no-fetch)"

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
