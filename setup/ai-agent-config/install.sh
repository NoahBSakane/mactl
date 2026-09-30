#!/bin/bash
# Installs (or re-installs) this Mac's AI coding agent config in full: the
# shared instruction files (AGENTS.md/CLAUDE.md/codex-AGENTS.md) plus the
# delegation-compliance Claude Code hooks. See ./ai-agent-config.md for what
# this does and why.
#
# Portable across any Mac/user account: everything below resolves through
# $HOME, no hardcoded paths. Safe to re-run any time.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SRC_DIR/../.." && pwd)"
CLAUDE_DIR="$HOME/.claude"

# ---------------------------------------------------------------------------
# Part 1: instruction files (AGENTS.md / CLAUDE.md / codex-AGENTS.md)
#
# ~/AGENTS.md is the source of truth for rules common to both tools. Claude
# Code can `@AGENTS.md`-import it directly, so ~/.claude/AGENTS.md is made a
# symlink to ~/AGENTS.md instead of a copy. Codex CLI has no import
# mechanism, so ~/.codex/AGENTS.md stays a real file that must duplicate the
# common rules by hand.
#
# These 3 files are fully owned by this repo, so they're overwritten without
# backup on every run. If you've made machine-local edits directly to the
# live files since the last snapshot, copy them back into this repo first or
# you'll lose them.
# ---------------------------------------------------------------------------

mkdir -p "$HOME/.claude" "$HOME/.codex"

cp "$REPO_ROOT/AGENTS.md" "$HOME/AGENTS.md"
cp "$REPO_ROOT/CLAUDE.md" "$CLAUDE_DIR/CLAUDE.md"
cp "$SRC_DIR/codex-AGENTS.md" "$HOME/.codex/AGENTS.md"
ln -sf "$HOME/AGENTS.md" "$CLAUDE_DIR/AGENTS.md"

echo "Installed:"
echo "  $HOME/AGENTS.md"
echo "  $CLAUDE_DIR/AGENTS.md  -> symlink to ~/AGENTS.md"
echo "  $CLAUDE_DIR/CLAUDE.md"
echo "  $HOME/.codex/AGENTS.md"
echo
echo "Note: ~/AGENTS.md and ~/.codex/AGENTS.md must be kept in sync by hand"
echo "going forward (Codex CLI can't import files, so the common rules are"
echo "duplicated, not shared)."

# ---------------------------------------------------------------------------
# Part 2: delegation-compliance hooks
#
# Unlike the 3 files above, ~/.claude/settings.json is NOT fully owned by
# this repo (it also holds the user's own model/permissions/etc.), so it is
# merged rather than overwritten, and backed up first.
# ---------------------------------------------------------------------------

HOOK_SRC_DIR="$SRC_DIR/hooks"
HOOK_DEST_DIR="$CLAUDE_DIR/hooks/delegation"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
FRAGMENT_FILE="$HOOK_SRC_DIR/hooks-fragment.json"

command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 1
}

hook_scripts=(
  user-prompt-delegation-reminder.sh
  pre-edit-composition-check.sh
  post-tool-delegation-logger.sh
  delegation-status.sh
)

for script in "${hook_scripts[@]}"; do
  [ -f "$HOOK_SRC_DIR/$script" ] || {
    echo "Missing source: $HOOK_SRC_DIR/$script" >&2
    exit 1
  }
done
jq empty "$FRAGMENT_FILE"

umask 077
mkdir -p "$HOOK_DEST_DIR"
for script in "${hook_scripts[@]}"; do
  cp "$HOOK_SRC_DIR/$script" "$HOOK_DEST_DIR/$script"
  chmod 0755 "$HOOK_DEST_DIR/$script"
done

if [ -f "$SETTINGS_FILE" ]; then
  timestamp="$(date '+%Y%m%d%H%M%S')"
  backup_file="$SETTINGS_FILE.bak.$timestamp"
  suffix=0
  while [ -e "$backup_file" ]; do
    suffix=$((suffix + 1))
    backup_file="$SETTINGS_FILE.bak.$timestamp.$suffix"
  done
  cp "$SETTINGS_FILE" "$backup_file"
fi

current_file="$(mktemp "$CLAUDE_DIR/settings.json.current.XXXXXX")"
merged_file="$(mktemp "$CLAUDE_DIR/settings.json.merged.XXXXXX")"
cleanup() {
  rm -f "$current_file" "$merged_file"
}
trap cleanup EXIT

if [ -f "$SETTINGS_FILE" ]; then
  cp "$SETTINGS_FILE" "$current_file"
else
  printf '{}\n' >"$current_file"
fi

jq --slurpfile fragment "$FRAGMENT_FILE" '
  def hook_equal($left; $right):
    (($left.type // null) == ($right.type // null)) and
    (($left.command // null) == ($right.command // null)) and
    (($left.prompt // null) == ($right.prompt // null));

  def matcher_equal($left; $right):
    (($left.matcher // "") == ($right.matcher // ""));

  def add_hook_group($groups; $incoming):
    if any($groups[]?; matcher_equal(.; $incoming)) then
      reduce (($incoming.hooks // [])[]) as $hook (
        $groups;
        if any(.[]?;
          matcher_equal(.; $incoming) and
          any((.hooks // [])[]?; hook_equal(.; $hook))
        ) then
          .
        else
          ([to_entries[] | select(matcher_equal(.value; $incoming)) | .key] | first) as $index
          | .[$index].hooks = ((.[$index].hooks // []) + [$hook])
        end
      )
    else
      $groups + [$incoming]
    end;

  reduce ($fragment[0].hooks | to_entries[]) as $event (
    .;
    .hooks = (.hooks // {})
    | .hooks[$event.key] = (
        reduce ($event.value[]) as $group (
          (.hooks[$event.key] // []);
          add_hook_group(.; $group)
        )
      )
  )
' "$current_file" >"$merged_file"

jq empty "$merged_file"
mv "$merged_file" "$SETTINGS_FILE"

echo
echo "Installed delegation hooks:"
for script in "${hook_scripts[@]}"; do
  echo "  $HOOK_DEST_DIR/$script"
done
echo "Merged hooks into:"
echo "  $SETTINGS_FILE"
