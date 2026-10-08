# Shared helpers for the agent hooks. Sourced by the other scripts; never executed.
#
# Contract: these hooks are speed bumps, not security gates. Any internal error
# (missing jq, malformed payload, parser crash) must FAIL OPEN. The only way to
# block a tool call is the explicit `deny` helper below (exit 2 + reason on
# stderr), which is the deny contract shared by Claude Code, Codex, Grok and Muse.

AGENT_STATE_DIR="${AGENT_STATE_DIR:-$HOME/.agent-state}"
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

trap 'exit 0' ERR

hook_read_payload() {
  command -v jq >/dev/null 2>&1 || exit 0
  PAYLOAD="$(cat)" || exit 0
  jq -e . >/dev/null 2>&1 <<<"$PAYLOAD" || exit 0
  SESSION_ID="$(jget .session_id)"
}

# jget '<jq path>' -> raw string, empty when null/absent
jget() { jq -r "($1) // empty" <<<"$PAYLOAD" 2>/dev/null || true; }

safe_id() { printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9._-]/_/g'; }

now_epoch() { date +%s; }

session_dir() {
  local d="$AGENT_STATE_DIR/sessions/$(safe_id "$SESSION_ID")"
  mkdir -p "$d" 2>/dev/null || exit 0
  printf '%s' "$d"
}

# One key per user prompt: Claude prompt_id, Codex/Muse turn_id, else our own counter.
turn_key() {
  local k
  k="$(jget '.prompt_id // .turn_id')"
  if [ -z "$k" ]; then k="$(cat "$(session_dir)/prompt_count" 2>/dev/null || echo 0)"; fi
  printf '%s' "$k"
}

deny() { printf '%s\n' "$1" >&2; exit 2; }

ofuro_file() { printf '%s' "$AGENT_STATE_DIR/ofuro/$(safe_id "$SESSION_ID").json"; }

# True when /ofuro is active *for this session* and not expired.
ofuro_active() {
  local f u
  f="$(ofuro_file)"
  [ -f "$f" ] || return 1
  u="$(jq -r '.until_epoch // 0' "$f" 2>/dev/null)" || return 1
  [ "${u:-0}" -gt "$(now_epoch)" ] 2>/dev/null
}

# agents.conf lookups (see agents.conf): no agent is named in any script.
conf() { python3 "$HOOK_DIR/agentconf.py" "$@" 2>/dev/null || true; }
tool_class() { conf toolclass "$1"; }   # shell | edit | subagent | other
is_shell_tool() { [ "$(tool_class "$1")" = shell ]; }
# a command may arrive as a string or as an argv array (Codex): both become one line
tool_command() { jq -r '(.tool_input.command // .tool_input.CommandLine // .tool_input.cmd // .tool_input.script // empty) | if type == "array" then map(@sh) | join(" ") else . end' <<<"$PAYLOAD" 2>/dev/null || true; }

# Agents (agents.conf sections) launched by an executing command in a shell command line, one per line.
classify_bash() { printf '%s' "$1" | python3 "$HOOK_DIR/parse_cmd.py" cmd 2>/dev/null || true; }

# Files an edit-class tool call touches, one per line (Claude/agy/Muse path fields and Codex apply_patch headers).
edit_paths() {
  {
    jget .tool_input.file_path
    jget .tool_input.notebook_path
    jget .tool_input.path
    jget .tool_input.TargetFile
    jget .tool_input.target_file
    jq -r '[.tool_input | .. | strings] | join("\n")' <<<"$PAYLOAD" \
      | sed -nE 's/^\*\*\* (Update|Add|Delete|Move to) File: //p'
  } | sed '/^$/d'
}

# secret_hit <text> -> the first secret-looking string in the text (empty when none)
secret_hit() {
  local p hit
  for p in \
    'AKIA[0-9A-Z]{16}' \
    'gh[pousr]_[A-Za-z0-9]{36,}' \
    'github_pat_[A-Za-z0-9_]{40,}' \
    'sk-[A-Za-z0-9_-]{20,}' \
    'xox[abprs]-[A-Za-z0-9-]{10,}' \
    'AIza[0-9A-Za-z_-]{35}' \
    '-----BEGIN [A-Z ]*PRIVATE KEY-----' \
    '(api[_-]?key|secret|token|passw(or)?d)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*["'\'']?[A-Za-z0-9/+_.-]{16,}'; do
    hit="$(printf '%s' "$1" | grep -oEi -m1 -- "$p" | head -1 || true)"
    if [ -n "$hit" ]; then printf '%s' "$hit"; return 0; fi
  done
  return 0
}
