#!/bin/bash
# Keep handoff records out of Git. Hook failures must never block other work.
main() {
  local dir="${1:-.}" prefix exclude pattern rc last separator=""
  command -v git >/dev/null 2>&1 || return
  [ -d "$dir/.agent-handoff" ] || return
  [ "$(git -C "$dir" rev-parse --is-inside-work-tree)" = true ] || return

  git -C "$dir" check-ignore -q .agent-handoff/
  rc=$?
  [ "$rc" -ne 0 ] || return
  [ "$rc" -eq 1 ] || return

  prefix=$(git -C "$dir" rev-parse --show-prefix) || return
  # Gitignore is line-based; do not write an ambiguous multiline pattern.
  case "$prefix" in *$'\n'*) return ;; esac
  prefix=${prefix//\\/\\\\}
  prefix=${prefix//\*/\\*}
  prefix=${prefix//\?/\\?}
  prefix=${prefix//\[/\\[}
  pattern="/${prefix}.agent-handoff/"
  exclude=$(git -C "$dir" rev-parse --git-path info/exclude) || return
  [ -n "$exclude" ] || return
  case "$exclude" in /*) ;; *) exclude="$dir/$exclude" ;; esac
  mkdir -p "$(dirname "$exclude")" || return
  if [ -e "$exclude" ]; then
    [ -f "$exclude" ] || return
    grep -Fqx -- "$pattern" "$exclude"
    rc=$?
    [ "$rc" -ne 0 ] || return
    [ "$rc" -eq 1 ] || return
  fi
  if [ -s "$exclude" ]; then
    last=$(tail -c 1 "$exclude") || return
    [ -z "$last" ] || separator=$'\n'
  fi
  printf '%s%s\n' "$separator" "$pattern" >>"$exclude"
}

main "$@" >/dev/null 2>&1
exit 0
