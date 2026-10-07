#!/bin/bash
# Antigravity (agy) hook adapter.   agy-adapter.sh <script.sh> <PreToolUse|PostToolUse|PreInvocation|Stop>
#
# agy speaks a different hook dialect (camelCase payload, JSON decisions on stdout, tool names
# run_command / write_to_file ...). This translates the payload into the shape the shared
# scripts expect, runs the script, and translates the result back:
#   PreToolUse   exit 2 -> {"decision":"deny"|"ask","reason":...}   (deny for secret-scan, ask for the
#                          composition gate so interactive agy gets a native approval prompt)
#                else   -> {"decision":"allow"}
#   PostToolUse  always {}   (anything else is an error in agy)
#   Stop         the script's {"decision":"block"} -> {"decision":"continue","reason":...}; else {}
#   PreInvocation  (script name `pending`) hands the model what a PostToolUse script wanted to tell it:
#                PostToolUse can only answer {}, so a script that exits 2 (md-lint.sh: markdownlint findings)
#                has its stderr parked in the session's agy-pending.txt, and the next PreInvocation injects
#                it as {"injectSteps":[{"ephemeralMessage":...}]} (once). It also injects the status line
#                on every 3rd user turn (invocationNum 0 = the first model call of a turn), and starts /ofuro:
#                the turn's prompt is read from the transcript (transcriptPath) and replayed through reminder.sh
# Fails open: any internal error answers allow / {}.
script="${1:-}"; event="${2:-}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
allow() { case "$event" in PreToolUse) echo '{"decision":"allow"}' ;; *) echo '{}' ;; esac; exit 0; }
command -v jq >/dev/null 2>&1 || allow
payload="$(cat)"
STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
pending_file() { # -> the session's parked-message file (empty when there is no conversation id)
  local sid; sid="$(jq -r '.conversationId // empty' <<<"$payload" 2>/dev/null)"
  [ -n "$sid" ] || return 1
  printf '%s/sessions/%s/agy-pending.txt' "$STATE" "$(printf '%s' "$sid" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g')"
}
if [ "$event" = PreInvocation ]; then
  f="$(pending_file)" || allow
  msg=""; [ ! -s "$f" ] || { msg="$(cat "$f")"; rm -f "$f"; }
  # invocationNum 0 is the first model call of a user turn (it counts up while the model works through
  # tool results), so it is the "user sent a prompt" signal agy has no hook for: every 3rd turn, starting
  # with the first, the status line goes in (status-line.sh; not in background jobs)
  if [ "$(jq -r '.invocationNum // empty' <<<"$payload" 2>/dev/null)" = 0 ] && [ -z "${AGENT_JOB:-}" ]; then
    # /ofuro: agy has no prompt hook, but the payload names the transcript, whose last USER_INPUT is the
    # prompt. A /ofuro line is replayed through reminder.sh (the same activation as every other agent).
    tp="$(jq -r '.transcriptPath // empty' <<<"$payload" 2>/dev/null)"
    if [ -f "$tp" ]; then
      ptxt="$(grep -F '"type":"USER_INPUT"' "$tp" | tail -1 | jq -r '.content // empty' 2>/dev/null | sed -n '/^<USER_REQUEST>$/,/^<\/USER_REQUEST>$/p' | sed '1d;$d')"
      if [[ "${ptxt%%$'\n'*}" =~ ^(/|\$)ofuro([[:space:]]|$) ]]; then
        sid="$(jq -r '.conversationId // empty' <<<"$payload")"; wp="$(jq -r '(.workspacePaths // [""])[0]' <<<"$payload")"
        octx="$(jq -cn --arg s "$sid" --arg p "$ptxt" --arg c "$wp" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:$p,cwd:$c}' \
          | AGENT_SELF=agy bash "$HOOK_DIR/reminder.sh" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
        [ -z "$octx" ] || msg="${msg:+$msg
}$octx"
      fi
    fi
    mkdir -p "$(dirname "$f")" 2>/dev/null; tf="$(dirname "$f")/agy-turns"; n=$(( $(cat "$tf" 2>/dev/null || echo 0) + 1 )); printf '%s' "$n" >"$tf" 2>/dev/null
    if [ $(( n % 3 )) -eq 1 ]; then
      line="$(AGENT_SELF=agy bash "$HOOK_DIR/status-line.sh" --instruction 2>/dev/null)"
      [ -z "$line" ] || msg="${msg:+$msg
}$line"
    fi
  fi
  [ -n "$msg" ] || allow
  jq -cn --arg m "$msg" '{injectSteps:[{ephemeralMessage:$m}]}'; exit 0
fi
[ -x "$HOOK_DIR/$script" ] || allow

norm="$(jq -c --arg ev "$event" '
  def mapname: if . == "run_command" then "Bash"
               elif (. == "write_to_file" or . == "replace_file_content" or . == "multi_replace_file_content") then "Edit"
               else . end;
  { session_id: (.conversationId // ""), hook_event_name: $ev,
    cwd: ((.workspacePaths // [""])[0]), transcript_path: (.transcriptPath // ""),
    tool_name: ((.toolCall.name // "") | mapname),
    tool_input: ((.toolCall.args // {}) + { command: (.toolCall.args.CommandLine // null), file_path: (.toolCall.args.TargetFile // null) }) }' <<<"$payload" 2>/dev/null)" || allow
[ -n "$norm" ] || allow

err="$(mktemp)"; out="$(bash "$HOOK_DIR/$script" <<<"$norm" 2>"$err")"; code=$?
reason="$(cat "$err")"; rm -f "$err"

case "$event" in
  PreToolUse)
    if [ "$code" -eq 2 ]; then
      kind=ask; { [ "$script" = "secret-scan.sh" ] || [ "$script" = "agy-job-guard.sh" ] || [[ "$reason" == 【指示ファイルの直接編集* ]]; } && kind=deny
      jq -cn --arg k "$kind" --arg r "$reason" '{decision:$k,reason:$r}'
    else echo '{"decision":"allow"}'; fi ;;
  Stop)
    if jq -e '.decision == "block"' <<<"$out" >/dev/null 2>&1; then
      jq -c '{decision:"continue",reason:(.reason // "")}' <<<"$out"
    else echo '{}'; fi ;;
  PostToolUse)
    if [ "$code" -eq 2 ] && [ -n "$reason" ] && f="$(pending_file)"; then
      mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$reason" >>"$f"
    fi
    echo '{}' ;;
  *) echo '{}' ;;
esac
exit 0
