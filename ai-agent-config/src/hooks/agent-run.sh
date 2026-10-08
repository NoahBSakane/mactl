#!/bin/bash
# agent-run.sh - run one headless job on whichever agent is available.
#
#   agent-run.sh <template-key> <prompt-file|->     e.g. `agent-run.sh research prompt.txt`
#   agent-run.sh --check <template-key>             exit 0 when at least one agent could run it
#
# Agents are tried in the order of [runtime] order in agents.conf. One that has no template for
# the key, is not installed, is logged out, or is marked unavailable is skipped. A run that
# fails with a structured signal, matching error text, or an AI-confirmed refusal marks that agent
# unavailable until the reset from its text or judge (6 hours when neither names one), in
# ~/.agent-state/unavailable/<agent>.txt, and the next agent takes over.
# stdout: the job's output. stderr: `# agent: <name>` on success. Exit 0 on success.
# The jobs run with AGENT_JOB=1 and AGENT_DELEGATED_BY=agent-run (no approval prompts, no
# obligations, no recursive jobs). No agent is named here - see agents.conf.
set -uo pipefail
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
JOB_TIMEOUT="${AGENT_RUN_TIMEOUT:-1800}"
conf() { python3 "$HOOK_DIR/agentconf.py" "$@" 2>/dev/null; }

unavailable() { # agent -> 0 when marked unavailable and not yet reset
  local um="$STATE/unavailable/$1.txt"
  [ -f "$um" ] && [ "$(cut -f1 "$um" | head -1)" -gt "$(date +%s)" ] 2>/dev/null
}
candidates() { # key -> agents that could run it (installed, template, not unavailable)
  local a bin
  for a in $(conf get runtime order); do
    [ -n "$(conf get "$a" "$1")" ] || continue
    bin="$(conf get "$a" bin)"; command -v "${bin:-$a}" >/dev/null 2>&1 || continue
    unavailable "$a" && continue
    echo "$a"
  done
}

if [ "${1:-}" = "--check" ]; then [ -n "$(candidates "${2:-}")" ]; exit; fi
key="${1:-}"; src="${2:-}"
[ -n "$key" ] && [ -n "$src" ] || { echo "usage: $0 <template-key> <prompt-file|->" >&2; exit 2; }
if [ "$src" = "-" ]; then AGENT_PROMPT="$(cat)"; else AGENT_PROMPT="$(cat "$src")"; fi
export AGENT_PROMPT AGENT_JOB=1 AGENT_DELEGATED_BY=agent-run
tried=""
for a in $(candidates "$key"); do
  auth="$(conf get "$a" auth)"
  if [ -n "$auth" ] && ! sh -c "$auth" >/dev/null 2>&1; then tried="$tried $a(未認証)"; continue; fi
  out="$(mktemp)"; err="$(mktemp)"
  since=$(date +%s)
  python3 - "$JOB_TIMEOUT" "$(conf get "$a" "$key")" >"$out" 2>"$err" <<'PY'
import subprocess, sys
try:
    r = subprocess.run(["sh", "-c", sys.argv[2]], capture_output=True, text=True, timeout=float(sys.argv[1]), stdin=subprocess.DEVNULL)
    sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
except subprocess.TimeoutExpired:
    sys.stderr.write("timeout\n"); sys.exit(124)
PY
  rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$out" ]; then cat "$out"; echo "# agent: $a" >&2; rm -f "$out" "$err"; exit 0; fi
  # Prefer session/log signals; fall back to the last stderr lines plus tiny stdout (a work product
  # merely talking about quotas or rate limits must not mark an agent unavailable).
  sample="$(python3 "$HOOK_DIR/limit-reset.py" --structured "$a" --since "$since" 2>/dev/null)"
  structured_limit=0; [ -n "$sample" ] && structured_limit=1
  if [ "$structured_limit" -eq 0 ]; then
    sample="$( { tail -n 20 "$err"; [ "$(wc -c <"$out")" -le 600 ] && cat "$out"; } | head -c 4000)"
  fi
  is_limit="$structured_limit"; judge_epoch=""
  if [ "$is_limit" -eq 0 ]; then
    if printf '%s' "$sample" | python3 "$HOOK_DIR/limit-reset.py" --is-limit; then is_limit=1
    elif [ -z "${AGENT_JUDGE:-}" ] && printf '%s' "$sample" | grep -Eiq 'quota|limit|\b429\b|too many|\brate\b|\bresets?\b|try again|exhaust|\busage\b|capacity|overload|credit|billing|exceed'; then
      # Only ambiguous failures need a judge; judge jobs must never recurse.
      judge_input="$(mktemp)"
      printf '%s' "$sample" >"$judge_input"
      judgment="$(bash "$HOOK_DIR/limit-judge.sh" "$judge_input")"
      rm -f "$judge_input"
      if [ "${judgment%%$'\t'*}" = LIMIT ]; then
        is_limit=1; judge_epoch="${judgment#*$'\t'}"
      fi
    fi
  fi
  if [ "$is_limit" -eq 1 ]; then
    mkdir -p "$STATE/unavailable"
    until_epoch="$(printf '%s' "$sample" | python3 "$HOOK_DIR/limit-reset.py" 2>/dev/null)"
    [ -n "$until_epoch" ] || until_epoch="$judge_epoch"
    if [ -n "$until_epoch" ]; then note="使用上限(agent-runが検知。判定した解除時刻まで)"
    else until_epoch=$(( $(date +%s) + 21600 )); note="使用上限(agent-runが検知。解除時刻が読めないため6時間後に再試行)"; fi
    printf '%s\t%s\n' "$until_epoch" "$note" >"$STATE/unavailable/$a.txt"
    tried="$tried $a(使用上限・復帰: $(bash "$HOOK_DIR/fmt-epoch.sh" "$until_epoch"))"
  else tried="$tried $a(失敗: $(head -c 120 "$err" | tr '\n' ' '))"; fi
  rm -f "$out" "$err"
done
echo "# どのエージェントでも実行できませんでした。試行:${tried:- なし(該当するエージェントが無い)}" >&2
exit 1
