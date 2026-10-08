#!/usr/bin/env python3
"""Cases for danger_check.py from the second independent review (run by hooks-test.sh).
   danger-cases-review2.py <hooks dir>   prints the misses / false alarms (nothing = all good)
"""
import os
import subprocess
import sys
import time

hooks = sys.argv[1]
HOME = os.path.realpath(os.path.expanduser("~"))
USER = os.environ.get("USER") or os.path.basename(HOME)
PROJ = HOME + "/proj"
T = "/tmp"


def chk(cmd, cwd=T):
    return subprocess.run(["python3", hooks + "/danger_check.py", "--cwd", cwd], input=cmd, capture_output=True, text=True, timeout=20).stdout.strip()


DENY = [(c, T) for c in [
    "rm -rf ~ $'\\8'", "printf '%s' $'\\8'; rm -rf ~", "rm -rf ~ $'\\x00'",
    "# don't worry\nrm -rf ~\n# won't", "echo start # let's go\nrm -rf ~\n# that's it",
    'for d in ~/Documents ~/Desktop; do rm -rf "$d"; done', 'for d in Documents Desktop; do rm -rf ~/"$d"; done',
    'for d in ~ ; do rm -rf "$d"; done', 'for d in ~/*; do rm -rf "$d"; done',
    "rm -rf ~/*/", "rm -rf /*/", "rm -rf ~/.*/", "find ~/*/ -delete", "rm -rf /Users/*/Documents", "rm -rf ~/Doc*",
    "rm -rf ~/Documen?s", "rm -rf ~/[D]ocuments", "rm -rf ~/{Doc,Desk}*", "rm -rf /Use*", "rm -rf /Users/" + USER[:4] + "*",
    "eval eval eval eval eval eval eval rm -rf ~", "bash -c 'bash -c \"eval eval eval eval rm -rf ~\"'",
    'c="rm -rf $HOME"; eval "$c"', "c='rm -rf ~'; bash -c \"$c\"", 'x="rm -rf ~"; $x',
    "cat <<EOF-1\nhi\nEOF-1\nrm -rf ~", "cat > /tmp/notes.md <<'END.'\nx\nEND.\nrm -rf ~", 'git commit -m "doc: explain <<EOF usage"\nrm -rf ~',
    "# example: cat <<EOF\nrm -rf ~",
    "cd /a; cd /b; cd /c; cd /d; cd /e; cd ~; rm -rf *",
    'rm -rf "$(realpath ~)"', 'rm -rf "$(readlink -f ~)"', 'rm -rf "$(cd ~; pwd)"', 'rm -rf "$(cd ~ && pwd -P)"', 'rm -rf "$(dirname ~/x)"',
    'rm -rf "$(eval echo ~)"', 'H=$(realpath ~); rm -rf "$H"',
    "rm -rf \"$(dscl . -read /Users/$USER NFSHomeDirectory | awk '{print $2}')\"",
    'bash -c "$(echo cm0gLXJmIH4= | base64 -d)"', 'eval "$(echo cm0gLXJmIH4= | base64 -d)"', 'sh -c "$(echo cm0gLXJmIH4= | base64 --decode)"',
    "python3 -c \"import os; os.system('rm -rf /')\"", "perl -e 'system \"rm -rf /\"'", "node -e \"require('child_process').execSync('rm -rf /*')\"",
    "osascript -e 'do shell script \"rm -rf /\"'",
    "find ~ ! -name .DS_Store -delete", "find ~ -not -name keep -delete", "find ~ -user $USER -delete", "find ~ -size +0 -delete",
    "find ~ -mtime -100000 -delete", "find ~ -path '*' -delete", "find ~ -regex '.*' -delete",
    "sudo -iu root rm -rf ~", "sudo -Hu root rm -rf /",
    "npx rimraf@latest ~", "npm exec -- rimraf ~", "npx -y trash-cli ~", "env -S 'rm -rf ~'", "parallel rm -rf ::: ~", "find ~ | parallel rm -rf",
    "launchctl asuser 501 rm -rf ~",
    "uv run python -c \"import shutil,os;shutil.rmtree(os.path.expanduser('~'))\"", "poetry run python -c \"import shutil,os;shutil.rmtree(os.path.expanduser('~'))\"",
    "echo x | xargs sh -c 'rm -rf ~'", "find /tmp -maxdepth 0 -exec rm -rf ~ \;", "find ~ -exec command rm -rf {} +", "find ~ -exec timeout 9 rm -rf {} +",
    "xargs rm -rf < <(echo ~)", "xargs -a <(echo ~) rm -rf",
    'ls ~ | while read f; do rm -rf ~/"$f"; done', 'ls -A ~ | while IFS= read -r f; do rm -rf "./$f"; done',
    "mv ~/Documents ~/x && rm -rf ~/x", "mv ~ /Users/tmpx; rm -rf /Users/tmpx",
    'f() { rm -rf "$1"; }; f ~', 'cleanup() { rm -rf "$1"; }\ncleanup "$HOME"', "alias x='rm -rf ~'\nx",
    "echo " + "{a,b}" * 26 + "; rm -rf ~", "echo " + "a" * 250000 + "; rm -rf ~; echo " + "b" * 250000,
    "rm -rf ${HOME:0}", "rm -rf ${HOME/x/x}",
    "awk 'BEGIN{system(\"rm -rf ~\")}'", "tclsh <<< 'exec rm -rf ~'", "expect -c 'spawn rm -rf ~'", "pwsh -c 'Remove-Item -Recurse -Force ~'",
    "ssh localhost 'rm -rf ~'", "echo 'rm -rf ~' | tee /dev/null | bash", "rsync -a --del /tmp/empty/ ~/", "cat /dev/zero > /dev/disk2",
    "ln -s ~ /tmp/ && rm -rf /tmp/" + os.path.basename(HOME) + "/",
]] + [
    ("rm -rf ~+", HOME), ("rm -rf ~+/*", HOME), ('rm -rf "$(dirname "$PWD")"', PROJ),
]
ALLOW = [(c, PROJ) for c in [
    "rm -rf '~'", "find ~ -type d -empty -delete", "# it's a comment\nrm -rf ./build",
    "python3 -c \"import shutil,os; shutil.rmtree(os.path.expanduser('~/.cache/pip'))\"",
    "python3 - <<'EOF'\nimport shutil\nshutil.rmtree('" + HOME + "/proj/build')\nEOF",
    "python3 -c \"print('rm -rf ~ is dangerous')\"",
    "git commit -m 'fix `rm -rf ~` docs'", "echo \"don't rm -rf ~\"", "grep -n 'rm -rf' file.sh", "ls ~ | head",
    "for f in *.log; do rm -f \"$f\"; done", "for d in build dist; do rm -rf \"$d\"; done", "f() { echo \"$1\"; }; f ~",
    "cat > setup.sh <<'EOF'\nrm -rf ~/.cache/x\nEOF", "alias ll='ls -la'\nll", "cd ~/proj && make clean",
]] + [("rm -rf '~'", HOME), ("find . -type d -empty -delete", HOME)]
bad = []
t0 = time.time()
for c, cwd in DENY:
    try:
        if not chk(c, cwd):
            bad.append("missed: " + repr(c[:90]) + (" cwd=home" if cwd == HOME else ""))
    except subprocess.TimeoutExpired:
        bad.append("too slow (>20s): " + repr(c[:60]))
for c, cwd in ALLOW:
    if chk(c, cwd):
        bad.append("false alarm: " + repr(c[:90]) + (" cwd=home" if cwd == HOME else ""))
print("\n".join(bad[:60]))
