#!/bin/bash
# Keep three newest entries per kind, then retire entries older than STATE_KEEP_DAYS.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
python3 "$HOOK_DIR/state-history.py" prune "$@"
exit 0
