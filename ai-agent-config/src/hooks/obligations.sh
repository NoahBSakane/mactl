#!/bin/bash
# Prints one line per pending obligation (nothing when there is none). Used by the reminder hook
# (so agents are told, deterministically, without having to run anything) and by agents-probe.sh.
#   - the registry has not been re-verified for at least one day
#   - a registry update proposal from the background research job waits for review
#   - rule proposals are waiting for triage
#   - agent memory has new/changed files nobody has looked at
# Obligations never block work: the lines ask the agent to deal with them at a natural pause.
#   obligations.sh [--skip-registry]
STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
REGISTRY="${AGENTS_REGISTRY:-$HOME/.knowledge/ai-agents.md}"
PROPOSALS="${RULE_PROPOSALS:-$HOME/.knowledge/rule-proposals.md}"
STALE_DAYS="${AGENTS_STALE_DAYS:-1}"
skip_registry=0; [ "${1:-}" = "--skip-registry" ] && skip_registry=1

if [ "$skip_registry" -eq 0 ] && [ -f "$REGISTRY" ]; then
  worst=""; worst_age=0
  while read -r agent date; do
    [ -n "$date" ] || continue
    age=$(( ( $(date +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S" "$date 00:00:00" +%s 2>/dev/null || echo 0) ) / 86400 ))
    if [ "$age" -gt "$worst_age" ]; then worst_age="$age"; worst="$agent"; fi
  done < <(sed -nE 's/.*<!-- verified agent=([a-z]+) date=([0-9-]+) -->.*/\1 \2/p' "$REGISTRY")
  if [ "$worst_age" -ge "$STALE_DAYS" ]; then
    echo "台帳の確認が${STALE_DAYS}日以上経過しています(最も古い: ${worst}、${worst_age}日)。毎日の自動調査で更新します。要確認の提案や差分に違和感があれば refresh-registry skill で確認してください(作業は止めない)。"
  fi
fi

for f in "$STATE"/proposals/registry-*.md; do
  [ -f "$f" ] && { echo "台帳の更新提案(自動調査の結果)が届いています: ${f/#$HOME/~}。refresh-registry skill で検証して反映し、終わったら proposals/done/ へ移してください。"; break; }
done

if [ -f "$PROPOSALS" ]; then
  n="$(awk '/^```/{f=!f; next} !f && /^- 状態: 未検討/{c++} END{print c+0}' "$PROPOSALS" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] && echo "未検討のルール提案が ${n} 件あります(~/.knowledge/rule-proposals.md)。区切りの良いところで triage-rules skill を実行してください(採用にはユーザーの承認が必要)。"
fi

if [ -x "$HOME/.knowledge/bin/memory-harvest.sh" ]; then
  m="$("$HOME/.knowledge/bin/memory-harvest.sh" --count 2>/dev/null)"
  [ "${m:-0}" -gt 0 ] && echo "未収穫のエージェントメモリが ${m} 件あります。triage-rules skill の収穫手順で、ふるまいに関わる好み・訂正を提案として拾ってください。"
fi
exit 0
