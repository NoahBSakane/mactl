#!/bin/zsh
set -eu

repo_root="${0:A:h}"
destination="$HOME/.local/bin/mactl"
mkdir -p "$HOME/.local/bin"

if [[ ! -L "$destination" && -e "$destination" ]]; then
  if [[ ! -f "$destination" ]]; then
    print -u2 "Refusing to replace a non-file: $destination"
    exit 1
  fi
  backup="$destination.bak.$(date '+%Y%m%d%H%M%S')"
  candidate="$backup"
  suffix=0
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    (( ++suffix ))
    candidate="$backup.$suffix"
  done
  mv -- "$destination" "$candidate"
  print -r -- "Backup: $candidate"
fi

ln -sfn -- "$repo_root/bin/mactl" "$destination"
print -r -- "Installed: $destination -> $repo_root/bin/mactl"
print -r -- 'If needed, add $HOME/.local/bin to PATH before running mactl.'
