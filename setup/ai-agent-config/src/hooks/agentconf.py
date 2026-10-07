#!/usr/bin/env python3
"""Reader for agents.conf (see that file). Importable, and a small CLI for shell scripts.

  agentconf.py agents                    agent section names, in file order (not [runtime])
  agentconf.py get <section> <key>       one value
  agentconf.py all <key>                 `section<TAB>value` for every agent that sets the key
  agentconf.py has <key> <word>          exit 0 when <word> is in any agent's list for <key>
  agentconf.py toolclass <tool>          shell | edit | subagent | other
  agentconf.py memory-files              `agent<TAB>path` for every existing memory file

Any problem (missing file, bad line) yields empty output / `other`: callers fail open.
"""
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def conf_path():
    return os.environ.get("AGENTS_CONF") or os.path.join(HERE, "agents.conf")


def load():
    """-> (ordered section names, {section: {key: value}})"""
    order, data, cur = [], {}, None
    try:
        lines = open(conf_path(), encoding="utf-8").read().split("\n")
    except OSError:
        return order, data
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur = line[1:-1].strip()
            if cur not in data:
                data[cur] = {}
                order.append(cur)
            continue
        if cur is not None and "=" in line:
            k, v = line.split("=", 1)
            data[cur][k.strip()] = v.strip()
    return order, data


def agents(order):
    return [s for s in order if s != "runtime"]


def words(data, section, key):
    return data.get(section, {}).get(key, "").split()


def toolclass(data, order, tool):
    for cls, key in (("shell", "shell_tools"), ("edit", "edit_tools"), ("subagent", "subagent_tools")):
        for a in agents(order):
            if tool in words(data, a, key):
                return cls
    return "other"


def memory_files(data, order):
    out = []
    for a in agents(order):
        spec = words(data, a, "memory")
        excluded = {w[1:] for w in spec if w.startswith("!")}
        for pattern in (w for w in spec if not w.startswith("!")):
            for path in sorted(glob.glob(os.path.expanduser(pattern), recursive=True)):
                if os.path.isfile(path) and os.path.basename(path) not in excluded and (a, path) not in out:
                    out.append((a, path))
    return out


def main():
    try:
        order, data = load()
        cmd = sys.argv[1] if len(sys.argv) > 1 else ""
        if cmd == "agents":
            print("\n".join(agents(order)))
        elif cmd == "get":
            print(data.get(sys.argv[2], {}).get(sys.argv[3], ""))
        elif cmd == "all":
            for a in agents(order):
                v = data[a].get(sys.argv[2], "")
                if v:
                    print("%s\t%s" % (a, v))
        elif cmd == "has":
            sys.exit(0 if any(sys.argv[3] in words(data, a, sys.argv[2]) for a in agents(order)) else 1)
        elif cmd == "toolclass":
            print(toolclass(data, order, sys.argv[2]))
        elif cmd == "memory-files":
            for a, p in memory_files(data, order):
                print("%s\t%s" % (a, p))
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001
        if len(sys.argv) > 1 and sys.argv[1] == "toolclass":
            print("other")
        sys.exit(1 if len(sys.argv) > 1 and sys.argv[1] == "has" else 0)


if __name__ == "__main__":
    main()
