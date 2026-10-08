#!/usr/bin/env python3
"""Cases for danger_check.py from the third independent review, by a different model family (run by hooks-test.sh).
   danger-cases-review3.py <hooks dir>   prints the misses / false alarms (nothing = all good)
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
    # substitution hidden in a here-string / arithmetic
    'cat <<< "$(rm -rf ~)"', 'cat <<EOF\n$(rm -rf ~)\nEOF', "echo $(( $(rm -rf ~) + 1 ))",
    # positional parameters of a child shell, eval --
    "bash -c 'rm -rf \"$1\"' _ \"$HOME\"", "sh -c 'rm -rf \"$0\"' \"$HOME\"", "bash -c 'rm -rf \"$@\"' _ ~/Documents ~/Desktop",
    'eval -- "rm -rf ~"',
    # find with an -o branch that deletes everything, or that only copies /dev/null over files
    "find ~ -name '*.tmp' -o -delete", "find ~ -name keep -prune -o -exec rm -rf {} +",
    "find ~ -type f -exec cp /dev/null {} \\;", "find ~ -type f -exec dd if=/dev/zero of={} count=1 \\;",
    "find ~ \\( -type f \\) -delete", "find ~ \\( -name a -o -true \\) -delete", "find ~ -exec echo {} \\; -delete", "cat <<< `rm -rf ~`",
    "find ~ -exec chmod 000 {} +", "bash -c 'rm -rf $HOME'", "c='rm -rf $HOME'; eval \"$c\"", "echo 'rm -rf $HOME' | sh",
    # values handed over by an array, an indirect reference, read, a changed HOME
    'dirs=("$HOME"); rm -rf "${dirs[@]}"', 'dirs=(/tmp/a "$HOME"); rm -rf "${dirs[@]}"', 'a=HOME; rm -rf "${!a}"',
    'read -r dest <<< "$HOME"; rm -rf "$dest"', 'HOME=/; rm -rf "${HOME}Users/' + USER + '"',
    # long options of wrappers
    "sudo --user root rm -rf ~", "env --chdir /tmp rm -rf ~", "env --split-string='rm -rf ~'", "sudo --preserve-env --user=root rm -rf ~",
    # expansion limits are not a way out
    "rm -rf /{Users,x}{,,,,}{,,,,}{,,,,}", "for x in " + "x " * 70 + "~/Documents; do rm -rf \"$x\"; done",
    "for x in " + "x " * 5000 + "~/Documents; do rm -rf \"$x\"; done",
    # disks and permissions through variables
    "D=/dev/disk2; dd if=/dev/zero of=$D", 'D=/dev/disk2; cat /dev/zero > "$D"',
    "chmod -R 000 ~/Documents", "chmod -R a-rwx ~/.ssh", "chmod -R 000 ~/*", "chmod a= ~", "chmod 000 ~/Documents",
    "asr restore --source /tmp/image.dmg --target /dev/disk2 --erase --noprompt", "diskutil resetFusion",
    # other interpreters and spellings of the home
    "perl -MFile::Path=remove_tree -e 'remove_tree($ENV{HOME})'",
    "node -e \"require('fs').rmSync(require('os').homedir(), {recursive:true})\"",
    "node -e \"require('fs').promises.rm(require('os').homedir(), {recursive:true})\"",
    "python3 -c \"import shutil,os;shutil.rmtree(os.getenv('HOME'))\"",
    "python3 -c \"import os; import shutil; h=os.environ['HOME']; shutil.rmtree(h)\"",
    "ruby -rfileutils -e 'FileUtils.remove_entry_secure(Dir.home)'", "ruby -rfileutils -e 'FileUtils.rm_r(ENV.fetch(\"HOME\"))'",
    "lua -e 'os.execute(\"rm -rf ~\")'",
    "swift -e 'import Foundation; try! FileManager.default.removeItem(atPath: NSHomeDirectory())'",
    # key files, a few irreversible things
    "> ~/.ssh/authorized_keys", "ln -sf /dev/null ~/.zshrc", ": > ~/.zshrc", "crontab -r", "tmutil delete -p /Volumes/Backups/Backups.backupdb/Mac",
    "defaults delete NSGlobalDomain", "kill -9 -1",
    # a recursion that grows too fast to follow is refused rather than followed for ever
    "f(){ " + "f; " * 20 + "}; f",
    # a huge command line: the middle is looked at too
    "echo " + "a" * 210000 + "\nchmod -R 000 /\necho " + "b" * 210000,
    "echo " + "a" * 210000 + "\ndd if=/dev/zero of=/dev/disk2\necho " + "b" * 210000,
]]
ALLOW = [(c, PROJ) for c in [
    "rsync -an --delete /tmp/empty/ ~/Documents/", "git -C ~ clean -ndx", "D=/tmp/project; echo ~; rm -rf \"$D/build\"",
    'rm -rf "${UNSET:?}"/build', "rm -rf ${HOME:+/tmp/build}", "rm -rf '$HOME'", "rm -rf '${HOME}'", "rm -rf ~/Downloads/a*",
    "chmod -R go-rwx ~/.ssh", "chmod 600 ~/.ssh/id_ed25519", "chmod -R u+w ~/Documents", "echo 'a b' >> ~/.zshrc",
    "find ~ \\( -name '*.tmp' -o -name '*.bak' \\) -delete", "find ~ -name '*.log' -exec rm {} +",
    "ls ~ | head -3; rm -rf ./build", "kill -1 1234", "pkill -1 nginx", "defaults delete com.example.app",
    "ssh-keygen -t ed25519 -f /tmp/k -N '' > /dev/null",
    "for d in a b c; do rm -rf \"$d\"; done", "dirs=(build dist); rm -rf \"${dirs[@]}\"", "a=X; rm -rf \"${!a}build\"",
    "bash -c 'rm -rf \"$1\"' _ ./build",
    "echo '$HOME' | cat", "rm -rf '$HOME/x'", "x='$HOME'; echo $x", "chmod -R 755 ~/proj", "chmod go-w ~/Documents/f", "find ~/proj -name '*.o' -o -name '*.a'",
]]
bad = []
t0 = time.time()
for c, cwd in DENY:
    try:
        if not chk(c, cwd):
            bad.append("missed: " + repr(c[:90]))
    except subprocess.TimeoutExpired:
        bad.append("too slow (>20s): " + repr(c[:60]))
for c, cwd in ALLOW:
    if chk(c, cwd):
        bad.append("false alarm: " + repr(c[:90]))
print("\n".join(bad[:60]))
