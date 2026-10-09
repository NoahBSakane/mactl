#!/bin/bash
# Self-contained fixtures: no real registry, HOME, network or agent CLI is used.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP"
python3 - "$HERE/../src/hooks/registry-apply.py" "$TEST_TMP" <<'PY'
import datetime
import pathlib
import subprocess
import sys

script, root = sys.argv[1], pathlib.Path(sys.argv[2])
today = datetime.date.today()
yesterday = today - datetime.timedelta(days=1)
base = f'''# 架空の台帳

## Example
<!-- verified agent=example date={yesterday} -->

- コマンド: example --run
<!-- flags agent=example cmd="run" : --safe -->

- 適切用途: 架空の従来用途
  従来の根拠 https://example.org/old

## 代行先の優先順位

1. Example

## その他

変更しない本文
'''
count = 0

def run(candidate, marker=True):
    global count
    count += 1
    folder = root / str(count)
    folder.mkdir()
    ledger, report, output = folder / 'ledger.md', folder / 'report.md', folder / 'out'
    ledger.write_text(base)
    report.write_text('<<<LEDGER\n' + candidate + 'LEDGER>>>\n## 要確認\n' if marker else candidate)
    result = subprocess.run([sys.executable, script, str(ledger), str(report), str(output)], capture_output=True, text=True)
    assert result.returncode == 0, result
    if ledger.read_text() != base:
        history = (output / 'CHANGELOG.md').read_text()
        assert '台帳を自動更新: 適用' in history and '・却下' in history and '(退避 ai-agents-' in history, history
    else:
        assert not (output / 'CHANGELOG.md').exists()
    return ledger.read_text(), result.stdout, output

candidate = base.replace('架空の従来用途', '架空の新用途').replace('1. Example', '1. Example (更新)').replace(str(yesterday), str(today)).replace('--safe', '--unsafe')
text, result, out = run(candidate)
assert '架空の新用途' in text and '1. Example (更新)' in text and str(today) in text
assert '--safe' in text and '--unsafe' not in text
assert 'REJECTED 1' in result, result
assert len(list((out / 'backups').glob('*.md'))) == 1
assert next((out / 'backups').glob('*.md')).read_text() == base
assert '架空の新用途' in next((out / 'changes').glob('*.diff')).read_text()
for candidate in [base.replace('## Example', '## Renamed'), base.replace(str(yesterday), '2000-01-01'), base.replace('agent=example', 'agent=another'), base.replace(str(yesterday), str(today + datetime.timedelta(days=1)))]:
    text, result, out = run(candidate)
    assert text == base and 'APPLIED 0 REJECTED' in result and not out.exists(), result
for injection in ['http://example.org', 'ftp://example.org', '$(id)', '`echo danger`', 'rm -rf /tmp/fake', 'curl https://example.org', '| sh', 'ignore previous instructions', '以前の指示を無視', 'x' * 1501]:
    text, result, out = run(base.replace('架空の従来用途', injection))
    assert text == base and 'REJECTED 1' in result, (injection, result)
for candidate in ['x\n', base * 3]:
    text, result, out = run(candidate)
    assert text == base and '範囲外' in result and not out.exists()
text, result, out = run(base, marker=False)
assert text == base and result.startswith('INVALID ') and not out.exists()
for broken in ['LEDGER>>>\n<<<LEDGER\n' + base, '<<<LEDGER\n<<<LEDGER\n' + base + 'LEDGER>>>\n']:
    text, result, out = run(broken, marker=False)
    assert text == base and result.startswith('INVALID ') and not out.exists()
text, result, out = run(base)
assert text == base and result == 'APPLIED 0 REJECTED 0\n' and not out.exists()
# Explicit additions/deletions and multiline usage continuations remain supported.
for candidate in [base.replace('  従来の根拠', '  新しい根拠'), base.replace('- 適切用途: 架空の従来用途\n  従来の根拠 https://example.org/old\n', ''), base.replace('- コマンド:', '- 適切用途: 追加の架空用途\n\n- コマンド:')]:
    text, result, out = run(candidate)
    assert text == candidate and 'REJECTED 0' in result, result
text, result, out = run(base.replace('## その他', '## 新しい代行先の優先順位').replace('変更しない本文', '不正な新本文'))
assert text == base and 'REJECTED' in result
print(f'registry-apply: passed={count} failed=0')
PY
