#!/usr/bin/env python3
"""Apply only allowlisted registry hunks; research output is untrusted data."""
import datetime
import difflib
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile

VERIFIED = re.compile(r'<!-- verified agent=([^\s]+) date=(\d{4}-\d{2}-\d{2}) -->\s*$')
HEADING = re.compile(r'^ {0,3}#{1,6}\s')


def extract(report):
    lines = report.splitlines(keepends=True)
    starts = [i for i, s in enumerate(lines) if s.strip() == '<<<LEDGER']
    ends = [i for i, s in enumerate(lines) if s.strip() == 'LEDGER>>>']
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ValueError('台帳マーカーが無いか壊れています')
    return lines[starts[0] + 1:ends[0]]


def allowed(lines, priority_headings):
    """Label content, never headings/comments/other list items as continuations."""
    labels = []
    priority_level = None
    usage = False
    for line in lines:
        heading = HEADING.match(line)
        if heading:
            level = len(line.split()[0])
            if priority_level is not None and level <= priority_level:
                priority_level = None
            if line in priority_headings:
                priority_level = level
            usage = False
            labels.append(False)
            continue
        if '<!--' in line:
            usage = False
            labels.append(False)
            continue
        if line.startswith('- 適切用途:'):
            usage = True
            labels.append("usage")
            continue
        continuation = usage and (not line.strip() or line.startswith((' ', '\t')))
        if not continuation:
            usage = False
        labels.append(('priority' if priority_level is not None else 'usage' if continuation else False)
                      if '<!--' not in line else False)
    return labels


def unsafe(line):
    if len(line.rstrip('\r\n')) > 1500:
        return '行が1500文字を超えています'
    if any(s.lower() != 'https://' for s in re.findall(r'[a-z][a-z0-9+.-]*://', line, re.I)):
        return 'HTTPS以外のURLです'
    if re.search(r'http://|\$\(|rm\s+-rf|curl\s|\|\s*sh\b|ignore previous|以前の指示を無視', line, re.I):
        return '安全でないURLまたは注入文です'
    for command in re.findall(r'`([^`]+)`', line):
        # a plain `agy models` is ordinary; a pipe, a redirect, a chain or a risky first word is not
        if re.search(r'[;|&<>]', command) or re.match(r'\s*(?:sudo\s+)?(?:echo|rm|curl|wget|sh|bash|zsh|eval|chmod|chown|dd|nc|ncat|ssh|scp|python3?|perl|ruby|node|osascript|base64|xargs|tee|mkfs|diskutil|kill)\b', command):
            return 'バッククォート内にコマンド風の記述があります'
    return None


def main():
    if len(sys.argv) != 4:
        raise ValueError('usage: registry-apply.py <台帳> <候補> <出力ディレクトリ>')
    registry, candidate, output = map(Path, sys.argv[1:])
    old = registry.read_text().splitlines(keepends=True)
    new = extract(candidate.read_text())
    if not len(old) * .5 <= len(new) <= len(old) * 2:
        print('APPLIED 0 REJECTED 1\n候補の行数が現在の0.5〜2倍の範囲外です')
        return
    priority_headings = {s for s in old if HEADING.match(s) and '代行先の優先順位' in s} & set(new)
    old_labels, new_labels = allowed(old, priority_headings), allowed(new, priority_headings)
    today = datetime.date.today().isoformat()
    merged, reasons, count = [], [], 0
    for tag, a, b, c, d in difflib.SequenceMatcher(None, old, new, autojunk=False).get_opcodes():
        if tag == 'equal':
            merged.extend(old[a:b])
            continue
        reason = next((reason for s in new[c:d] if (reason := unsafe(s))), None)
        before = [VERIFIED.fullmatch(s.rstrip('\n')) for s in old[a:b]]
        after = [VERIFIED.fullmatch(s.rstrip('\n')) for s in new[c:d]]
        old_markers = [m for m in before if m]
        new_markers = [m for m in after if m]
        permitted = (all(label or marker or not line.strip() for label, marker, line in zip(old_labels[a:b], before, old[a:b]))
                     and all(label or marker or not line.strip() for label, marker, line in zip(new_labels[c:d], after, new[c:d])))
        permitted = permitted and any(old_labels[a:b] + new_labels[c:d] + old_markers + new_markers)
        if a == b and 'priority' in new_labels[c:d]:
            # A rejected heading deletion must not broaden the permitted section.
            permitted = permitted and ((a < len(old_labels) and old_labels[a] == 'priority')
                                       or (a > 0 and old_labels[a - 1] == 'priority'))
        if old_markers or new_markers:
            permitted = (permitted and len(old_markers) == len(new_markers)
                         and all(x[1] == y[1] and y[2] == today and x[2] < y[2]
                                 for x, y in zip(old_markers, new_markers)))
        if reason or not permitted:
            reasons.append(f'ハンク {a + 1}-{b}: {reason or "許可対象外の変更です"}')
            merged.extend(old[a:b])
        else:
            count += 1
            merged.extend(new[c:d])
    if merged != old:
        backup_dir, diff_dir = output / 'backups', output / 'changes'
        backup_dir.mkdir(parents=True, exist_ok=True)
        diff_dir.mkdir(parents=True, exist_ok=True)
        moment = datetime.datetime.now()
        backup = backup_dir / f'ai-agents-{moment:%Y%m%d-%H%M%S}.md'
        while backup.exists():
            moment += datetime.timedelta(seconds=1)
            backup = backup_dir / f'ai-agents-{moment:%Y%m%d-%H%M%S}.md'
        # Never overwrite a backup from a previous run within the same second.
        with backup.open('x') as handle:
            handle.write(''.join(old))
        fd, temp = tempfile.mkstemp(prefix='.registry-', dir=registry.parent)
        try:
            with os.fdopen(fd, 'w') as handle:
                handle.write(''.join(merged))
                handle.flush()
                os.fsync(handle.fileno())
            shutil.copymode(registry, temp)
            diff = ''.join(difflib.unified_diff(old, merged, fromfile=str(registry), tofile=str(registry)))
            with (diff_dir / f'registry-{datetime.date.today():%Y%m%d}.diff').open('a') as handle:
                handle.write(diff)
            os.replace(temp, registry)
        finally:
            if os.path.exists(temp):
                os.unlink(temp)
    print(f'APPLIED {count} REJECTED {len(reasons)}')
    for reason in reasons:
        print(reason)


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(f'INVALID {str(exc).replace(chr(10), " ")}')
    # Hooks must fail open, even for malformed reports or filesystem errors.
    sys.exit(0)
