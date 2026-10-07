#!/bin/bash
# PreToolUse composition gate (a speed bump, see lib.sh for the fail-open contract).
#
# Asks the top-level agent to state its agent composition (and get it approved)
# before it edits files, launches another agent CLI, or spawns subagents.
# Which tool names mean "edit", "shell" or "subagent" for which agent comes from agents.conf.
#
# Always, in every mode: deployed instruction files (protected-paths.txt, written by install.sh)
# are never edited directly - rules are proposed (propose-rule) and adopted through the repo.
#
# Pass-through conditions for the composition gate, in order:
#   - the call comes from inside a subagent (payload has agent_id)
#   - this process was launched by an orchestrator (AGENT_DELEGATED_BY is set)
#   - /ofuro is active for this session (only costly-model use is policed)
#   - the user was already asked this session (AskUserQuestion ran)
#   - the user has sent a new prompt since the previous denial of this class
# Otherwise the call is denied; retries inside the same prompt stay denied, so
# parallel tool calls cannot slip through after the first denial.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
[ -n "$SESSION_ID" ] || exit 0

tool="$(jget .tool_name)"
tclass="$(tool_class "$tool")"
class=""
paths=""
if [ "$tclass" = edit ]; then
  paths="$(edit_paths)"
  if [ "$(printf '%s\n' "$paths" | python3 "$HOOK_DIR/parse_cmd.py" protected 2>/dev/null || true)" = protected ]; then
    deny "【指示ファイルの直接編集は不可】編集しようとしたファイルは、install.sh が配備・管理する指示ファイルです。ルールを足したい・変えたい場合は、直接編集せず propose-rule skill で ~/.knowledge/rule-proposals.md に提案してください(全体か固有かは、triage-rules skill でユーザーの承認を得て決まります)。採用された内容は、リポジトリ mac-setup/ai-agent-config/src/ を直して install.sh で配備します。"
  fi
fi

[ -z "$(jget .agent_id)" ] || exit 0
[ -z "${AGENT_DELEGATED_BY:-}" ] || exit 0

case "$tclass" in
  edit)
    verdict="$(printf '%s\n' "$paths" | python3 "$HOOK_DIR/parse_cmd.py" editcheck "$(jget .scratchpad_dir)" 2>/dev/null || true)"
    [ "$verdict" != skip ] || exit 0
    class=edit
    ;;
  shell)
    [ -n "$(classify_bash "$(tool_command)")" ] || exit 0
    class=ext
    ;;
  subagent)
    st="$(jget .tool_input.subagent_type)"
    if [ -n "$st" ] && python3 "$HOOK_DIR/agentconf.py" has readonly_subagents "$st" 2>/dev/null; then exit 0; fi
    class=subagent
    ;;
  *) exit 0 ;;
esac

if ofuro_active; then
  if [ "$class" = subagent ]; then
    model="$(jget .tool_input.model | tr '[:upper:]' '[:lower:]')"
    for m in $(conf get runtime costly_models); do
      case "$model" in
        *"$m"*)
          if ! jq -e --arg m "$m" '(.allow_models // []) | index($m)' "$(ofuro_file)" >/dev/null 2>&1; then
            deny "お風呂モード中: $m は /ofuro の呼び出し時に指示されていないため使えません。標準モデルで続行してください。"
          fi
          ;;
      esac
    done
  fi
  exit 0
fi

sd="$(session_dir)"
[ ! -e "$sd/asked" ] || exit 0
[ ! -e "$sd/ok.$class" ] || exit 0
key="$(turn_key)"
if [ -f "$sd/denied.$class" ]; then
  if [ "$(cat "$sd/denied.$class")" != "$key" ]; then
    : >"$sd/ok.$class"
    exit 0
  fi
else
  printf '%s' "$key" >"$sd/denied.$class"
fi

case "$class" in
  edit) what="ファイルの編集" ;;
  ext) what="別のエージェントCLI($(classify_bash "$(tool_command)" | paste -sd, -))の実行" ;;
  subagent) what="サブエージェント/Workflowの起動" ;;
esac
deny "【エージェント構成の事前承認】このセッションではまだ構成を提示していないため、${what}を止めました。orchestrate-agents skill に従い、agents-probe.sh で導入済みのエージェントを確認し、台帳で用途に適したものだけを並べた構成を、質問UI(無ければ番号付きの選択肢)で提示して承認を得てから、この操作をやり直してください。サブエージェント内や委譲先として動いている場合は不要です。"
