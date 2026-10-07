#!/bin/bash
# Isolated fixture tests: only disposable repositories are changed.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HERE/../src/hooks/handoff-exclude.sh"
TMP_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP_ROOT"' EXIT
export HOME="$TMP_ROOT/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_CONFIG GIT_CONFIG_COUNT
mkdir -p "$HOME" "$TMP_ROOT/template"

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
new_repo() {
  git init -q --template="$TMP_ROOT/template" "$1" || exit 1
}
run() {
  OUT="$(bash "$HOOK" "$@" 2>"$TMP_ROOT/err")"; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "hook exits zero ($*)"
  [ -z "$OUT" ] && [ ! -s "$TMP_ROOT/err" ] && ok || bad "hook is silent ($*)"
}
expect_line() {
  grep -Fqx -- "$2" "$1" && ok || bad "expected line $2"
}

# Root directory; default argument; status; idempotence.
repo="$TMP_ROOT/root"; new_repo "$repo"
mkdir "$repo/.agent-handoff"
printf 'fixture\n' >"$repo/.agent-handoff/STATE.md"
(cd "$repo" && bash "$HOOK") >"$TMP_ROOT/out" 2>"$TMP_ROOT/err"; RC=$?
[ "$RC" -eq 0 ] && [ ! -s "$TMP_ROOT/out" ] && [ ! -s "$TMP_ROOT/err" ] \
  && ok || bad "default directory succeeds silently"
expect_line "$repo/.git/info/exclude" '/.agent-handoff/'
[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ] \
  && ok || bad "handoff absent from git status"
cp "$repo/.git/info/exclude" "$TMP_ROOT/before"
run "$repo"
cmp -s "$TMP_ROOT/before" "$repo/.git/info/exclude" && ok || bad "second run unchanged"

# Subdirectory, including spaces and literal Gitignore metacharacters.
repo="$TMP_ROOT/sub"; new_repo "$repo"
mkdir -p "$repo/sub/.agent-handoff" "$repo/literal [x]*?/.agent-handoff"
run "$repo/sub"
expect_line "$repo/.git/info/exclude" '/sub/.agent-handoff/'
git -C "$repo" check-ignore -q sub/.agent-handoff/ && ok || bad "subdirectory ignored"
run "$repo/literal [x]*?"
git -C "$repo" check-ignore -q 'literal [x]*?/.agent-handoff/' \
  && ok || bad "literal metacharacters ignored"

# Linked worktree: Git resolves the shared info/exclude location.
repo="$TMP_ROOT/main"; new_repo "$repo"
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  -c commit.gpgsign=false commit -q --allow-empty -m fixture || exit 1
worktree="$TMP_ROOT/worktree"
git -C "$repo" worktree add -q -b fixture-worktree "$worktree" || exit 1
mkdir "$worktree/.agent-handoff"
run "$worktree"
expect_line "$repo/.git/info/exclude" '/.agent-handoff/'
git -C "$worktree" check-ignore -q .agent-handoff/ && ok || bad "worktree ignored"

# Outside Git and absent handoff: no metadata is created.
outside="$TMP_ROOT/outside"; mkdir -p "$outside/.agent-handoff"
run "$outside"
[ ! -e "$outside/.git" ] && ok || bad "outside Git unchanged"
repo="$TMP_ROOT/absent"; new_repo "$repo"
run "$repo"
[ ! -e "$repo/.git/info/exclude" ] && ok || bad "absent handoff leaves exclude absent"

# Existing .gitignore rule must leave exclude byte-for-byte unchanged.
repo="$TMP_ROOT/ignored"; new_repo "$repo"
mkdir -p "$repo/.agent-handoff" "$repo/.git/info"
printf '/.agent-handoff/\n' >"$repo/.gitignore"
printf '# existing exclude\n' >"$repo/.git/info/exclude"
cp "$repo/.git/info/exclude" "$TMP_ROOT/before"
run "$repo"
cmp -s "$TMP_ROOT/before" "$repo/.git/info/exclude" && ok || bad "gitignore preserves exclude"

# Preserve existing content and supply a missing final newline.
for ending in newline no-newline; do
  repo="$TMP_ROOT/$ending"; new_repo "$repo"
  mkdir -p "$repo/.agent-handoff" "$repo/.git/info"
  if [ "$ending" = newline ]; then
    printf '# existing\nkeep-me\n' >"$repo/.git/info/exclude"
  else
    printf '# existing\nkeep-me' >"$repo/.git/info/exclude"
  fi
  printf '# existing\nkeep-me\n/.agent-handoff/\n' >"$TMP_ROOT/expected"
  run "$repo"
  cmp -s "$TMP_ROOT/expected" "$repo/.git/info/exclude" && ok || bad "preserve $ending content"
done

# An identical line remains untouched even if a later rule negates it.
repo="$TMP_ROOT/duplicate"; new_repo "$repo"
mkdir -p "$repo/.agent-handoff" "$repo/.git/info"
printf '/.agent-handoff/\n!/.agent-handoff/\n' >"$repo/.git/info/exclude"
cp "$repo/.git/info/exclude" "$TMP_ROOT/before"
run "$repo"
cmp -s "$TMP_ROOT/before" "$repo/.git/info/exclude" && ok || bad "identical line never duplicated"

# Fail-open on invalid paths, missing Git, and unusable exclude destinations.
run "$TMP_ROOT/nonexistent"
OUT="$(PATH="$TMP_ROOT/template" /bin/bash "$HOOK" "$repo" 2>"$TMP_ROOT/err")"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ ! -s "$TMP_ROOT/err" ] \
  && ok || bad "missing Git fails open silently"
repo="$TMP_ROOT/blocked"; new_repo "$repo"
mkdir -p "$repo/.agent-handoff" "$repo/.git/info/exclude"
run "$repo"
[ -d "$repo/.git/info/exclude" ] && ok || bad "unusable exclude remains untouched"

echo "passed=$pass failed=$fail"
exit "$fail"
