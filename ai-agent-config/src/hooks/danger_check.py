#!/usr/bin/env python3
"""danger_check.py - does a shell command wipe out (or make unusable) a home or system directory?

  danger_check.py [--cwd DIR] < command-line        stdout: one line per reason (nothing = no objection)

Exits 0 always. Unlike the other hooks this one does NOT simply let a command through when its own analysis
breaks: an internal error falls back to a coarse look (a deleting word plus a home/root-looking word), and a
command nested too deeply to follow is refused.

How a command line is read: line continuations are joined, ANSI-C quotes ($'..') decoded, comments dropped,
heredoc bodies and here-strings set aside (run as code when the command is a shell or an interpreter),
$(...) / `...` / <(...) either evaluated (echo, printf, pwd, realpath, cd X && pwd, whoami, base64 -d of a
literal ...) or analysed as commands of their own, the rest lexed once with shlex, redirections dropped,
`if/then/do/{` skipped, wrappers (sudo, env, nice, timeout, nohup, npx, uv run, ssh localhost ...) unwrapped,
and `cd`, `( )`, assignments, `for x in ...`, functions, aliases, `ln -s` and `mv` tracked. A relative path is
judged for every directory the command line might be running in (a failed `cd` leaves it where it was).

Refused: rm/shred/srm/unlink/trash/rimraf (recursive, or any glob that can match a protected place) on a protected
place; find <protected> with -delete/-exec rm and nothing narrowing the match; `... | xargs rm` / `while read`
fed by such a find or ls; mv of a protected place (a rename in the same folder is fine); recursive chmod/chown on the
home, the root or a system directory; rsync --delete / tar --remove-files / zip -m on one; git clean / reset --hard in
the home; truncate / cp /dev/null on one; dd of=/dev/disk*; diskutil erase*; mkfs/newfs; python/perl/ruby/node/
osascript one-liners whose removal calls point at the home; code piped into a shell after decoding.
Protected: /, the home and its parents, system directories, the home's personal folders (Documents, Desktop,
Downloads, Pictures, Movies, Music, Library, .ssh, .gnupg, .config, ...). Deleting something *inside* them
(rm -rf ~/Documents/old-project) is fine. Add your own, one per line, in ~/.config/ai-agent-config/danger-paths.txt.
Best effort: a script file that does the deleting, or a shell built at run time, cannot be seen.
"""
import fnmatch
import os
import pwd
import re
import shlex
import sys
import base64

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
               "/opt/homebrew", "/usr/local/bin", "/var/db", "/private/var/db", "/var/root", "/private/var/root",
               "/Library/Application Support", "/Library/Preferences"}
DEEP_SYSTEM = ("/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/bin", "/sbin", "/etc",
               "/private/etc", "/dev", "/cores", "/var/db", "/private/var/db")
CRITICAL = {"/", "/System", "/usr", "/bin", "/sbin", "/etc", "/Library", "/Applications", "/private", "/var", "/Users", "/home"}
PERSONAL = ["Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", "Library", "Public", "Applications",
            ".ssh", ".gnupg", ".config", ".local", ".claude", ".codex", ".gemini", ".grok", ".knowledge", ".agents",
            ".agent-state", ".aws", ".kube", ".docker", "Library/Application Support", "Library/Keychains",
            "Library/Mobile Documents", "Library/Containers", "Library/Group Containers", "Library/CloudStorage",
            "Library/Mail", "Library/Messages", "Pictures/Photos Library.photoslibrary"]
RESERVED = {"if", "then", "else", "elif", "fi", "while", "until", "do", "done", "case", "esac", "function", "time", "!",
            "{", "}", "coproc", ";;"}
SEP = {";", "&&", "||", "|", "&", "|&", "(", ")", "\x00NL"}
SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "ash", "pwsh", "powershell"}
RM_LIKE = {"rm", "grm", "gnurm", "srm", "shred", "unlink", "rmdir", "rimraf", "trash", "trash-put", "trash-cli", "del-cli", "remove-item"}
INTERP = re.compile(r"^(python|ruby|perl|node|php|osascript|lua|deno|bun|nodejs|awk|gawk|tclsh|expect|pwsh|powershell)[0-9.]*$")
FILTERS = {"grep", "egrep", "fgrep", "rg", "sort", "head", "tail", "sed", "awk", "tr", "uniq", "cut", "xargs", "tee", "while",
           "read", "cat"}
ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
GLOB = re.compile(r"[*?\[]")
WRAP_OPTS = {"sudo": set("ugphCDRTUrt"), "doas": set("uC"), "env": set("uSCP"), "nice": set("n"), "ionice": set("cnp"),
             "stdbuf": set("ioe"), "caffeinate": set("tw"), "arch": set(), "setsid": set(), "nohup": set(), "command": set(),
             "builtin": set(), "exec": set("a"), "time": set("fo"), "xcrun": set(), "chroot": set(), "busybox": set(),
             "unbuffer": set(), "chronic": set(), "watch": set("ndp"), "flock": set("wEc"), "script": set("tF"),
             "npx": set("pc"), "bunx": set(), "pnpx": set(), "dlx": set(), "gtimeout": set(), "timeout": set("sk"),
             "runuser": set("ulg"), "parallel": set("jN"), "launchctl": set()}
TIMEOUTS = {"timeout", "gtimeout"}
RUNNERS = {"uv", "poetry", "pipenv", "conda", "pdm", "rye", "hatch"}
DEL_NAMES = r"(?:rmtree|remove_tree|rm_rf|rm_r|rmSync|rimraf|rmdirSync|unlinkSync|removeItem|trashItem|Remove-Item|rmdir)"
STR = r"""(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")"""


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
PROTECTED_LIST = sorted(PROTECTED)
CRITICAL_ALL = {fold(p) for p in CRITICAL} | {fold(HOME_ENV), fold(HOME_PW)} | {fold(os.path.dirname(h)) for h in (HOME_ENV, HOME_PW)}


def is_protected(p):
    q = fold(p)
    return q in PROTECTED or any(q == fold(d) or q.startswith(fold(d) + "/") for d in DEEP_SYSTEM)


def is_critical(p):
    return fold(p) in CRITICAL_ALL


def brace_expand(s, limit=64):
    out, work = [], [s]
    while work and len(out) < limit:
        cur = work.pop()
        m = re.search(r"\{([^{}]*,[^{}]*)\}", cur)
        if not m:
            out.append(cur)
            continue
        for alt in m.group(1).split(","):
            work.append(cur[:m.start()] + alt + cur[m.end():])
            if len(work) > 4 * limit:
                break
    return out or [s]


class Ctx:
    """where a command line may be running, what it assigned, which links and functions it made"""

    def __init__(self, cwds, env=None, links=None, multi=None, funcs=None, aliases=None):
        self.cwds = list(cwds) or [None]
        self.env = dict(env or {})
        self.links = dict(links or {})
        self.multi = dict(multi or {})        # for x in a b c: x -> [a, b, c]
        self.funcs = funcs if funcs is not None else {}
        self.aliases = aliases if aliases is not None else {}
        self.pending_old = None               # where to fall back to if the `cd` of an && chain failed
        self.subst_bodies = []                # bodies of $(...) that could not be evaluated
        self.psub = {}                        # <(...) markers -> (value or None, body)

    def copy(self):
        c = Ctx(self.cwds, self.env, self.links, self.multi, self.funcs, self.aliases)
        c.subst_bodies = list(self.subst_bodies)
        c.psub = dict(self.psub)
        return c

    def keep_cwds(self, new):
        out = list(dict.fromkeys(new))
        if len(out) > 6:  # never drop a protected directory: keep those first, then the newest others
            prot = [c for c in out if c and is_protected(c)]
            rest = [c for c in out if c not in prot]
            out = (prot + rest[-max(0, 6 - len(prot)):])[:max(6, len(prot))]
        self.cwds = out


def norm(path, cwd, ctx):
    try:
        if not os.path.isabs(path):
            if cwd is None:
                return None
            path = os.path.join(cwd, path)
        lex = os.path.normpath(path)
        try:
            p = os.path.realpath(lex)
        except (OSError, ValueError):
            p = lex
    except (ValueError, TypeError):
        return None
    for src, dst in ctx.links.items():
        if fold(p) == fold(src) or fold(p).startswith(fold(src) + "/"):
            p = os.path.normpath(dst + p[len(src):])
            break
    return p


def norm_both(path, cwd, ctx):
    """the lexical and the symlink-resolved form (a protected folder may itself be a symlink)"""
    out = []
    p = norm(path, cwd, ctx)
    if p:
        out.append(p)
    try:
        if os.path.isabs(path) or cwd:
            lex = os.path.normpath(path if os.path.isabs(path) else os.path.join(cwd, path))
            if lex not in out:
                out.append(lex)
    except (ValueError, TypeError):
        pass
    return out


def decode_ansi_c(s):
    def one(m):
        body = m.group(1)

        def esc(e):
            t = e.group(0)
            if t[1] in "xX":
                return chr(int(t[2:], 16))
            if t[1] in "01234567":
                return chr(int(t[1:], 8) % 256)
            return {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "a": "\a", "b": "\b", "e": "\x1b"}.get(t[1], t[1])
        out = re.sub(r"\\(x[0-9a-fA-F]{1,2}|[0-7]{1,3}|.)", esc, body).replace("\x00", "")
        return "'" + out.replace("'", "'\\''") + "'"
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
    """~, ~user, ~+, $HOME, ${HOME...}, $USER, $PWD and earlier assignments; unknown ones stay as written"""
    t = tok
    t = re.sub(r"\$\{HOME[^}]*\}|\$ENV\{HOME\}", HOME, t)

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
    elif (t == "~+" or t.startswith("~+/")) and cwd:
        t = cwd + t[2:]
    else:
        m = re.match(r"^~([A-Za-z0-9_.-]+)(/.*)?$", t)
        if m:
            try:
                t = os.path.realpath(pwd.getpwnam(m.group(1)).pw_dir) + (m.group(2) or "")
            except KeyError:
                pass
    return t


def variants(tok, ctx):
    """a word with every value a loop variable can take (bounded)"""
    out = [tok]
    for var, vals in ctx.multi.items():
        pat = re.compile(r"\$\{%s\}|\$%s\b" % (var, var))
        if any(pat.search(x) for x in out):
            out = [pat.sub(lambda m: v, x) for x in out for v in vals][:64]
    return out


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
    m = re.match(r"^cd\s+(\S+)\s*(?:&&|;)\s*pwd(?:\s+-[PL])?$", b)
    if m:
        t = expand(m.group(1).strip("'\""), ctx, cwd)
        return norm(t, cwd, ctx) if not t.startswith("$") else None
    m = re.match(r"^(?:realpath|readlink\s+-f|greadlink\s+-f|dirname)\s+(?:--\s+)?(\S+)$", b)
    if m:
        t = expand(m.group(1).strip("'\""), ctx, cwd)
        if t.startswith("$"):
            return None
        p = norm(t, cwd, ctx)
        return os.path.dirname(p) if b.startswith("dirname") and p else p
    m = re.match(r"^eval\s+echo\s+(\S+)$", b)
    if m:
        return expand(m.group(1).strip("'\""), ctx, cwd)
    m = re.match(r"^(?:echo|printf)\s+(?:-n\s+)?(['\"]?)([A-Za-z0-9+/=]+)\1\s*\|\s*(?:base64|openssl\s+base64)\s+(?:-d|--decode|-D)$", b)
    if m:
        try:
            return base64.b64decode(m.group(2)).decode("utf-8", "replace")
        except Exception:  # noqa: BLE001
            return None
    lit = literal_of(b)
    if lit is not None:
        return expand(lit, ctx, cwd)
    return None


def preprocess(text, ctx, cwd, depth, reasons):
    """replace $((..)), evaluate or analyse $(..) and `..`"""
    for start, end, body in reversed(substitutions(text)):
        v = eval_simple(body, ctx, cwd)
        if text[start:start + 2] in ("<(", ">("):
            marker = "__PSUB%d__" % len(ctx.psub)
            ctx.psub[marker] = (v, body)
            if v is None:
                reasons += analyse(body, ctx.copy(), depth + 1)
            text = text[:start] + marker + text[end:]
            continue
        if v is not None:
            repl = v
        else:
            reasons += analyse(body, ctx.copy(), depth + 1)
            ctx.subst_bodies.append(body)
            repl = "__SUBST__"
        text = text[:start] + repl + text[end:]
    return text


def scan_script(text):
    """-> (text without comments and heredoc bodies, [(command line, body, terminated)]).
    One pass over the lines, keeping the quote state, so an apostrophe in a comment or a `<<` in a string is no trap."""
    out_lines, docs = [], []
    lines = text.split("\n")
    i = 0
    quote = None
    while i < len(lines):
        line = lines[i]
        i += 1
        buf, pending, j = [], [], 0
        while j < len(line):
            c = line[j]
            if quote:
                if c == "\\" and quote == '"' and j + 1 < len(line):
                    buf.append(line[j:j + 2])
                    j += 2
                    continue
                if c == quote:
                    quote = None
                buf.append(c)
                j += 1
                continue
            if c in "'\"":
                quote = c
                buf.append(c)
                j += 1
                continue
            if c == "\\" and j + 1 < len(line):
                buf.append(line[j:j + 2])
                j += 2
                continue
            if c == "#" and (j == 0 or line[j - 1] in " \t;&|(") and not line.startswith("${#", j - 2):
                break
            if line.startswith("<<<", j):
                m = re.match(r"<<<\s*(?:'([^']*)'|\"([^\"]*)\"|(\S+))", line[j:])
                if m:
                    docs.append((("".join(buf)), m.group(1) or m.group(2) or m.group(3) or "", True))
                    j += m.end()
                    continue
            m = re.match(r"<<(-?)\s*(?:'([^']*)'|\"([^\"]*)\"|\\?([^\s;&|<>()'\"]+))", line[j:])
            if m:
                pending.append((m.group(1) == "-", m.group(2) or m.group(3) or m.group(4)))
                j += m.end()
                continue
            buf.append(c)
            j += 1
        cleaned = "".join(buf)
        out_lines.append(cleaned)
        for dash, term in pending:
            body, closed = [], False
            while i < len(lines):
                l = lines[i]
                i += 1
                if (l.strip() if dash else l.rstrip("\r")) == term:
                    closed = True
                    break
                body.append(l)
            docs.append((cleaned, "\n".join(body), closed))
    return "\n".join(out_lines), docs


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
            out.append(" ¶ ")
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


def strip_redirects(argv, reasons=None, targets=None):
    out, i = [], 0
    while i < len(argv):
        t = argv[i]
        if REDIR.match(t) or t in ("&>", "&>>", ">&", ">|"):
            if out and re.fullmatch(r"\d{1,2}", out[-1]) and t[0] in "<>&":
                out.pop()
            i += 1
            if i < len(argv):
                if reasons is not None and re.match(r"^/dev/(r?disk|sd|nvme|hd)", argv[i]) and ">" in t:
                    reasons.append("ディスク装置(%s)へ直接書き込もうとしています" % argv[i])
                if targets is not None and "<" in t:
                    targets.append(argv[i])
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
    guard = 0
    while argv and guard < 40:
        guard += 1
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
            if base == "launchctl" and argv[:1] in (["asuser"], ["submit"]):
                argv = argv[2:]
                continue
            if base == "parallel":
                while argv and argv[0].startswith("-") and argv[0] != "--":
                    opt = argv.pop(0)
                    if opt in ("-j", "-N", "-n", "-S", "-a") and argv:
                        argv.pop(0)
                if argv and argv[0] == "--":
                    argv.pop(0)
                if ":::" in argv:
                    k = argv.index(":::")
                    argv = argv[:k] + argv[k + 1:]
                continue
            while argv and argv[0].startswith("-") and argv[0] != "--":
                opt = argv.pop(0)
                if base == "env" and opt == "-S" and argv:
                    argv = (safe_tokens(argv.pop(0)) or []) + argv
                    continue
                if opt.startswith("--"):
                    continue
                if re.match(r"^-\d+$", opt):
                    continue
                if opt[1:] and opt[-1] in valued and len(opt) >= 2 and argv:
                    if len(opt) == 2 or opt[1:-1].isalpha():
                        argv.pop(0)
            if argv and argv[0] == "--":
                argv.pop(0)
            if base in TIMEOUTS and argv:
                argv.pop(0)  # the duration
            if base in ("flock", "script") and argv:
                argv.pop(0)  # the lock / transcript file
            if base == "env":
                while argv and ASSIGN.match(argv[0]):
                    assigns.append(argv.pop(0))
            if base == "npx" and argv:
                argv[0] = re.sub(r"@[^/@]*$", "", argv[0]) if not argv[0].startswith("@") else argv[0]
        elif base in ("pnpm", "yarn", "npm", "bun") and argv[1:2] in (["dlx"], ["exec"], ["x"]):
            argv = argv[2:]
            while argv and argv[0].startswith("-") and argv[0] != "--":
                argv.pop(0)
            if argv and argv[0] == "--":
                argv.pop(0)
        elif base in RUNNERS and argv[1:2] in (["run"], ["exec"], ["x"], ["tool"]):
            argv = argv[2:]
            while argv and argv[0].startswith("-") and argv[0] != "--":
                argv.pop(0)
            if argv and argv[0] == "--":
                argv.pop(0)
        elif base == "su":
            for i, a in enumerate(argv):
                if a in ("-c", "--command") and i + 1 < len(argv):
                    return ["bash", "-c", argv[i + 1]], assigns
            break
        elif base == "ssh":
            rest = [a for a in argv[1:] if not a.startswith("-")]
            if rest and rest[0].split("@")[-1] in ("localhost", "127.0.0.1", "::1"):
                return ["bash", "-c", " ".join(rest[1:])], assigns
            break
        else:
            break
    return argv, assigns


def wide_glob(name):
    """a glob that matches (nearly) everything in a folder: *, .*, .[a-z]*, ?*  -- not *.dmg"""
    core = re.sub(r"\[[^\]]*\]", "", name)
    core = re.sub(r"[*?]", "", core).strip(".")
    return len(core) < 2


def glob_hits_protected(pattern):
    """does this glob (all of its path) match some protected place?"""
    pat = fold(pattern)
    for p in PROTECTED_LIST:
        if fnmatch.fnmatchcase(p, pat):
            return p
    return None


def operand_reason(tok, ctx, *, globs=True):
    """why this operand is a protected place (or a glob that reaches one), else None"""
    for t0 in brace_expand(tok):
        for t1 in variants(t0, ctx):
            for cwd in ctx.cwds:
                t = expand(t1, ctx, cwd)
                if re.match(r"^\$\{[A-Za-z_][^}]*\}(/+(\.?\*)?)?$|^\$[A-Za-z_][A-Za-z0-9_]*(/+(\.?\*)?)?$", t) and ("*" in t or t.endswith("/")):
                    return "展開される変数だけの `%s` を対象にしています(変数が空だと、ルート直下全体になります。`${VAR:?}` を使うと安全です)" % tok
                bare = t.strip("/")
                if bare == "__SUBST__" and any(re.search(r"~|\bHOME\b|/Users|\$USER|realpath|readlink|dirname|NFSHomeDirectory", b) for b in ctx.subst_bodies):
                    return "`%s` は、ホームなどを指す結果を返すコマンドの置き換えです" % tok
                if t.startswith(("$", "`")) or "__SUBST__" in t:
                    continue
                if globs and GLOB.search(t):
                    base = os.path.basename(t.rstrip("/"))
                    full = t if os.path.isabs(t) else (os.path.join(cwd, t) if cwd else None)
                    if full:
                        full = os.path.normpath(full)
                        hit = glob_hits_protected(full)
                        if hit:
                            return "`%s` は、保護された場所(%s)に当たる指定です" % (tok, hit)
                        parent = norm(os.path.dirname(full) or ".", cwd, ctx)
                        if wide_glob(base) and parent and is_protected(parent):
                            return "`%s` は、保護された場所(%s)の直下を丸ごと対象にしています" % (tok, parent)
                    continue
                for p in norm_both(t.rstrip("/") or "/", cwd, ctx):
                    if is_protected(p):
                        return "`%s` は保護された場所(%s)です" % (tok, p)
    return None


def cwd_reason(ctx):
    for cwd in ctx.cwds:
        if cwd and is_protected(cwd):
            return cwd
    return None


def literal_path_reason(expr, ctx):
    """a path written in an interpreter's code (a literal, or the home looked up): protected or not"""
    e = expr.strip()
    e = re.sub(r"os\.path\.join\(\s*(.*?)\s*,\s*(" + STR + r")\s*\)", lambda m: "%s/%s" % (m.group(1), m.group(3) or m.group(4)), e)
    e = re.sub(r"os\.path\.expanduser\(\s*(" + STR + r")\s*\)", lambda m: m.group(2) or m.group(3), e)
    e = re.sub(r"(?:Path\.home\(\)|os\.homedir\(\)|os\.environ\[['\"]HOME['\"]\]|ENV\[['\"]HOME['\"]\]|\$ENV\{HOME\}|Dir\.home|"
               r"NSHomeDirectory\(\)|__import__\(['\"]os['\"]\)\.path\.expanduser\(['\"]~['\"]\))", "~", e)
    lits = re.findall(STR, e)
    cand = [a or b for a, b in lits] or [e.strip("'\" ")]
    for c in cand:
        c = c.replace("\\\\", "\\")
        if re.match(r"^(~|/|\.\.?$|\.\./|\./)", c) or c == "~":
            r = operand_reason(c, ctx)
            if r:
                return r
            if c in (".", "./") and cwd_reason(ctx):
                return "`%s` は、保護された場所(%s)です" % (c, cwd_reason(ctx))
    if e.strip() in ("~", "'~'", '"~"'):
        return "ホームそのものです"
    return None


def interp_reasons(src, ctx, depth):
    """removal calls and shell strings inside an interpreter one-liner or script"""
    reasons = []
    # shell strings handed to system()/exec()/subprocess: run them through the shell analysis
    for m in re.finditer(r"(?:system|popen|execSync|exec|spawnSync|check_call|check_output|run|call|Popen|backticks|do shell script)"
                         r"\s*\(?\s*" + STR, src):
        cmd = m.group(1) or m.group(2)
        if cmd and re.match(r"^\s*(sudo\s+)?(rm|find|dd|diskutil|mv|chmod|chown|rsync|git|truncate|cp|mkfs|newfs|shred|trash|tar|zip|sh|bash)\b", cmd):
            reasons += analyse(cmd, ctx.copy(), depth + 1)
    for m in re.finditer(r"\b(?:exec|spawn)\s+((?:sudo\s+)?(?:rm|find|dd|diskutil|mv|chmod|chown|rsync|truncate|shred|trash)\b[^;\n'\"]*)", src):
        reasons += analyse(m.group(1), ctx.copy(), depth + 1)
    for m in re.finditer(r"do shell script\s+" + STR, src):
        reasons += analyse(m.group(1) or m.group(2) or "", ctx.copy(), depth + 1)
    # list form: ['rm', '-rf', path]
    for m in re.finditer(r"\[\s*['\"](rm|find|mv|chmod|chown|shred|trash|rimraf)['\"]\s*,((?:[^\]\[]|\[[^\]]*\])*)\]", src):
        items = []
        for part in re.split(r",(?![^()]*\))", m.group(2)):
            r = literal_path_reason(part, ctx)
            items.append(part.strip().strip("'\"") if not r else "~")
        reasons += analyse(m.group(1) + " " + " ".join(shlex.quote(i) if i != "~" else "~" for i in items), ctx.copy(), depth + 1)
    # direct removal calls: rmtree(path), shutil.rmtree(path), fs.rmSync(path), FileUtils.rm_rf(path) ...
    for m in re.finditer(DEL_NAMES + r"\s*\(?\s*((?:[^(),]|\([^()]*(?:\([^()]*\)[^()]*)*\))+)", src):
        r = literal_path_reason(m.group(1), ctx)
        if r:
            reasons.append("ワンライナー(スクリプト)が、保護された場所を消す恐れがあります: " + r)
    if re.search(r"Finder.{0,60}delete\s+(every\s+item|folder|items?)\s+of\s+(home|folder|desktop|documents)", src, re.I | re.S):
        reasons.append("osascript で Finder からホームの中身を消そうとしています")
    return reasons


def analyse(text, ctx, depth=0):
    reasons = []
    if depth > 5:
        return ["入れ子が深すぎて解析できません(eval や bash -c の連鎖)。実行内容を確認できないので拒否します"]
    if not text.strip():
        return reasons
    big = len(text) > 400000
    if big:
        reasons += fallback(text)
    cwd0 = ctx.cwds[0] if ctx.cwds else None
    text = text.replace("\\\r\n", "").replace("\\\n", "")
    text = decode_ansi_c(text)
    text = re.sub(r"\$\(\([^()]*(?:\([^()]*\)[^()]*)*\)\)", "0", text)  # arithmetic: its << is no heredoc
    text = re.sub(r"(?<![\w'\"(\[,=])(['\"])~(/[^'\"]*)?\1(?![\w'\")\],])", lambda m: "__QT__" + (m.group(2) or ""), text)  # a quoted ~ word is a name, not the home
    text, docs = scan_script(text if not big else text[:200000] + "\n" + text[-200000:])
    for cmdline, body, closed in docs:
        spec = re.sub(r"<<-?\s*(?:'[^']*'|\"[^\"]*\"|\\?[^\s;&|<>()'\"]+)", " ", cmdline)
        names = []
        for seg in re.split(r"\|", spec):
            t = safe_tokens(seg)
            f, _ = unwrap(strip_redirects(t or []))
            names.append(os.path.basename(f[0]).lower() if f else "")
        first_args = []
        t0 = safe_tokens(re.split(r"\|", spec)[0])
        f0, _ = unwrap(strip_redirects(t0 or []))
        first_args = f0[1:] if f0 else []
        runs_as_code = any(n in SHELLS | {"eval", "source", "."} for n in names) or not closed
        if runs_as_code:
            reasons += analyse(body, ctx.copy(), depth + 1)
        elif names and INTERP.match(names[0]):
            reasons += interp_reasons(body, ctx, depth)
        elif names and names[0] == "xargs" and re.search(r"\b(rm|unlink|shred|rimraf)\b", " ".join(first_args)):
            for word in re.split(r"[\s,]+", body):
                r = operand_reason(word, ctx) if word else None
                if r:
                    reasons.append("here-string の中身を xargs で消そうとしています: " + r)
                    break
    # functions and aliases defined in the text (positional parameters are filled in when they are called)
    for m in re.finditer(r"(?:^|[;\n&|{(]\s*)(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\s*\)\s*\{(.*?)\}", text, re.S):
        ctx.funcs[m.group(1)] = m.group(2)
    for m in re.finditer(r"(?:^|[;\n&|]\s*)alias\s+([\w-]+)=(?:'([^']*)'|\"([^\"]*)\"|(\S+))", text):
        ctx.aliases[m.group(1)] = m.group(2) or m.group(3) or m.group(4) or ""
    text = preprocess(text, ctx, cwd0, depth, reasons)
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
    toks = ["\x00NL" if t == "¶" else t for t in flat]
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
                ctx.cwds, ctx.env, ctx.links, ctx.multi = saved.cwds, saved.env, saved.links, saved.multi
            continue
        if argv:
            r, pipe_src, pipe_lit = run_command(argv, tok, sep_prev, ctx, depth, pipe_src, pipe_lit)
            reasons += r
            if tok == ")" and stack:
                saved = stack.pop()
                ctx.cwds, ctx.env, ctx.links, ctx.multi = saved.cwds, saved.env, saved.links, saved.multi
        argv = []
        if tok in (";", "\x00NL", "||", "&", ")") and ctx.pending_old:
            ctx.keep_cwds(ctx.cwds + ctx.pending_old)
            ctx.pending_old = None
        if tok != "|" and tok != "|&":
            pipe_lit = None
        if tok in ("&&", "||", "\x00NL"):
            pipe_src = None
        sep_prev = tok
    return reasons


def fallback(text):
    """a coarse look, used when the analysis broke or could not lex: a deleting word near a home/root-looking word"""
    if re.search(r"\b(rm|rmdir|unlink|shred|srm|rimraf|trash)\b", text) and \
            re.search(r"(?:^|[\s\"'=(])(?:~|\$HOME|\$\{HOME\}|/Users|/)(?:/?\*|/)?(?:$|[\s\"';&|)])|\s(?:\.|\*)(?:$|\s|;|&|\|)", text):
        return ["コマンドを解析し切れませんでしたが、ホームやルートを対象にした削除のように見えます"]
    return []


def run_command(argv, sep, sep_prev, ctx, depth, pipe_src, pipe_lit):
    reasons = []
    in_targets = []
    argv = strip_redirects(argv, reasons, in_targets)
    argv, assigns = unwrap(argv)
    cwd = ctx.cwds[0] if ctx.cwds else None
    for a in assigns:
        k, v = ASSIGN.match(a).groups()
        val = expand(v.strip("'\""), ctx, cwd)
        if "__SUBST__" in val:
            ctx.env.pop(k, None)
        else:
            ctx.env[k] = val
    if not argv:
        return reasons, pipe_src, pipe_lit
    raw = argv[0]
    # for x in a b c  /  select x in ...
    if raw in ("for", "select") and "in" in argv[:3]:
        k = argv.index("in")
        var = argv[1] if k >= 2 else None
        if var:
            ctx.multi[var] = [expand(a, ctx, cwd) for a in argv[k + 1:]][:64] or ["__EMPTY__"]
        return reasons, pipe_src, None
    if raw in ("for", "select"):
        return reasons, pipe_src, None
    # a name that is a variable, an alias or a function
    if raw.startswith("$") and "__SUBST__" not in raw:
        val = expand(raw, ctx, cwd)
        if val != raw:
            toks = safe_tokens(val) or []
            return run_command(toks + argv[1:], sep, sep_prev, ctx, depth, pipe_src, pipe_lit)
    if raw in ctx.aliases:
        toks = safe_tokens(ctx.aliases[raw]) or []
        return run_command(toks + argv[1:], sep, sep_prev, ctx, depth, pipe_src, pipe_lit)
    if raw in ctx.funcs and depth < 4:
        body = ctx.funcs[raw]
        args_ = argv[1:]
        for n in range(1, 10):
            val = args_[n - 1] if n - 1 < len(args_) else ""
            body = re.sub(r"\$\{%d\}|\$%d\b" % (n, n), lambda m, v=val: shlex.quote(v) if re.search(r"\s", v) else v, body)
        body = re.sub(r"\$\{@\}|\$@|\$\*|\"\$@\"|\"\$\*\"", " ".join(args_), body)
        return analyse(body, ctx.copy(), depth + 1), pipe_src, None
    name = os.path.basename(raw).lower()
    args = argv[1:]
    short, long_ = flags_of(args)
    in_pipe_after = sep_prev in ("|", "|&")

    if name in ("cd", "pushd", "chdir"):
        rest = [a for a in args if a not in ("--", "-P", "-L", "-e", "-@")]
        if rest and rest[0] == "-":
            new = []
        else:
            tgt = expand(rest[0] if rest else "~", ctx, cwd)
            new = [] if tgt.startswith(("$", "`")) or "__SUBST__" in tgt else [norm(tgt, cwd, ctx)]
            new = [n for n in new if n]
        if new:
            if sep == "&&":
                ctx.pending_old = list(ctx.cwds)
                ctx.cwds = new
            else:
                ctx.keep_cwds(ctx.cwds + new)
        return reasons, pipe_src, None
    if name == "ln" and ("s" in short or "symbolic" in long_):
        ops = operands(args)
        if len(ops) >= 2:
            a = norm(expand(ops[0], ctx, cwd), cwd, ctx)
            b = norm(expand(ops[1], ctx, cwd), cwd, ctx)
            if a and b:
                if os.path.isdir(b) or ops[1].endswith("/"):
                    b = os.path.join(b, os.path.basename(a.rstrip("/")))
                ctx.links[b] = a
        return reasons, pipe_src, None

    # shells and eval: the string they are given is code
    if name in SHELLS or name in ("eval", "source", "."):
        if name in ("eval", "source", "."):
            for a in args:
                if a in ctx.psub and ctx.psub[a][0]:
                    reasons += analyse(ctx.psub[a][0], ctx.copy(), depth + 1)
            code = " ".join(expand(a, ctx, cwd) for a in args if a not in ctx.psub).replace("__SUBST__", "")
            if "__SUBST__" in " ".join(args) and any(re.search(r"base64|xxd|openssl", b) for b in ctx.subst_bodies):
                reasons.append("デコードした内容を eval で実行しようとしています")
            reasons += analyse(code, ctx.copy(), depth + 1)
        else:
            for i, a in enumerate(args):
                if a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                    rest = [x for x in args[i + 1:] if x != "--"]
                    if rest:
                        code = expand(rest[0], ctx, cwd)
                        if "__SUBST__" in rest[0] and any(re.search(r"base64|xxd|openssl", b) for b in ctx.subst_bodies):
                            reasons.append("デコードした内容を sh -c で実行しようとしています")
                        reasons += analyse(code.replace("__SUBST__", ""), ctx.copy(), depth + 1)
                    break
            else:
                if in_pipe_after and pipe_lit == "__DECODED__":
                    reasons.append("デコード(base64 など)した内容を、そのままシェルで実行しようとしています")
                elif in_pipe_after and pipe_lit:
                    reasons += analyse(pipe_lit, ctx.copy(), depth + 1)
        return reasons, None, None
    if name in ("echo", "printf"):
        lit = literal_of(" ".join(shlex.quote(a) for a in argv))
        src = next((operand_reason(o, ctx, globs=True) for o in operands(args) if operand_reason(o, ctx, globs=True)), None)
        return reasons, src, lit
    if name in ("base64", "xxd", "openssl", "basenc") and ("d" in short or "decode" in long_ or "D" in short or "r" in short or "-d" in args):
        return reasons, pipe_src, "__DECODED__"
    if name == "tee":
        return reasons, pipe_src, pipe_lit

    if name in RM_LIKE:
        recursive = bool(short & {"r", "R"}) or "recursive" in long_ or name in ("shred", "srm", "unlink", "rimraf", "trash", "trash-put", "trash-cli", "del-cli")
        for o in operands(args):
            r = operand_reason(o, ctx, globs=True)
            if r and (recursive or GLOB.search(o)):
                reasons.append("%s で消そうとしています: %s" % (name, r))
        if not operands(args) and cwd_reason(ctx) and name == "rimraf":
            reasons.append("rimraf を、保護された場所(%s)で実行しようとしています" % cwd_reason(ctx))
        if pipe_src and (not operands(args) or any("$" in o for o in operands(args))):
            reasons.append("保護された場所を列挙した結果を、%s で消そうとしています: %s" % (name, pipe_src))
        return reasons, None, None
    if name in ("find", "gfind", "fd", "fdfind"):
        return check_find(name, args, ctx, depth, reasons)
    if name == "xargs":
        valued = {"-n", "-I", "-L", "-P", "-d", "-s", "-a", "-E", "-J", "-R", "-S", "--max-args", "--replace", "--max-procs", "-i"}
        rest = list(args)
        k = 0
        src_from_file = None
        while k < len(rest) and rest[k].startswith("-"):
            if rest[k] == "-a" and k + 1 < len(rest):
                src_from_file = rest[k + 1]
            k += 2 if rest[k] in valued else 1
        cmd, _ = unwrap(rest[k:])
        feed = pipe_src
        for src_ in ([src_from_file] if src_from_file else []) + in_targets:
            if feed:
                break
            if src_ in ctx.psub:
                val, body = ctx.psub[src_]
                feed = (operand_reason(val, ctx) if val else None) or ("入力が置き換え(`%s`)で、ホームなどを指しています" % body if re.search(r"~|HOME|/Users|\$USER", body) else None)
            else:
                feed = operand_reason(src_, ctx)
        if cmd:
            c0 = os.path.basename(cmd[0]).lower()
            if c0 in RM_LIKE and feed:
                reasons.append("保護された場所を列挙した結果を、xargs で消そうとしています: " + feed)
            elif c0 in SHELLS and any(re.search(r"\b(rm|unlink|shred|rimraf)\b", a) for a in cmd[1:]):
                inner = " ".join(cmd[1:])
                if feed:
                    reasons.append("保護された場所を列挙した結果を、xargs 経由のシェルで消そうとしています: " + feed)
                reasons += analyse(" ".join(a for a in cmd[1:] if not a.startswith("-") or a == "-c") if False else _shell_c_code(cmd), ctx.copy(), depth + 1)
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
                elif dest and len(srcs) == 1:  # a rename in place: remember it, so that removing the new name is judged as removing the old
                    a = norm(expand(o, ctx, cwd), cwd, ctx)
                    b = norm(expand(dest, ctx, cwd), cwd, ctx)
                    if a and b:
                        ctx.links[b] = a
        return reasons, None, None
    if name in ("chmod", "chown", "chgrp", "chflags"):
        recursive = bool(short & {"R", "r"}) or "recursive" in long_
        ops = operands(args)
        for o in ops[1:]:
            for t0 in brace_expand(o):
                for c in ctx.cwds:
                    t = expand(t0, ctx, c)
                    p = norm(t, c, ctx) if not GLOB.search(t) else None
                    if p and is_critical(p) and (recursive or name == "chmod" and re.search(r"^0{3,4}$|^[ugoa]*-[rwx]+", ops[0] if ops else "")):
                        reasons.append("%s で、ホーム・ルート・システムの場所(%s)の権限を変えようとしています" % (name, p))
        return reasons, None, None
    if name == "rsync":
        ops = operands(args, valued={"--exclude", "--include", "-e", "--exclude-from", "--include-from", "--filter", "-f", "--rsh", "--files-from"})
        if any(a.startswith(("--delete", "--del")) for a in args) and ops:
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
        return check_git(args, ctx, reasons)
    if name == "dd":
        for a in args:
            if re.match(r"^of=/dev/(r?disk|sd|nvme|hd)", a):
                reasons.append("dd でディスク装置(%s)へ書き込もうとしています" % a[3:])
        return reasons, None, None
    if name == "diskutil":
        sub = (args[0] if args else "").lower()
        if sub.startswith(("erase", "reformat", "partition", "secureerase", "zero", "random")) or \
                (sub == "apfs" and len(args) > 1 and re.match(r"(?i)^(delete|erase)", args[1])):
            reasons.append("diskutil でディスクやボリュームを消去しようとしています")
        return reasons, None, None
    if name.startswith(("mkfs", "newfs")):
        return ["%s でファイルシステムを作り直そうとしています" % name], None, None
    if INTERP.match(name):
        reasons += interp_reasons(" ".join(args), ctx, depth)
        return reasons, None, None
    if name.startswith("$") or name.startswith("`") or name == "__subst__":
        for o in operands(args):
            r = operand_reason(o, ctx)
            if r:
                reasons.append("コマンド名が展開で作られていて、保護された場所を対象にしています: " + r)
                break
        return reasons, None, None

    # a source of paths: remember where it points, so that a later `xargs rm` / `while read` can be judged
    new_src = None
    if name in ("ls", "cat", "tree", "du", "locate", "mdfind"):
        ops = operands(args)
        new_src = next((operand_reason(o, ctx, globs=True) for o in ops if operand_reason(o, ctx, globs=True)), None)
        if not new_src and not ops and cwd_reason(ctx) and name in ("ls", "tree", "du"):
            new_src = "カレントディレクトリが保護された場所(%s)です" % cwd_reason(ctx)
    elif name in FILTERS:
        new_src = pipe_src
    return reasons, new_src, (pipe_lit if name == "cat" else None)


def _shell_c_code(cmd):
    for i, a in enumerate(cmd):
        if a.startswith("-") and not a.startswith("--") and "c" in a[1:] and i + 1 < len(cmd):
            return cmd[i + 1]
    return ""


def check_find(name, args, ctx, depth, reasons):
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
    if not hit and cwd_reason(ctx) and any(x in (".", "./", "*") for x in roots):
        hit = "`%s` は、保護された場所(%s)です" % (roots[0], cwd_reason(ctx))
    narrow = False
    for i2, a in enumerate(args):
        negated = i2 > 0 and args[i2 - 1] in ("!", "-not")
        nxt = args[i2 + 1] if i2 + 1 < len(args) else ""
        if a in ("-name", "-iname", "-path", "-ipath", "-regex", "-iregex") and not negated and not wide_glob(nxt.replace(".*", "*")):
            narrow = True
        if a in ("-newer", "-lname", "-inum", "-empty") and not negated:
            narrow = True
        if a in ("-e", "--extension", "-g", "--glob"):
            narrow = True
    runner = ("-exec", "-execdir", "-ok", "-okdir", "-x", "--exec", "-X", "--exec-batch")
    deletes = "-delete" in args
    for i2, a in enumerate(args):
        if a in runner and i2 + 1 < len(args):
            cmd = []
            for x in args[i2 + 1:]:
                if x in (";", "\\;", "+"):
                    break
                cmd.append(x)
            inner, _ = unwrap(cmd)
            if inner:
                r_inner, _s, _l = run_command(inner, ";", "", ctx.copy(), depth + 1, None, None)
                reasons += r_inner
                c0 = os.path.basename(inner[0]).lower()
                if c0 in RM_LIKE | {"mv", "truncate"}:
                    deletes = True
                elif c0 in SHELLS and re.search(r"\b(rm|unlink|shred|rimraf|mv|truncate)\b", " ".join(inner[1:])):
                    deletes = True
                    reasons += analyse(_shell_c_code(inner).replace("{}", "x"), ctx.copy(), depth + 1)
    if hit and deletes and not narrow:
        reasons.append("find で、保護された場所の中身を絞り込まずに消そうとしています: " + hit)
    return reasons, (hit if hit and not narrow else None), None


def check_git(args, ctx, reasons):
    i, base_dirs, work = 0, [], None
    while i < len(args) and args[i].startswith("-"):
        a = args[i]
        if a == "-C" and i + 1 < len(args):
            base_dirs.append(args[i + 1])
            i += 2
        elif a in ("-c", "--exec-path", "--namespace", "--super-prefix") and i + 1 < len(args):
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


def main():
    args = sys.argv[1:]
    cwd = None
    try:
        if "--cwd" in args:
            cwd = args[args.index("--cwd") + 1] or None
    except IndexError:
        cwd = None
    text = ""
    try:
        text = sys.stdin.read()
    except Exception:  # noqa: BLE001
        return
    seen = []
    try:
        base = os.path.realpath(cwd) if cwd else None
        for r in analyse(text, Ctx([base])):
            if r not in seen:
                seen.append(r)
    except RecursionError:
        seen = ["入れ子が深すぎて解析できません。実行内容を確認できないので拒否します"]
    except Exception:  # noqa: BLE001
        try:
            seen = fallback(text)
        except Exception:  # noqa: BLE001
            seen = []
    if seen:
        print("\n".join(seen[:4]))


if __name__ == "__main__":
    main()
