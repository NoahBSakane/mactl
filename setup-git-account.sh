#!/bin/bash
# setup-git-account.sh - make this clone pull/push as one GitHub account, whatever `gh` has active.
#
#   ./setup-git-account.sh [account]        (default: the owner named in origin's URL)
#
# Writes only this clone's .git/config (never ~/.gitconfig, never the gh active account):
#   - origin gets the account name in its URL (https://<account>@github.com/...)
#   - git asks for credentials through a small helper that returns that account's token from `gh`'s
#     keyring (`gh auth token -u <account>`), so pushes work even when `gh` has another account
#     active (e.g. the company account used by the other projects). No token is stored anywhere.
# Safe to run again. The account must already be logged in: gh auth login -h github.com -p https -w
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
g() { git -C "$repo" "$@"; }
account="${1:-}"
if [ -z "$account" ]; then
  account="$(g remote get-url origin 2>/dev/null | sed -nE 's#^https://([^@/]+@)?github\.com/([^/]+)/.*#\2#p')"
  [ -n "$account" ] || { echo "origin のURLからアカウントを決められません。引数で渡してください" >&2; exit 1; }
fi
command -v gh >/dev/null 2>&1 || { echo "gh が見つかりません" >&2; exit 1; }
if ! gh auth token -u "$account" >/dev/null 2>&1; then
  echo "gh に $account でログインしていません。端末(Claude Code の外)で次を実行してから、もう一度:" >&2
  echo "  gh auth login -h github.com -p https -w" >&2
  exit 1
fi
url="$(g remote get-url origin 2>/dev/null)" || { echo "origin がありません" >&2; exit 1; }
case "$url" in
  https://github.com/*) g remote set-url origin "https://${account}@${url#https://}" ;;
  https://*@github.com/*) g remote set-url origin "https://${account}@${url#https://*@}" ;;
esac
key="credential.https://github.com"
g config --local --replace-all "$key.helper" ''
g config --local --add "$key.helper" "!f() { [ \"\$1\" = get ] || exit 0; echo username=$account; echo \"password=\$(gh auth token -u $account)\"; }; f"
g config --local "$key.username" "$account"
echo "設定しました: $(g remote get-url origin)"
got="$(printf 'protocol=https\nhost=github.com\nusername=%s\n\n' "$account" | g credential fill 2>/dev/null | sed -n 's/^password=//p')"
if [ -n "$got" ] && [ "$got" = "$(gh auth token -u "$account")" ]; then echo "確認: git の認証は $account のトークンです"; else echo "警告: 認証の確認に失敗しました" >&2; exit 1; fi

# pre-push check: keep company names, IDs and secrets out of this public repository (public-check.py).
# Installed only when no other pre-push hook is there. Fail-open if the script has moved; `git push --no-verify` skips it.
hook="$(g rev-parse --git-path hooks/pre-push)"; case "$hook" in /*) ;; *) hook="$repo/$hook" ;; esac
if [ ! -e "$hook" ] || grep -q "public-check" "$hook" 2>/dev/null; then
  mkdir -p "$(dirname "$hook")"
  cat >"$hook" <<'HOOK'
#!/bin/bash
# installed by setup-git-account.sh: scan what is about to be pushed (setup/ai-agent-config/public-check.py)
top="$(git rev-parse --show-toplevel)" || exit 0
f="$(git -C "$top" ls-files '*public-check.py' | head -1)"
[ -n "$f" ] && [ -f "$top/$f" ] || exit 0
exec python3 "$top/$f" --pre-push
HOOK
  chmod +x "$hook"; echo "pre-push の検査を設定しました: $hook"
else
  echo "既存の pre-push hook があるので、公開前の検査は設定しませんでした: $hook" >&2
fi

# pre-commit: bring the public registry seed up to date in the same commit.
hook="$(g rev-parse --git-path hooks/pre-commit)"; case "$hook" in /*) ;; *) hook="$repo/$hook" ;; esac
if [ ! -e "$hook" ] || grep -q '^# installed by setup-git-account.sh: sync-registry-seed$' "$hook" 2>/dev/null; then
  mkdir -p "$(dirname "$hook")"
  cat >"$hook" <<'HOOK'
#!/bin/bash
# installed by setup-git-account.sh: sync-registry-seed
top="$(git rev-parse --show-toplevel)" || exit 0
f="$(git -C "$top" ls-files '*sync-registry-seed.sh' | head -1)"
[ -n "$f" ] && [ -f "$top/$f" ] || exit 0
seed="$(dirname "$f")/src/agents-registry.md"
before="$(git -C "$top" hash-object -- "$seed" 2>/dev/null)"
bash "$top/$f"
after="$(git -C "$top" hash-object -- "$seed" 2>/dev/null)"
if [ -f "$top/$seed" ] && [ "$before" != "$after" ]; then
  git -C "$top" add -- "$seed"
fi
exit 0
HOOK
  chmod +x "$hook"; echo "pre-commit の台帳同期を設定しました: $hook"
else
  echo "既存の pre-commit hook があるので、台帳同期は設定しませんでした: $hook" >&2
fi
