# Shared by install.sh and diff-ai-agent-config.sh. Sourced, not executed. Bash 3.2 safe.
#
# Row status (live vs what the repo wants):
#   OK       live already matches
#   MISSING  nothing deployed yet
#   UPDATE   repo changed; live still equals what install last wrote -> safe to overwrite
#   ERROR    the merge cannot be computed (e.g. a config we must not overwrite); never applied
#   DRIFT    live differs from both the repo and what install last wrote, i.e. someone edited
#            the live file. Never overwritten without --force (reconcile first).
#   SKIP     condition not met (CLI not installed)

CFG_DIR="${CFG_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
MANIFEST="${MANIFEST:-$CFG_DIR/manifest.tsv}"
STATE_DIR="${AGENT_STATE_DIR:-$HOME/.agent-state}"
RECORD="$STATE_DIR/installed.tsv"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ai-agent-config.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

expand() { # ~ expansion; bare relative paths are relative to ai-agent-config/
  local p="$1"; p="${p/#\~/$HOME}"
  case "$p" in /*) ;; *) p="$CFG_DIR/$p" ;; esac
  printf '%s' "$p"
}
cond_ok() { case "$1" in always) return 0 ;; cmd:*) command -v "${1#cmd:}" >/dev/null 2>&1 ;; *) return 1 ;; esac }
sha() { shasum -a 256 | cut -d' ' -f1; }

hash_path() {
  local p="$1"
  if [ -L "$p" ]; then echo "link:$(readlink "$p")"
  elif [ -f "$p" ]; then sha <"$p"
  elif [ -d "$p" ]; then
    (cd "$p" && find . -type f | LC_ALL=C sort | while read -r f; do printf '%s %s\n' "$f" "$(sha <"$f")"; done) | sha
  else echo absent; fi
}

recorded_hash() { [ -f "$RECORD" ] && awk -F'\t' -v id="$1" '$1==id{h=$2} END{print h}' "$RECORD" || true; }
record_hash() {
  mkdir -p "$STATE_DIR"; touch "$RECORD"
  grep -v "^$1	" "$RECORD" >"$RECORD.tmp" 2>/dev/null || true
  printf '%s\t%s\n' "$1" "$2" >>"$RECORD.tmp"; mv "$RECORD.tmp" "$RECORD"
}

# jq program: drop every hook entry we manage (old and new locations), then add the fragment's.
MERGE_JQ='
  def managed: ((.command // "") | test("(\\$HOME|~|/Users/[^/]+)/(\\.claude/hooks/delegation|\\.agents/hooks)/"));
  .hooks = (.hooks // {})
  | .hooks |= with_entries(.value |= (map(.hooks |= map(select(managed | not))) | map(select((.hooks | length) > 0))))
  | .hooks |= with_entries(select(.value | length > 0))
  | reduce ($frag[0].hooks | to_entries[]) as $e (.; .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value))'
UNMERGE_JQ='
  def managed: ((.command // "") | test("(\\$HOME|~|/Users/[^/]+)/(\\.claude/hooks/delegation|\\.agents/hooks)/"));
  .hooks = (.hooks // {})
  | .hooks |= with_entries(.value |= (map(.hooks |= map(select(managed | not))) | map(select((.hooks | length) > 0))))
  | .hooks |= with_entries(select(.value | length > 0))
  | if (.hooks | length) == 0 then del(.hooks) else . end'

# merge-union: the fragment's values are added without removing what is already there - arrays are
# unioned (an entry the user persisted stays), objects are merged key by key, scalars are set.
# Unmerging takes exactly the fragment's entries out again (and drops objects left empty).
UNION_JQ='def u(a; b): if (a|type)=="object" and (b|type)=="object" then reduce (b|keys_unsorted[]) as $k (a; .[$k] = (if has($k) then u(.[$k]; b[$k]) else b[$k] end))
  elif (a|type)=="array" and (b|type)=="array" then a + (b - a) else b end;
  u(.; $frag[0])'
UNION_UNJQ='def x(a; b): if (a|type)=="object" and (b|type)=="object" then reduce (b|keys_unsorted[]) as $k (a; if has($k) then (.[$k] = x(.[$k]; b[$k])) | (if (.[$k]|type)=="object" and (.[$k]|length)==0 or (.[$k]|type)=="array" and (.[$k]|length)==0 then del(.[$k]) else . end) else . end)
  elif (a|type)=="array" and (b|type)=="array" then a - b else a end;
  x(.; $frag[0])'

# agy's skills.json accepts absolute paths only (it logs "must be an absolute path" for ~/...),
# so the registered path is the expanded one; an earlier "~/.agents/skills" entry is dropped.
AGY_SKILLS_PATH="$HOME/.agents/skills"
AGY_SKILLS_JQ='.entries = ((.entries // []) | map(select(.path != "~/.agents/skills")) | if any(.[]; .path == $p) then . else . + [{path:$p}] end)'

# Muse imports ~/.claude/CLAUDE.md (else ~/.codex/AGENTS.md) and the skills of other agents as
# "foreign personal context" by default, and it does not resolve @AGENTS.md imports. We switch
# that off and give Muse its own ~/.config/muse/AGENTS.md (the shared rules) instead.
MUSE_CTX_JQ='.context = ((.context // {}) + {foreign_personal_rules: false, foreign_personal_skills: false})'
MUSE_CTX_UNJQ='del(.context.foreign_personal_rules, .context.foreign_personal_skills) | if ((.context // {}) | length) == 0 then del(.context) else . end'

unmerge_json() { # mode file [id] -> the file's JSON with our entries removed (merge-union reads the fragment of row <id>)
  case "$1" in
    merge-hooks) jq "$UNMERGE_JQ" "$2" ;;
    merge-agy-hooks) jq 'del(.["ai-agent-config"])' "$2" ;;
    merge-agy-skills) jq --arg p "$AGY_SKILLS_PATH" '.entries = ((.entries // []) | map(select(.path != $p and .path != "~/.agents/skills")))' "$2" ;;
    merge-muse-context) jq "$MUSE_CTX_UNJQ" "$2" ;;
    merge-codex-persona) python3 "$CFG_DIR/toml-block.py" remove "$2" ;;
    merge-union) jq --slurpfile frag "$(expand "$(awk -F'\t' -v id="$3" '$1==id{print $3}' "$MANIFEST")")" "$UNION_UNJQ" "$2" ;;
    merge-enforce) cat "$2" ;;   # enforced values are not taken back on rollback (the old values are in the backup file)
  esac
}

SHIMS="user-prompt-delegation-reminder.sh:reminder.sh pre-edit-composition-check.sh:gate.sh post-tool-delegation-logger.sh:logger.sh delegation-status.sh:status.sh scope-discipline-reminder.sh:-"

build_shims() { # $1 = output dir
  mkdir -p "$1"; local pair name target
  for pair in $SHIMS; do
    name="${pair%%:*}"; target="${pair#*:}"
    if [ "$target" = "-" ]; then
      printf '#!/bin/bash\n# legacy shim (ai-agent-config): this reminder now lives in ~/.agents/hooks/reminder.sh\nexit 0\n' >"$1/$name"
    else
      printf '#!/bin/bash\n# legacy shim (ai-agent-config): the hook moved to ~/.agents/hooks/%s\nexec "$HOME/.agents/hooks/%s" "$@"\n' "$target" "$target" >"$1/$name"
    fi
    chmod 755 "$1/$name"
  done
}

# build_desired ID MODE SRC DEST -> prints the hash the live path should have; the artifact is
# left in $WORK/ID so apply_row can install exactly what was hashed.
build_desired() {
  local id="$1" mode="$2" src="$3" dest="$4" out="$WORK/$1" a b
  case "$mode" in
    copy|seed) cp -p "$(expand "$src")" "$out"; hash_path "$out" ;;
    copydir) cp -a "$(expand "$src")" "$out"; hash_path "$out" ;;
    link) echo "link:$(expand "$src")" ;;
    shims) build_shims "$out"; hash_path "$out" ;;
    merge-codex-persona)
      local cur="$dest"; [ -f "$cur" ] || { : >"$WORK/empty.toml"; cur="$WORK/empty.toml"; }
      python3 "$CFG_DIR/toml-block.py" apply "$cur" "$(expand "$src")" >"$out" 2>"$WORK/$id.err" || { echo "merge-error"; return; }
      sha <"$out" ;;
    merge-hooks|merge-agy-hooks|merge-agy-skills|merge-muse-context|merge-enforce|merge-union)
      local cur="$dest"; [ -f "$cur" ] || { echo '{}' >"$WORK/empty.json"; cur="$WORK/empty.json"; }
      case "$mode" in
        merge-hooks) jq --slurpfile frag "$(expand "$src")" "$MERGE_JQ" "$cur" ;;
        merge-agy-hooks) jq --slurpfile frag "$(expand "$src")" '.["ai-agent-config"] = $frag[0]' "$cur" ;;
        merge-agy-skills) jq --arg p "$AGY_SKILLS_PATH" "$AGY_SKILLS_JQ" "$cur" ;;
        merge-muse-context) jq "$MUSE_CTX_JQ" "$cur" ;;
        merge-union) jq --slurpfile frag "$(expand "$src")" "$UNION_JQ" "$cur" ;;
        merge-enforce) jq --slurpfile frag "$(expand "$src")" '. * $frag[0]' "$cur" ;;   # repo values win; keys the fragment does not mention are left alone
      esac >"$out" 2>/dev/null || { echo "merge-error"; return; }
      jq -S . "$out" | sha ;;
    *) echo "unknown-mode" ;;
  esac
}

live_hash() { # canonical hash of the live artifact, comparable with build_desired
  local mode="$1" dest="$2"
  case "$mode" in
    merge-codex-persona) [ -f "$dest" ] && sha <"$dest" || echo absent ;;
    merge-*) [ -f "$dest" ] && jq -S . "$dest" 2>/dev/null | sha || echo absent ;;
    *) hash_path "$dest" ;;
  esac
}

# row_status ID MODE SRC DEST COND -> sets ST and WANT
row_status() {
  local id="$1" mode="$2" src="$3" dest="$4" cond="$5" live last
  if ! cond_ok "$cond"; then ST=SKIP; WANT=""; return; fi
  WANT="$(build_desired "$id" "$mode" "$src" "$dest")"
  if [ "$WANT" = "merge-error" ] || [ "$WANT" = "unknown-mode" ]; then ST=ERROR; return; fi
  live="$(live_hash "$mode" "$dest")"
  if [ "$mode" = seed ]; then [ -e "$dest" ] && ST=OK || ST=MISSING; return; fi
  if [ "$live" = absent ]; then ST=MISSING
  elif [ "$live" = "$WANT" ]; then ST=OK
  elif [[ "$mode" == merge-* ]]; then ST=UPDATE      # merged in place; other keys are never touched
  else
    last="$(recorded_hash "$id")"
    if [ -n "$last" ] && [ "$live" = "$last" ]; then ST=UPDATE; else ST=DRIFT; fi
  fi
}

each_row() { # calls: "$1" id mode src dest(expanded) cond flags
  local cb="$1" id mode src dest cond flags
  while IFS=$'\t' read -r id mode src dest cond flags; do
    case "$id" in ''|\#*) continue ;; esac
    "$cb" "$id" "$mode" "$src" "$(expand "$dest")" "$cond" "${flags:-}"
  done <"$MANIFEST"
}
