#!/usr/bin/env python3
"""danger_check.py - does a shell command wipe out (or make unusable) a home or system directory?

  danger_check.py [--cwd DIR] < command-line        stdout: one line per reason (nothing = no objection)

Exits 0 always; any internal problem prints nothing (the hook fails open, like the other hooks).

How it reads a command line: line continuations are joined, ANSI-C quotes ($'..') decoded, heredoc bodies
set aside (run as code when the command is a shell or an interpreter), $(...) / `...` / <(...) either
evaluated (echo, printf, pwd, cd X && pwd, whoami) or analysed as commands of their own, the rest lexed
once with shlex, redirections dropped, `if/then/do/{`... skipped, wrappers (sudo, env, nice, timeout,
nohup, xargs, npx ...) unwrapped, `cd`, `pushd`, `( )`, assignments and `ln -s` tracked. The place a relative
path means is judged for every directory the command line might be running in (a failed `cd` leaves it where it was).

Refused: rm/shred/srm/unlink/trash/rimraf (recursive, or any glob that matches everything) on a protected place;
find <protected> with -delete/-exec rm and nothing narrowing the match; `... | xargs rm` fed by such a find or ls;
mv of a protected place (a rename in the same folder is fine); recursive chmod/chown on the home, the root or a
system directory; rsync --delete / tar --remove-files / zip -m on one; git clean / reset --hard in the home;
truncate / cp /dev/null on one; dd of=/dev/disk*; diskutil erase*; mkfs/newfs; python/perl/ruby/node/osascript
one-liners that remove trees near the home; code piped into a shell after base64/xxd/openssl decoding.
Protected: /, the home and its parents, system directories, the home's personal folders (Documents, Desktop,
Downloads, Pictures, Movies, Music, Library, .ssh, .gnupg, .config, ...). Deleting something *inside* them
(rm -rf ~/Documents/old-project) is fine. Add your own, one per line, in ~/.config/ai-agent-config/danger-paths.txt.
Best effort: a script file that does the deleting, shell aliases and functions cannot be seen.
"""
import os
import pwd
import re
import shlex
import sys

try:
    HOME_ENV = os.path.realpath(os.path.expanduser("~"))
except Exception:  # noqa: BLE001
    HOME_ENV = "/"
try:
    HOME_PW = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
except Exception:  # noqa: BLE001
    HOME_PW = HOME_ENV
HOME = HOME_ENV
USER = os.environ.get("USER") or os.environ.get("LOGNAME") or os.path.basename(HOME_PW)
CASEFOLD = sys.platform == "darwin"  # the default macOS volume does not tell Documents from documents

SYSTEM_DIRS = {"/", "/bin", "/sbin", "/usr", "/usr/bin", "/usr/local", "/etc", "/var", "/opt", "/private", "/private/etc",
               "/private/var", "/System", "/Library", "/Applications", "/Users", "/home", "/Volumes", "/dev", "/cores",
               "/opt/homebrew", "/usr/local/bin", "/var/db", "/Library/Application Support", "/Library/Preferences"}
DEEP_SYSTEM = ("/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/bin", "/sbin", "/etc",
               "/private/etc", "/dev", "/cores", "/var/db", "/private/var/db")
CRITICAL = {"/", "/System", "/usr", "/bin", "/sbin", "/etc", "/Library", "/Applications", "/private", "/var", "/Users", "/home"}
PERSONAL = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Public", "Applications",
            ".ssh", ".gnupg", ".config", ".local", ".claude", ".codex", ".gemini", ".grok", ".knowledge", ".agents",
            ".agent-state", ".aws", ".kube", ".docker", "Library/Application Support", "Library/Keychains",
            "Library/Mobile Documents", "Library/Containers", "Library/Group Containers", "Library/CloudStorage",
            "Library/Mail", "Library/Messages", "Pictures/Photos Library.photoslibrary"]
RESERVED = {"if", "then", "else", "elif", "fi", "while", "until", "do", "done", "for", "in", "case", "esac", "select",
            "function", "time", "!", "{", "}", "coproc", ";;"}
SEP = {";", "&&", "||", "|", "&", "|&", "(", ")", "\n", "\x00NL"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "ash"}
RM_LIKE = {"rm", "grm", "gnurm", "srm", "shred", "unlink", "rmdir", "rimraf", "trash", "del-cli"}
INTERP = re.compile(r"^(python|ruby|perl|node|php|osascript|lua|deno|bun|nodejs)[0-9.]*$")
SOURCES = {"find", "gfind", "ls", "echo", "printf", "cat", "tree", "du", "fd", "locate", "mdfind", "dir"}
FILTERS = {"grep", "egrep", "fgrep", "rg", "sort", "head", "tail", "sed", "awk", "tr", "uniq", "cut", "xargs", "tee", "while", "read"}
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
GLOB = re.compile(r"[*?\[]")
# value-taking options of the wrappers we unwrap
WRAP_OPTS = {"sudo": set("ugphCDRTUrt"), "doas": set("uC"), "env": set("uSCP"), "nice": set("n"), "ionice": set("cnp"),
             "stdbuf": set("ioe"), "caffeinate": set("tw"), "arch": set(), "setsid": set(), "nohup": set(), "command": set(),
             "builtin": set(), "exec": set("a"), "time": set("fo"), "xcrun": set(), "chroot": set(), "busybox": set(),
             "unbuffer": set(), "chronic": set(), "watch": set("ndp"), "flock": set("wEc"), "script": set("tF"),
             "npx": set("pc"), "bunx": set(), "pnpx": set(), "dlx": set(), "gtimeout": set(), "timeout": set("sk")}
TIMEOUTS = {"timeout", "gtimeout"}
TREE_KILL = re.compile(r"rmtree|remove_tree|rm_rf|rm_r\b|rmSync|rimraf|shutil\.rmtree|FileUtils\.rm|\brm\s+-|"
                       r"['\"]rm['\"]\s*,\s*['\"]-|removeItem|trashItem|fs\.rm\b|Remove-Item|Finder.{0,40}delete|"
                       r"find .{0,40}-delete", re.I)
HOMEISH = re.compile(r"expanduser|homedir|os\.homedir|\$HOME|\bHOME\b|\bENV\{HOME\}|Dir\.home|~|NSHomeDirectory|"
                     r"/Users/|path\.home|\"/\"|'/'|\bhome\b|rmtree\(['\"]\.['\"]|" + re.escape(HOME_ENV) + "|" +
                     re.escape(HOME_PW), re.I)


def fold(p):
    return p.lower() if CASEFOLD else p


def read_user_paths():
    out = []
    try:
        for raw in open(os.path.join(HOME, ".config", "ai-agent-config", "danger-paths.txt"), encoding="utf-8"):
            line = raw.strip()
            if line and not line.startswith("#"):
                out.append(os.path.realpath(os.path.expanduser(line)))
    except OSError:
        pass
    return out


def build_protected():
    homes = {HOME_ENV, HOME_PW}
    out = set(SYSTEM_DIRS) | homes | set(read_user_paths())
    for h in homes:
        out |= {os.path.join(h, p) for p in PERSONAL}
        q = h
        while q != "/":
            q = os.path.dirname(q)
            out.add(q)
    return {fold(p) for p in out}


PROTECTED = build_protected()
HOMES = {fold(HOME_ENV), fold(HOME_PW)}
CRITICAL_ALL = {fold(p) for p in CRITICAL} | HOMES | {fold(os.path.dirname(h)) for h in (HOME_ENV, HOME_PW)}


def is_protected(p):
    q = fold(p)
    return q in PROTECTED or any(q == fold(d) or q.startswith(fold(d) + "/") for d in DEEP_SYSTEM)


def is_critical(p):
    return fold(p) in CRITICAL_ALL


def brace_expand(s):
    m = re.search(r"\{([^{}]*,[^{}]*)\}", s)
    if not m:
        return [s]
    out = []
    for alt in m.group(1).split(","):
        out.extend(brace_expand(s[:m.start()] + alt + s[m.end():]))
    return out[:64]


class Ctx:
    """where a command line may be running, what it assigned, which links it made"""

    def __init__(self, cwds, env=None, links=None):
        self.cwds = list(cwds) or [None]
        self.env = dict(env or {})
        self.links = dict(links or {})
        self.pending_old = None  # directories to fall back to if the `cd` of an && chain failed

    def copy(self):
        return Ctx(self.cwds, self.env, self.links)


def norm(path, cwd, ctx):
    if not os.path.isabs(path):
        if cwd is None:
            return None
        path = os.path.join(cwd, path)
    try:
        p = os.path.realpath(os.path.normpath(path))
    except OSError:
        p = os.path.normpath(path)
    for src, dst in ctx.links.items():
        if fold(p) == fold(src) or fold(p).startswith(fold(src) + "/"):
            p = os.path.normpath(dst + p[len(src):])
            break
    return p


def decode_ansi_c(s):
    def one(m):
        body = m.group(1)

        def esc(e):
            t = e.group(0)
            if t[1] in "xX":
                return chr(int(t[2:], 16))
            if t[1].isdigit():
                return chr(int(t[1:], 8))
            return {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "a": "\a", "b": "\b", "e": "\x1b"}.get(t[1], t[1])
        return "'" + re.sub(r"\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)", esc, body).replace("'", "'\\''") + "'"
    return re.sub(r"\$'((?:[^'\\]|\\.)*)'", one, s)


def known_value(name, ctx):
    if name in ctx.env:
        return ctx.env[name]
    if name == "HOME":
        return HOME
    if name in ("USER", "LOGNAME"):
        return USER
    if name in ("TMPDIR", "TMP", "TEMP"):
        return os.environ.get(name)
    return None


def expand(tok, ctx, cwd):
    """~, ~user, $HOME, ${HOME...}, $USER, $PWD and earlier assignments; unknown ones stay as written"""
    t = tok
    def var(m):
        name = m.group(1) or m.group(3)
        if name == "PWD":
            return cwd or m.group(0)
        v = known_value(name, ctx)
        if v is None:
            return m.group(0)
        if m.group(2) and m.group(2).startswith(("%", "#")):
            v = v.rstrip("/")
        return v
    t = re.sub(r"\$\{([A-Za-z_][A-Za-z0-9_]*)((?::?[-=+?][^}]*|[%#][^}]*))?\}|\$([A-Za-z_][A-Za-z0-9_]*)", var, t)
    if t == "~" or t.startswith("~/"):
        t = HOME + t[1:]
    else:
        m = re.match(r"^~([A-Za-z0-9_.-]+)(/.*)?$", t)
        if m:
            try:
                t = os.path.realpath(pwd.getpwnam(m.group(1)).pw_dir) + (m.group(2) or "")
            except KeyError:
                pass
    return t


def literal_of(text):
    """the text an `echo`/`printf` command line prints (None when it is not that simple)"""
    toks = safe_tokens(text.strip())
    if not toks:
        return None
    name = os.path.basename(toks[0]).lower()
    args = [a for a in toks[1:] if not (name == "echo" and a in ("-n", "-e", "-E"))]
    if name == "echo":
        return " ".join(args)
    if name == "printf" and args:
        fmt, rest = args[0], args[1:]
        out = fmt.replace("\\n", "\n")
        for a in rest:
            out = re.sub(r"%[sdq]", lambda m: a, out, count=1)
        return out
    return None


def substitutions(text):
    """top-level bodies of $(...) , <(...) , >(...) and `...`, with their spans; text inside single quotes is not code"""
    out, i, single, double = [], 0, False, False
    while i < len(text):
        c = text[i]
        if c == "\\" and not single and i + 1 < len(text):
            i += 2
            continue
        if c == "'" and not double:
            single = not single
            i += 1
            continue
        if c == '"' and not single:
            double = not double
            i += 1
            continue
        if single:
            i += 1
            continue
        two = text[i:i + 2]
        if two in ("$(", "<(", ">(") and not text.startswith("$((", i) and not (two != "$(" and double):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            out.append((i, j, text[i + 2:j - 1]))
            i = j
        elif c == "`":
            j = text.find("`", i + 1)
            if j < 0:
                break
            out.append((i, j + 1, text[i + 1:j]))
            i = j + 1
        else:
            i += 1
    return out


def eval_simple(body, ctx, cwd):
    """value of a simple command substitution, or None"""
    b = body.strip()
    if b in ("pwd", "/bin/pwd", "pwd -P", "pwd -L"):
        return "$PWD"  # expanded where it is used: a `cd` may come before
    if b in ("whoami", "id -un", "logname"):
        return USER
    m = re.match(r"^cd\s+(\S+)\s*&&\s*pwd$", b)
    if m:
        t = expand(m.group(1).strip("'\""), ctx, cwd)
        return norm(t, cwd, ctx) if not t.startswith("$") else None
    lit = literal_of(b)
    if lit is not None:
        return expand(lit, ctx, cwd)
    return None


def preprocess(text, ctx, cwd, depth, reasons):
    """join continuations, decode $'..', replace $((..)), evaluate or analyse $(..)"""
    text = text.replace("\\\r\n", "").replace("\\\n", "")
    text = decode_ansi_c(text)
    text = re.sub(r"\$\(\([^()]*(?:\([^()]*\)[^()]*)*\)\)", "0", text)
    for start, end, body in reversed(substitutions(text)):
        v = eval_simple(body, ctx, cwd)
        if v is not None:
            repl = v
        else:
            reasons += analyse(body, ctx.copy(), depth + 1)
            repl = "__SUBST__"
        text = text[:start] + repl + text[end:]
    return text


def split_heredocs(text):
    """-> (text without heredoc bodies and here-strings, [(command line, body)])"""
    out, bodies, term, cmd, cur = [], [], None, "", []
    for line in text.split("\n"):
        if term is not None:
            if line.strip() == term:
                bodies.append((cmd, "\n".join(cur)))
                term, cur = None, []
            else:
                cur.append(line)
            continue
        m = re.search(r"(?<![<$(])<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?", line)
        if m and "$((" not in line[:m.start()][-3:]:
            term, cmd = m.group(1), line
        hs = re.search(r"<<<\s*('([^']*)'|\"([^\"]*)\"|(\S+))", line)
        if hs:
            bodies.append((line[:hs.start()], hs.group(2) or hs.group(3) or hs.group(4) or ""))
            line = line[:hs.start()] + line[hs.end():]
        out.append(line)
    if term is not None and cur:
        bodies.append((cmd, "\n".join(cur)))
    return "\n".join(out), bodies


def mark_newlines(text):
    """unquoted newlines become a separator token; quoted ones stay"""
    out, q = [], None
    i = 0
    while i < len(text):
        c = text[i]
        if q:
            if c == "\\" and q == '"' and i + 1 < len(text):
                out.append(c + text[i + 1])
                i += 2
                continue
            if c == q:
                q = None
            out.append(c)
        elif c in "'\"":
            q = c
            out.append(c)
        elif c == "\\" and i + 1 < len(text):
            out.append(c + text[i + 1])
            i += 2
            continue
        elif c == "\n":
            out.append(" \u00b6 ")
        else:
            out.append(c)
        i += 1
    return "".join(out)


def safe_tokens(line):
    try:
        lex = shlex.shlex(line, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        lex.commenters = ""
        return list(lex)
    except ValueError:
        return None


REDIR = re.compile(r"^[0-9]*(?:[<>]+[&|]?|&>>?|>&)$")


def strip_redirects(argv):
    out, i = [], 0
    while i < len(argv):
        t = argv[i]
        if REDIR.match(t) or t in ("&>", "&>>", ">&", ">|"):
            if out and re.fullmatch(r"\d{1,2}", out[-1]) and t[0] in "<>&":
                out.pop()
            i += 1
            if i < len(argv) and not re.fullmatch(r"\d+|-", argv[i]):
                i += 1
            elif i < len(argv):
                i += 1
            continue
        out.append(t)
        i += 1
    return out


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


def operands(args, valued=()):
    out, after, skip = [], False, False
    for a in args:
        if skip:
            skip = False
            continue
        if after:
            out.append(a)
        elif a == "--":
            after = True
        elif a in valued:
            skip = True
        elif a.startswith("-") and a != "-":
            continue
        else:
            out.append(a)
    return out


def unwrap(argv):
    """peel off reserved words, assignments and wrappers; returns (argv, extra assignments)"""
    argv = list(argv)
    assigns = []
    while argv:
        tok = argv[0]
        base = os.path.basename(tok).lower()
        if tok in RESERVED:
            argv.pop(0)
        elif ASSIGN.match(tok) and not tok.startswith("-"):
            assigns.append(argv.pop(0))
        elif tok == "\\":
            argv.pop(0)
        elif base in ("export", "declare", "local", "readonly", "typeset"):
            argv.pop(0)
            while argv and argv[0].startswith("-"):
                argv.pop(0)
            return [], assigns + [a for a in argv if ASSIGN.match(a)]
        elif base in WRAP_OPTS:
            argv.pop(0)
            valued = WRAP_OPTS[base]
            while argv and argv[0].startswith("-") and argv[0] != "--":
                opt = argv.pop(0)
                if len(opt) == 2 and opt[1] in valued and argv:
                    argv.pop(0)
                elif base in ("nice",) and re.match(r"^-\d+$", opt):
                    pass
            if argv and argv[0] == "--":
                argv.pop(0)
            if base in TIMEOUTS and argv:
                argv.pop(0)  # the duration
            if base == "flock" and argv:
                argv.pop(0)  # the lock file
            if base == "script" and argv:
                argv.pop(0)  # the transcript file
            if base == "env":
                while argv and ASSIGN.match(argv[0]):
                    assigns.append(argv.pop(0))
        elif base == "pnpm" and argv[1:2] in (["dlx"], ["exec"]) or base in ("yarn", "npm") and argv[1:2] in (["dlx"], ["exec"]):
            argv = argv[2:]
        elif base == "su":
            for i, a in enumerate(argv):
                if a in ("-c", "--command") and i + 1 < len(argv):
                    return ["bash", "-c", argv[i + 1]], assigns
            break
        else:
            break
    return argv, assigns


def wide_glob(name):
    """a glob that matches (nearly) everything in a folder: *, .*, .[a-z]*, ?*  -- not *.dmg"""
    core = re.sub(r"\[[^\]]*\]", "", name)
    core = re.sub(r"[*?]", "", core).strip(".")
    return len(core) < 2


def operand_reason(tok, ctx, *, globs=True):
    """why this operand is a protected place (or a glob that wipes a protected folder), else None"""
    for t0 in brace_expand(tok):
        for cwd in ctx.cwds:
            t = expand(t0, ctx, cwd)
            if re.match(r"^\$\{[A-Za-z_][^}]*\}(/+(\.?\*)?)?$|^\$[A-Za-z_][A-Za-z0-9_]*(/+(\.?\*)?)?$", t) and ("*" in t or t.endswith("/")):
                return "展開される変数だけの `%s` を対象にしています(変数が空だと、ルート直下全体になります。`${VAR:?}` を使うと安全です)" % tok
            if t.startswith(("$", "`")) or "__SUBST__" in t:
                continue
            base = os.path.basename(t)
            if globs and GLOB.search(base):
                if not wide_glob(base):
                    continue
                parent = norm(os.path.dirname(t) or ".", cwd, ctx)
                if parent and is_protected(parent):
                    return "`%s` は、保護された場所(%s)の直下を丸ごと対象にしています" % (tok, parent)
                continue
            p = norm(t, cwd, ctx)
            if p and is_protected(p):
                return "`%s` は保護された場所(%s)です" % (tok, p)
    return None


def cwd_reason(ctx):
    for cwd in ctx.cwds:
        if cwd and is_protected(cwd):
            return cwd
    return None


def interp_reason(src):
    if TREE_KILL.search(src) and HOMEISH.search(src):
        return True
    return False


def analyse(text, ctx, depth=0):
    reasons = []
    if depth > 5 or not text.strip():
        return reasons
    if len(text) > 400000:
        text = text[:200000] + "\n" + text[-200000:]
    cwd0 = ctx.cwds[0] if ctx.cwds else None
    text = text.replace("\\\r\n", "").replace("\\\n", "")
    text = re.sub(r"\$\(\([^()]*(?:\([^()]*\)[^()]*)*\)\)", "0", text)  # arithmetic: its << is no heredoc
    text, docs = split_heredocs(text)
    text = preprocess(text, ctx, cwd0, depth, reasons)
    for cmdline, body in docs:
        spec = re.sub(r"(?<![<$(])<<-?\s*['\"]?[A-Za-z_][A-Za-z0-9_]*['\"]?", " ", cmdline)
        segs = [x for x in re.split(r"\|", spec)]
        names = []
        for seg in segs:
            t = safe_tokens(seg)
            f, _ = unwrap(strip_redirects(t or []))
            names.append(os.path.basename(f[0]).lower() if f else "")
        first = []
        t0 = safe_tokens(segs[0])
        first, _ = unwrap(strip_redirects(t0 or []))
        name = names[0] if names else ""
        if any(n in SHELLS | {"eval", "source", "."} for n in names[:1] + names[1:]):
            reasons += analyse(body, ctx.copy(), depth + 1)
        elif INTERP.match(name) and interp_reason(body):
            reasons.append("%s のスクリプトが、ホームなどの下を丸ごと消す恐れがあります" % name)
        elif name == "xargs" and re.search(r"\b(rm|unlink|shred|rimraf)\b", " ".join(first[1:])):
            for word in re.split(r"[\s,]+", body):
                r = operand_reason(word, ctx) if word else None
                if r:
                    reasons.append("here-string の中身を xargs で消そうとしています: " + r)
                    break
    toks = safe_tokens(mark_newlines(text))
    if toks is None:
        return reasons + fallback(text)
    flat = []
    for t in toks:
        if t and set(t) <= set("();&|") and t not in SEP and len(t) > 1:
            i = 0
            while i < len(t):
                two = t[i:i + 2]
                if two in ("&&", "||", "|&", ";;"):
                    flat.append(two)
                    i += 2
                else:
                    flat.append(t[i])
                    i += 1
        else:
            flat.append(t)
    toks = ["\x00NL" if t == "\u00b6" else t for t in flat]
    stack, argv, sep_prev, pipe_src, pipe_lit = [], [], "", None, None
    for tok in toks + [";"]:
        if tok not in SEP:
            argv.append(tok)
            continue
        if tok == "(" and not argv:
            stack.append(ctx.copy())
            continue
        if tok == ")" and not argv:
            if stack:
                saved = stack.pop()
                ctx.cwds, ctx.env, ctx.links = saved.cwds, saved.env, saved.links
            continue
        if argv:
            r, pipe_src, pipe_lit = run_command(argv, tok, sep_prev, ctx, depth, pipe_src, pipe_lit)
            reasons += r
            if tok == ")" and stack:
                saved = stack.pop()
                ctx.cwds, ctx.env, ctx.links = saved.cwds, saved.env, saved.links
        argv = []
        if tok in (";", "\x00NL", "||", "&", ")") and ctx.pending_old:
            ctx.cwds = list(dict.fromkeys(ctx.cwds + ctx.pending_old))[:6]
            ctx.pending_old = None
        if tok != "|" and tok != "|&":
            pipe_lit = None
        if tok in ("&&", "||", "\x00NL"):
            pipe_src = None
        sep_prev = tok
    return reasons


def fallback(text):
    """lexing failed (unbalanced quotes): a coarse look so that a plain `rm -rf ~` is still caught"""
    if re.search(r"\brm\s+(-[A-Za-z-]*\s+)*(~|\$HOME|\$\{HOME\}|/|/\*|\.|\*)(\s|/|$|;|&|\|)", text):
        return ["コマンドを解析できませんでしたが、ホームやルートを対象にした rm のように見えます"]
    return []


def run_command(argv, sep, sep_prev, ctx, depth, pipe_src, pipe_lit):
    reasons = []
    argv = strip_redirects(argv)
    argv, assigns = unwrap(argv)
    for a in assigns:
        k, v = ASSIGN.match(a).groups()
        ctx.env[k] = expand(v.strip("'\""), ctx, ctx.cwds[0] if ctx.cwds else None)
        if "__SUBST__" in ctx.env[k]:
            ctx.env.pop(k, None)
    if not argv:
        return reasons, pipe_src, pipe_lit
    raw = argv[0]
    name = os.path.basename(raw).lower()
    args = argv[1:]
    cwd = ctx.cwds[0] if ctx.cwds else None
    short, long_ = flags_of(args)
    in_pipe_after = sep_prev in ("|", "|&")

    if name in ("cd", "pushd", "chdir"):
        rest = [a for a in args if a not in ("--", "-P", "-L", "-e", "-@")]
        if rest and rest[0] == "-":
            new = []
        else:
            tgt = expand(rest[0] if rest else "~", ctx, cwd)
            new = [] if tgt.startswith(("$", "`")) or "__SUBST__" in tgt else [norm(tgt, cwd, ctx)]
        if new:
            if sep == "&&":
                ctx.pending_old = list(ctx.cwds)
                ctx.cwds = new
            else:
                ctx.cwds = (list(dict.fromkeys(ctx.cwds + new)))[:6]
        return reasons, pipe_src, None
    if name == "ln" and ("s" in short or "symbolic" in long_):
        ops = operands(args)
        if len(ops) >= 2:
            a = norm(expand(ops[0], ctx, cwd), cwd, ctx)
            b = norm(expand(ops[1], ctx, cwd), cwd, ctx)
            if a and b:
                ctx.links[b] = a
        return reasons, pipe_src, None

    # shells and eval: the string they are given is code
    if name in SHELLS or name in ("eval", "source", "."):
        if name in ("eval", "source", "."):
            reasons += analyse(" ".join(args).replace("__SUBST__", ""), ctx.copy(), depth + 1)
        else:
            for i, a in enumerate(args):
                if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                    rest = [x for x in args[i + 1:] if x != "--"]
                    if rest:
                        reasons += analyse(rest[0], ctx.copy(), depth + 1)
                    break
            else:
                if in_pipe_after and pipe_lit == "__DECODED__":
                    reasons.append("デコード(base64 など)した内容を、そのままシェルで実行しようとしています")
                elif in_pipe_after and pipe_lit:
                    reasons += analyse(pipe_lit, ctx.copy(), depth + 1)
        return reasons, None, None
    if name in ("echo", "printf"):
        lit = literal_of(" ".join(shlex.quote(a) for a in argv))
        ops = operands(args)
        src = next((operand_reason(o, ctx, globs=True) for o in ops if operand_reason(o, ctx, globs=True)), None)
        return reasons, src, lit
    if name in ("base64", "xxd", "openssl", "basenc") and ("d" in short or "decode" in long_ or "D" in short or "r" in short or "-d" in args):
        return reasons, pipe_src, "__DECODED__"
    if name in SOURCES:
        pass

    if name in RM_LIKE:
        recursive = bool(short & {"r", "R"}) or "recursive" in long_ or name in ("shred", "srm", "unlink", "rimraf", "trash", "del-cli")
        for o in operands(args):
            r = operand_reason(o, ctx, globs=True)
            if r and (recursive or GLOB.search(os.path.basename(o))):
                reasons.append("%s で消そうとしています: %s" % (name, r))
        if not operands(args) and cwd_reason(ctx) and name == "rimraf":
            reasons.append("rimraf を、保護された場所(%s)で実行しようとしています" % cwd_reason(ctx))
        if pipe_src and any(o.startswith("$") for o in operands(args)):
            reasons.append("保護された場所を列挙した結果を、%s で消そうとしています: %s" % (name, pipe_src))
        return reasons, None, None
    if name in ("find", "gfind", "fd", "fdfind"):
        opts_skip = {"-H", "-L", "-P", "-E", "-X", "-x", "-d", "-s", "-f", "-O1", "-O2", "-O3", "-D"}
        i = 0
        while i < len(args) and args[i] in opts_skip:
            i += 1
        roots = []
        if name in ("fd", "fdfind"):
            roots = [a for a in args if not a.startswith("-")][1:2] or ["."]
        else:
            while i < len(args) and not args[i].startswith("-") and args[i] not in ("(", "!", ")"):
                roots.append(args[i])
                i += 1
            roots = roots or ["."]
        hit = None
        for x in roots:
            hit = operand_reason(x, ctx, globs=True)
            if hit:
                break
        if not hit and any(cwd_reason(ctx) and x in (".", "./", "*") for x in roots):
            hit = "`%s` は、保護された場所(%s)です" % (roots[0], cwd_reason(ctx))
        narrow = any(a in ("-name", "-iname", "-path", "-ipath", "-regex", "-iregex", "-newer", "-mtime", "-mmin", "-user", "-perm", "-size", "-inum", "-lname")
                     and i2 + 1 < len(args) and not (a in ("-name", "-iname") and wide_glob(args[i2 + 1]))
                     for i2, a in enumerate(args)) or any(a in ("-e", "--extension", "-g", "--glob") for a in args)
        deletes = "-delete" in args or any(a in ("-exec", "-execdir", "-ok", "-okdir", "-x", "--exec", "-X", "--exec-batch") and i2 + 1 < len(args) and
                                           (os.path.basename(args[i2 + 1]).lower() in RM_LIKE | {"mv", "truncate", "sudo", "sh", "bash", "zsh", "env"})
                                           for i2, a in enumerate(args))
        if hit and deletes and not narrow:
            reasons.append("find で、保護された場所の中身を絞り込まずに消そうとしています: " + hit)
        return reasons, (hit if hit and not narrow else None), None
    if name == "xargs":
        valued = {"-n", "-I", "-L", "-P", "-d", "-s", "-a", "-E", "-J", "-R", "-S", "--max-args", "--replace", "--max-procs", "-i"}
        rest = list(args)
        k = 0
        while k < len(rest) and rest[k].startswith("-"):
            k += 2 if rest[k] in valued else 1
        cmd = rest[k:]
        cmd, _ = unwrap(cmd)
        if cmd:
            c0 = os.path.basename(cmd[0]).lower()
            if c0 in RM_LIKE and pipe_src:
                reasons.append("保護された場所を列挙した結果を、xargs で消そうとしています: " + pipe_src)
            elif c0 in SHELLS and pipe_src and any(re.search(r"\b(rm|unlink|shred|rimraf)\b", a) for a in cmd[1:]):
                reasons.append("保護された場所を列挙した結果を、xargs 経由のシェルで消そうとしています: " + pipe_src)
            elif c0 in RM_LIKE:
                for o in operands(cmd[1:]):
                    r = operand_reason(o, ctx)
                    if r:
                        reasons.append("xargs %s で消そうとしています: %s" % (c0, r))
        return reasons, pipe_src, None
    if name == "mv":
        ops = operands(args, valued={"-t", "-S"})
        t_dir = None
        for i, a in enumerate(args):
            if a == "-t" and i + 1 < len(args):
                t_dir = args[i + 1]
            elif a.startswith("--target-directory="):
                t_dir = a.split("=", 1)[1]
        srcs = ops if t_dir else ops[:-1]
        dest = t_dir or (ops[-1] if ops else None)
        for o in srcs:
            r = operand_reason(o, ctx, globs=True)
            if r:
                same_parent = False
                if dest and not t_dir and len(srcs) == 1 and not GLOB.search(o):
                    a = norm(expand(o, ctx, cwd), cwd, ctx)
                    b = norm(expand(dest, ctx, cwd), cwd, ctx)
                    same_parent = bool(a and b and fold(os.path.dirname(a)) == fold(os.path.dirname(b)))
                if not same_parent:
                    reasons.append("mv で保護された場所を動かそうとしています: " + r)
        return reasons, None, None
    if name in ("chmod", "chown", "chgrp", "chflags"):
        recursive = bool(short & {"R", "r"}) or "recursive" in long_
        ops = operands(args)
        for o in ops[1:]:
            for t0 in brace_expand(o):
                for c in ctx.cwds:
                    p = norm(expand(t0, ctx, c), c, ctx) if not GLOB.search(t0) else None
                    if p and is_critical(p) and (recursive or name == "chmod" and re.search(r"(^0{3,4}$|[a-z]*-[rwx]+)", ops[0] if ops else "")):
                        reasons.append("%s で、ホーム・ルート・システムの場所(%s)の権限を変えようとしています" % (name, p))
        return reasons, None, None
    if name == "rsync":
        ops = operands(args, valued={"--exclude", "--include", "-e", "--exclude-from", "--include-from", "--filter", "-f", "--rsh", "--files-from"})
        if any(a.startswith("--delete") for a in args) and ops:
            r = operand_reason(ops[-1], ctx, globs=False)
            if r:
                reasons.append("rsync --delete で保護された場所の中身を消す恐れがあります: " + r)
        if "--remove-source-files" in args:
            for o in ops[:-1]:
                r = operand_reason(o, ctx, globs=False)
                if r:
                    reasons.append("rsync --remove-source-files で保護された場所の中身が消えます: " + r)
        return reasons, None, None
    if name in ("tar", "bsdtar", "gtar", "zip") and ("--remove-files" in args or name == "zip" and any(a.startswith("-") and "m" in a[1:] and not a.startswith("--") for a in args)):
        for o in operands(args):
            r = operand_reason(o, ctx, globs=False)
            if r:
                reasons.append("%s が、保護された場所を圧縮したあとで消そうとしています: %s" % (name, r))
        return reasons, None, None
    if name in ("truncate", "cp") and (name == "truncate" or any(a == "/dev/null" for a in args)):
        for o in operands(args, valued={"-s", "-r", "--size"}):
            if o == "/dev/null":
                continue
            r = operand_reason(o, ctx, globs=True)
            if r:
                reasons.append("%s で、保護された場所を空にしようとしています: %s" % (name, r))
        return reasons, None, None
    if name == "git":
        i, base_dirs, work = 0, [], None
        while i < len(args) and args[i].startswith("-"):
            a = args[i]
            if a == "-C" and i + 1 < len(args):
                base_dirs.append(args[i + 1])
                i += 2
            elif a in ("-c", "--exec-path", "--namespace", "--super-prefix") and i + 1 < len(args) and "=" not in a:
                i += 2
            elif a.startswith("--work-tree="):
                work = a.split("=", 1)[1]
                i += 1
            elif a == "--work-tree" and i + 1 < len(args):
                work = args[i + 1]
                i += 2
            else:
                i += 1
        rest = args[i:]
        sub = rest[0] if rest else ""
        dirs = []
        for d in ([work] if work else base_dirs):
            for c in ctx.cwds:
                dirs.append(norm(expand(d, ctx, c), c, ctx))
        if not dirs:
            dirs = [c for c in ctx.cwds if c]
        wipes = sub == "clean" or sub == "reset" and "--hard" in rest or sub == "checkout" and ("-f" in rest or "--force" in rest or "--" in rest and rest[-1] == ".") or sub == "stash" and "-u" in rest
        if wipes:
            for d in dirs:
                if d and is_protected(d):
                    reasons.append("git %s を、保護された場所(%s)で実行しようとしています" % (sub, d))
                    break
            for o in operands(rest[1:]):
                r = operand_reason(o, ctx, globs=False)
                if sub == "clean" and r:
                    reasons.append("git clean で保護された場所を消そうとしています: " + r)
        return reasons, None, None
    if name == "dd":
        for a in args:
            if re.match(r"^of=/dev/(r?disk|sd|nvme|hd)", a):
                reasons.append("dd でディスク装置(%s)へ書き込もうとしています" % a[3:])
        return reasons, None, None
    if name == "diskutil":
        sub = (args[0] if args else "").lower()
        if sub.startswith(("erase", "reformat", "partition", "secureerase", "zero", "random")) or \
                (sub in ("apfs", "coreStorage".lower()) and len(args) > 1 and re.match(r"(?i)^(delete|erase)", args[1])):
            reasons.append("diskutil でディスクやボリュームを消去しようとしています")
        return reasons, None, None
    if name.startswith(("mkfs", "newfs")):
        return ["%s でファイルシステムを作り直そうとしています" % name], None, None
    if INTERP.match(name):
        src = " ".join(args)
        if interp_reason(src) or (TREE_KILL.search(src) and cwd_reason(ctx) and re.search(r"rmtree\(['\"]\.['\"]", src)):
            reasons.append("%s のワンライナーで、ホームなどの下を丸ごと消す恐れがあります" % name)
        return reasons, None, None
    if name.startswith("$") or name.startswith("`") or name == "__subst__":
        for o in operands(args):
            r = operand_reason(o, ctx)
            if r:
                reasons.append("コマンド名が展開で作られていて、保護された場所を対象にしています: " + r)
                break
        return reasons, None, None

    # a source of paths: remember where it points, so that a later `xargs rm` / `while read` can be judged
    new_src = pipe_src
    if name in ("ls", "echo", "printf", "cat", "tree", "du", "locate", "mdfind"):
        ops = operands(args)
        hit = next((operand_reason(o, ctx, globs=True) for o in ops if operand_reason(o, ctx, globs=True)), None)
        if not hit and not ops and cwd_reason(ctx) and name in ("ls", "tree", "du"):
            hit = "カレントディレクトリが保護された場所(%s)です" % cwd_reason(ctx)
        new_src = hit
    elif name in FILTERS:
        new_src = pipe_src
    else:
        new_src = None
    # `... | while read f; do rm -rf "$f"; done`
    return reasons, new_src, None


def main():
    args = sys.argv[1:]
    cwd = None
    try:
        if "--cwd" in args:
            cwd = args[args.index("--cwd") + 1] or None
    except IndexError:
        cwd = None
    try:
        text = sys.stdin.read()
        base = os.path.realpath(cwd) if cwd else None
        out, seen = [], []
        for r in analyse(text, Ctx([base])):
            if r not in seen:
                seen.append(r)
        if seen:
            print("\n".join(seen[:4]))
    except Exception:  # noqa: BLE001
        pass


if __name__ == "__main__":
    main()
