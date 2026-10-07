#!/bin/bash
# PostToolUse(AskUserQuestion | request_user_input): the user was actually asked, so the
# composition gates for this session are lifted. A cancelled/rejected question does not count.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
[ -n "$SESSION_ID" ] || exit 0
resp="$(jq -c '.tool_response // empty' <<<"$PAYLOAD" 2>/dev/null || true)"
[ -n "$resp" ] || exit 0
case "$resp" in
  *"doesn't want to proceed"*|*"rejected"*|*"cancelled"*|*"canceled"*) exit 0 ;;
esac
: >"$(session_dir)/asked"
exit 0
