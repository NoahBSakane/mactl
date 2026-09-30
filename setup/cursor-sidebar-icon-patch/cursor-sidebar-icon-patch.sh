#!/bin/bash
# Forces the Claude Code and Codex (openai.chatgpt) Cursor extensions to register
# their sidebar icon in the primary Activity Bar (next to Explorer/Search/Source
# Control) instead of the secondary/auxiliary sidebar.
#
# Both extensions gate this via a bundled version check against the host editor's
# reported VS Code API version (>= 1.106 => secondary sidebar). Cursor reports a
# version that satisfies this, so without patching, both icons always end up in
# the secondary sidebar. This script neutralizes that check in the minified
# extension bundle via regex (see comment below), not exact-string matching.
# Idempotent: safe to re-run (skips already-patched files, re-patches after an
# extension auto-update replaces the bundle).
#
# Triggered by com.nbs.cursor-sidebar-icon-patch.plist (LaunchAgent):
#   - RunAtLoad: every login/restart
#   - WatchPaths on ~/.cursor/extensions: fires again shortly after Cursor
#     auto-updates either extension, before the patch would otherwise be lost.

set -uo pipefail

LOG="$HOME/Library/Logs/cursor-sidebar-icon-patch.log"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# Both extensions' version-gate code survives extension updates structurally intact
# but with its minified identifiers (variable / function / helper names) renamed by
# the bundler each build -- that's what silently broke the old exact-string patch_file
# helper this script used to call for both extensions (Codex: 803.61601 -> 810.41047
# on 2026-08-14; Claude Code: 2.1.241 -> 2.1.243 on 2026-08-25). Both patch_* functions
# below instead match the *shape* of the gate via regex, capturing whatever the current
# identifiers are, so a future rename alone won't break them again (only a genuine
# logic change would). Idempotency is tracked via an inline marker comment rather than
# exact-string before/after matching, since the "after" text also depends on the
# captured names.
MARKER="/*cursor-sidebar-icon-patch*/"

# Claude Code's gate computes `<major>>1||<major>===1&&<minor>>=106` (true => host
# supports the secondary sidebar => icon goes there) and assigns it to a result var,
# e.g. `let U=g0.version.split(".").map(Number),H=U[0]??0,B=U[1]??0,N=H>1||H===1&&B>=106;`.
# We force just the trailing `<result>=<major>>1||<major>===1&&<minor>>=106;` assignment
# to `<result>=!1;`, leaving the version-parsing lines untouched.
patch_claude_code() {
  local label="Claude Code" file="$1"

  if [ ! -f "$file" ]; then
    log "[$label] SKIP: file not found: $file"
    return 1
  fi

  local backup="$file.bak-$(date +%Y%m%d%H%M%S)"
  local status
  status=$(python3 - "$file" "$backup" "$MARKER" <<'PYEOF'
import re, sys
path, backup, MARKER = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

if MARKER in content:
    print("ALREADY_PATCHED")
    sys.exit(0)

pattern = re.compile(r"(\w+)=(\w+)>1\|\|\2===1&&(\w+)>=106;")
matches = list(pattern.finditer(content))
if len(matches) != 1:
    print(f"NOT_FOUND:{len(matches)}")
    sys.exit(1)

m = matches[0]
result_var = m.group(1)
replacement = f"{result_var}={MARKER}!1;"
new_content = content[:m.start()] + replacement + content[m.end():]

with open(backup, "w", encoding="utf-8") as f:
    f.write(content)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
print(f"PATCHED:{result_var}")
PYEOF
  )

  case "$status" in
    PATCHED:*)
      log "[$label] PATCHED (var ${status#PATCHED:} forced to !1): $file (backup: $backup)"
      ;;
    ALREADY_PATCHED)
      rm -f "$backup"
      log "[$label] OK: already patched: $file"
      ;;
    NOT_FOUND:*)
      rm -f "$backup"
      log "[$label] WARN: target pattern not found (extension internals may have changed, matches=${status#NOT_FOUND:}): $file"
      ;;
    *)
      rm -f "$backup"
      log "[$label] ERROR: unexpected patch result ('$status'): $file"
      ;;
  esac
}
patch_codex() {
  local label="Codex" file="$1"

  if [ ! -f "$file" ]; then
    log "[$label] SKIP: file not found: $file"
    return 1
  fi

  local backup="$file.bak-$(date +%Y%m%d%H%M%S)"
  local status
  status=$(python3 - "$file" "$backup" "$MARKER" <<'PYEOF'
import re, sys
path, backup, MARKER = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()

if MARKER in content:
    print("ALREADY_PATCHED")
    sys.exit(0)

pattern = re.compile(
    r"function (\w+)\(t\)\{let e=(\w+)\(t\);"
    r"return e==null\?!1:e\.major!==(\w+)\.major\?e\.major>\3\.major:e\.minor>=\3\.minor\}"
)
matches = list(pattern.finditer(content))
if len(matches) != 1:
    print(f"NOT_FOUND:{len(matches)}")
    sys.exit(1)

m = matches[0]
fn = m.group(1)
replacement = f"function {fn}(t){{return {MARKER}!1}}"
new_content = content[:m.start()] + replacement + content[m.end():]

with open(backup, "w", encoding="utf-8") as f:
    f.write(content)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
print(f"PATCHED:{fn}")
PYEOF
  )

  case "$status" in
    PATCHED:*)
      log "[$label] PATCHED (function ${status#PATCHED:} forced to return false): $file (backup: $backup)"
      ;;
    ALREADY_PATCHED)
      rm -f "$backup"
      log "[$label] OK: already patched: $file"
      ;;
    NOT_FOUND:*)
      rm -f "$backup"
      log "[$label] WARN: target pattern not found (extension internals may have changed, matches=${status#NOT_FOUND:}): $file"
      ;;
    *)
      rm -f "$backup"
      log "[$label] ERROR: unexpected patch result ('$status'): $file"
      ;;
  esac
}

CC_DIR=$(ls -d "$HOME/.cursor/extensions/anthropic.claude-code-"* 2>/dev/null | sort -V | tail -1)
OA_DIR=$(ls -d "$HOME/.cursor/extensions/openai.chatgpt-"* 2>/dev/null | sort -V | tail -1)

if [ -n "$CC_DIR" ]; then
  patch_claude_code "$CC_DIR/extension.js"
else
  log "[Claude Code] SKIP: extension directory not found"
fi

if [ -n "$OA_DIR" ]; then
  patch_codex "$OA_DIR/out/extension.js"
else
  log "[Codex] SKIP: extension directory not found"
fi

log "run complete"
