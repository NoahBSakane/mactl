#!/bin/bash

command -v jq >/dev/null 2>&1 || exit 0

set -euo pipefail

payload="$(cat)"
jq -e . >/dev/null <<<"$payload"
session_id="$(jq -er '.session_id | strings | select(length > 0)' <<<"$payload")"

# Claude Code currently emits UUID-like session IDs. Restrict the marker name
# anyway so an unexpected ID cannot escape the marker root.
marker_id="$(LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g' <<<"$session_id")"
marker_root="/tmp/claude-agent-composition"
marker_dir="$marker_root/$marker_id.done"

umask 077
mkdir -p "$marker_root"

# mkdir is the lock: exactly one concurrent first edit creates the marker and
# receives the speed bump. Every later edit sees mkdir fail and passes through.
if mkdir "$marker_dir" 2>/dev/null; then
  reason='このセッションでまだエージェント構成(Sonnet単独/Codex/Grok Build/Gemini/Opus/Fable)を一言も提示していません。CLAUDE.mdの「エージェント構成の事前承認」節に従い、まず構成を一言提示してからこの操作をやり直してください'
  jq -cn --arg reason "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
fi

exit 0
