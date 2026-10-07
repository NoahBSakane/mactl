#!/usr/bin/env python3
"""Manage one `developer_instructions` block inside Codex's config.toml.

Codex reads a single global AGENTS.md and cannot import files, so the shared rules reach it
through a symlink and Codex's own persona goes in `developer_instructions` instead (verified
with `codex debug prompt-input`: it is appended to the developer message, nothing is replaced).
Everything else in config.toml is left untouched.

  toml-block.py apply  <config.toml> <text-file>   print the config with our block set
  toml-block.py remove <config.toml>               print the config without our block

Exit status 3: the user already has a top-level developer_instructions of their own (we never
overwrite it). 4: the result would not be valid TOML. 5: the text cannot be embedded.
"""
import re
import sys

BEGIN = "# >>> ai-agent-config (managed: developer_instructions) >>>"
END = "# <<< ai-agent-config <<<"


def strip_block(text):
    out, skipping = [], False
    for line in text.split("\n"):
        if line.strip() == BEGIN:
            skipping = True
            continue
        if skipping:
            if line.strip() == END:
                skipping = False
            continue
        out.append(line)
    return "\n".join(out)


def first_table(lines):
    for i, line in enumerate(lines):
        if re.match(r"^\s*\[", line):
            return i
    return len(lines)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("apply", "remove"):
        sys.exit(2)
    mode, path = sys.argv[1], sys.argv[2]
    try:
        text = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        text = ""
    base = strip_block(text)
    if mode == "remove":
        sys.stdout.write(base)
        return
    body = open(sys.argv[3], encoding="utf-8").read().rstrip("\n")
    if "'''" in body:
        sys.stderr.write("persona text contains ''' and cannot be embedded\n")
        sys.exit(5)
    lines = base.split("\n")
    cut = first_table(lines)
    if any(re.match(r"^\s*developer_instructions\s*=", l) for l in lines[:cut]):
        sys.stderr.write("config.toml already has its own top-level developer_instructions\n")
        sys.exit(3)
    block = [BEGIN, "developer_instructions = '''", body, "'''", END, ""]
    head = lines[:cut]
    while head and head[-1] == "":
        head.pop()
    new = head + ([""] if head else []) + block + lines[cut:]
    result = "\n".join(new)
    if not result.endswith("\n"):
        result += "\n"
    try:
        import tomllib
        tomllib.loads(result)
    except ImportError:
        pass
    except Exception as e:  # noqa: BLE001
        sys.stderr.write("result is not valid TOML: %s\n" % e)
        sys.exit(4)
    sys.stdout.write(result)


if __name__ == "__main__":
    main()
