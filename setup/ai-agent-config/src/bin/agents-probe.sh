#!/bin/bash
# agents-probe.sh - which AI coding agents can this machine use *right now*?
#
# Everything machine-specific is read live from the CLIs themselves (versions, auth, model lists);
# nothing is kept as a source of truth. Which agents exist and how to ask each one comes from
# agents.conf (no agent is named in this script). Only a short-lived output cache is stored.
#
#   agents-probe.sh            human-readable table (+ models, + registry freshness)
#   agents-probe.sh --json     machine-readable summary
#   agents-probe.sh --fresh    ignore the cache (default TTL 10m)
#   agents-probe.sh --check    also verify that every flag the registry declares still
#                              exists in the CLI's --help (queues a notice if one vanished)
#
# Registry markers read from ~/.knowledge/ai-agents.md (comments, one per agent):
#   <!-- verified agent=codex date=2026-10-06 -->
#   <!-- flags agent=codex cmd="exec" : --approve-for-me -m -c -->
set -uo pipefail

STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
HOOKS="${AGENTS_HOOKS_DIR:-$HOME/.agents/hooks}"
REGISTRY="${AGENTS_REGISTRY:-$HOME/.knowledge/ai-agents.md}"
CACHE="$STATE/probe-cache.txt"
TTL="${AGENTS_PROBE_TTL:-600}"
STALE_DAYS="${AGENTS_STALE_DAYS:-1}"
JSON=0; FRESH=0; CHECK=0
for a in "$@"; do case "$a" in --json) JSON=1 ;; --fresh) FRESH=1 ;; --check) CHECK=1 ;; -h|--help) sed -n 2,17p "$0"; exit 0 ;; esac; done
mkdir -p "$STATE/alerts" 2>/dev/null || true
conf() { AGENTS_CONF="${AGENTS_CONF:-$HOOKS/agents.conf}" python3 "$HOOKS/agentconf.py" "$@" 2>/dev/null; }

# run a command with a time limit (macOS has no `timeout`); prints stdout, returns its status
to() {
  python3 - "$@" <<'PY'
import subprocess, sys
secs, cmd = float(sys.argv[1]), sys.argv[2:]
try:
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=secs, stdin=subprocess.DEVNULL)
    sys.stdout.write(r.stdout); sys.exit(r.returncode)
except Exception:
    sys.exit(124)
PY
}
# same, but stdout and stderr together (some CLIs print --help usage on stderr)
to_all() {
  python3 - "$@" <<'PY'
import subprocess, sys
secs, cmd = float(sys.argv[1]), sys.argv[2:]
try:
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=secs, stdin=subprocess.DEVNULL)
    sys.stdout.write(r.stdout + r.stderr); sys.exit(r.returncode)
except Exception:
    sys.exit(124)
PY
}
have() { command -v "$1" >/dev/null 2>&1; }

probe_one() { # prints: agent<TAB>state<TAB>version<TAB>detail
  local a="$1" bin v st="ready" detail="" auth um
  bin="$(conf get "$a" bin)"; bin="${bin:-$a}"
  if ! have "$bin"; then printf '%s\tmissing\t-\t未導入\n' "$a"; return; fi
  v="$(to 8 sh -c "$(conf get "$a" version)" | head -1)"
  auth="$(conf get "$a" auth)"
  if [ -n "$auth" ] && ! to 25 sh -c "$auth" >/dev/null 2>&1; then st="no-auth"; detail="未認証(ログイン状態を確認)"; fi
  # an orchestrator that hit a usage limit records "<resume-epoch><TAB><message>" here (the epoch is the real reset moment)
  um="$STATE/unavailable/$a.txt"
  if [ -f "$um" ] && [ "$(cut -f1 "$um" | head -1)" -gt "$(date +%s)" ] 2>/dev/null; then
    st="limit"; detail="復帰: $(bash "$HOOKS/fmt-epoch.sh" "$(cut -f1 "$um" | head -1)"): $(cut -f2- "$um" | head -1)"
  fi
  printf '%s\t%s\t%s\t%s\n' "$a" "$st" "${v:--}" "$detail"
}

models_of() { local m; m="$(conf get "$1" models)"; [ -z "$m" ] || to 25 sh -c "$m"; }

render() {
  echo "エージェント状況($(date '+%Y-%m-%d %H:%M'))"
  local rows="" a
  for a in $(conf agents); do rows="$rows$(probe_one "$a")"$'\n'; done
  printf '%s' "$rows" | awk -F'\t' 'NF{printf "  %-7s %-8s %-22s %s\n",$1,$2,$3,$4}'
  echo "利用可能(ready)のモデル:"
  printf '%s' "$rows" | awk -F'\t' '$2=="ready"{print $1}' | while read -r a; do echo "  [$a]"; models_of "$a"; done
}

if [ "$FRESH" -eq 0 ] && [ -f "$CACHE" ] && [ $(( $(date +%s) - $(stat -f %m "$CACHE") )) -lt "$TTL" ]; then
  body="$(cat "$CACHE")"
else
  body="$(render)"
  printf '%s\n' "$body" >"$CACHE" 2>/dev/null || true
fi

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$body" | awk 'NR>1 && /^  [a-z]+ +(ready|no-auth|missing|limit) /{print $1, $2, $3}' \
    | jq -Rn '[inputs | split(" ") | {agent:.[0], state:.[1], version:(.[2] // "")}]'
else
  printf '%s\n' "$body"
fi

# ---- registry freshness (cheap; recomputed every time) ----------------------------------
if [ -f "$REGISTRY" ]; then
  stale=""
  while read -r agent date; do
    [ -n "$date" ] || continue
    age=$(( ( $(date +%s) - $(date -j -f "%Y-%m-%d %H:%M:%S" "$date 00:00:00" +%s 2>/dev/null || echo 0) ) / 86400 ))
    [ "$age" -ge "$STALE_DAYS" ] && stale="$stale $agent(${age}日)"
  done < <(sed -nE 's/.*<!-- verified agent=([a-z]+) date=([0-9-]+) -->.*/\1 \2/p' "$REGISTRY")
  markers="$(grep -c '<!-- verified agent=' "$REGISTRY" 2>/dev/null || true)"
  if [ "${markers:-0}" -eq 0 ]; then
    echo "台帳に確認日マーカー(<!-- verified agent=... date=... -->)がありません。refresh-registry skill で付与してください"
  elif [ -n "$stale" ]; then
    echo "台帳の確認が${STALE_DAYS}日以上経過したエージェント:$stale → 毎日の自動調査で更新します。要確認の提案や差分に違和感があれば refresh-registry skill で確認してください(作業は止めない)"
  else
    echo "台帳: 全エージェントの確認日は${STALE_DAYS}日未満"
  fi
else
  echo "台帳が見つかりません: $REGISTRY"
fi

# ---- other pending obligations (rule proposals, unharvested memory, registry proposals) ----
if [ -x "$HOOKS/obligations.sh" ]; then
  ob="$(bash "$HOOKS/obligations.sh" --skip-registry 2>/dev/null)"
  if [ -n "$ob" ]; then echo "未処理の義務:"; printf '%s\n' "$ob" | sed 's/^/  - /'; fi
fi

# ---- declared flags still exist? -----------------------------------------------------------
if [ "$CHECK" -eq 1 ] && [ -f "$REGISTRY" ]; then
  while IFS= read -r line; do
    agent="$(sed -nE 's/.*agent=([a-z]+).*/\1/p' <<<"$line")"
    sub="$(sed -nE 's/.*cmd="([^"]*)".*/\1/p' <<<"$line")"
    flags="$(sed -nE 's/.*cmd="[^"]*" *: *(.*) *-->.*/\1/p' <<<"$line")"
    bin="$(conf get "$agent" bin)"; bin="${bin:-$agent}"
    have "$bin" || continue
    # shellcheck disable=SC2086
    help="$(to_all 15 "$bin" $sub --help)"
    missing=""
    for f in $flags; do grep -qF -- "$f" <<<"$help" || missing="$missing $f"; done
    if [ -n "$missing" ]; then
      echo "要確認: $agent $sub の --help から次のフラグが見当たりません:$missing"
      printf '台帳が記載する %s %s のフラグが消えました:%s(承認フラグ等の破壊的変更の可能性。台帳と委譲レシピを確認)\n' "$agent" "$sub" "$missing" >"$STATE/alerts/flags-$agent.txt"
    fi
  done < <(grep -E '<!-- flags agent=' "$REGISTRY")
fi
exit 0
