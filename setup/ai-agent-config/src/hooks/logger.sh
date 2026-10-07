#!/bin/bash
# PostToolUse audit log of external-CLI launches and subagent spawns, one JSON line each.
# Rotates at ~1MB. Never blocks, never exits 2.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
tool="$(jget .tool_name)"
log="$AGENT_STATE_DIR/delegation-log.jsonl"
mkdir -p "$AGENT_STATE_DIR" 2>/dev/null || exit 0
ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
subagent_flag=false; [ -z "$(jget .agent_id)" ] || subagent_flag=true

case "$(tool_class "$tool")" in
  shell)
    cmd="$(tool_command)"
    kinds="$(classify_bash "$cmd" | paste -sd, -)"
    [ -n "$kinds" ] || exit 0
    jq -cn --arg ts "$ts" --arg sid "$SESSION_ID" --arg kinds "$kinds" --arg cmd "${cmd:0:300}" --argjson sub "$subagent_flag" \
      '{timestamp:$ts,session_id:$sid,kind:"external_cli",agents:$kinds,from_subagent:$sub,command:$cmd}' >>"$log"
    ;;
  subagent)
    jq -c --arg ts "$ts" --argjson sub "$subagent_flag" \
      '{timestamp:$ts,session_id:(.session_id // ""),kind:"subagent",tool_name:(.tool_name // ""),from_subagent:$sub,
        subagent_type:(.tool_input.subagent_type // null),model:(.tool_input.model // null),
        description:((.tool_input.description // "")[0:200])}' <<<"$PAYLOAD" >>"$log"
    ;;
  *) exit 0 ;;
esac

if [ -f "$log" ] && [ "$(wc -c <"$log")" -gt 1048576 ]; then
  tail -n 3000 "$log" >"$log.tmp" && mv "$log.tmp" "$log"
fi
exit 0
