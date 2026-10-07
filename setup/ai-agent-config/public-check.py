#!/usr/bin/env python3
"""public-check.py - keep company names, IDs, people and secrets out of a PUBLIC repository.

  public-check.py                  scan every tracked file                  (exit 1 when something is found)
  public-check.py --diff A..B      scan only the lines added between two commits
  public-check.py --pre-push       git pre-push protocol (stdin: local ref/sha, remote ref/sha); used by the hook
  public-check.py --suggest        after a scan, ask one of your agents (agents.conf `ask`, read-only) to
                                   propose generic replacements; printed, never applied
  public-check.py --localise       list placeholders such as <自分のSlackユーザーID> left in the seeded
                                   files; with --agent, start one of your agents to fill them in with you

Mechanical rules (always on): e-mail addresses, Slack IDs, UUIDs, /Users/<name>/ paths, secrets/tokens.
Your own private words (company, clients, colleagues) go in ~/.config/ai-agent-config/public-denylist.txt,
one regular expression per line (`#` comments): the list is private, so it never lives in the repository.
Known-safe hits: <repo>/ai-agent-config/public-check.allow, lines `rule<TAB>path-glob` (or `rule` alone).
`git push --no-verify` skips the hook when you decide a hit is fine.
"""
import fnmatch
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
DENYLIST = os.path.join(HOME, ".config", "ai-agent-config", "public-denylist.txt")
ALLOW = os.path.join(HERE, "public-check.allow")
HOOKS = os.environ.get("AGENTS_HOOKS_DIR") or os.path.join(HOME, ".agents", "hooks")
ZERO = "0" * 40
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

RULES = [
    ("email", re.compile(r"(?<![\w/:@.-])[\w.+-]+@(?!(?:users\.noreply\.github\.com|noreply\.anthropic\.com|github\.com|"
                         r"example\.(?:com|org|net|invalid)|[\w.-]*\.invalid)\b)[\w-]+(?:\.[\w-]+)+")),
    ("slack-id", re.compile(r"\b[UWCD]0[0-9A-Z]{8,10}\b")),
    ("uuid", re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")),
    ("home-path", re.compile(r"/Users/(?!(?:you|name|user|username|<)\b)[A-Za-z0-9._-]+/")),
    ("secret", re.compile(r"AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{20,}|"
                          r"xox[abprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}|-----BEGIN [A-Z ]*PRIVATE KEY-----")),
]


def git(*args):
    r = subprocess.run(["git", "-C", HERE, *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def toplevel():
    return git("rev-parse", "--show-toplevel").strip()


def load_allow():
    out = []
    try:
        for raw in open(ALLOW, encoding="utf-8"):
            line = raw.rstrip("\n")
            if line.strip() and not line.lstrip().startswith("#"):
                rule, _, glob = line.partition("\t")
                out.append((rule.strip(), glob.strip() or "*"))
    except OSError:
        pass
    return out


def load_deny():
    out = []
    try:
        for raw in open(DENYLIST, encoding="utf-8"):
            line = raw.strip()
            if line and not line.startswith("#"):
                try:
                    out.append(("denylist", re.compile(line, re.I)))
                except re.error:
                    print("public-denylist.txt: 正規表現を読めません: %s" % line, file=sys.stderr)
    except OSError:
        pass
    return out


def scan_text(path, lines, rules, allow, hits):
    for n, text in lines:
        for name, rx in rules:
            m = rx.search(text)
            if not m:
                continue
            if any(r == name and fnmatch.fnmatch(path, g) for r, g in allow):
                continue
            hits.append((path, n, name, text.strip()[:140]))


def tracked_files():
    top = toplevel()
    out = subprocess.run(["git", "-C", top, "ls-files"], capture_output=True, text=True).stdout
    return top, [f for f in out.split("\n") if f]


def scan_all(rules, allow):
    top, files = tracked_files()
    hits = []
    for f in files:
        try:
            data = open(os.path.join(top, f), "rb").read()
        except OSError:
            continue
        if b"\0" in data:
            continue
        scan_text(f, enumerate(data.decode("utf-8", "replace").split("\n"), 1), rules, allow, hits)
    return hits


def scan_diff(rng, rules, allow):
    hits, path, new_n = [], None, 0
    for line in git("diff", "-U0", "--no-color", rng).split("\n"):
        if line.startswith("+++ "):
            path = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@"):
            m = re.search(r"\+(\d+)", line)
            new_n = int(m.group(1)) if m else 0
        elif line.startswith("+") and not line.startswith("+++") and path:
            scan_text(path, [(new_n, line[1:])], rules, allow, hits)
            new_n += 1
    return hits


def pre_push(rules, allow):
    hits = []
    for raw in sys.stdin:
        parts = raw.split()
        if len(parts) < 4:
            continue
        local, lsha, _remote, rsha = parts[:4]
        if lsha == ZERO:
            continue
        if rsha == ZERO:
            base = git("merge-base", lsha, "refs/remotes/origin/HEAD").strip() or git("merge-base", lsha, "origin/main").strip() or EMPTY_TREE
        else:
            base = rsha
        hits += scan_diff("%s..%s" % (base, lsha), rules, allow)
    return hits


def report(hits):
    for path, n, name, text in hits:
        print("%s:%s: [%s] %s" % (path, n, name, text))
    if hits:
        print("\n公開リポジトリに載せてよいか確認してください(%d件)。一般名・プレースホルダに直すか、問題なければ public-check.allow に足す(または git push --no-verify)。" % len(hits), file=sys.stderr)
        print("直し方の提案が欲しいときは: ai-agent-config/public-check.py --suggest", file=sys.stderr)


def suggest(hits):
    if not hits:
        return
    prompt = ("次は、公開リポジトリに載せる前の検査で見つかった行です。社内・個人の固有名、ID、人名、メールを、意味を保った"
              "一般名・プレースホルダ(例: <自分のSlackユーザーID>、app-a、Taro Yamada)に置き換える案を、"
              "『ファイル:行 / 元の語 / 置き換え後 / 置き換えると動作に支障が出るか』の表で出してください。"
              "ファイルは編集せず、案だけ出すこと。\n\n" + "\n".join("%s:%s [%s] %s" % h for h in hits[:80]))
    runner = os.path.join(HOOKS, "agent-run.sh")
    if not os.path.exists(runner):
        print("agent-run.sh が見つかりません(install.sh を実行してください)", file=sys.stderr)
        return
    r = subprocess.run(["bash", runner, "ask", "-"], input=prompt, text=True)
    if r.returncode != 0:
        print("提案を出せるエージェントがありません(agents.conf の ask・導入・認証・上限を確認)", file=sys.stderr)


PLACEHOLDER = re.compile(r"<[^<>\s]*(?:ID|Id|名|キー|URL)[^<>\s]*>")


def localise(use_agent):
    kdir = os.path.join(HOME, ".knowledge")
    found = []
    for f in sorted(os.listdir(kdir)) if os.path.isdir(kdir) else []:
        p = os.path.join(kdir, f)
        if f.endswith(".md") and os.path.isfile(p):
            for n, line in enumerate(open(p, encoding="utf-8", errors="replace"), 1):
                for m in PLACEHOLDER.finditer(line):
                    found.append((p, n, m.group(0)))
    if not found:
        print("埋めるプレースホルダはありません")
        return 0
    for p, n, ph in found:
        print("%s:%d %s" % (p, n, ph))
    if not use_agent:
        print("\nこの Mac のエージェントに埋めさせるには: public-check.py --localise --agent", file=sys.stderr)
        return 0
    prompt = ("~/.knowledge の次のファイルに、この Mac 用に埋めるプレースホルダが残っています。\n" +
              "\n".join("%s:%d %s" % x for x in found) +
              "\nそれぞれ、この Mac で分かること(接続済みのサービス、過去の記録、設定)から実際の値を調べ、分からないものはユーザーに質問してから、"
              "上のファイルだけを直してください。これは公開リポジトリに戻す内容ではなく、この Mac のローカルの知識ファイルです。")
    conf = os.path.join(HOOKS, "agentconf.py")
    order = subprocess.run(["python3", conf, "get", "runtime", "order"], capture_output=True, text=True).stdout.split()
    for agent in order:
        tpl = subprocess.run(["python3", conf, "get", agent, "interactive"], capture_output=True, text=True).stdout.strip()
        binary = subprocess.run(["python3", conf, "get", agent, "bin"], capture_output=True, text=True).stdout.strip() or agent
        if tpl and subprocess.run(["sh", "-c", "command -v %s" % binary], capture_output=True).returncode == 0:
            print("\n%s を起動します" % agent)
            os.environ["AGENT_PROMPT"] = prompt
            os.execvp("sh", ["sh", "-c", tpl])
    print("\n起動できるエージェントが無いので、次を使っているエージェントに渡してください:\n" + prompt)
    return 0


def main():
    args = sys.argv[1:]
    if "--localise" in args:
        return localise("--agent" in args)
    rules = RULES + load_deny()
    allow = load_allow()
    if "--pre-push" in args:
        hits = pre_push(rules, allow)
    elif "--diff" in args:
        hits = scan_diff(args[args.index("--diff") + 1], rules, allow)
    else:
        hits = scan_all(rules, allow)
    report(hits)
    if "--suggest" in args:
        suggest(hits)
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
