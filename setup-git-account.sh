#!/bin/bash
# setup-git-account.sh - make this clone pull/push as one GitHub account, whatever `gh` has active.
#
#   ./setup-git-account.sh [account]        (default: NoahBSakane)
#
# Writes only this clone's .git/config (never ~/.gitconfig, never the gh active account):
#   - origin gets the account name in its URL (https://<account>@github.com/...)
#   - git asks for credentials through a small helper that returns that account's token from `gh`'s
#     keyring (`gh auth token -u <account>`), so pushes work even when `gh` has another account
#     active (e.g. the company account used by the other projects). No token is stored anywhere.
# Safe to run again. The account must already be logged in: gh auth login -h github.com -p https -w
set -uo pipefail
account="${1:-NoahBSakane}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
g() { git -C "$repo" "$@"; }
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
