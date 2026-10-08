#!/usr/bin/env python3
"""Cases for interpreter calls versus strings/comments (run by hooks-test.sh).
   danger-cases-review4.py <hooks dir>   prints the misses / false alarms (nothing = all good)
"""
import os
import shlex
import subprocess
import sys
import time

hooks = sys.argv[1]
HOME = os.path.realpath(os.path.expanduser("~"))
PROJ = HOME + "/proj"
T = "/tmp"


def chk(cmd, cwd=T):
    return subprocess.run(["python3", hooks + "/danger_check.py", "--cwd", cwd], input=cmd, capture_output=True, text=True, timeout=20).stdout.strip()


def one(lang, code):
    return lang + (" -c " if lang.startswith("python") else " -e ") + shlex.quote(code)


DENY = [(one(lang, code), T) for lang, code in [
    ('python3', 'import shutil; shutil.rmtree("/")'),
    ('python3', 'import shutil,os; h=os.environ["HOME"]; shutil.rmtree(h)'),
    ('python3', 'import shutil,os; h=os.path.expanduser("~"); p=h; shutil.rmtree(p)'),
    ('python3', 'import os; os.system("rm -rf ~")'),
    ('python3', 'import os; cmd="rm -rf ~"; os.system(cmd)'),
    ('python3', '__import__("shutil").rmtree(__import__("os").path.expanduser("~"))'),
    ('python3', 'import shutil; getattr(shutil,"rmtree")("/")'),
    ('python3', 'getattr(__import__("shutil"),"rmtree")("/")'),
    ('python3', 'import shutil; delete=shutil.rmtree; delete("/")'),
    ('python3', 'import os; getattr(os,"system")("rm -rf ~")'),
    ('python3', 'import subprocess; subprocess.run(["rm","-rf",__import__("os").path.expanduser("~")])'),
    ('python3', 'exec(\'import shutil; shutil.rmtree("/")\')'),
    ('python3', 'eval(\'__import__("shutil").rmtree("/")\')'),
    ('python3', 'compile(\'import shutil; shutil.rmtree("/")\', "<code>", "exec")'),
    ('python3', 'c=\'import shutil; shutil.rmtree("/")\'; exec(c)'),
    ('python3', 'import shutil as s; s.rmtree("/")'),
    ('python3', 'from shutil import rmtree as delete; delete("/")'),
    ('node', 'const h=require("os").homedir(); require("fs").rmSync(h,{recursive:true})'),
    ('node', 'require("child_process").execSync("rm -rf ~")'),
    ('ruby', 'FileUtils.rm_rf(Dir.home)'),
    ('perl', 'remove_tree($ENV{HOME})'),
    ('perl', 'system("rm -rf ~")'),
    ('node', 'eval(\'require("fs").rmSync("/")\')'),
    ('python3', 'import shutil; shutil.rmtree("/"); broken ='),
    ('python3', 'import pathlib, shutil; shutil.rmtree(pathlib.Path.home())'),
    ('python3', "import os; os.system('rm' + ' -rf ~')"),
    ('python3', "import base64,os; os.system(base64.b64decode('cm0gLXJmIH4=').decode())"),
    ('python3', "import shutil; [shutil.rmtree(p) for p in ['/']]"),
    ('python3', "import shutil\nfor p in ('/tmp/x', '/'):\n    shutil.rmtree(p)"),
    ('python3', "import shutil; list(map(shutil.rmtree, ['/']))"),
]]
ALLOW = [(one(lang, code), PROJ) for lang, code in [
    ('python3', 'print(\'shutil.rmtree("/")\')'),
    ('python3', 'x = \'os.system("rm -rf ~")\''),
    ('python3', '# shutil.rmtree("/")\nprint(1)'),
    ('python3', 'print(1) # os.system("rm -rf ~")'),
    ('python3', '"""shutil.rmtree("/")\nos.system("rm -rf ~")"""'),
    ('python3', 'x=["rm", "-rf", "/"]; print(x)'),
    ('python3', 'print("subprocess.run([\\"rm\\",\\"-rf\\",\\"/\\"])")'),
    ('python3', 'import shutil; shutil.rmtree("/tmp/example-build")'),
    ('node', "console.log('fs.rmSync(os.homedir())')"),
    ('node', "const x='fs.rmSync(os.homedir())'; console.log(x)"),
    ('node', 'const x=["rm", "-rf", "/"]; console.log(x)'),
    ('node', '// fs.rmSync(os.homedir())\nconsole.log(1)'),
    ('node', '/* fs.rmSync(os.homedir()) */ console.log(1)'),
    ('node', 'const x=\'child_process.execSync("rm -rf ~")\''),
    ('node', 'const x="escaped \\" fs.rmSync(\'/\')"; console.log(x)'),
    ('ruby', "puts 'FileUtils.rm_rf(Dir.home)'"),
    ('ruby', '# FileUtils.rm_rf(Dir.home)\nputs 1'),
    ('perl', "print 'remove_tree($ENV{HOME})'"),
    ('perl', '# remove_tree($ENV{HOME})\nprint 1'),
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
