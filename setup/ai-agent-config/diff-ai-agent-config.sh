#!/bin/bash
# Mechanical half of "does this Mac match the repo?": compares every manifest row with its live
# artifact and reports. It decides nothing; for which side wins see the reconcile-agent-config
# skill (../../.claude/skills/reconcile-agent-config/SKILL.md).
#
#   diff-ai-agent-config.sh           status of every row, with a diff for each DRIFT
#   diff-ai-agent-config.sh -b        status lines only (--brief)
#
# Exit code: 0 when every row is OK (or SKIP), 1 otherwise.
set -uo pipefail
CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$CFG_DIR/manifest-lib.sh"
BRIEF=0; case "${1:-}" in --brief|-b) BRIEF=1 ;; -h|--help) sed -n 2,12p "$0"; exit 0 ;; esac

bad=0
report() {
  local id="$1" mode="$2" src="$3" dest="$4" cond="$5"
  row_status "$id" "$mode" "$src" "$dest" "$cond"
  printf '[%-7s] %-32s %s\n' "$ST" "$id" "$dest"
  case "$ST" in OK|SKIP) return ;; esac
  bad=1
  [ "$ST" != ERROR ] || { echo "  $(cat "$WORK/$id.err" 2>/dev/null | head -1)"; return; }
  [ "$BRIEF" -eq 0 ] && [ "$ST" = DRIFT ] || return 0
  if [ -d "$dest" ] && [ ! -L "$dest" ]; then diff -ru "$WORK/$id" "$dest" | head -60
  elif [ -f "$dest" ] && [ -f "$WORK/$id" ]; then diff -u "$WORK/$id" "$dest" | head -60
  else echo "  (live: $(hash_path "$dest") / repo: $WANT)"; fi
}
each_row report

# information only: more than one CLAUDE.md / AGENTS.md style file in a managed directory
echo
echo "同一階層の指示ファイル重複(情報):"
found=0
check_dir() { # dir, files relative to it that must not exist
  local d="$1"; shift; local f
  for f in "$@"; do [ -e "$d/$f" ] && { echo "  $d/$f"; found=1; }; done
}
check_dir "$HOME" CLAUDE.md CLAUDE.local.md GEMINI.md .agents/AGENTS.md
check_dir "$HOME/.claude" .claude/CLAUDE.md CLAUDE.local.md
check_dir "$HOME/.codex" CLAUDE.md
check_dir "$HOME/.gemini" CLAUDE.md
check_dir "$CFG_DIR/../.." .claude/CLAUDE.md CLAUDE.local.md GEMINI.md .agents/AGENTS.md
[ "$found" -eq 1 ] || echo "  なし"
# the shared rules must be the same content on every route an agent reads them by. Derived from the
# manifest (no agent is named): every link whose target is ~/AGENTS.md must resolve to that one file,
# and ~/AGENTS.md itself must equal src/shared-rules.md.
echo
echo "共通ルールの一致(全経路で同じ内容が読まれること):"
rp() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
sr_bad=0
sr_row() { # label, ok|ng
  if [ "$2" = ok ]; then printf '  [OK] %s\n' "$1"; else printf '  [NG] %s\n' "$1"; sr_bad=1; fi
}
sr_cb() {
  local id="$1" mode="$2" src="$3" dest="$4" cond="$5" s
  cond_ok "$cond" || return 0
  if [ "$dest" = "$HOME/AGENTS.md" ] && [ "$mode" = copy ]; then
    [ -f "$dest" ] && cmp -s "$(expand "$src")" "$dest" && s=ok || s=ng
    sr_row "~/AGENTS.md(実体) == $src" "$s"
  elif [ "$mode" = link ] && [ "$(expand "$src")" = "$HOME/AGENTS.md" ]; then
    [ -e "$dest" ] && [ "$(rp "$dest")" = "$(rp "$HOME/AGENTS.md")" ] && s=ok || s=ng
    sr_row "${dest/#$HOME/~} は ~/AGENTS.md と同一ファイル" "$s"
  fi
}
each_row sr_cb
if [ "$sr_bad" -eq 0 ]; then echo "共通ルールの一致: OK"; else echo "共通ルールの一致: NG"; bad=1; fi
exit "$bad"
