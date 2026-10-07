#!/bin/bash
# Start another agent as the orchestrator, picking up from .agent-handoff/STATE.md.
# Use when the current orchestrator cannot continue (usage limit etc.). See the
# orchestrate-agents skill, references/failover.md.
#
#   agent-takeover.sh <agent> [working-dir]
#
# <agent> is any [section] of agents.conf that has an `interactive` template. The agent is started
# interactively with a prompt that points it at the shared rules and the handoff file; it is a
# normal top-level session (it asks for approval as usual). No agent is named in this script.
set -uo pipefail
HOOKS="${AGENTS_HOOKS_DIR:-$HOME/.agents/hooks}"
export AGENTS_CONF="${AGENTS_CONF:-$HOOKS/agents.conf}"
conf() { python3 "$HOOKS/agentconf.py" "$@" 2>/dev/null; }
agent="${1:-}"; dir="${2:-$PWD}"
tpl="$([ -n "$agent" ] && conf get "$agent" interactive)"
if [ -z "$tpl" ]; then
  echo "Usage: $0 <agent> [working-dir]   (agent: $(conf all interactive | cut -f1 | paste -sd' ' -))" >&2; exit 2
fi
bin="$(conf get "$agent" bin)"; command -v "${bin:-$agent}" >/dev/null 2>&1 || { echo "$agent は導入されていません" >&2; exit 1; }
cd "$dir" || exit 1
state=".agent-handoff/STATE.md"
if [ ! -f "$state" ]; then
  echo "注意: $dir/$state がありません。git status と git diff から状況を再構築するよう指示して起動します。" >&2
fi
AGENT_PROMPT="現在の司令塔が使えなくなったため、あなたが司令塔として作業を引き継ぎます。まず ~/AGENTS.md の共通ルール(司令塔プロトコル)と ${state}(無ければ git status / git diff / 直近のコミット)を読み、『次の一手』から再開してください。構成の承認・レビュー・品質ゲート・完了判定は共通ルールどおりです。委譲先は ~/.knowledge/bin/agents-probe.sh と ~/.knowledge/ai-agents.md で選び、使えなくなった元の司令塔には委譲しないでください。"
export AGENT_PROMPT
exec sh -c "$tpl"
