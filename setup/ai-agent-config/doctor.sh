#!/bin/bash
# doctor.sh - are the tools this repository needs on this Mac? (and what is optional)
#
#   ./doctor.sh              list everything, with how to install what is missing
#   ./doctor.sh --required   only the must-haves, quietly (install.sh runs this first); exit 1 if one is missing
#
# Must-have: bash, jq, python3 (3.8+), git, a SHA-256 tool, awk, sed, find.
# Optional: gh (pushing this repository), node/npx (markdownlint on edit), curl, and the agent CLIs
# (their state is agents-probe.sh's job). Without python3 the hooks silently stop checking (they fail open),
# so it is a must-have even though nothing says so at run time. Exit 0 = all must-haves present.
set -uo pipefail
case "${BASH_SOURCE[0]}" in */*) HERE="$(cd "${BASH_SOURCE[0]%/*}" && pwd)" ;; *) HERE="$(pwd)" ;; esac
REQ_ONLY=0; [ "${1:-}" = --required ] && REQ_ONLY=1
miss=0
hint() { # tool -> how to get it on macOS
  case "$1" in
    jq) echo "brew install jq" ;;
    python3) echo "xcode-select --install   (or: brew install python)" ;;
    git) echo "xcode-select --install" ;;
    gh) echo "brew install gh" ;;
    node|npx) echo "brew install node" ;;
    *) echo "(macOS に標準で付属するはずです。PATH を確認してください)" ;;
  esac
}
row() { # level tool note
  local lv="$1" tool="$2" note="${3:-}"
  if [ "$lv" = need ] && ! command -v "$tool" >/dev/null 2>&1; then miss=$((miss+1)); printf '[MISSING] %-8s %s → %s\n' "$tool" "$note" "$(hint "$tool")"; return; fi
  if [ "$lv" = want ] && ! command -v "$tool" >/dev/null 2>&1; then [ "$REQ_ONLY" -eq 1 ] || printf '[ WARN  ] %-8s %s → %s\n' "$tool" "$note" "$(hint "$tool")"; return; fi
  [ "$REQ_ONLY" -eq 1 ] || printf '[  OK   ] %-8s %s\n' "$tool" "$note"
}
row need bash "シェル"
row need jq "JSON(hook・install が使う)"
row need python3 "hook・manifest 処理が使う"
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
  miss=$((miss+1)); printf '[MISSING] %-8s %s → %s\n' python3 "3.8 以上が必要です(今: $(python3 --version 2>&1))" "$(hint python3)"
fi
row need git "リポジトリの操作"
if command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1; then [ "$REQ_ONLY" -eq 1 ] || printf '[  OK   ] %-8s %s\n' sha256 "ハッシュ(drift の検出)"; else miss=$((miss+1)); printf '[MISSING] %-8s %s → %s\n' shasum "ハッシュ" "$(hint shasum)"; fi
for t in awk sed find dirname basename mktemp; do row need "$t" "標準コマンド"; done
row want gh "このリポジトリへ push するとき(NoahBSakane でログイン)"
row want node "markdownlint(編集直後の検査)"
row want npx "markdownlint(編集直後の検査)"
row want curl "台帳の調査など"
if [ "$REQ_ONLY" -eq 0 ]; then
  echo "--- エージェント(導入の有無。認証・上限は agents-probe.sh)"
  for a in $(python3 "$HERE/src/hooks/agentconf.py" agents 2>/dev/null || true); do
    bin="$(AGENTS_CONF="$HERE/src/hooks/agents.conf" python3 "$HERE/src/hooks/agentconf.py" get "$a" bin 2>/dev/null)"
    command -v "${bin:-$a}" >/dev/null 2>&1 && printf '[  OK   ] %s\n' "$a" || printf '[  --   ] %s (未導入)\n' "$a"
  done
fi
if [ "$miss" -gt 0 ]; then echo "必須のツールが $miss 件足りません。上の案内で入れてから、もう一度実行してください。" >&2; exit 1; fi
[ "$REQ_ONLY" -eq 1 ] || echo "必須のツールはそろっています。"
exit 0
