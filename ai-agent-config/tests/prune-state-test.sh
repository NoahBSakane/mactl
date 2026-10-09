#!/bin/bash
# Independent HOME, deterministic mtimes, and three kinds of state artifacts.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home" AGENT_STATE_DIR="$TEST_TMP/state"
mkdir -p "$HOME" "$AGENT_STATE_DIR/backups" "$AGENT_STATE_DIR/changes"
python3 - "$AGENT_STATE_DIR" <<'PY'
import datetime
import os
from pathlib import Path
import subprocess
import sys
state = Path(sys.argv[1])
for n in range(6):
    deployment = state / 'backups' / f'2026010100000{n}'
    deployment.mkdir()
    (deployment / 'applied.tsv').write_text('fixture\n')
    registry = state / 'backups' / f'ai-agents-20260101-00000{n}.md'
    registry.write_text('fixture\n')
    diff = state / 'changes' / f'registry-2026010{n + 1}.diff'
    diff.write_text('fixture\n')
    # Names encode creation time; n=1 has a recent modification outside the newest three.
    age = 2 if n == 1 else 10
    moment = datetime.datetime.now() - datetime.timedelta(days=age, minutes=6-n)
    for path in (deployment, registry, diff):
        subprocess.run(['touch', '-t', moment.strftime('%Y%m%d%H%M.%S'), str(path)], check=True)
(state / 'backups' / 'unrelated').mkdir()
(state / 'changes' / 'other.diff').write_text('untouched')
PY
bash "$HERE/../src/hooks/prune-state.sh" --dry-run >"$TEST_TMP/dry"
[ "$(find "$AGENT_STATE_DIR/backups" -type d -name '2026*' | wc -l | tr -d ' ')" = 6 ]
[ ! -e "$AGENT_STATE_DIR/CHANGELOG.md" ]
bash "$HERE/../src/hooks/prune-state.sh"
[ "$(find "$AGENT_STATE_DIR/backups" -type d -name '2026*' | wc -l | tr -d ' ')" = 4 ]
[ "$(find "$AGENT_STATE_DIR/backups" -type f -name 'ai-agents-*.md' | wc -l | tr -d ' ')" = 4 ]
[ "$(find "$AGENT_STATE_DIR/changes" -type f -name 'registry-*.diff' | wc -l | tr -d ' ')" = 4 ]
grep -q '退避を整理: 配備の退避2件・台帳の退避2件・差分2件' "$AGENT_STATE_DIR/CHANGELOG.md"
[ -d "$AGENT_STATE_DIR/backups/20260101000001" ]
[ -d "$AGENT_STATE_DIR/backups/20260101000005" ]
[ -d "$AGENT_STATE_DIR/backups/unrelated" ]; [ -f "$AGENT_STATE_DIR/changes/other.diff" ]
lines=$(wc -l <"$AGENT_STATE_DIR/CHANGELOG.md")
bash "$HERE/../src/hooks/prune-state.sh"
[ "$(wc -l <"$AGENT_STATE_DIR/CHANGELOG.md")" = "$lines" ]
# With no recent entries, all three newest old entries must survive.
export AGENT_STATE_DIR="$TEST_TMP/old-only"
mkdir -p "$AGENT_STATE_DIR/backups"
for n in 1 2 3 4; do
  mkdir "$AGENT_STATE_DIR/backups/2026010100000$n"
  touch -t "20260101000$n.00" "$AGENT_STATE_DIR/backups/2026010100000$n"
done
STATE_KEEP_DAYS=10000 bash "$HERE/../src/hooks/prune-state.sh"
[ -d "$AGENT_STATE_DIR/backups/20260101000001" ]
[ ! -e "$AGENT_STATE_DIR/CHANGELOG.md" ]
bash "$HERE/../src/hooks/prune-state.sh"
[ ! -d "$AGENT_STATE_DIR/backups/20260101000001" ]
for n in 2 3 4; do [ -d "$AGENT_STATE_DIR/backups/2026010100000$n" ]; done
# Invalid retention settings fail open and delete nothing.
STATE_KEEP_DAYS=invalid bash "$HERE/../src/hooks/prune-state.sh" 2>/dev/null
[ -d "$AGENT_STATE_DIR/backups/20260101000002" ]
echo 'prune-state: 全検証パス'
