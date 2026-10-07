#!/usr/bin/env python3
"""Markdown lint with one house rule: MD013 (line length) is not applied to lines with Japanese
(nor to one-line `<!-- ... -->` markers).

  md-lint.py <file.md>...      print the findings; exit 1 when there are any, 0 when clean

The linter is `markdownlint-cli2` (on PATH, else `npx --yes markdownlint-cli2`; override with
MD_LINT_CMD). A project's own markdownlint config wins; without one, ~/.agents/hooks/markdownlint.json
(next to this file) is used. When no linter can run (offline, no node) nothing is reported:
callers fail open.
"""
import os
import re
import shlex
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_NAMES = (".markdownlint-cli2.jsonc", ".markdownlint-cli2.yaml", ".markdownlint-cli2.cjs",
                ".markdownlint.jsonc", ".markdownlint.json", ".markdownlint.yaml", ".markdownlint.yml",
                ".markdownlint.cjs")
MARKER = re.compile(r"^\s*<!--")   # machine-read markers must stay on one line
CJK = re.compile("[぀-ヿ㐀-䶿一-鿿＀-￯]")
FINDING = re.compile(r"^(.*?):(\d+)(?::\d+)? (?:error|warning) (MD\d+)")


def linter():
    if os.environ.get("MD_LINT_CMD"):
        return shlex.split(os.environ["MD_LINT_CMD"])
    if shutil.which("markdownlint-cli2"):
        return ["markdownlint-cli2"]
    if shutil.which("npx"):
        return ["npx", "--yes", "markdownlint-cli2"]
    return None


def project_config(path):
    """nearest project config above the file: (kind, path) with kind rules|cli2, or None.
    markdownlint-cli2 finds a rules file only in the file's own folder, so it is passed explicitly."""
    d = os.path.dirname(os.path.abspath(path))
    while True:
        for n in CONFIG_NAMES:
            if os.path.exists(os.path.join(d, n)):
                return ("cli2" if "cli2" in n else "rules", os.path.join(d, n))
        parent = os.path.dirname(d)
        if parent == d:
            return None
        d = parent


def linter():
    if os.environ.get("MD_LINT_CMD"):
        return shlex.split(os.environ["MD_LINT_CMD"])
    if shutil.which("markdownlint-cli2"):
        return ["markdownlint-cli2"]
    if shutil.which("npx"):
        return ["npx", "--yes", "markdownlint-cli2"]
    return None


def has_project_config(path):
    d = os.path.dirname(os.path.abspath(path))
    while True:
        if any(os.path.exists(os.path.join(d, n)) for n in CONFIG_NAMES):
            return True
        parent = os.path.dirname(d)
        if parent == d:
            return False
        d = parent


def lint(path, cmd):
    args = list(cmd)
    found = project_config(path)
    if found is None:
        args += ["--config", os.path.join(HERE, "markdownlint.json")]
    elif found[0] == "rules":
        args += ["--config", found[1]]
    r = subprocess.run(args + [os.path.abspath(path)], capture_output=True, text=True, timeout=90, stdin=subprocess.DEVNULL,
                       cwd=os.path.dirname(os.path.abspath(path)))
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError:
        lines = []
    out = []
    for raw in (r.stdout + r.stderr).split("\n"):
        m = FINDING.match(raw)
        if not m:
            continue
        n = int(m.group(2))
        if m.group(3) == "MD013" and 0 < n <= len(lines) and (CJK.search(lines[n - 1]) or MARKER.match(lines[n - 1])):
            continue
        out.append(os.path.join(os.path.dirname(os.path.abspath(path)), raw))
    return out


def main():
    cmd = linter()
    if not cmd:
        return 0
    found = []
    try:
        for p in sys.argv[1:]:
            if p.endswith(".md") and os.path.isfile(p):
                found += lint(p, cmd)
    except Exception:  # noqa: BLE001
        return 0
    if found:
        print("\n".join(found))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
