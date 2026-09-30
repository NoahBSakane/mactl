#!/bin/bash
# Installs (or re-installs) the generic login-items runner from this folder
# onto the current Mac. See ./login-items-startup-scripts.md for what this
# does and why.
#
# Portable across any Mac/user account: the .plist is generated from
# com.nbs.login-items-runner.plist.template by substituting the __HOME__
# placeholder with this machine's actual $HOME at install time (launchd
# itself can't expand ~ or $HOME, so the template can't be installed as-is).
# run-login-items.sh needs no such substitution — it already resolves
# everything via $HOME at runtime.
#
# Note: this only installs the runner itself. Whatever scripts you had in
# ~/Library/Scripts/login-items.d/ on the old machine are NOT part of this
# repo and need to be copied over separately.
#
# Safe to re-run any time (e.g. after this Mac was reset, restoring from
# this repo, or setting up a different Mac/user account).

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCRIPT_DEST="$HOME/Library/Scripts/run-login-items.sh"
PLIST_DEST="$HOME/Library/LaunchAgents/com.nbs.login-items-runner.plist"
LABEL="com.nbs.login-items-runner"

mkdir -p "$(dirname "$SCRIPT_DEST")" "$(dirname "$PLIST_DEST")" "$HOME/Library/Scripts/login-items.d"

cp "$SRC_DIR/run-login-items.sh" "$SCRIPT_DEST"
chmod +x "$SCRIPT_DEST"
sed "s|__HOME__|$HOME|g" "$SRC_DIR/com.nbs.login-items-runner.plist.template" > "$PLIST_DEST"

UID_NUM=$(id -u)
launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST_DEST"
launchctl enable "gui/$UID_NUM/$LABEL"
launchctl kickstart -k "gui/$UID_NUM/$LABEL"

echo "Installed:"
echo "  $SCRIPT_DEST"
echo "  $PLIST_DEST"
echo "  $HOME/Library/Scripts/login-items.d/  (drop-in folder, created if missing)"
echo
echo "Log: ~/Library/Logs/login-items.log"
