#!/bin/bash

set -euo pipefail

if [ "$#" -gt 1 ]; then
  echo "Usage: $0 [session_id]" >&2
  exit 2
fi

log_file="$HOME/.claude/delegation-hooks/delegation-log.jsonl"
session_id="${1:-}"

if [ -n "$session_id" ]; then
  scope="セッション $session_id"
  cutoff=0
else
  scope="直近24時間"
  cutoff="$(date -u -v-24H '+%s')"
fi

if [ -f "$log_file" ]; then
  summary="$(jq -s \
    --arg session_id "$session_id" \
    --argjson cutoff "$cutoff" '
      map(select(
        if $session_id != "" then
          .session_id == $session_id
        else
          ((.timestamp | fromdateiso8601?) // 0) >= $cutoff
        end
      ))
      | sort_by(.timestamp)
      | {
          total: length,
          external_cli: (map(select(.kind == "external_cli")) | length),
          subagent: (map(select(.kind == "subagent")) | length),
          entries: reverse
        }
    ' "$log_file")"
else
  summary='{"total":0,"external_cli":0,"subagent":0,"entries":[]}'
fi

echo "委譲実績 ($scope)"
jq -r '"合計: \(.total)", "  external_cli: \(.external_cli)", "  subagent: \(.subagent)"' <<<"$summary"

if [ "$(jq -r '.total' <<<"$summary")" -gt 0 ]; then
  echo "直近の記録:"
  jq -r '
    .entries[]
    | if .kind == "external_cli" then
        "  \(.timestamp) [external_cli] \(.command)"
      else
        "  \(.timestamp) [subagent:\(.tool_name)] \(.description // .prompt // "(詳細なし)")"
      end
  ' <<<"$summary"
fi
