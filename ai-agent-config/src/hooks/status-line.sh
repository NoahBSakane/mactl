#!/bin/bash
# status-line.sh - one line on how the *other* agents on this Mac are doing, for the reminder hook
# to hand to the agent (every 3rd prompt). Prints nothing when no other agent is installed.
#
#   AGENT_SELF=<section> status-line.sh [--instruction]
#                the agent running this session is left out; --instruction wraps the line in the
#                sentence the reminder hooks hand to the agent (nothing when there is no line)
#
# Only agents whose CLI is installed (agents.conf `bin` on PATH) appear - one that is not installed
# is never mentioned. A usage limit is read live from ~/.agent-state/unavailable/<agent>.txt and
# shown with its reset moment to the second; login state comes from the probe's cache (refreshed in
# the background when it is missing or older than its TTL). Always exits 0.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
PROBE="${AGENTS_PROBE:-$HOME/.knowledge/bin/agents-probe.sh}"
CACHE="$STATE/probe-cache.txt"
conf() { python3 "$HOOK_DIR/agentconf.py" "$@" 2>/dev/null; }
self="${AGENT_SELF:-}"

if [ ! -f "$CACHE" ] || [ $(( $(date +%s) - $(stat -f %m "$CACHE" 2>/dev/null || echo 0) )) -gt "${AGENTS_PROBE_TTL:-21600}" ]; then
  [ -x "$PROBE" ] && ( bash "$PROBE" >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

parts=()
for a in $(conf agents); do
  [ "$a" = "$self" ] && continue
  bin="$(conf get "$a" bin)"; command -v "${bin:-$a}" >/dev/null 2>&1 || continue
  label="$(conf get "$a" label)"; label="${label:-$a}"
  um="$STATE/unavailable/$a.txt"
  until_epoch="$(cut -f1 "$um" 2>/dev/null | head -1)"
  if [ -n "$until_epoch" ] && [ "$until_epoch" -gt "$(date +%s)" ] 2>/dev/null; then
    # 曜日は英語3文字(Sun..Sat)に固定する。日本語ロケールだと %a が「土」になるため LC_ALL=C を付ける。
    offset="$(TZ=Asia/Tokyo date -r "$until_epoch" '+%z')"
    reset_at="$(LC_ALL=C TZ=Asia/Tokyo date -r "$until_epoch" '+%Y-%m-%d(%a)%H:%M:%S')${offset%??}:${offset#???}"
    parts+=("$label: 利用上限(復帰: $reset_at)"); continue
  fi
  st="$(awk -v a="$a" '$1==a{print $2}' "$CACHE" 2>/dev/null | head -1)"
  case "$st" in
    ready) parts+=("$label: 有効") ;;
    no-auth) parts+=("$label: 未ログイン") ;;
    *) parts+=("$label: 導入済み(状態は確認中)") ;;
  esac
done
[ "${#parts[@]}" -gt 0 ] || exit 0
out=""; for p in "${parts[@]}"; do out="${out:+$out, }$p"; done
line="($out)"
if [ "${1:-}" = --instruction ]; then
  printf '【状態行】定例(3回に1回)です。この応答の最後に、次の1行を一字一句そのまま添えてください(省略・言い換え不可): %s\n' "$line"
else printf '%s\n' "$line"; fi
exit 0
