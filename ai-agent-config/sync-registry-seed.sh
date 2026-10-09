#!/bin/bash
# Reconcile the repository seed with this Mac's working registry; always fail open.
CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
python3 - "$CFG_DIR" "$@" <<'PY'
import datetime
import importlib.util
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True


def main():
    cfg = Path(sys.argv[1])
    dry = '--dry-run' in sys.argv[2:]
    live = Path(os.environ.get('AGENTS_REGISTRY') or str(Path.home() / '.knowledge/ai-agents.md'))
    seed = cfg / 'src/agents-registry.md'
    if not live.is_file():
        return
    candidate = live.read_bytes()
    prior = seed.read_bytes() if seed.exists() else b''
    if candidate == prior:
        return
    def latest(data):
        dates = re.findall(rb'<!-- verified agent=\S+ date=(\d{4}-\d{2}-\d{2}) -->', data)
        return max((datetime.date.fromisoformat(d.decode()) for d in dates), default=datetime.date.min)
    if latest(candidate) < latest(prior):
        print('台帳のシードは変更しません: live の確認日が古いため', file=sys.stderr)
        return
    # Use the public checker's existing rules, private denylist and repository path allowances.
    spec = importlib.util.spec_from_file_location('public_check', cfg / 'public-check.py')
    check = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(check)
    top = subprocess.run(['git', '-C', str(cfg), 'rev-parse', '--show-toplevel'], capture_output=True, text=True)
    label = os.path.relpath(seed, top.stdout.strip()) if top.returncode == 0 else 'src/agents-registry.md'
    hits = []
    check.scan_text(label, enumerate(candidate.decode('utf-8').splitlines(), 1),
                    check.RULES + check.load_deny(), check.load_allow(), hits)
    if hits:
        # Do not echo potentially private contents into commit logs.
        print('台帳のシードは変更しません: 公開検査で検出 (' +
              '・'.join(sorted({h[2] for h in hits})) + ')', file=sys.stderr)
        return
    if dry:
        print('dry-run: 台帳のシードを live に合わせます')
        return
    fd, tmp = tempfile.mkstemp(prefix='.registry-seed-', dir=seed.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(candidate)
        os.chmod(tmp, seed.stat().st_mode & 0o777 if seed.exists() else 0o644)
        os.replace(tmp, seed)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)
    print('台帳のシードを live に合わせました')


try:
    main()
except Exception as exc:
    print('台帳のシードを同期できませんでした: ' + type(exc).__name__, file=sys.stderr)
PY
exit 0
