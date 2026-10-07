#!/bin/bash
# memory-harvest.sh - which agent memory files are new or changed since the last harvest?
#
# Agents keep private memory (e.g. an auto memory or a notes folder). Preferences and corrections
# that should change how agents behave belong in the shared rules - after review. This only finds
# *what to look at*; the triage-rules skill reads the files and turns the relevant parts into
# proposals. Memory itself is never managed, copied or edited.
# Where each agent keeps its memory is data: the `memory` key of every [section] in agents.conf.
#
#   memory-harvest.sh            list new/changed memory files: agent, status, path
#   memory-harvest.sh --count    print only the number of new/changed files
#   memory-harvest.sh --mark     record the current content as harvested
set -uo pipefail
STATE="${AGENT_STATE_DIR:-$HOME/.agent-state}"
HOOKS="${AGENTS_HOOKS_DIR:-$HOME/.agents/hooks}"
TSV="$STATE/harvest.tsv"
mkdir -p "$STATE" 2>/dev/null || true
hash_of() { shasum -a 256 <"$1" | cut -d' ' -f1; }

mode="${1:-list}"
changed=0; current="$(mktemp)"
while IFS=$'\t' read -r agent path; do
  [ -n "$path" ] || continue
  h="$(hash_of "$path")"
  printf '%s\t%s\n' "$path" "$h" >>"$current"
  old="$(awk -F'\t' -v p="$path" '$1==p{print $2}' "$TSV" 2>/dev/null | tail -1)"
  if [ -z "$old" ]; then st=new; elif [ "$old" != "$h" ]; then st=changed; else continue; fi
  changed=$((changed+1))
  [ "$mode" = list ] && printf '%s\t%s\t%s\n' "$agent" "$st" "$path"
done < <(AGENTS_CONF="${AGENTS_CONF:-$HOOKS/agents.conf}" python3 "$HOOKS/agentconf.py" memory-files 2>/dev/null)

case "$mode" in
  --count) echo "$changed" ;;
  --mark) mv "$current" "$TSV"; echo "収穫済みにしました($(wc -l <"$TSV" | tr -d ' ')件)"; exit 0 ;;
  list) [ "$changed" -gt 0 ] || echo "(新しい・変わったメモリはありません)" ;;
esac
rm -f "$current"
exit 0
