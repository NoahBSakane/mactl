#!/bin/bash
# Summarise delegation activity: last 24h, or one session when a session id is given.
set -euo pipefail
[ "$#" -le 1 ] || { echo "Usage: $0 [session_id]" >&2; exit 2; }

log="${AGENT_STATE_DIR:-$HOME/.agent-state}/delegation-log.jsonl"
sid="${1:-}"
if [ -n "$sid" ]; then scope="セッション $sid"; cutoff=0; else scope="直近24時間"; cutoff="$(date -u -v-24H '+%s')"; fi

if [ -f "$log" ]; then
  summary="$(jq -s --arg sid "$sid" --argjson cutoff "$cutoff" '
    map(select(if $sid != "" then .session_id == $sid else ((.timestamp | fromdateiso8601?) // 0) >= $cutoff end))
    | sort_by(.timestamp)
    | {total: length,
       external_cli: (map(select(.kind == "external_cli")) | length),
       subagent: (map(select(.kind == "subagent")) | length),
       entries: reverse}' "$log")"
else
  summary='{"total":0,"external_cli":0,"subagent":0,"entries":[]}'
fi

echo "委譲実績 ($scope)"
jq -r '"合計: \(.total)", "  external_cli: \(.external_cli)", "  subagent: \(.subagent)"' <<<"$summary"
if [ "$(jq -r '.total' <<<"$summary")" -gt 0 ]; then
  echo "直近の記録:"
  jq -r '.entries[] | if .kind == "external_cli" then "  \(.timestamp) [\(.agents)] \(.command)" else "  \(.timestamp) [subagent:\(.tool_name)] \(.description // "(詳細なし)")" end' <<<"$summary"
fi
