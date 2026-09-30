#!/bin/bash

command -v jq >/dev/null 2>&1 || exit 0

set -euo pipefail

payload="$(cat)"
jq -e . >/dev/null <<<"$payload"

reminder='実装・調査に着手する前に、Codex CLI・Grok Build・Gemini CLI・Opus・Fable・Sonnet単独から今回のエージェント構成を検討しましたか。詳細はCLAUDE.mdの「エージェント構成の事前承認」節を確認してください。'

jq -cn --arg reminder "$reminder" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $reminder
  }
}'
