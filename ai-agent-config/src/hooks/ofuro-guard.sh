#!/bin/bash
# /ofuro enforcement, for this session only.
#   PreToolUse(AskUserQuestion|request_user_input): deny, with the decide-and-journal rule.
#   Stop: keep the agent working until its work is done or the time box ends, with a hard
#         cap on forced continuations and a no-progress check, so it can never loop forever.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
[ -n "$SESSION_ID" ] || exit 0
of="$(ofuro_file)"
[ -f "$of" ] || exit 0

event="$(jget .hook_event_name)"
done_marker="${of%.json}.done"
MAX_CONTINUES=30
MAX_STALE=3

case "$event" in
  PreToolUse)
    ofuro_active || exit 0
    deny "お風呂モード中のためユーザーへ質問できません。推奨案で進め、『問い/採用案/理由』を ~/.agent-state/ofuro-journal.md に追記してください。"
    ;;
  Stop)
    if [ -e "$done_marker" ]; then rm -f "$of" "$done_marker"; exit 0; fi
    state_dir="$(dirname "$of")"
    if ! ofuro_active; then
      # time box ended: one final wrap-up turn, then let it stop
      if [ "$(jq -r '.wrapup // false' "$of")" = "true" ]; then rm -f "$of"; exit 0; fi
      jq '.wrapup = true' "$of" >"$of.tmp" && mv "$of.tmp" "$of"
      jq -cn '{decision:"block",reason:"お風呂モードの時間が終了しました。.agent-handoff/STATE.md を更新し、~/.agent-state/ofuro-report-<日時>.md に『完了/未完/保留/判断ログの要点』を書いて終了してください。"}'
      exit 0
    fi
    continues="$(jq -r '.continues // 0' "$of")"
    [ "$continues" -lt "$MAX_CONTINUES" ] || { rm -f "$of"; exit 0; }
    # progress = journal + STATE.md changed since the last stop
    sig="$(cat "$AGENT_STATE_DIR/ofuro-journal.md" "$(jget .cwd)/.agent-handoff/STATE.md" 2>/dev/null | cksum | cut -d' ' -f1)"
    last="$(jq -r '.last_sig // ""' "$of")"
    stale="$(jq -r '.stale_stops // 0' "$of")"
    if [ "$sig" = "$last" ]; then stale=$(( stale + 1 )); else stale=0; fi
    [ "$stale" -lt "$MAX_STALE" ] || { rm -f "$of"; exit 0; }
    jq --arg sig "$sig" --argjson st "$stale" '.continues += 1 | .last_sig = $sig | .stale_stops = $st' "$of" >"$of.tmp" && mv "$of.tmp" "$of"
    jq -cn '{decision:"block",reason:"お風呂モード中です。タスクが残っていれば質問せずに続行してください。全て完了していれば、レポートを ~/.agent-state/ofuro-report-<日時>.md に書き、~/.agent-state/ofuro/'"$(safe_id "$SESSION_ID")"'.done を作成して終了してください。"}'
    ;;
esac
exit 0
