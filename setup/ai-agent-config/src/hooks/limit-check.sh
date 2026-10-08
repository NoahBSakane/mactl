#!/bin/bash
# limit-check.sh - has a usage limit been lifted early?
#
#   limit-check.sh [--force]
#
# A limit is recorded in ~/.agent-state/unavailable/<agent>.txt with the moment it should end, but
# that moment can be wrong: resets arrive early (a reset ticket, a plan change). For every agent that
# is marked unavailable, installed, logged in and has a `ping` template (agents.conf), this makes the
# cheapest real call - at most once per LIMIT_CHECK_INTERVAL (default 30 min) per agent - and:
#   - it answers          -> the marker is removed and a notice is queued (shown once by the reminder)
#   - it names a new time -> the marker moves to that time
#   - anything else       -> the marker stays
# Run in the background by reminder.sh on every prompt (cheap when nothing is marked). Always exits 0.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
INTERVAL="${LIMIT_CHECK_INTERVAL:-1800}"
FORCE=0; [ "${1:-}" = --force ] && FORCE=1
conf() { python3 "$HOOK_DIR/agentconf.py" "$@" 2>/dev/null; }
[ -d "$STATE/unavailable" ] || exit 0
mkdir -p "$STATE/limit-check" "$STATE/alerts" 2>/dev/null || exit 0

for um in "$STATE"/unavailable/*.txt; do
  [ -f "$um" ] || continue
  a="$(basename "$um" .txt)"
  until_epoch="$(cut -f1 "$um" | head -1)"
  if ! [ "${until_epoch:-0}" -gt "$(date +%s)" ] 2>/dev/null; then rm -f "$um"; continue; fi   # already over
  ping="$(conf get "$a" ping)"; [ -n "$ping" ] || continue
  bin="$(conf get "$a" bin)"; command -v "${bin:-$a}" >/dev/null 2>&1 || continue
  auth="$(conf get "$a" auth)"; if [ -n "$auth" ] && ! sh -c "$auth" >/dev/null 2>&1; then continue; fi
  stamp="$STATE/limit-check/$a.stamp"
  if [ "$FORCE" -eq 0 ] && [ -f "$stamp" ] && [ $(( $(date +%s) - $(stat -f %m "$stamp") )) -lt "$INTERVAL" ]; then continue; fi
  # one check at a time per agent
  lock="$STATE/limit-check/$a.lock"; mkdir "$lock" 2>/dev/null || { [ -n "$(find "$lock" -mmin +10 2>/dev/null)" ] && rmdir "$lock"; continue; }
  touch "$stamp"
  since=$(date +%s)
  out="$(AGENT_JOB=1 AGENT_DELEGATED_BY=limit-check AGENT_PROMPT="" python3 - "$ping" <<'PY'
import subprocess, sys
try:
    r = subprocess.run(["sh", "-c", sys.argv[1]], capture_output=True, text=True, timeout=150, stdin=subprocess.DEVNULL)
    print(r.returncode); sys.stdout.write(r.stdout + "\n--stderr--\n" + r.stderr)
except Exception:
    print(124)
PY
)"
  rmdir "$lock" 2>/dev/null
  rc="$(head -1 <<<"$out")"; text="$(tail -n +2 <<<"$out")"
  label="$(conf get "$a" label)"; label="${label:-$a}"
  signal=""; [ "$rc" = 0 ] || signal="$(python3 "$HOOK_DIR/limit-reset.py" --structured "$a" --since "$since" 2>/dev/null)"
  structured_limit=0
  if [ -n "$signal" ]; then text="$signal"; structured_limit=1; fi
  if [ "$structured_limit" -eq 1 ] || printf '%s' "$text" | python3 "$HOOK_DIR/limit-reset.py" --is-limit; then
    new="$(printf '%s' "$text" | python3 "$HOOK_DIR/limit-reset.py")"
    [ -z "$new" ] || [ "$new" = "$until_epoch" ] || printf '%s\t%s\n' "$new" "使用上限(limit-checkが確認。エラー文の解除時刻まで)" >"$um"
  elif [ "$rc" = 0 ] && [ -n "$(sed -n '1,/^--stderr--$/p' <<<"$text" | grep -v '^--stderr--$' | tr -d '[:space:]')" ]; then
    rm -f "$um"
    printf '%s の使用上限が解除されていました(%s に確認。記録していた解除予定は %s)。使えます。\n' "$label" "$(bash "$HOOK_DIR/fmt-epoch.sh" "$(date +%s)")" "$(bash "$HOOK_DIR/fmt-epoch.sh" "$until_epoch")" >"$STATE/alerts/limit-lifted-$a.txt"
  fi
done
exit 0
