#!/bin/bash

# An audit hook must never interfere with the tool that triggered it. Parsing,
# directory creation, and append failures therefore all degrade to exit 0.
set -uo pipefail

payload="$(cat)"
if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
  exit 0
fi

tool_name="$(jq -r '.tool_name // ""' <<<"$payload" 2>/dev/null)" || exit 0
timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
log_dir="$HOME/.claude/delegation-hooks"
log_file="$log_dir/delegation-log.jsonl"

mkdir -p "$log_dir" 2>/dev/null || exit 0

if [ "$tool_name" = "Bash" ]; then
  command="$(jq -r '.tool_input.command // ""' <<<"$payload" 2>/dev/null)" || exit 0
  codex_re='(^|[[:space:];|&])codex[[:space:]]+exec([[:space:]]|$)'
  grok_re='(^|[[:space:];|&])grok([[:space:]][^;|&]*)?[[:space:]]-p([[:space:]]|$)'
  agy_re='(^|[[:space:];|&])agy([[:space:]][^;|&]*)?[[:space:]]-p([[:space:]]|$)'

  if [[ "$command" =~ $codex_re || "$command" =~ $grok_re || "$command" =~ $agy_re ]]; then
    (jq -c \
      --arg timestamp "$timestamp" \
      '{
        timestamp: $timestamp,
        session_id: (.session_id // ""),
        kind: "external_cli",
        command: (.tool_input.command // "")
      }' <<<"$payload" >>"$log_file") 2>/dev/null || true
  fi
elif [ "$tool_name" = "Agent" ] || [ "$tool_name" = "Task" ]; then
  (jq -c \
    --arg timestamp "$timestamp" \
    '{
      timestamp: $timestamp,
      session_id: (.session_id // ""),
      kind: "subagent",
      tool_name: (.tool_name // ""),
      prompt: (.tool_input.prompt // null),
      description: (.tool_input.description // null),
      subagent_type: (.tool_input.subagent_type // null),
      model: (.tool_input.model // null)
    }' <<<"$payload" >>"$log_file") 2>/dev/null || true
fi

exit 0
