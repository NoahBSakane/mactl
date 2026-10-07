#!/bin/bash
# Muse hook adapter.   muse-adapter.sh <script.sh>
#
# Muse runs hooks with a minimal environment (HOME LANG LOGNAME PATH PWD SHELL SHLVL TMPDIR
# USER only), so AGENT_DELEGATED_BY never reaches them. An orchestrator launches Muse with
# --disable-approval / --yolo / --approval-mode never, and Muse reports that to hooks as
# permission_mode bypassPermissions (or dontAsk). Nobody is in the loop to approve a
# composition then, so such a run is treated as delegated. Everything else passes through
# unchanged (payload on stdin, deny = exit 2 + reason on stderr).
script="${1:-}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -x "$HOOK_DIR/$script" ] || exit 0
payload="$(cat)"
if command -v jq >/dev/null 2>&1; then
  case "$(jq -r '.permission_mode // empty' <<<"$payload" 2>/dev/null)" in
    bypassPermissions|dontAsk) export AGENT_DELEGATED_BY="${AGENT_DELEGATED_BY:-muse-unattended}" ;;
  esac
fi
exec bash "$HOOK_DIR/$script" <<<"$payload"
