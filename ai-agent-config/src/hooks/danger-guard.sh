#!/bin/bash
# PreToolUse for shell commands: refuse a command that wipes out (or ruins) the home directory, the root,
# a system directory or one of the home's personal folders (rm -rf ~, find ~ -delete, dd of=/dev/disk2 ...).
# The analysis is danger_check.py. Any tool whose input carries a command line is checked (the name of the
# shell tool differs between agents), and - unlike the composition gate - nothing lifts this: not a subagent,
# not a delegated run, not /ofuro. Fail-open only on internal errors; a deny is exit 2 with the reason.
# Deleting something specific (rm -rf ~/project/build) is fine. To delete a protected place on purpose, run it yourself.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
cmd="$(tool_command)"
[ -n "$cmd" ] || exit 0
reasons="$(printf '%s' "$cmd" | python3 "$HOOK_DIR/danger_check.py" --cwd "$(jget .cwd)" 2>/dev/null || true)"
[ -n "$reasons" ] || exit 0
deny "【破壊的な削除の拒否】ホーム・ルート・システムのディレクトリ、または Documents などの個人フォルダ全体を、消す・壊す恐れのあるコマンドです。
$reasons
範囲を狭めた削除(例: ~/project/build)は通ります。本当に必要なら、あなたの端末で自分で実行してください(エージェントには許可されません)。保護する場所を増やすには ~/.config/ai-agent-config/danger-paths.txt に1行ずつ書きます。"
