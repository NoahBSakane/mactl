#!/usr/bin/env python3
"""danger_check.py - does a shell command wipe out (or make unusable) a home or system directory?

  danger_check.py [--cwd DIR] < command-line        stdout: one line per reason (nothing = no objection)

Exits 0 always; any internal problem prints nothing (the hook fails open, like the other hooks).

What is refused, however the command is dressed up (env/sudo/command wrappers, bash -c, eval, heredocs,
$(...) and `...`, a variable assigned earlier in the same line, `cd ~` before a relative path, braces):
  - rm / shred / srm / unlink / rmdir -r on, or a glob directly inside, a protected place; `rm -rf $VAR/*`
    (an empty variable turns it into /*)
  - find <protected> ... -delete | -exec rm ...   (also find ... | xargs rm)
  - mv of a protected place; chmod/chown/chgrp -R on one; rsync --delete into one
  - git clean in the home directory; dd of=/dev/disk*; diskutil erase*/partition*; mkfs/newfs
  - python/perl/ruby/node/osascript one-liners that remove trees and mention the home directory
Protected: /, the home directory and its parents, system directories, and the home's personal folders
(Documents, Desktop, Downloads, Pictures, Movies, Music, Library, .ssh, .gnupg, .config, ...). Deleting
something *inside* them (rm -rf ~/Documents/old-project) is fine. Add your own, one per line, in
~/.config/ai-agent-config/danger-paths.txt. Best effort: a script file that does the deleting cannot be seen.
"""
import glob
import itertools
import os
import re
import shlex
import sys

HOME = os.path.realpath(os.path.expanduser("~"))
SYSTEM_DIRS = {"/", "/bin", "/sbin", "/usr", "/usr/bin", "/usr/local", "/etc", "/var", "/opt", "/private",
               "/private/etc", "/private/var", "/System", "/Library", "/Applications", "/Users", "/home", "/Volumes",
               "/dev", "/cores", "/opt/homebrew"}
PERSONAL = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Public", "Applications",
            ".ssh", ".gnupg", ".config", ".local", ".claude", ".codex", ".gemini", ".grok", ".knowledge", ".agents",
            ".agent-state", ".aws", ".kube", ".docker", "Library/Application Support", "Library/Keychains",
            "Library/Mobile Documents"]
SEP = {";", "&&", "||", "|", "&", "|&", "(", ")", "\n"}
WRAPPERS = {"env", "time", "nohup", "command", "sudo", "exec", "builtin", "nice", "caffeinate", "stdbuf", "doas",
            "ionice", "setsid", "unbuffer", "arch", "chroot", "busybox", "xcrun"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "ash"}
RM_LIKE = {"rm", "grm", "gnurm", "srm", "shred", "unlink", "rmdir"}
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$")
GLOB = re.compile(r"[*?\[]")
INTERP = {"python", "python3", "perl", "ruby", "node", "php", "osascript", "lua", "deno", "bun"}
TREE_KILL = re.compile(r"rmtree|remove_tree|rm_rf|rm_r\b|rmSync|rimraf|shutil\.rmtree|os\.remove|unlink|rmdir|"
                       r"File\.delete|FileUtils|do shell script|\brm\s+-|removeItem|trashItem|fs\.rm|Remove-Item", re.I)
HOMEISH = re.compile(r"expanduser|homedir|os\.homedir|\$HOME|\bHOME\b|\bENV\{HOME\}|Dir\.home|~|NSHomeDirectory|"
                     r"/Users/|path\.home|\"/\"|'/'", re.I)


def user_paths():
    out = []
    try:
        for raw in open(os.path.join(HOME, ".config", "ai-agent-config", "danger-paths.txt"), encoding="utf-8"):
            line = raw.strip()
            if line and not line.startswith("#"):
                out.append(os.path.realpath(os.path.expanduser(line)))
    except OSError:
        pass
    return out


PROTECTED = set(SYSTEM_DIRS) | {HOME} | {os.path.join(HOME, p) for p in PERSONAL} | set(user_paths())
# every parent of the home directory (/Users, /home, ...)
_p = HOME
while _p != "/":
    _p = os.path.dirname(_p)
    PROTECTED.add(_p)


def brace_expand(s):
    m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
    if not m:
        return [s]
    out = []
    for alt in m.group(1).split(","):
        out.extend(brace_expand(s[:m.start()] + alt + s[m.end():]))
    return out[:64]


class Ctx:
    def __init__(self, cwd, env=None):
        self.cwd = os.path.realpath(cwd) if cwd else HOME
        self.env = dict(env or {})


def expand(tok, ctx):
    """tilde, $HOME, ${HOME...}, $PWD and variables assigned earlier; unknown ones stay as written"""
    t = tok
    if t == "~" or t.startswith("~/"):
        t = HOME + t[1:]
    t = re.sub(r"\$\{HOME[^}]*\}|\$HOME\b", HOME, t)
    t = re.sub(r"\$\{PWD\}|\$PWD\b", ctx.cwd, t)
    for k, v in ctx.env.items():
        t = re.sub(r"\$\{%s\}|\$%s\b" % (k, k), v.replace("\\", "\\\\"), t)
    return t


def norm(path, ctx):
    p = path if os.path.isabs(path) else os.path.join(ctx.cwd, path)
    p = os.path.normpath(p)
    try:
        return os.path.realpath(p)
    except OSError:
        return p


DEEP_SYSTEM = ("/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/bin", "/sbin", "/etc",
               "/private/etc", "/dev", "/cores")


def is_protected(p):
    return p in PROTECTED or any(p == d or p.startswith(d + "/") for d in DEEP_SYSTEM)


def operand_reason(tok, ctx, *, glob_counts=True):
    """why this operand is a protected place (or a glob directly inside one), else None"""
    for t0 in brace_expand(tok):
        t = expand(t0, ctx)
        if re.match(r"^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?(/+(\.?\*|\.\*)?)?$", t) and ("*" in t or t.endswith("/")):
            return "展開される変数だけの `%s` を対象にしています(変数が空だと、ルート直下全体になります)" % tok
        if t.startswith("$") or t.startswith("`") or "$(" in t:
            continue  # unknown expansion: nothing to judge here
        if GLOB.search(os.path.basename(t)) and glob_counts:
            parent = norm(os.path.dirname(t) or ".", ctx)
            if is_protected(parent):
                return "`%s` は、保護された場所(%s)の直下を丸ごと対象にしています" % (tok, parent)
            continue
        p = norm(t, ctx)
        if is_protected(p):
            return "`%s` は保護された場所(%s)です" % (tok, p)
    return None


def flags_of(args):
    short, long_ = set(), set()
    for a in args:
        if a == "--":
            break
        if a.startswith("--"):
            long_.add(a[2:].split("=")[0])
        elif a.startswith("-") and len(a) > 1:
            short.update(a[1:])
    return short, long_


def operands(args):
    out, after = [], False
    for a in args:
        if after:
            out.append(a)
        elif a == "--":
            after = True
        elif not a.startswith("-") or a == "-":
            out.append(a)
    return out


def tokenize(line):
    lex = shlex.shlex(line, posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ""
    return list(lex)


def groups(tokens):
    cur, seps = [], []
    for tok in tokens:
        if tok in SEP:
            if cur:
                yield cur, tok
            cur = []
        else:
            cur.append(tok)
    if cur:
        yield cur, ""


def heredocs(text):
    """-> (text without heredoc bodies, [(command line, body)])"""
    out, bodies, term, cur_cmd, cur_body = [], [], None, "", []
    for line in text.split("\n"):
        if term is not None:
            if line.strip() == term:
                bodies.append((cur_cmd, "\n".join(cur_body)))
                term, cur_body = None, []
            else:
                cur_body.append(line)
            continue
        m = re.search(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if m:
            term, cur_cmd = m.group(1), line
        out.append(line)
    if term is not None and cur_body:
        bodies.append((cur_cmd, "\n".join(cur_body)))
    return "\n".join(out), bodies


def substitutions(text):
    """bodies of $(...) , <(...) and `...`"""
    out, i = [], 0
    while i < len(text):
        if text.startswith("$(", i) or text.startswith("<(", i) or text.startswith(">(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            out.append(text[i + 2:j - 1])
            i = j
        elif text[i] == "`":
            j = text.find("`", i + 1)
            if j < 0:
                break
            out.append(text[i + 1:j])
            i = j + 1
        else:
            i += 1
    return out


def unwrap(argv):
    argv = list(argv)
    while argv:
        tok = argv[0]
        if ASSIGN.match(tok) or tok in WRAPPERS or os.path.basename(tok) in WRAPPERS or tok == "\\":
            argv.pop(0)
            while argv and argv[0].startswith("-") and tok in ("sudo", "env", "nice", "doas", "arch", "time"):
                opt = argv.pop(0)
                if tok == "sudo" and opt in ("-u", "-g", "-h", "-p", "-C", "-D", "-R", "-T", "-U") and argv:
                    argv.pop(0)
                if tok == "env" and opt in ("-u", "-S", "-C") and argv:
                    argv.pop(0)
        elif tok in ("timeout",):
            argv.pop(0)
            while argv and argv[0].startswith("-"):
                argv.pop(0)
            if argv:
                argv.pop(0)
        else:
            break
    return argv


def analyse(text, ctx, depth=0):
    reasons = []
    if depth > 4 or not text.strip():
        return reasons
    body_text, docs = heredocs(text)
    for cmdline, body in docs:
        first = unwrap(safe_tokens(cmdline.split("<<")[0]) or [""])
        if first and os.path.basename(first[0]) in SHELLS | {"eval", "source", "."}:
            reasons += analyse(body, Ctx(ctx.cwd, ctx.env), depth + 1)
    for sub in substitutions(body_text):
        reasons += analyse(sub, Ctx(ctx.cwd, ctx.env), depth + 1)
    pipe_find_root = None
    for line in body_text.split("\n"):
        toks = safe_tokens(line)
        if toks is None:
            continue
        for argv, sep in groups(toks):
            # simple assignments and cd update the context
            if all(ASSIGN.match(a) for a in argv):
                for a in argv:
                    k, v = ASSIGN.match(a).groups()
                    ctx.env[k] = expand(v, ctx)
                continue
            if argv[0] in ("cd", "pushd"):
                target = argv[1] if len(argv) > 1 and not argv[1].startswith("-") else "~"
                t = expand(target, ctx)
                if not t.startswith("$"):
                    ctx.cwd = norm(t, ctx)
                continue
            r, find_root = check_command(unwrap(argv), ctx, depth, pipe_find_root)
            reasons += r
            pipe_find_root = find_root if sep in ("|", "|&") else None
    return reasons


def safe_tokens(line):
    try:
        return tokenize(line)
    except ValueError:
        return None


def check_command(argv, ctx, depth, pipe_find_root):
    reasons, find_root = [], None
    if not argv:
        return reasons, find_root
    name, args = os.path.basename(argv[0]), argv[1:]
    short, long_ = flags_of(args)
    ops = operands(args)
    if name.startswith("$") or name.startswith("`") or name.startswith("$'"):
        for o in ops:
            r = operand_reason(o, ctx)
            if r:
                reasons.append("コマンド名が展開で作られていて、保護された場所を対象にしています: " + r)
                break
        return reasons, find_root
    if name in SHELLS or name in ("eval",):
        if name == "eval":
            reasons += analyse(" ".join(args), Ctx(ctx.cwd, ctx.env), depth + 1)
        else:
            for i, a in enumerate(args):
                if a.startswith("-") and not a.startswith("--") and "c" in a[1:] and i + 1 < len(args):
                    reasons += analyse(args[i + 1], Ctx(ctx.cwd, ctx.env), depth + 1)
                    break
        return reasons, find_root
    if name in RM_LIKE:
        recursive = bool(short & {"r", "R"}) or "recursive" in long_ or name in ("shred", "srm") and True
        for o in ops:
            r = operand_reason(o, ctx, glob_counts=True)
            if r and (recursive or GLOB.search(os.path.basename(o)) or name in ("shred", "srm", "unlink")):
                reasons.append("%s で消そうとしています: %s" % (name, r))
            elif r and name == "rm" and re.match(r"^\$\{?\w+\}?/", o):
                reasons.append(r)
    elif name == "find":
        roots = []
        for a in args:
            if a.startswith("-") or a in ("(", "!", ")"):
                break
            roots.append(a)
        roots = roots or ["."]
        hit = next((operand_reason(x, ctx, glob_counts=False) for x in roots if operand_reason(x, ctx, glob_counts=False)), None)
        deletes = "-delete" in args or any(a in ("-exec", "-execdir", "-ok", "-okdir") and i + 1 < len(args) and
                                           os.path.basename(args[i + 1]) in RM_LIKE | {"mv"}
                                           for i, a in enumerate(args))
        if hit and deletes:
            reasons.append("find で、保護された場所の中身を消そうとしています: " + hit)
        if hit:
            find_root = hit
    elif name == "xargs":
        inner = unwrap([a for a in args if not a.startswith("-")][:] or [])
        first = None
        for a in args:
            if not a.startswith("-"):
                first = os.path.basename(a)
                break
        if first in RM_LIKE and pipe_find_root:
            reasons.append("find の結果を xargs で消そうとしています: " + pipe_find_root)
    elif name == "mv":
        for o in ops[:-1] if len(ops) > 1 else ops:
            r = operand_reason(o, ctx)
            if r:
                reasons.append("mv で保護された場所を動かそうとしています: " + r)
    elif name in ("chmod", "chown", "chgrp"):
        if short & {"R", "r"} or "recursive" in long_:
            for o in ops[1:]:
                r = operand_reason(o, ctx, glob_counts=False)
                if r:
                    reasons.append("%s -R で保護された場所の全体を変えようとしています: %s" % (name, r))
    elif name == "rsync":
        if any(a.startswith("--delete") for a in args) and ops:
            r = operand_reason(ops[-1], ctx, glob_counts=False)
            if r:
                reasons.append("rsync --delete で保護された場所の中身を消す恐れがあります: " + r)
    elif name == "git":
        sub = [a for a in args if not a.startswith("-")]
        c_dir = None
        for i, a in enumerate(args):
            if a == "-C" and i + 1 < len(args):
                c_dir = args[i + 1]
        base = norm(expand(c_dir, ctx), ctx) if c_dir else ctx.cwd
        if sub and (sub[0] == "clean" or (c_dir and len(sub) > 1 and sub[1] == "clean")) and is_protected(base):
            reasons.append("git clean を、保護された場所(%s)で実行しようとしています" % base)
    elif name == "dd":
        for a in args:
            if re.match(r"^of=/dev/(r?disk|sd|nvme|hd)", a):
                reasons.append("dd でディスク装置(%s)へ書き込もうとしています" % a[3:])
    elif name == "diskutil":
        if args and re.match(r"(?i)^(erase|reformat|partition|secureerase|zero|random|apfs$)", args[0]) and \
                (args[0].lower().startswith(("erase", "reformat", "partition", "secureerase", "zero", "random")) or
                 any(re.match(r"(?i)delete|erase", a) for a in args[1:2])):
            reasons.append("diskutil でディスクやボリュームを消去しようとしています")
    elif name.startswith(("mkfs", "newfs")):
        reasons.append("%s でファイルシステムを作り直そうとしています" % name)
    elif name in INTERP or re.match(r"^(python|ruby|perl|node)[0-9.]*$", name):
        src = " ".join(args)
        if TREE_KILL.search(src) and HOMEISH.search(src):
            reasons.append("%s のワンライナーで、ホームなどの下を丸ごと消す恐れがあります" % name)
    return reasons, find_root


def main():
    args = sys.argv[1:]
    cwd = None
    if "--cwd" in args:
        cwd = args[args.index("--cwd") + 1]
    try:
        text = sys.stdin.read()[:20000]
        seen = []
        for r in analyse(text, Ctx(cwd)):
            if r not in seen:
                seen.append(r)
        print("\n".join(seen[:4]))
    except Exception:  # noqa: BLE001
        pass


if __name__ == "__main__":
    main()
