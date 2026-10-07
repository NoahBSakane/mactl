#!/bin/bash
# ofuro-run.sh - start /ofuro (bath mode) non-interactively, so a long task keeps running while you are away.
#
#   ofuro-run.sh [時間] <任務...>        例: ofuro-run.sh 2h "テストを直してPRの下書きまで"
#   ofuro-run.sh -f [時間] <任務...>     前面で実行する(既定はバックグラウンド)
#
# 時間は 30m / 2h / 90分 / 3時間 の形(省略すると /ofuro の既定の2時間)。`claude -p "/ofuro ..."` を
# 起動する: UserPromptSubmit hook(reminder.sh)が /ofuro を認識して状態を作り、Stop hook
# (ofuro-guard.sh)が、完了報告が出るか期限が来るまで止まらずに続ける(非対話でも動くことは確認済み)。
# 環境変数: OFURO_MODEL(モデル名。既定はアカウントの既定)、OFURO_MAX_TURNS(既定2000)。
# 出力は ~/.agent-state/ofuro-run-<日時>.log。終わったら ~/.agent-state/ofuro-report-*.md を見る。
set -uo pipefail
usage() { sed -n 2,12p "$0" >&2; exit 2; }
fg=0; [ "${1:-}" = -f ] && { fg=1; shift; }
time=""
if [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?(m|min|分|h|時間)$ ]]; then time="$1"; shift; fi
task="$*"
[ -n "$task" ] || usage
command -v claude >/dev/null 2>&1 || { echo "claude が見つかりません" >&2; exit 1; }
mkdir -p "$HOME/.agent-state"
log="$HOME/.agent-state/ofuro-run-$(date +%Y%m%d-%H%M%S).log"
args=(-p "/ofuro ${time:+$time }$task" --permission-mode auto --max-turns "${OFURO_MAX_TURNS:-2000}")
[ -z "${OFURO_MODEL:-}" ] || args+=(--model "$OFURO_MODEL")
if [ "$fg" -eq 1 ]; then claude "${args[@]}" 2>&1 | tee "$log"; exit "${PIPESTATUS[0]}"; fi
nohup claude "${args[@]}" >"$log" 2>&1 </dev/null &
echo "起動しました(pid $!)。ログ: $log"
echo "終わったら ~/.agent-state/ofuro-report-*.md を見てください。止めるには: kill $!"
