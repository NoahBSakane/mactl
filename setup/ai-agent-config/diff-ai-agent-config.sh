#!/bin/bash
# Mechanical half of the "does the repo snapshot match this Mac's live
# AI-agent-config files?" check. Just diffs each of the 3 repo/live pairs and
# reports; makes no judgment about which side to keep. For the judgment half
# (decide which side wins, or synthesize both into one), see the
# reconcile-agent-config skill: ../../.claude/skills/reconcile-agent-config/SKILL.md
#
# ~/.claude/AGENTS.md is intentionally excluded: it's a symlink to ~/AGENTS.md,
# so it's identical to that pair by construction and has nothing to diff.
#
# Exit code: 0 if every pair is identical, 1 if at least one pair differs or
# a live-side file is missing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# repo path : live path
PAIRS=(
  "$REPO_ROOT/AGENTS.md:$HOME/AGENTS.md"
  "$REPO_ROOT/CLAUDE.md:$HOME/.claude/CLAUDE.md"
  "$REPO_ROOT/setup/ai-agent-config/codex-AGENTS.md:$HOME/.codex/AGENTS.md"
)

status=0
for pair in "${PAIRS[@]}"; do
  repo_file="${pair%%:*}"
  live_file="${pair#*:}"
  echo "=== $repo_file  <->  $live_file ==="
  if [ ! -f "$live_file" ]; then
    echo "(live側が見つかりません: $live_file)"
    status=1
  elif diff -q "$repo_file" "$live_file" >/dev/null 2>&1; then
    echo "差分なし"
  else
    diff -u "$repo_file" "$live_file"
    status=1
  fi
  echo
done

exit $status
