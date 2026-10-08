#!/usr/bin/env python3
"""Cases for danger_check.py (run by hooks-test.sh): what must be refused, and what must pass.

  danger-cases.py <hooks dir>     prints the misses / false alarms (nothing = all good)
"""
import subprocess, sys
hooks = sys.argv[1]
def chk(cmd, cwd="/tmp"):
    return subprocess.run(["python3", hooks + "/danger_check.py", "--cwd", cwd], input=cmd, capture_output=True, text=True).stdout.strip()
DENY = [
 'rm -rf $HOME', 'rm -rf ~', 'rm -rf ~/', 'rm -rf "$HOME"', 'rm -rf "${HOME}"', 'rm -rf $HOME/*', 'rm -rf ~/*', 'rm -fr ~', 'rm -r -f ~',
 'rm --recursive --force ~', 'rm -rf /', 'rm -rf /*', 'sudo rm -rf /', 'rm -rf /Users', 'rm -rf /Users/*', 'rm -rf ~/Documents',
 'rm -rf ~/Desktop ~/Downloads', 'rm -rf ~/Library', 'rm -rf ~/.ssh', 'rm -rf ~/{Documents,Desktop}', 'rm -rf ~/Library/*', 'rm -rf ~/.[a-z]*',
 '/bin/rm -rf ~', 'command rm -rf ~', 'env rm -rf ~', '\\rm -rf ~', 'bash -c "rm -rf ~"', "sh -c 'rm -rf $HOME'", 'eval "rm -rf ~"',
 'echo $(rm -rf ~)', 'x=$(rm -rf ~)', 'H=~; rm -rf $H', 'H=$HOME && rm -rf "$H"', 'cd ~ && rm -rf *', 'cd && rm -rf .', 'cd ~; rm -rf ./*',
 'cd $HOME; rm -rf *', 'rm -rf $DIR/*', 'rm -rf "$DIR"/*', 'rm -rf ${X}/', 'find ~ -delete', 'find $HOME -type f -delete',
 'find ~ -type f | xargs rm', 'find / -delete', 'find ~/Documents -delete', 'mv ~ /tmp/x',
 'mv ~/Documents /dev/null', 'chmod -R 000 ~', 'chown -R nobody ~', 'rsync -a --delete /tmp/empty/ ~/', 'git -C ~ clean -fdx',
 'dd if=/dev/zero of=/dev/disk2', 'diskutil eraseDisk JHFS+ x disk2', 'diskutil eraseVolume HFS+ x /Volumes/y', 'mkfs.ext4 /dev/sda1',
 'python3 -c "import shutil,os; shutil.rmtree(os.path.expanduser(\'~\'))"', 'perl -e \'system("rm -rf $ENV{HOME}")\'', 'shred -u ~/Documents/*',
 'timeout 5 rm -rf ~', 'nohup rm -rf ~ &', 'time rm -rf ~', 'rm -rf ~ ; echo done', 'true && rm -rf ~', 'ls | rm -rf ~',
 "bash <<'EOF'\nrm -rf ~\nEOF", '$RM -rf ~', '"r"m -rf ~', 'rm -rf -- ~', 'rm -rf /private/etc', 'rm -rf /System/Library',
]
ALLOW = [
 'ls -la', 'rm -rf node_modules', 'rm -rf build dist', 'rm -rf /tmp/x', 'rm -rf "$TMPDIR/foo"', 'rm -rf ~/Documents/old-project',
 'rm -rf ~/work/x/build', 'rm file.txt', 'rm -f ./a.log', 'rm -rf ~/Library/Caches/com.foo.app', 'rm -rf $HOME/.cache/foo',
 'find . -name "*.pyc" -delete', 'find ~ -name "*.txt" -exec rm {} \\;', 'find /tmp -name "x" -delete', 'git clean -fdx', 'git status', 'mv a b', 'mv ~/Downloads/x.zip ~/Documents/',
 'chmod -R 755 ./dir', 'chown -R me ./dir', 'rsync -a src/ dest/', 'rsync -a --delete ./out/ /tmp/out/', 'echo rm -rf ~', 'cat <<EOF\nrm -rf ~\nEOF',
 'grep "rm -rf" file', 'git commit -m "rm -rf ~ is bad"', 'python3 -c "print(1)"', 'dd if=a of=b', 'diskutil list', 'rm -rf "$WORK"',
 'rm -rf "$tmp/x"', 'cd /tmp && rm -rf *', 'cd ~/proj && rm -rf build', 'npm run clean', 'make clean', 'docker rm -f x', 'kubectl delete pod x',
 'brew uninstall foo', 'rm -r some/dir', 'rm -rf ../x',
]
bad = []
for c in DENY:
    if not chk(c): bad.append("missed: " + repr(c))
for c in ALLOW:
    if chk(c): bad.append("false alarm: " + repr(c))
print("; ".join(bad[:6]))
