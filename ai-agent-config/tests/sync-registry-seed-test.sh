#!/bin/bash
# Isolated repository, HOME and credential stub; never invokes a real service CLI.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
mkdir -p "$HOME" "$TEST_TMP/repo/aac/src" "$TEST_TMP/bin"
unset AGENTS_REGISTRY AGENT_STATE_DIR
repo="$TEST_TMP/repo"
cp "$HERE/../sync-registry-seed.sh" "$HERE/../public-check.py" "$repo/aac/"
SGA="$HERE/../../setup-git-account.sh"; [ -f "$SGA" ] || SGA="$HERE/../../../setup-git-account.sh"   # the repository root is one level higher when the tool lives under setup/
cp "$SGA" "$repo/"
git -C "$repo" init -q
git -C "$repo" config user.name 'Fixture'
git -C "$repo" config user.email 'fixture@example.invalid'
git -C "$repo" config commit.gpgsign false
git -C "$repo" remote add origin https://github.com/fixture/project.git
export AGENTS_REGISTRY="$HOME/live.md"
seed="$repo/aac/src/agents-registry.md"
ledger() { printf '<!-- verified agent=example date=%s -->\n%s\n' "$1" "$2"; }
ledger 2026-10-08 old >"$seed"
# Missing live, newer, older, equal-date change and identical contents.
[ -z "$(bash "$repo/aac/sync-registry-seed.sh")" ]
ledger 2026-10-09 new >"$AGENTS_REGISTRY"
[ "$(bash "$repo/aac/sync-registry-seed.sh")" = '台帳のシードを live に合わせました' ]
cmp "$seed" "$AGENTS_REGISTRY"
cp "$seed" "$HOME/expected"
ledger 2026-10-08 older >"$AGENTS_REGISTRY"
bash "$repo/aac/sync-registry-seed.sh" >/dev/null 2>&1
cmp "$seed" "$HOME/expected"
cp "$seed" "$AGENTS_REGISTRY"
[ -z "$(bash "$repo/aac/sync-registry-seed.sh")" ]
ledger 2026-10-09 same-day >"$AGENTS_REGISTRY"
bash "$repo/aac/sync-registry-seed.sh" >/dev/null
cmp "$seed" "$AGENTS_REGISTRY"
cp "$seed" "$HOME/expected"
# Construct a fictitious detector-positive address without publishing an email literal.
ledger 2026-10-10 "$(printf 'fixture%sfixture.test' '@')" >"$AGENTS_REGISTRY"
bash "$repo/aac/sync-registry-seed.sh" >"$HOME/stdout" 2>"$HOME/stderr"
[ ! -s "$HOME/stdout" ]; grep -q email "$HOME/stderr"
cmp "$seed" "$HOME/expected"
ledger 2026-10-10 dry >"$AGENTS_REGISTRY"
bash "$repo/aac/sync-registry-seed.sh" --dry-run | grep -q dry-run
cmp "$seed" "$HOME/expected"
# The HOME-local denylist is honored too.
mkdir -p "$HOME/.config/ai-agent-config"
printf 'fixture-private-word\n' >"$HOME/.config/ai-agent-config/public-denylist.txt"
ledger 2026-10-10 fixture-private-word >"$AGENTS_REGISTRY"
bash "$repo/aac/sync-registry-seed.sh" 2>"$HOME/stderr"
grep -q denylist "$HOME/stderr"; cmp "$seed" "$HOME/expected"
ledger 2026-10-10 committed >"$AGENTS_REGISTRY"
cat >"$TEST_TMP/bin/gh" <<'STUB'
#!/bin/sh
printf 'fixture-token\n'
STUB
chmod +x "$TEST_TMP/bin/gh"
export PATH="$TEST_TMP/bin:$PATH"
git -C "$repo" add .
git -C "$repo" -c core.hooksPath=/dev/null commit -qm initial
bash "$repo/setup-git-account.sh" fixture >/dev/null
# Reinstallation updates our hook, but leaves a user's hook untouched.
printf '# obsolete fixture\n' >>"$repo/.git/hooks/pre-commit"
bash "$repo/setup-git-account.sh" fixture >/dev/null
! grep -q obsolete "$repo/.git/hooks/pre-commit"
printf 'trigger\n' >"$repo/trigger"
git -C "$repo" add trigger
git -C "$repo" commit -qm synchronized
git -C "$repo" show HEAD:aac/src/agents-registry.md >"$HOME/committed"
cmp "$HOME/committed" "$AGENTS_REGISTRY"
git -C "$repo" diff --quiet
# no-verify bypasses synchronization, and rejection never blocks a commit.
ledger 2026-10-11 skipped >"$AGENTS_REGISTRY"
printf 'skip\n' >"$repo/skip"; git -C "$repo" add skip
git -C "$repo" commit --no-verify -qm skipped
cmp "$seed" "$HOME/committed"
ledger 2026-10-11 "$(printf 'fixture%sfixture.test' '@')" >"$AGENTS_REGISTRY"
printf 'rejected\n' >"$repo/rejected"; git -C "$repo" add rejected
git -C "$repo" commit -qm rejected 2>"$HOME/stderr"
grep -q email "$HOME/stderr"
git -C "$repo" show HEAD:aac/src/agents-registry.md >"$HOME/rejected-seed"
cmp "$HOME/rejected-seed" "$HOME/committed"
printf '#!/bin/sh\n# user hook\nexit 0\n' >"$repo/.git/hooks/pre-commit"
cp "$repo/.git/hooks/pre-commit" "$HOME/user-hook"
bash "$repo/setup-git-account.sh" fixture >/dev/null 2>"$HOME/stderr"
cmp "$repo/.git/hooks/pre-commit" "$HOME/user-hook"
grep -q '既存の pre-commit' "$HOME/stderr"
echo 'sync-registry-seed: 全検証パス'
