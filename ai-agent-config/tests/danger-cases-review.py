#!/usr/bin/env python3
"""More cases for danger_check.py, from an independent review that hunted for ways round it
(run by hooks-test.sh).   danger-cases-review.py <hooks dir>   prints the misses / false alarms (nothing = all good)
"""
import os
import subprocess
import sys

hooks = sys.argv[1]
HOME = os.path.realpath(os.path.expanduser("~"))
USER = os.environ.get("USER") or os.path.basename(HOME)
PROJ = HOME + "/proj"
os.environ["TMPDIR"] = "/tmp/t"


def chk(cmd, cwd="/tmp"):
    return subprocess.run(["python3", hooks + "/danger_check.py", "--cwd", cwd], input=cmd, capture_output=True, text=True).stdout.strip()


DENY = [  # (command, cwd)
    ("if [ -d ~ ]; then rm -rf ~; fi", "/tmp"), ("for i in 1; do rm -rf ~; done", "/tmp"), ("until false; do rm -rf ~; done", "/tmp"),
    ("{ cd ~; rm -rf *; }", "/tmp"), ("true || { rm -rf ~; }", "/tmp"), ("! rm -rf ~", "/tmp"),
    ("rm -rf \\\n  ~/Documents", "/tmp"), ('rm -rf \\\n  "$HOME"', "/tmp"), ("sudo rm -rf \\\n  /", "/tmp"),
    ("cat <<< 'x'\nrm -rf ~", "/tmp"), ("echo $((1<<y))\nrm -rf ~", "/tmp"),
    ("nice -n 19 rm -rf ~", "/tmp"), ("stdbuf -o0 rm -rf ~", "/tmp"), ("caffeinate -i rm -rf ~", "/tmp"), ("ionice -c3 rm -rf ~", "/tmp"),
    ("timeout -s KILL 10 rm -rf ~", "/tmp"), ("timeout -k 5 10 rm -rf ~", "/tmp"), ("gtimeout 10 rm -rf ~", "/tmp"),
    ("command -p rm -rf ~", "/tmp"), ("flock /tmp/l rm -rf ~", "/tmp"), ("watch rm -rf ~", "/tmp"), ("script -q /dev/null rm -rf ~", "/tmp"),
    ("RM -rf ~", "/tmp"), ("Rm -rf ~", "/tmp"), ("/BIN/RM -rf ~", "/tmp"), ("rm -rf /users/" + USER, "/tmp"), ("rm -rf /USERS", "/tmp"),
    ("rm -rf ~/documents", "/tmp"), ("rm -rf ~/DOCUMENTS/", "/tmp"),
    ("export X=$HOME; rm -rf $X", "/tmp"), ("declare X=$HOME; rm -rf $X", "/tmp"), ("local X=$HOME; rm -rf $X", "/tmp"),
    ("readonly H=$HOME; rm -rf $H", "/tmp"), ("typeset X=~; rm -rf $X", "/tmp"),
    ("rm -rf $(echo ~)", "/tmp"), ('rm -rf "$(echo ~)"', "/tmp"), ("rm -rf `echo ~`", "/tmp"), ('H=$(echo ~); rm -rf "$H"', "/tmp"),
    ('H="$(cd ~ && pwd)"; rm -rf "$H"', "/tmp"), ('cd ~ && rm -rf "$(pwd)"', "/tmp"), ("cd ~ && rm -rf $(pwd)/*", "/tmp"),
    ("cd /tmp/x || true; rm -rf *", HOME), ("cd /nonexistent && echo; rm -rf *", HOME), ("(cd /tmp/x); rm -rf *", HOME),
    ("(cd /tmp/x && rm -rf *); rm -rf *", HOME),
    ("python3 - <<'P'\nimport shutil, os\nshutil.rmtree(os.path.expanduser(\"~\"))\nP", "/tmp"),
    ("python3 <<'P'\nimport shutil; shutil.rmtree('" + HOME + "/Documents')\nP", "/tmp"),
    ('python3 -c "\nimport shutil, os\nshutil.rmtree(os.path.expanduser(\'~\'))\n"', "/tmp"),
    ("echo 'rm -rf ~' | bash", "/tmp"), ("echo 'rm -rf ~' | sh", "/tmp"), ("bash <<< 'rm -rf ~'", "/tmp"), ("cat <<'X' | bash\nrm -rf ~\nX", "/tmp"),
    ("source <(echo 'rm -rf ~')", "/tmp"), ('. <(echo "rm -rf ~")', "/tmp"), ("eval $(echo 'rm -rf ~')", "/tmp"),
    ("eval \"$(printf 'rm -rf %s' ~)\"", "/tmp"), ("bash -c -- 'rm -rf ~'", "/tmp"),
    ("ls ~ | xargs rm -rf", "/tmp"), ("ls ~ | xargs -I{} rm -rf ~/{}", "/tmp"), ("echo ~ | xargs rm -rf", "/tmp"),
    ("printf '%s\\n' ~/Documents | xargs rm -rf", "/tmp"), ("xargs rm -rf <<< ~", "/tmp"),
    ("find ~ -type f -print0 | xargs -0 -n 10 rm -f", "/tmp"), ("find ~ | xargs -I {} rm -rf {}", "/tmp"), ("find ~ -print0 | xargs -0 -P 4 rm -rf", "/tmp"),
    ("find ~ -type f | grep -v keep | xargs rm -f", "/tmp"), ("find ~ -type f | xargs sh -c 'rm -f \"$@\"' _", "/tmp"),
    ('find ~ -maxdepth 1 | while read f; do rm -rf "$f"; done', "/tmp"), ("ls | xargs rm -rf", HOME),
    ("find -L ~ -delete", "/tmp"), ("find -H ~ -delete", "/tmp"), ("gfind ~ -delete", "/tmp"), ("find ~/* -delete", "/tmp"),
    ("find ~/Documents/* -delete", "/tmp"), ("find * -delete", HOME), ("find ~ -exec sh -c 'rm -rf \"$1\"' _ {} \;", "/tmp"),
    ("fd . ~ -x rm -rf", "/tmp"), ("fd . ~ --exec rm -rf", "/tmp"),
    ("git -C ~ -c x=y clean -fdx", "/tmp"), ("git -c core.x=y -C ~ clean -fdx", "/tmp"), ("cd ~ && git -c a=b clean -fdx", "/tmp"),
    ("git --work-tree=~ clean -fdx", "/tmp"), ("git --git-dir=~/.dotfiles --work-tree=~ clean -fdx", "/tmp"),
    ("git --git-dir=$HOME/.dotfiles --work-tree=$HOME reset --hard", "/tmp"), ("git -C ~ reset --hard", "/tmp"),
    ("git -C ~ checkout -- .", "/tmp"), ("cd ~ && git checkout -f && git reset --hard", "/tmp"), ("git clean -fdx ~", "/tmp"),
    ("mv -t /tmp ~/Documents", "/tmp"), ("rsync -a --delete /tmp/empty/ ~/Documents/ --exclude .git", "/tmp"),
    ("rsync -a --remove-source-files ~/Documents/ /tmp/x/", "/tmp"),
    ("tar --remove-files -cf /tmp/a.tar ~", "/tmp"), ("tar -cf /tmp/a.tar --remove-files ~/Documents", "/tmp"), ("zip -rm /tmp/a.zip ~/Documents", "/tmp"),
    ("trash ~", "/tmp"), ("trash ~/Documents", "/tmp"), ("npx rimraf ~", "/tmp"), ("npx -y rimraf ~/Documents", "/tmp"), ("rimraf ~", "/tmp"),
    ("bunx rimraf ~", "/tmp"), ("osascript -e 'tell application \"Finder\" to delete every item of home'", "/tmp"),
    ("python3 -c \"import subprocess; subprocess.run(['rm','-rf',__import__('os').path.expanduser('~')])\"", "/tmp"),
    ("python3 -c \"import shutil; shutil.rmtree('.')\"", HOME),
    ("echo " + "a" * 25000 + "; rm -rf ~", "/tmp"),
    ("rm -rf ~" + USER, "/tmp"), ("rm -rf ~" + USER + "/", "/tmp"), ("rm -rf ~$USER", "/tmp"), ("rm -rf /Users/$USER", "/tmp"),
    ('rm -rf "/Users/${USER}"', "/tmp"), ("rm -rf /Users/$(whoami)", "/tmp"), ("rm -rf $'/Users/" + USER + "'", "/tmp"),
    ("ln -s ~ /tmp/h && rm -rf /tmp/h/", "/tmp"), ("ln -s ~ /tmp/h && rm -rf /tmp/h/*", "/tmp"),
    ("cp /dev/null ~/Documents", "/tmp"), ("truncate -s 0 ~/Documents/*", "/tmp"), ("find ~ -type f -exec truncate -s0 {} +", "/tmp"),
    ("chmod 000 ~", "/tmp"), ("chflags -R uchg ~", "/tmp"),
    ("su - me -c 'rm -rf ~'", "/tmp"), ('rm -rf "${DIR:-}"/*', "/tmp"), ('rm -rf "${DIR%/}"/*', "/tmp"),
    ("echo cm0gLXJmIH4= | base64 -d | sh", "/tmp"),
    ("rm -rf ~/Library/Containers", "/tmp"), ("rm -rf ~/Library/Group\\ Containers", "/tmp"), ("rm -rf ~/Library/CloudStorage", "/tmp"),
    ("rm -rf ~/Library/Mail", "/tmp"), ("rm -rf ~/Library/Messages", "/tmp"), ("rm -rf ~/Pictures/Photos\\ Library.photoslibrary", "/tmp"),
    ("rm -rf /usr/local/bin", "/tmp"), ("rm -rf /var/db", "/tmp"), ("rm -rf /Library/Application\\ Support", "/tmp"),
]
ALLOW = [
    ("rm -rf build 2>/dev/null", PROJ), ("rm -rf node_modules >/dev/null 2>&1", PROJ), ("rm -rf dist &>/dev/null || true", PROJ),
    ("rm -rf ./build 2> /dev/null; echo ok", PROJ), ("chmod -R 755 dir 2>/dev/null", PROJ),
    ("rm -f ~/Downloads/*.dmg", PROJ), ("rm -rf ~/Downloads/*.dmg", PROJ), ("chmod -R go-rwx ~/.ssh", PROJ),
    ("sudo chown -R $USER /opt/homebrew", PROJ), ("mv ~/.config ~/.config.bak", PROJ), ("find ~ -name '.DS_Store' -delete", PROJ),
    ("find ~ -name node_modules -type d -prune -exec rm -rf {} +", PROJ), ("find ~/Library -name '*.tmp' -delete", PROJ),
    ("cd -- /tmp/build && rm -rf *", HOME), ("cd -P /tmp/build && rm -rf *", HOME), ('rm -rf "$TMPDIR"/*', PROJ),
    ("python3 -c \"import os; [os.remove(f) for f in os.listdir('.') if f.endswith('~')]\"", PROJ),
    ("node -e \"require('fs').unlinkSync(require('path').join(require('os').homedir(), '.cache/x.json'))\"", PROJ),
    ("python3 -c \"import pathlib; pathlib.Path('~/.cache/x').expanduser().unlink()\"", PROJ),
    ("git clean -fdx", ""), ("git clean -fdx", PROJ), ("rm -rf *", PROJ), ("cd " + PROJ + " && rm -rf *", HOME),
    ("ls | xargs rm", PROJ), ("find . -name '*.pyc' -delete", PROJ), ("echo hello | bash", PROJ),
]
bad = []
for c, cwd in DENY:
    if not chk(c, cwd):
        bad.append("missed: " + repr(c[:90]) + (" cwd=home" if cwd == HOME else ""))
for c, cwd in ALLOW:
    if chk(c, cwd):
        bad.append("false alarm: " + repr(c[:90]))
print("\n".join(bad[:60]))
