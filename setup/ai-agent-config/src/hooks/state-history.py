#!/usr/bin/env python3
"""Append concise state history and retire old backups (no external commands)."""
import datetime
import os
from pathlib import Path
import re
import shutil
import sys
import time


def append(state, message):
    state = Path(state)
    state.mkdir(parents=True, exist_ok=True)
    path = state / 'CHANGELOG.md'
    with path.open('a', encoding='utf-8') as handle:
        if path.stat().st_size == 0:
            handle.write('# 変更履歴\n\n')
        handle.write(f'{datetime.datetime.now():%Y-%m-%d %H:%M} {message}\n')


def prune(state, dry=False):
    days = int(os.environ.get('STATE_KEEP_DAYS', '7'))
    if days < 0:
        raise ValueError('STATE_KEEP_DAYS は0以上にしてください')
    cutoff = time.time() - days * 86400
    groups = [
        ('配備の退避', state / 'backups', lambda p: p.is_dir() and re.fullmatch(r'\d{14}', p.name)),
        ('台帳の退避', state / 'backups', lambda p: p.is_file() and re.fullmatch(r'ai-agents-\d{8}-\d{6}\.md', p.name)),
        ('差分', state / 'changes', lambda p: p.is_file() and re.fullmatch(r'registry-\d{8}\.diff', p.name)),
    ]
    counts, oldest = [], []
    for label, folder, matches in groups:
        # Names encode creation time; retention age separately uses modification time.
        candidates = sorted(((p.stat().st_mtime, p) for p in folder.iterdir()
                             if not p.is_symlink() and matches(p)),
                            key=lambda entry: entry[1].name, reverse=True) if folder.is_dir() else []
        count = 0
        for mtime, path in candidates[3:]:
            if mtime >= cutoff:
                continue
            if dry:
                print(f'dry-run: {label}を削除します: {path.name}')
                continue
            try:
                if path.is_dir():
                    shutil.rmtree(path)
                else:
                    path.unlink()
            except OSError as exc:
                print(f'退避を削除できません: {path.name} ({type(exc).__name__})', file=sys.stderr)
                continue
            count += 1
            oldest.append(mtime)
        if count:
            counts.append(f'{label}{count}件')
    if counts:
        day = datetime.datetime.fromtimestamp(min(oldest)).strftime('%Y-%m-%d')
        append(state, f'退避を整理: {"・".join(counts)}を削除(最古 {day})。')


def main():
    if sys.argv[1] == 'prune':
        state = Path(os.environ.get('AGENT_STATE_DIR') or str(Path.home() / '.agent-state'))
        prune(state, '--dry-run' in sys.argv[2:])
    elif sys.argv[1] == 'deploy':
        state, backup = map(Path, sys.argv[2:4])
        ids = [s.split('\t')[0] for s in (backup / 'applied.tsv').read_text().splitlines() if s]
        names = '・'.join(ids[:3])
        if len(ids) > 3:
            names += f'・ほか{len(ids) - 3}件'
        # Bound even unusually long private manifest IDs.
        if len(names) > 65:
            names = names[:62] + '…'
        append(state, f'配備: {names}を更新(退避 {backup.name})。')


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'状態履歴を処理できません: {type(exc).__name__}', file=sys.stderr)
    sys.exit(0)
