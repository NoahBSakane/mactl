#!/bin/bash
# UserPromptSubmit: injects short context for the agent, and activates/deactivates /ofuro.
#   - prompt counter (also the turn key fallback for gate.sh)
#   - /ofuro [時間] [任務] | /ofuro off  (also `$ofuro`, `/skill ofuro`): binds a state file to
#     THIS session; default length 2h; costly models (agents.conf [runtime] costly_models) named in the instruction are allowed
#   - delegation reminder on the first prompt and every 10th
#   - limit-check.sh in the background: a recorded usage limit that has been lifted early is dropped
#   - status line (how the other installed agents are doing, with usage-limit reset times) on the
#     first prompt and every 3rd after it, as an exact line to append to the reply (status-line.sh)
#   - pending obligations (stale registry, rule proposals to triage, unharvested memory) on the first
#     prompt and every 5th, and the automatic registry research job when the registry is stale
#   - scope-discipline reminder on every prompt (kept short)
#   - one-line notices queued in ~/.agent-state/alerts/ (e.g. registry drift), shown once
# Never exits 2: it must not be able to swallow a prompt.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
[ -n "$SESSION_ID" ] || exit 0

sd="$(session_dir)"
count=$(( $(cat "$sd/prompt_count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$count" >"$sd/prompt_count"

prompt="$(jget .prompt)"
first_line="${prompt%%$'\n'*}"
ctx=""
add() { ctx="${ctx:+$ctx
}$1"; }

# --- /ofuro activation ---------------------------------------------------------------
if [[ "$first_line" =~ ^(/|\$)ofuro([[:space:]]|$) ]] || [[ "$first_line" =~ ^/skill[[:space:]]+ofuro([[:space:]]|$) ]]; then
  args="$(printf '%s' "$first_line" | sed -E 's#^(/skill[[:space:]]+ofuro|[/$]ofuro)[[:space:]]*##')"
  of="$(ofuro_file)"
  mkdir -p "$(dirname "$of")" 2>/dev/null || true
  if [[ "$args" =~ ^(off|stop|end|終了)([[:space:]]|$) ]]; then
    rm -f "$of"
    add "お風呂モードを終了しました。~/.agent-state/ofuro-report-*.md の最新レポート(完了/未完/保留/判断ログの要点)をユーザーへ要約して報告してください。"
  else
    minutes=120
    if [[ "$args" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]*(m|min|分|h|時間)([[:space:]]|$) ]]; then
      n="${BASH_REMATCH[1]}"; u="${BASH_REMATCH[3]}"
      case "$u" in h|時間) minutes="$(awk -v n="$n" 'BEGIN{printf "%d", n*60}')" ;; *) minutes="$(awk -v n="$n" 'BEGIN{printf "%d", n}')" ;; esac
      args="$(printf '%s' "$args" | sed -E 's/^[0-9.]+[[:space:]]*(m|min|分|h|時間)[[:space:]]*//')"
    fi
    start="$(now_epoch)"; until_epoch=$(( start + minutes * 60 ))
    allow='[]'
    lower="$(printf '%s' "$args" | tr '[:upper:]' '[:lower:]')"
    for m in $(conf get runtime costly_models); do
      case "$lower" in *"$m"*) allow="$(jq -c --arg m "$m" '. + [$m]' <<<"$allow")" ;; esac
    done
    jq -n --arg sid "$SESSION_ID" --arg cwd "$(jget .cwd)" --arg task "$args" \
      --argjson s "$start" --argjson u "$until_epoch" --argjson allow "$allow" \
      '{session_id:$sid,cwd:$cwd,task:$task,started_epoch:$s,until_epoch:$u,allow_models:$allow,continues:0,stale_stops:0}' >"$of"
    until_iso="$(bash "$HOOK_DIR/fmt-epoch.sh" "$until_epoch")"
    add "【お風呂モード開始】${minutes}分間(〜${until_iso})、ユーザーは操作できません。質問・承認依頼は一切せず、推奨案で自動的に進めてください。判断した事項は ~/.agent-state/ofuro-journal.md に『問い/採用案/理由』で追記し、外部へ公開・送信する操作や破壊的な操作は実行内容をジャーナルに記録すること。止まってよいのは、認証情報の漏洩を確認した/侵害の兆候を検知した/第三者に即時の被害が出る操作に気づいた、の場合だけです。許可されたモデル外のOpus/Fableは使わないこと(許可: ${allow})。作業の節目で .agent-handoff/STATE.md を更新し、全て完了したら ~/.agent-state/ofuro-report-<日時>.md に『完了/未完/保留/判断ログの要点』を書き、~/.agent-state/ofuro/$(safe_id "$SESSION_ID").done を作成して終了してください。権限プロンプトで拒否された操作は止まらずに『保留』として記録し、他の作業を続けること。"
    case "$(jget .permission_mode)" in default|manual|plan) add "注意: 現在の権限モードは $(jget .permission_mode) です。無人で進めるにはauto modeへ切り替えてください(Shift+Tab)。" ;; esac
    add "お風呂モード中の指示: ${args:-(任務指定なし。直前までの作業を続行)}"
  fi
elif ofuro_active; then
  left=$(( ( $(jq -r '.until_epoch' "$(ofuro_file)") - $(now_epoch) ) / 60 ))
  add "【お風呂モード中】残り約${left}分。質問せず推奨案で進め、判断は ~/.agent-state/ofuro-journal.md に記録してください。"
fi

# --- periodic delegation reminder ----------------------------------------------------
if [ "$count" -eq 1 ] || [ $(( count % 10 )) -eq 0 ]; then
  add "実装に着手する前に、agents-probe.sh で導入済みのエージェントを確認し、台帳で用途に適したものだけからエージェント構成(単独/委譲/サブエージェント)を検討し、質問UIで承認を取ってください(最上位セッションのみ。詳細は orchestrate-agents skill)。"
fi
# --- status line: first prompt, then every 3rd; only installed agents (status-line.sh) -----
if [ -z "${AGENT_JOB:-}" ] && [ $(( count % 3 )) -eq 1 ]; then
  line="$(bash "$HOOK_DIR/status-line.sh" --instruction 2>/dev/null || true)"
  [ -z "$line" ] || add "$line"
fi
# --- keep .agent-handoff/ out of Git (cheap; a no-op unless the folder exists) ---
( bash "$HOOK_DIR/handoff-exclude.sh" "$(jget .cwd)" >/dev/null 2>&1 & ) >/dev/null 2>&1
# --- has a usage limit been lifted early? (background; limit-check.sh rate-limits itself) ---
if [ -z "${AGENT_JOB:-}" ]; then ( bash "$HOOK_DIR/limit-check.sh" >/dev/null 2>&1 & ) >/dev/null 2>&1; fi
# --- obligations: deterministic reminders of pending work, + the background registry research ---
# First prompt and every 5th. Never blocks; the agent handles them at a natural pause.
if [ -z "${AGENT_JOB:-}" ] && ! ofuro_active && { [ "$count" -eq 1 ] || [ $(( count % 5 )) -eq 0 ]; }; then
  ob="$(bash "$HOOK_DIR/obligations.sh" 2>/dev/null || true)"
  [ -z "$ob" ] || add "【未処理の義務】作業は止めず、区切りの良いところで処理してください。
$ob"
  ( bash "$HOOK_DIR/registry-job.sh" maybe >/dev/null 2>&1 & ) >/dev/null 2>&1
fi
add "このプロンプトが事実確認・状況確認(YES/NOで答えられるもの)なら、その範囲だけに答え、頼まれていない検証・調査・提案へ広げない。"

# --- queued notices -------------------------------------------------------------------
ad="$AGENT_STATE_DIR/alerts"
if [ -d "$ad" ]; then
  for f in $(ls "$ad"/*.txt 2>/dev/null | head -3); do
    add "[通知] $(head -c 400 "$f")"
    mkdir -p "$ad/seen" && mv "$f" "$ad/seen/" 2>/dev/null || true
  done
fi

# --- housekeeping (rare): drop session state older than 7 days -------------------------
if [ $(( count % 20 )) -eq 0 ]; then
  find "$AGENT_STATE_DIR/sessions" -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} + 2>/dev/null || true
  find "$AGENT_STATE_DIR/ofuro" -type f -mtime +2 -delete 2>/dev/null || true
fi

jq -cn --arg ctx "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
exit 0
