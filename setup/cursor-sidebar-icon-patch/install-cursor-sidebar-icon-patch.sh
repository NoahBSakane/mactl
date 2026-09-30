#!/bin/bash
# Installs (or re-installs) the Claude Code / Codex Cursor sidebar-icon fix
# from this folder onto the current Mac. See ./cursor-claude-codex-sidebar-fix.md
# for what this does and why.
#
# Portable across any Mac/user account: the .plist is generated from
# com.nbs.cursor-sidebar-icon-patch.plist.template by substituting the __HOME__
# placeholder with this machine's actual $HOME at install time (launchd itself
# can't expand ~ or $HOME, so the template can't be installed as-is). The
# .sh script needs no such substitution — it already resolves everything via
# $HOME at runtime.
#
# Safe to re-run any time (e.g. after this Mac was reset, restoring from this
# repo, or setting up a different Mac/user account).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_DEST="$HOME/Library/Scripts/cursor-sidebar-icon-patch.sh"
PLIST_DEST="$HOME/Library/LaunchAgents/com.nbs.cursor-sidebar-icon-patch.plist"
LABEL="com.nbs.cursor-sidebar-icon-patch"

mkdir -p "$(dirname "$SCRIPT_DEST")" "$(dirname "$PLIST_DEST")"

cp "$SRC_DIR/cursor-sidebar-icon-patch.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
sed "s|__HOME__|$HOME|g" "$SRC_DIR/com.nbs.cursor-sidebar-icon-patch.plist.template" > "$PLIST_DEST"

UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DEST"
launchctl enable "gui/$UID_NUM/$LABEL"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "Installed:"
echo "  $SCRIPT_DEST"
echo "  $PLIST_DEST"
echo
echo "Log: ~/Library/Logs/cursor-sidebar-icon-patch.log"
echo
echo "Next: fully quit Cursor (Cmd+Q, not just close the window) and reopen it"
echo "for the patch to take effect. Also make sure Cmd+Option+U (Unified Sidebar)"
echo "is toggled OFF."
