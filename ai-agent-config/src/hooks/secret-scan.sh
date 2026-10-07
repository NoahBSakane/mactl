#!/bin/bash
# PreToolUse(shell tools): refuse to hand secrets to an external agent CLI. Only commands that
# actually launch another agent CLI (agents.conf) are inspected (the command text, including an inline
# prompt, plus a --prompt-file target). This one is deliberately not skipped by /ofuro or
# AGENT_DELEGATED_BY: leaking a key to a third-party service is the one thing it exists for.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
is_shell_tool "$(jget .tool_name)" || exit 0
cmd="$(tool_command)"
[ -n "$(classify_bash "$cmd")" ] || exit 0

text="$cmd"
for f in $(printf '%s' "$cmd" | grep -oE -- '--(prompt|input)-file[ =]+[^ ;|&]+' | sed -E 's/^--[a-z]+-file[ =]+//' | head -3); do
  f="${f/#\~/$HOME}"
  if [ -f "$f" ] && [ "$(wc -c <"$f")" -le 204800 ]; then text="$text"$'\n'"$(cat "$f")"; fi
done

hit="$(secret_hit "$text")"
if [ -n "$hit" ]; then
  deny "【秘密情報の送信防止】外部エージェントCLIへ渡すコマンド/プロンプトに秘密情報らしき文字列(${hit:0:6}…)が含まれています。値を伏字にするか、環境変数経由に変えてから再実行してください。"
fi
exit 0
