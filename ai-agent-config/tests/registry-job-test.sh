#!/bin/bash
# Isolated research runner and probe; no external agent is executed.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP" AGENT_STATE_DIR="$TEST_TMP/state"
unset AGENT_JOB AGENTS_STALE_DAYS AGENTS_REGISTRY AGENT_DELEGATED_BY
mkdir -p "$HOME/hooks" "$HOME/.knowledge/bin" "$AGENT_STATE_DIR"
cp "$HERE/../src/hooks/registry-job.sh" "$HERE/../src/hooks/registry-apply.py" "$HOME/hooks/"
printf 'print("example")\n' >"$HOME/hooks/agentconf.py"
cat >"$HOME/hooks/agent-run.sh" <<'STUB'
#!/bin/bash
[ "$1" != --check ] || exit 0
cp "$2" "$HOME/prompt.txt"
printf '# agent: example\n' >&2
python3 - <<'PY'
import datetime, os, pathlib
ledger = (pathlib.Path.home() / '.knowledge/ai-agents.md').read_text()
ledger = ledger.replace('従来用途', '新用途').replace(str(datetime.date.today() - datetime.timedelta(days=1)), str(datetime.date.today()))
print('<<<LEDGER\n' + ledger + 'LEDGER>>>\n## 要確認')
if os.environ.get('TEST_REVIEW'):
    print('コマンド変更案: 公式の根拠 https://example.org/docs')
PY
STUB
cat >"$HOME/.knowledge/bin/agents-probe.sh" <<'STUB'
#!/bin/bash
printf 'probe called: %s\n' "$*" >>"$HOME/probe-calls"
echo 'EXAMPLE-MODEL-LIST'
STUB
seed() {
  python3 - <<'PY'
import datetime, pathlib
(pathlib.Path.home() / '.knowledge/ai-agents.md').write_text(f'''# 架空の台帳

## Example
<!-- verified agent=example date={datetime.date.today() - datetime.timedelta(days=1)} -->

- コマンド: example --run

- 適切用途: 従来用途

## 代行先の優先順位

1. Example
''')
PY
}
seed
# Yesterday is stale by default, with no override, and maybe launches a job.
bash "$HOME/hooks/registry-job.sh" maybe
for i in {1..50}; do
  [ ! -d "$AGENT_STATE_DIR/registry-job.lock" ] && [ -f "$AGENT_STATE_DIR/alerts/registry-job.txt" ] && break
  sleep .1
done
grep -q '新用途' "$HOME/.knowledge/ai-agents.md"
grep -q '台帳を自動更新しました' "$AGENT_STATE_DIR/alerts/registry-job.txt"
[ ! -d "$AGENT_STATE_DIR/proposals" ]
[ -s "$AGENT_STATE_DIR/registry-reports/registry-$(date +%Y%m%d).md" ]
grep -q 'EXAMPLE-MODEL-LIST' "$HOME/prompt.txt"
grep -q '<<<LEDGER' "$HOME/prompt.txt"
! grep -q -- '--fresh' "$HOME/probe-calls"
# Sensitive changes remain proposals even when safe changes were applied.
seed
TEST_REVIEW=1 bash "$HOME/hooks/registry-job.sh" run
proposal="$AGENT_STATE_DIR/proposals/registry-$(date +%Y%m%d).md"
[ -s "$proposal" ] && grep -q 'コマンド変更案' "$proposal"
grep -q '要確認の調査報告' "$AGENT_STATE_DIR/alerts/registry-job.txt"
# Unprocessed proposals block maybe even after cooldown has expired.
seed
rm "$AGENT_STATE_DIR/registry-job.stamp"
calls=$(wc -l <"$HOME/probe-calls")
bash "$HOME/hooks/registry-job.sh" maybe
sleep .2
[ "$(wc -l <"$HOME/probe-calls")" = "$calls" ]
# All stale consumers use the one-day default and inclusive boundary.
AGENTS_CONF=/nonexistent bash "$HERE/../src/hooks/obligations.sh" >"$HOME/obligations.txt"
grep -q '1日以上経過' "$HOME/obligations.txt"
AGENTS_CONF=/nonexistent AGENTS_HOOKS_DIR="$HERE/../src/hooks" bash "$HERE/../src/bin/agents-probe.sh" >"$HOME/probe.txt"
grep -q '1日以上経過したエージェント' "$HOME/probe.txt"
# Check the 600-second cache boundary without any real CLI in the conf.
printf '[runtime]\norder = example\n[example]\nbin = fictional-cli-that-does-not-exist\n' >"$HOME/test.conf"
printf 'CACHED-SENTINEL\n' >"$AGENT_STATE_DIR/probe-cache.txt"
touch -t "$(date -v-11M +%Y%m%d%H%M.%S)" "$AGENT_STATE_DIR/probe-cache.txt"
AGENTS_CONF="$HOME/test.conf" AGENTS_HOOKS_DIR="$HERE/../src/hooks" bash "$HERE/../src/bin/agents-probe.sh" >"$HOME/cache.txt"
! grep -q 'CACHED-SENTINEL' "$HOME/cache.txt"
printf 'CACHED-SENTINEL\n' >"$AGENT_STATE_DIR/probe-cache.txt"
touch -t "$(date -v-9M +%Y%m%d%H%M.%S)" "$AGENT_STATE_DIR/probe-cache.txt"
AGENTS_CONF="$HOME/test.conf" AGENTS_HOOKS_DIR="$HERE/../src/hooks" bash "$HERE/../src/bin/agents-probe.sh" >"$HOME/cache.txt"
grep -q 'CACHED-SENTINEL' "$HOME/cache.txt"
# Reminder warms the HOME-local stub on every prompt, but never from a job.
export AGENTS_CONF=/nonexistent AGENTS_HOOKS_DIR="$HERE/../src/hooks"
for n in 1 2; do
  calls=$(wc -l <"$HOME/probe-calls")
  printf '{"session_id":"warm-test","prompt":"test","prompt_id":"%s"}\n' "$n" | bash "$HERE/../src/hooks/reminder.sh" >/dev/null
  for i in {1..50}; do [ "$(wc -l <"$HOME/probe-calls")" -gt "$calls" ] && break; sleep .1; done
  [ "$(wc -l <"$HOME/probe-calls")" -gt "$calls" ]
done
calls=$(wc -l <"$HOME/probe-calls")
printf '{"session_id":"warm-job","prompt":"test"}\n' | AGENT_JOB=1 bash "$HERE/../src/hooks/reminder.sh" >/dev/null
sleep .2
[ "$(wc -l <"$HOME/probe-calls")" = "$calls" ]
echo 'registry-job: 全検証パス'
