#!/usr/bin/env python3
"""Small parsers shared by the agent hooks. Any failure prints nothing (fail open).

  parse_cmd.py cmd                    stdin: a shell command line
                                      stdout: the agent (section name in agents.conf) for every
                                      *executing* launch of another agent CLI found in it; help /
                                      version / model-list forms, quoted strings and heredoc
                                      bodies are ignored
  parse_cmd.py protected              stdin: file paths, one per line
                                      stdout: `protected` if any resolves to a deployed instruction
                                      file (the list install.sh wrote to protected-paths.txt), else `ok`
  parse_cmd.py editcheck <scratchpad> stdin: file paths, one per line
                                      stdout: `skip` if every path is a scratch/state/memory
                                      location, otherwise `gate`

No agent is named here: which CLIs exist and how an executing launch looks comes from agents.conf.
"""
import fnmatch
import os
import re
import shlex
import sys

sys.dont_write_bytecode = True  # the hooks are deployed as plain files: no __pycache__ next to them
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import agentconf  # noqa: E402

SEPARATORS = {";", "&&", "||", "|", "&", "|&", "(", ")", "\n"}
WRAPPERS = {"env", "time", "nohup", "command", "sudo", "exec", "builtin", "nice", "caffeinate", "stdbuf"}
HELP_FLAGS = {"--help", "-h", "--version", "-V"}
ENV_ASSIGN = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")


def specs():
    """{executable name: (agent, exec_sub, exec_flag, nonexec_sub)}"""
    order, data = agentconf.load()
    out = {}
    for a in agentconf.agents(order):
        cfg = data[a]
        binary = cfg.get("bin") or a
        out[binary] = (
            a,
            set(cfg.get("exec_sub", "").split()),
            set(cfg.get("exec_flag", "").split()),
            set(cfg.get("nonexec_sub", "").split()),
        )
    return out


def strip_heredocs(text):
    out, terminator = [], None
    for line in text.split("\n"):
        if terminator is not None:
            if line.strip() == terminator:
                terminator = None
            continue
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if m:
            terminator = m.group(1)
        out.append(line)
    return "\n".join(out)


def tokenize(line):
    lex = shlex.shlex(line, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def groups(tokens):
    cur = []
    for tok in tokens:
        if tok in SEPARATORS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(tok)
    if cur:
        yield cur


def unwrap(argv):
    argv = list(argv)
    while argv:
        tok = argv[0]
        if tok == "$" or ENV_ASSIGN.match(tok) or tok in WRAPPERS:
            argv.pop(0)
        elif tok == "timeout":
            argv.pop(0)
            while argv and argv[0].startswith("-"):
                argv.pop(0)
            if argv:
                argv.pop(0)  # duration
        else:
            break
    return argv


def kind_of(argv, table):
    argv = unwrap(argv)
    if not argv:
        return None
    name, args = os.path.basename(argv[0]), argv[1:]
    if name in ("bash", "sh", "zsh") and "-c" in args:
        idx = args.index("-c")
        return scan(args[idx + 1], table) if idx + 1 < len(args) else None
    if name not in table or any(a in HELP_FLAGS for a in args):
        return None
    agent, exec_sub, exec_flag, nonexec = table[name]
    first = next((a for a in args if not a.startswith("-")), "")
    if first and first in nonexec:
        return None
    by_sub = any(a in exec_sub for a in args[:6])
    by_flag = any(a in exec_flag or any(a.startswith(f + "=") for f in exec_flag if f.startswith("--")) for a in args)
    return agent if (by_sub or by_flag) else None


def scan(command, table=None):
    table = table if table is not None else specs()
    found = []
    for line in strip_heredocs(command).split("\n"):
        try:
            tokens = tokenize(line)
        except ValueError:
            continue
        for argv in groups(tokens):
            k = kind_of(argv, table)
            if isinstance(k, list):
                found.extend(k)
            elif k:
                found.append(k)
    return found


def protected():
    state = os.environ.get("AGENT_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".agent-state")
    try:
        listed = [l.strip() for l in open(os.path.join(state, "protected-paths.txt"), encoding="utf-8") if l.strip()]
    except OSError:
        return "ok"
    prot = {os.path.realpath(p) for p in listed}
    for p in [x.strip() for x in sys.stdin.read().split("\n") if x.strip()]:
        if os.path.realpath(os.path.expanduser(p)) in prot:
            return "protected"
    return "ok"


def editcheck(scratchpad):
    home = os.path.expanduser("~")
    prefixes = ["/tmp/", "/private/tmp/", os.path.join(home, ".agent-state") + "/"]
    tmpdir = os.environ.get("TMPDIR")
    if tmpdir:
        prefixes.append(os.path.realpath(tmpdir).rstrip("/") + "/")
    if scratchpad:
        prefixes.append(os.path.realpath(scratchpad).rstrip("/") + "/")
    memory_globs = [os.path.join(home, ".claude", "projects", "*", "memory", "*")]
    for _agent, path in agentconf.memory_files(*reversed(agentconf.load())):
        memory_globs.append(path)
    paths = [p.strip() for p in sys.stdin.read().split("\n") if p.strip()]
    if not paths:
        return "gate"
    for p in paths:
        real = os.path.realpath(os.path.expanduser(p))
        ok = any(real.startswith(pre) or real + "/" == pre for pre in prefixes) or any(
            fnmatch.fnmatch(real, g) for g in memory_globs
        )
        if not ok:
            return "gate"
    return "skip"


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    try:
        if mode == "cmd":
            seen = []
            for k in scan(sys.stdin.read()):
                if k not in seen:
                    seen.append(k)
            print("\n".join(seen))
        elif mode == "protected":
            print(protected())
        elif mode == "editcheck":
            print(editcheck(sys.argv[2] if len(sys.argv) > 2 else ""))
    except Exception:
        pass


if __name__ == "__main__":
    main()
