#!/bin/bash
# Generic login-item runner.
#
# Runs every executable file placed directly inside ~/Library/Scripts/login-items.d/
# every time this Mac starts up / you log in. To add a new "run at startup" task,
# just drop a script there and `chmod +x` it — no new LaunchAgent/plist needed.
#
# Triggered by ~/Library/LaunchAgents/com.nbs.login-items-runner.plist (RunAtLoad).
# Each script's own stdout/stderr is folded into this log, tagged with its name;
# one script failing doesn't stop the others from running.

set -uo pipefail

DIR="$HOME/Library/Scripts/login-items.d"
LOG="$HOME/Library/Logs/login-items.log"
mkdir -p "$(dirname "$LOG")" "$DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=== login-items run starting ==="
shopt -s nullglob
for script in "$DIR"/*; do
  [ -f "$script" ] && [ -x "$script" ] || continue
  name=$(basename "$script")
  log "-> running $name"
  if "$script" >>"$LOG" 2>&1; then
    log "   $name: OK"
  else
    log "   $name: FAILED (exit $?)"
  fi
done
log "=== login-items run complete ==="
