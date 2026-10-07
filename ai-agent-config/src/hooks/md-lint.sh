#!/bin/bash
# PostToolUse: after an agent writes a Markdown file, lint it (md-lint.py: markdownlint, MD013 is
# not applied to Japanese lines). Findings go back to the agent as stderr with exit 2 so it fixes
# them in the same turn. Not a gate: the file is already written, and any trouble (no linter,
# offline, timeout) passes silently.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
hook_read_payload
[ -z "${AGENT_JOB:-}" ] || exit 0
[ "$(tool_class "$(jget .tool_name)")" = edit ] || exit 0
files="$(edit_paths | grep -E '\.md$' || true)"
[ -n "$files" ] || exit 0
# scratch / state / memory locations are not the user's documents
[ "$(printf '%s\n' "$files" | python3 "$HOOK_DIR/parse_cmd.py" editcheck "$(jget .scratchpad_dir)" 2>/dev/null || true)" != skip ] || exit 0
# shellcheck disable=SC2086
res="$(printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 python3 "$HOOK_DIR/md-lint.py" 2>/dev/null)" || {
  [ -z "$res" ] || deny "【markdownlint の指摘】編集したMarkdownに指摘があります。同じ作業の中で直してください(MD013は日本語を含む行には適用しません)。
$res"
}
exit 0
