#!/bin/bash
# PostToolUse(edit tools): when an agent writes into a `.agent-handoff/` folder, make sure that folder is
# kept out of Git (handoff-exclude.sh adds it to .git/info/exclude). Never blocks.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
[ "$(tool_class "$(jget .tool_name)")" = edit ] || exit 0
edit_paths | while IFS= read -r p; do
  p="${p/#\~/$HOME}"
  case "$p" in
    */.agent-handoff/*) bash "$HOOK_DIR/handoff-exclude.sh" "${p%%/.agent-handoff/*}" ;;
  esac
done
exit 0
