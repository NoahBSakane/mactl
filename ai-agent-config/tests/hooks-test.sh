#!/bin/bash
# Fixture tests for the agent hooks. Runs against a throwaway HOME; touches nothing real.
#   ./hooks-test.sh            run all
# Exit code = number of failed assertions (0 = all good).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_REPO="$(cd "$HERE/.." && pwd)"
HOOKS="$(cd "$HERE/../src/hooks" && pwd)"
TMP_HOME="$(mktemp -d)"
trap 'rm -rf "$TMP_HOME"' EXIT
export HOME="$TMP_HOME" AGENT_STATE_DIR="$TMP_HOME/.agent-state" AGENTS_HOOKS_DIR="$HOOKS"
unset AGENT_DELEGATED_BY
# Never call a real agent from a test: same tool/exec data as agents.conf, but no research/interactive templates
SAFE_CONF="$TMP_HOME/agents.conf"
sed -e 's/^research = .*/research =/' -e 's/^interactive = .*/interactive =/' -e 's/^ping = .*/ping =/' -e 's/^ask = .*/ask =/' "$HOOKS/agents.conf" >"$SAFE_CONF"
export AGENTS_CONF="$SAFE_CONF"

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
expect_code() { # name want got
  if [ "$2" = "$3" ]; then ok; else bad "$1 (want exit $2, got $3)"; fi
}
new_sid() { echo "sess-$(uuidgen)"; }

# run <hook> <payload-json> [VAR=val ...]  -> sets RC, OUT, ERR
run() {
  local hook="$1" payload="$2"; shift 2
  OUT="$(env "$@" bash "$HOOKS/$hook" <<<"$payload" 2>"$TMP_HOME/err")"; RC=$?
  ERR="$(cat "$TMP_HOME/err")"
}
pl() { # sid tool tool_input_json [extra jq object]
  local extra="${4:-}"; [ -n "$extra" ] || extra='{}'
  jq -cn --arg sid "$1" --arg tool "$2" --argjson ti "$3" --argjson extra "$extra" \
    '{session_id:$sid,prompt_id:"p1",hook_event_name:"PreToolUse",tool_name:$tool,tool_input:$ti,cwd:"/work/repo"} + $extra'
}
bashpl() { pl "$1" Bash "$(jq -cn --arg c "$2" '{command:$c}')" "${3:-}"; }

# ---------- gate: edits ----------
s=$(new_sid)
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}')"; expect_code "edit first denied" 2 "$RC"
run gate.sh "$(pl "$s" Write '{"file_path":"/work/repo/b.txt"}')"; expect_code "parallel/retry same prompt still denied" 2 "$RC"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}' '{"prompt_id":"p2"}')"; expect_code "new prompt releases" 0 "$RC"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/c.txt"}' '{"prompt_id":"p3"}')"; expect_code "stays released" 0 "$RC"

s=$(new_sid)
run gate.sh "$(pl "$s" Edit '{"file_path":"/tmp/scratch.txt"}')"; expect_code "tmp edit exempt" 0 "$RC"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/x"}' '{"scratchpad_dir":"/work"}')"; expect_code "scratchpad_dir exempt" 0 "$RC"
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/.agent-state/x" '{file_path:$p}')")"; expect_code "agent-state exempt" 0 "$RC"
patch=$'*** Begin Patch\n*** Update File: /work/repo/z.py\n@@\n*** End Patch'
run gate.sh "$(pl "$s" apply_patch "$(jq -cn --arg c "$patch" '{input:$c}')")"; expect_code "apply_patch repo file gated" 2 "$RC"

s=$(new_sid)
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}' '{"agent_id":"sub-1"}')"; expect_code "subagent call passes" 0 "$RC"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}')" AGENT_DELEGATED_BY=orch; expect_code "delegated process passes" 0 "$RC"

# ---------- gate: external CLIs ----------
deny_cmd() { local s; s=$(new_sid); run gate.sh "$(bashpl "$s" "$1")"; expect_code "deny: $1" 2 "$RC"; }
pass_cmd() { local s; s=$(new_sid); run gate.sh "$(bashpl "$s" "$1")"; expect_code "pass: $1" 0 "$RC"; }
deny_cmd 'codex exec "fix it"'
deny_cmd 'cd /x && timeout 600 codex exec -m gpt-6.1-sol "go"'
deny_cmd 'FOO=1 agy -p "hi" --model gemini-3.8-flash-low --dangerously-skip-permissions'
deny_cmd 'muse exec --workspace . "hi"'
deny_cmd 'grok -p "hi" --always-approve'
deny_cmd "bash -c 'codex exec x'"
deny_cmd 'echo $(codex exec "x")'
deny_cmd 'codex review --uncommitted'
pass_cmd 'echo "codex exec x"'
pass_cmd 'codex exec --help'
pass_cmd 'codex debug models'
pass_cmd 'agy models'
pass_cmd 'agy --version'
pass_cmd 'grok models'
pass_cmd 'muse exec --help'
pass_cmd $'cat <<EOF\nagy -p "x"\ncodex exec y\nEOF'
pass_cmd 'ls -la'
pass_cmd 'git status'

# ---------- gate: subagents ----------
s=$(new_sid)
run gate.sh "$(pl "$s" Agent '{"subagent_type":"Explore","prompt":"x"}')"; expect_code "Explore exempt" 0 "$RC"
run gate.sh "$(pl "$s" Agent '{"subagent_type":"general-purpose","model":"haiku","prompt":"x"}')"; expect_code "general-purpose gated even on haiku" 2 "$RC"
s=$(new_sid)
run gate.sh "$(pl "$s" Workflow '{"script":"x"}')"; expect_code "Workflow gated" 2 "$RC"

# ---------- AskUserQuestion lifts the gates ----------
s=$(new_sid)
run mark-asked.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"PostToolUse",tool_name:"AskUserQuestion",tool_response:"User has answered your questions: x"}')"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}')"; expect_code "after AskUserQuestion edit passes" 0 "$RC"
run gate.sh "$(bashpl "$s" 'codex exec "x"')"; expect_code "after AskUserQuestion ext passes" 0 "$RC"
s=$(new_sid)
run mark-asked.sh "$(jq -cn --arg s "$s" '{session_id:$s,tool_name:"AskUserQuestion",tool_response:"The user doesn'"'"'t want to proceed with this tool use."}')"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}')"; expect_code "rejected question does not lift" 2 "$RC"

# ---------- fail-open ----------
run gate.sh 'not json'; expect_code "malformed json fails open" 0 "$RC"
run gate.sh '{"tool_name":"Edit","tool_input":{"file_path":"/work/a"}}'; expect_code "missing session_id fails open" 0 "$RC"
OUT="$(PATH=/usr/bin:/bin bash "$HOOKS/gate.sh" <<<"$(pl x Edit '{"file_path":"/work/a"}')" 2>/dev/null)"; RC=$?
if command -v /usr/bin/jq >/dev/null 2>&1; then :; else expect_code "no jq fails open" 0 "$RC"; fi

# ---------- secret scan ----------
s=$(new_sid)
run secret-scan.sh "$(bashpl "$s" 'codex exec "use key AKIAABCDEFGHIJKLMNOP please"')"; expect_code "aws key blocked" 2 "$RC"
run secret-scan.sh "$(bashpl "$s" 'agy -p "token=ghp_abcdefghijklmnopqrstuvwxyz0123456789ab"')"; expect_code "github token blocked" 2 "$RC"
run secret-scan.sh "$(bashpl "$s" 'codex exec "refactor the parser"')"; expect_code "clean prompt ok" 0 "$RC"
run secret-scan.sh "$(bashpl "$s" 'echo AKIAABCDEFGHIJKLMNOP')"; expect_code "non-agent command not scanned" 0 "$RC"

# ---------- reminder + ofuro ----------
s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"hello",prompt_id:"a"}')"
expect_code "reminder exits 0" 0 "$RC"
case "$OUT" in *agents-probe*) ok ;; *) bad "first prompt carries delegation reminder" ;; esac
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"again",prompt_id:"b"}')"
case "$OUT" in *agents-probe*) bad "2nd prompt should not repeat delegation reminder" ;; *) ok ;; esac

s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro テストを直して",prompt_id:"a",cwd:"/work/repo",permission_mode:"auto"}')"
of="$AGENT_STATE_DIR/ofuro/$s.json"
if [ -f "$of" ]; then
  ok
  mins=$(( ( $(jq -r .until_epoch "$of") - $(jq -r .started_epoch "$of") ) / 60 ))
  [ "$mins" = 120 ] && ok || bad "default ofuro length 120m (got $mins)"
  [ "$(jq -r '.allow_models|length' "$of")" = 0 ] && ok || bad "no models allowed by default"
else bad "ofuro state file created"; fi
# gate behaviour inside ofuro
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}')"; expect_code "ofuro: edit passes without bump" 0 "$RC"
run gate.sh "$(pl "$s" Agent '{"subagent_type":"general-purpose","model":"opus","prompt":"x"}')"; expect_code "ofuro: opus denied unless allowed" 2 "$RC"
run gate.sh "$(pl "$s" Agent '{"subagent_type":"general-purpose","model":"haiku","prompt":"x"}')"; expect_code "ofuro: haiku subagent passes" 0 "$RC"
run ofuro-guard.sh "$(pl "$s" AskUserQuestion '{"questions":[]}')"; expect_code "ofuro: AskUserQuestion denied" 2 "$RC"
# other session unaffected
s2=$(new_sid)
run ofuro-guard.sh "$(pl "$s2" AskUserQuestion '{"questions":[]}')"; expect_code "ofuro is per-session" 0 "$RC"
# stop hook: continue, then done marker ends it
run ofuro-guard.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"Stop",cwd:"/work/repo"}')"
case "$OUT" in *'"decision":"block"'*) ok ;; *) bad "ofuro Stop blocks while active" ;; esac
: >"$AGENT_STATE_DIR/ofuro/$s.done"
run ofuro-guard.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"Stop",cwd:"/work/repo"}')"
[ -z "$OUT" ] && ok || bad "Stop allowed after done marker"
[ ! -f "$of" ] && ok || bad "state cleaned after done"

s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro 90分 opus で設計して",prompt_id:"a"}')"
of="$AGENT_STATE_DIR/ofuro/$s.json"
mins=$(( ( $(jq -r .until_epoch "$of") - $(jq -r .started_epoch "$of") ) / 60 ))
[ "$mins" = 90 ] && ok || bad "ofuro 90分 parsed (got $mins)"
[ "$(jq -r '.allow_models[0]' "$of")" = opus ] && ok || bad "opus allowed when instructed"
run gate.sh "$(pl "$s" Agent '{"subagent_type":"general-purpose","model":"opus","prompt":"x"}')"; expect_code "ofuro: opus allowed when instructed" 0 "$RC"
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro off",prompt_id:"b"}')"
[ ! -f "$of" ] && ok || bad "ofuro off removes state"

# Stop hook caps: stale stops end the loop
s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro 60m x",prompt_id:"a"}')"
for i in 1 2 3 4; do run ofuro-guard.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"Stop",cwd:"/nonexistent"}')"; done
[ -z "$OUT" ] && ok || bad "stale stops terminate the continuation loop"


# ---------- other agents' payload shapes ----------
# Codex: turn_id (no prompt_id), tool_name Bash / apply_patch with the patch in tool_input.command
cx() { jq -cn --arg sid "$1" --arg tool "$2" --argjson ti "$3" --arg turn "$4" \
  '{session_id:$sid,turn_id:$turn,hook_event_name:"PreToolUse",tool_name:$tool,tool_input:$ti,cwd:"/work/repo",permission_mode:"default"}'; }
s=$(new_sid)
run gate.sh "$(cx "$s" Bash '{"command":"codex exec x"}' t1)"; expect_code "codex shape: ext denied" 2 "$RC"
run gate.sh "$(cx "$s" Bash '{"command":"codex exec x"}' t1)"; expect_code "codex shape: same turn still denied" 2 "$RC"
run gate.sh "$(cx "$s" Bash '{"command":"codex exec x"}' t2)"; expect_code "codex shape: next turn_id releases" 0 "$RC"
s=$(new_sid)
run gate.sh "$(cx "$s" apply_patch "$(jq -cn --arg c "$patch" '{command:$c}')" t1)"; expect_code "codex apply_patch gated" 2 "$RC"
tmppatch=$'*** Begin Patch\n*** Add File: /tmp/x.txt\n+hi\n*** End Patch'
s=$(new_sid)
run gate.sh "$(cx "$s" apply_patch "$(jq -cn --arg c "$tmppatch" '{command:$c}')" t1)"; expect_code "codex apply_patch to /tmp exempt" 0 "$RC"
# generic shell-tool names (Muse and others)
s=$(new_sid); run gate.sh "$(pl "$s" shell '{"command":"muse exec x"}')"; expect_code "tool name 'shell' recognised" 2 "$RC"

# agy adapter: camelCase payload in, JSON decision out
ag() { jq -cn --arg sid "$1" --arg name "$2" --argjson args "$3" \
  '{conversationId:$sid,workspacePaths:["/work/repo"],stepIdx:3,toolCall:{name:$name,args:$args}}'; }
adapt() { local script="$1" ev="$2" payload="$3"; shift 3; OUT="$(env "$@" bash "$HOOKS/agy-adapter.sh" "$script" "$ev" <<<"$payload" 2>/dev/null)"; RC=$?; }
s=$(new_sid)
adapt gate.sh PreToolUse "$(ag "$s" run_command '{"CommandLine":"codex exec x","Cwd":"/work/repo"}')"
[ "$(jq -r .decision <<<"$OUT")" = ask ] && ok || bad "agy: ext CLI -> ask (got $OUT)"
adapt gate.sh PreToolUse "$(ag "$s" run_command '{"CommandLine":"echo hi"}')"
[ "$(jq -r .decision <<<"$OUT")" = allow ] && ok || bad "agy: plain command allowed"
adapt gate.sh PreToolUse "$(ag "$s" write_to_file '{"TargetFile":"/work/repo/a.txt","CodeContent":"x"}')"
[ "$(jq -r .decision <<<"$OUT")" = ask ] && ok || bad "agy: edit outside tmp -> ask"
adapt gate.sh PreToolUse "$(ag "$s" write_to_file '{"TargetFile":"/tmp/a.txt","CodeContent":"x"}')"
[ "$(jq -r .decision <<<"$OUT")" = allow ] && ok || bad "agy: edit in /tmp allowed"
adapt gate.sh PreToolUse "$(ag "$s" run_command '{"CommandLine":"codex exec x"}')" AGENT_DELEGATED_BY=orch
[ "$(jq -r .decision <<<"$OUT")" = allow ] && ok || bad "agy: delegated process allowed"
adapt secret-scan.sh PreToolUse "$(ag "$s" run_command '{"CommandLine":"codex exec \"key AKIAABCDEFGHIJKLMNOP\""}')"
[ "$(jq -r .decision <<<"$OUT")" = deny ] && ok || bad "agy: secret -> deny (got $OUT)"
adapt logger.sh PostToolUse "$(ag "$s" run_command '{"CommandLine":"agy -p x"}')"
[ "$OUT" = "{}" ] && ok || bad "agy: PostToolUse answers {} (got $OUT)"
adapt gate.sh PreToolUse 'not json'; [ "$(jq -r .decision <<<"$OUT" 2>/dev/null)" = allow ] && ok || bad "agy: malformed payload fails open"
# agy Stop: ofuro block becomes continue
s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro 60m x",prompt_id:"a"}')"
adapt ofuro-guard.sh Stop "$(jq -cn --arg s "$s" '{conversationId:$s,workspacePaths:["/nonexistent"]}')"
[ "$(jq -r .decision <<<"$OUT")" = continue ] && ok || bad "agy: Stop continues while ofuro active (got $OUT)"


# muse adapter: unattended runs (permission_mode bypassPermissions) count as delegated; env vars never reach Muse hooks
madapt() { local payload="$1"; OUT="$(bash "$HOOKS/muse-adapter.sh" gate.sh <<<"$payload" 2>"$TMP_HOME/err")"; RC=$?; }
s=$(new_sid)
madapt "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}' '{"permission_mode":"bypassPermissions"}')"; expect_code "muse: unattended run passes the gate" 0 "$RC"
s=$(new_sid)
madapt "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}' '{"permission_mode":"dontAsk"}')"; expect_code "muse: dontAsk run passes the gate" 0 "$RC"
s=$(new_sid)
madapt "$(pl "$s" Edit '{"file_path":"/work/repo/a.txt"}' '{"permission_mode":"default"}')"; expect_code "muse: interactive run is still gated" 2 "$RC"
madapt 'not json'; expect_code "muse adapter fails open on bad input" 0 "$RC"


# ---------- protected instruction files ----------
mkdir -p "$HOME/.claude" "$HOME/.codex" "$HOME/.knowledge/bin"
echo "rules" >"$HOME/AGENTS.md"; echo "claude" >"$HOME/.claude/CLAUDE.md"
mkdir -p "$AGENT_STATE_DIR"; printf '%s\n' "$HOME/AGENTS.md" "$HOME/.claude/CLAUDE.md" "$HOME/.claude/AGENTS.md" "$HOME/.codex/AGENTS.md" >"$AGENT_STATE_DIR/protected-paths.txt"
ln -sf "$HOME/AGENTS.md" "$HOME/.claude/AGENTS.md"; ln -sf "$HOME/AGENTS.md" "$HOME/.codex/AGENTS.md"
s=$(new_sid)
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/AGENTS.md" '{file_path:$p}')")"; expect_code "protected: ~/AGENTS.md edit denied" 2 "$RC"
case "$ERR" in *"指示ファイルの直接編集は不可"*) ok ;; *) bad "protected: message points to propose-rule" ;; esac
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/.claude/AGENTS.md" '{file_path:$p}')")"; expect_code "protected: edit through the symlink denied" 2 "$RC"
run gate.sh "$(pl "$s" Write "$(jq -cn --arg p "$HOME/.codex/AGENTS.md" '{file_path:$p}')")"; expect_code "protected: ~/.codex/AGENTS.md denied" 2 "$RC"
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/.claude/CLAUDE.md" '{file_path:$p}')")"; expect_code "protected: ~/.claude/CLAUDE.md denied" 2 "$RC"
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/AGENTS.md" '{file_path:$p}')" '{"agent_id":"sub-1"}')"; expect_code "protected: even inside a subagent" 2 "$RC"
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/AGENTS.md" '{file_path:$p}')")" AGENT_DELEGATED_BY=orch; expect_code "protected: even when delegated" 2 "$RC"
pp=$'*** Begin Patch\n*** Update File: '"$HOME"$'/AGENTS.md\n*** End Patch'
run gate.sh "$(cx "$s" apply_patch "$(jq -cn --arg c "$pp" '{command:$c}')" t9)"; expect_code "protected: apply_patch on ~/AGENTS.md denied" 2 "$RC"
s=$(new_sid); run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro 30m x",prompt_id:"a"}')"
run gate.sh "$(pl "$s" Edit "$(jq -cn --arg p "$HOME/AGENTS.md" '{file_path:$p}')")"; expect_code "protected: even during /ofuro" 2 "$RC"
s=$(new_sid)
run mark-asked.sh "$(jq -cn --arg s "$s" '{session_id:$s,tool_name:"AskUserQuestion",tool_response:"answered"}')"
run gate.sh "$(pl "$s" Edit '{"file_path":"/work/repo/AGENTS.md"}')"; expect_code "a project's own AGENTS.md is not protected" 0 "$RC"
s=$(new_sid)
adapt gate.sh PreToolUse "$(ag "$s" write_to_file "$(jq -cn --arg p "$HOME/AGENTS.md" '{TargetFile:$p,CodeContent:"x"}')")"
[ "$(jq -r .decision <<<"$OUT")" = deny ] && ok || bad "agy: protected file is a hard deny (got $OUT)"

# ---------- obligations in the reminder, background research job, memory harvest ----------
printf '<!-- verified agent=codex date=2020-01-01 -->\n' >"$HOME/.knowledge/ai-agents.md"
printf '## a\n\n- 状態: 未検討\n\n## b\n\n- 状態: 未検討\n\n## c\n\n- 状態: 採用(x)\n' >"$HOME/.knowledge/rule-proposals.md"
s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"hi",prompt_id:"a"}')" AGENTS_CONF=/nonexistent
case "$OUT" in *"未検討のルール提案が 2 件"*) ok ;; *) bad "reminder lists pending rule proposals" ;; esac
case "$OUT" in *"台帳の確認が14日を超えています"*) ok ;; *) bad "reminder lists the stale registry" ;; esac
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"again",prompt_id:"b"}')"
case "$OUT" in *"未処理の義務"*) bad "obligations are not repeated on the 2nd prompt" ;; *) ok ;; esac
for i in 3 4 5; do run reminder.sh "$(jq -cn --arg s "$s" --arg i "$i" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"p",prompt_id:$i}')"; done
case "$OUT" in *"未処理の義務"*) ok ;; *) bad "obligations come back on the 5th prompt" ;; esac
s=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"hi",prompt_id:"a"}')" AGENT_JOB=1
case "$OUT" in *"未処理の義務"*) bad "no obligations inside the research job itself" ;; *) ok ;; esac

# research job on the generic runner: the first agent is out of quota, the next one takes over
BIN="$TMP_HOME/bin"; mkdir -p "$BIN"
printf '#!/bin/bash\necho "usage limit reached, try again later" >&2; exit 1\n' >"$BIN/stub-a"
printf '#!/bin/bash\necho "STUB-REPORT from b: $#"\n' >"$BIN/stub-b"; chmod +x "$BIN/stub-a" "$BIN/stub-b"
CONF="$TMP_HOME/test-agents.conf"
cat >"$CONF" <<'CONFEOF'
[runtime]
order = a b
costly_models = opus
[a]
bin = stub-a
research = stub-a "$AGENT_PROMPT"
[b]
bin = stub-b
research = stub-b "$AGENT_PROMPT"
CONFEOF
NOJOB="$TMP_HOME/nojob.conf"; printf '[runtime]\norder = a\n[a]\nbin = stub-a\n' >"$NOJOB"
rm -rf "$AGENT_STATE_DIR/proposals" "$AGENT_STATE_DIR/registry-job.stamp" "$AGENT_STATE_DIR/alerts" "$AGENT_STATE_DIR/unavailable"
export PATH="$BIN:$PATH"
AGENTS_CONF="$NOJOB" bash "$HOOKS/registry-job.sh" maybe; sleep 1
ls "$AGENT_STATE_DIR"/proposals/registry-*.md >/dev/null 2>&1 && bad "no job when no agent has a research template" || ok
AGENT_JOB=1 AGENTS_CONF="$CONF" bash "$HOOKS/registry-job.sh" maybe; sleep 1
ls "$AGENT_STATE_DIR"/proposals/registry-*.md >/dev/null 2>&1 && bad "no job from inside the job" || ok
AGENTS_CONF="$CONF" bash "$HOOKS/registry-job.sh" maybe
for i in 1 2 3 4 5 6 7 8; do ls "$AGENT_STATE_DIR"/proposals/registry-*.md >/dev/null 2>&1 && break; sleep 1; done
f="$(ls "$AGENT_STATE_DIR"/proposals/registry-*.md 2>/dev/null | head -1)"
[ -n "$f" ] && grep -q "STUB-REPORT from b" "$f" && ok || bad "stale registry starts the job; the second agent takes over when the first is out of quota"
grep -q "researched-by: b" "$f" && ok || bad "the report records which agent produced it"
[ -f "$AGENT_STATE_DIR/unavailable/a.txt" ] && ok || bad "the agent that hit its limit is marked unavailable"
[ -f "$AGENT_STATE_DIR/alerts/registry-job.txt" ] && ok || bad "a notice is queued when the report arrives"
rm -f "$f"
AGENTS_CONF="$CONF" bash "$HOOKS/registry-job.sh" maybe; sleep 1
ls "$AGENT_STATE_DIR"/proposals/registry-*.md >/dev/null 2>&1 && bad "cooldown: no second job within a day" || ok
# agent-run directly: --check, unavailable agents are skipped
AGENTS_CONF="$CONF" bash "$HOOKS/agent-run.sh" --check research && ok || bad "agent-run --check: b can run"
rm -f "$AGENT_STATE_DIR/unavailable/a.txt"
printf 'x' >"$TMP_HOME/p.txt"; out="$(AGENTS_CONF="$CONF" bash "$HOOKS/agent-run.sh" research "$TMP_HOME/p.txt" 2>"$TMP_HOME/e")"
case "$out" in *"STUB-REPORT from b"*) ok ;; *) bad "agent-run falls through to the next agent" ;; esac
grep -q "# agent: b" "$TMP_HOME/e" && ok || bad "agent-run reports who ran the job"

# nothing in the scripts is tied to a particular agent: a brand-new agent only needs a conf section
NEW="$TMP_HOME/new.conf"; printf '[newagent]\nbin = newagent\nshell_tools = sh_exec\nedit_tools = save_file\nexec_flag = --go\n' >"$NEW"
s=$(new_sid); run gate.sh "$(pl "$s" sh_exec '{"command":"newagent --go task"}')" AGENTS_CONF="$NEW"; expect_code "new agent via conf: its launch is gated" 2 "$RC"
s=$(new_sid); run gate.sh "$(pl "$s" sh_exec '{"command":"newagent --help"}')" AGENTS_CONF="$NEW"; expect_code "new agent via conf: help is not" 0 "$RC"
s=$(new_sid); run gate.sh "$(pl "$s" save_file '{"file_path":"/work/repo/a"}')" AGENTS_CONF="$NEW"; expect_code "new agent via conf: its edit tool is gated" 2 "$RC"
[ "$(AGENTS_CONF="$NEW" python3 "$HOOKS/agentconf.py" toolclass sh_exec)" = shell ] && ok || bad "agentconf toolclass"

# memory harvest: finds what is new or changed, then remembers
mkdir -p "$HOME/.claude/projects/p1/memory"; echo "feedback" >"$HOME/.claude/projects/p1/memory/feedback_a.md"; echo "index" >"$HOME/.claude/projects/p1/memory/MEMORY.md"
[ "$(bash "$HOOKS/../bin/memory-harvest.sh" --count)" = 1 ] && ok || bad "harvest: one new memory file (MEMORY.md index ignored)"
bash "$HOOKS/../bin/memory-harvest.sh" --mark >/dev/null
[ "$(bash "$HOOKS/../bin/memory-harvest.sh" --count)" = 0 ] && ok || bad "harvest: nothing after --mark"
echo "more" >>"$HOME/.claude/projects/p1/memory/feedback_a.md"
bash "$HOOKS/../bin/memory-harvest.sh" | grep -q "changed" && ok || bad "harvest: a changed file is reported"

# ---------- usage-limit reset time (limit-reset.py) ----------
NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-10-07 14:00:00' +%s)
lim() { printf '%s' "$1" | python3 "$HOOKS/limit-reset.py" --now "$NOW" | { read -r e; [ -n "$e" ] && date -r "$e" '+%Y-%m-%d %H:%M:%S' || echo none; }; }
[ "$(lim "Try again at 11:42 AM.")" = "2026-10-08 11:42:00" ] && ok || bad "limit-reset: bare time = the next such time"
[ "$(lim "Try again at Oct 10th, 2026 11:42 AM.")" = "2026-10-10 11:42:00" ] && ok || bad "limit-reset: month day year time"
[ "$(lim "limit until 2026-10-10 11:42:34")" = "2026-10-10 11:42:34" ] && ok || bad "limit-reset: ISO date-time to the second"
[ "$(lim "please retry in 2 hours 15 minutes")" = "2026-10-07 16:15:00" ] && ok || bad "limit-reset: relative wait"
[ "$(lim "retry after 90s")" = "2026-10-07 14:01:30" ] && ok || bad "limit-reset: seconds"
[ "$(lim "resets_at: $((NOW + 7200))")" = "2026-10-07 16:00:00" ] && ok || bad "limit-reset: epoch"
[ "$(lim "nothing useful here")" = none ] && ok || bad "limit-reset: no time in the text"
[ "$(lim "try again at Jan 2, 2020 1:00 AM")" = none ] && ok || bad "limit-reset: a past moment is not believed"
[ "$(lim "try again at 2030-01-01 00:00")" = none ] && ok || bad "limit-reset: more than 14 days away is not believed"

# agent-run records the real reset moment (6 hours only when the text names none)
RS="$TMP_HOME/reset.conf"; printf '[runtime]\norder = c\n[c]\nbin = stub-c\nresearch = stub-c "$AGENT_PROMPT"\n' >"$RS"
want="$(date -v+3d '+%Y-%m-%d %H:%M:%S')"
printf '#!/bin/bash\necho "usage limit reached. Try again at %s" >&2; exit 1\n' "$want" >"$BIN/stub-c"; chmod +x "$BIN/stub-c"
rm -rf "$AGENT_STATE_DIR/unavailable"
AGENTS_CONF="$RS" bash "$HOOKS/agent-run.sh" research "$TMP_HOME/p.txt" >/dev/null 2>&1
got="$(cut -f1 "$AGENT_STATE_DIR/unavailable/c.txt" 2>/dev/null | { read -r e; date -r "$e" '+%Y-%m-%d %H:%M:%S' 2>/dev/null; })"
[ "$got" = "$want" ] && ok || bad "agent-run: unavailable until the time in the error text (want $want, got $got)"
rm -rf "$AGENT_STATE_DIR/unavailable"
printf '#!/bin/bash\necho "usage limit reached" >&2; exit 1\n' >"$BIN/stub-c"
AGENTS_CONF="$RS" bash "$HOOKS/agent-run.sh" research "$TMP_HOME/p.txt" >/dev/null 2>&1
d=$(( $(cut -f1 "$AGENT_STATE_DIR/unavailable/c.txt" 2>/dev/null || echo 0) - $(date +%s) ))
[ "$d" -gt 21000 ] && [ "$d" -le 21600 ] && ok || bad "agent-run: 6 hours when no time is named (got ${d}s)"

# ---------- status line: installed agents only, every 3rd prompt ----------
ST="$TMP_HOME/status.conf"
cat >"$ST" <<'CONFEOF'
[runtime]
order = me up gone lim
[me]
label = Me
bin = stub-a
[up]
label = Upper
bin = stub-b
[gone]
label = Gone
bin = no-such-binary-xyz
[lim]
label = Limited
bin = stub-c
CONFEOF
rm -rf "$AGENT_STATE_DIR/unavailable"; mkdir -p "$AGENT_STATE_DIR/unavailable"
until_e=$(( $(date +%s) + 90061 )); printf '%s\tlimit\n' "$until_e" >"$AGENT_STATE_DIR/unavailable/lim.txt"
printf 'x\n  up      ready    1.0\n' >"$AGENT_STATE_DIR/probe-cache.txt"
line="$(AGENTS_CONF="$ST" AGENT_SELF=me AGENTS_PROBE=/nonexistent bash "$HOOKS/status-line.sh")"
case "$line" in *"Upper: 有効"*) ok ;; *) bad "status line: an installed ready agent is listed ($line)" ;; esac
case "$line" in *Gone*) bad "status line: an agent that is not installed is never listed" ;; *) ok ;; esac
case "$line" in *"Me:"*) bad "status line: the running agent is left out" ;; *) ok ;; esac
reset_at="$(LC_ALL=C TZ=Asia/Tokyo date -r "$until_e" '+%Y-%m-%d(%a)%H:%M:%S')"
offset="$(TZ=Asia/Tokyo date -r "$until_e" '+%z')"
reset_at="${reset_at}${offset%??}:${offset#???}"
case "$line" in *"Limited: 利用上限(復帰: $reset_at)"*) ok ;; *) bad "status line: the limit shows its reset moment in the locale-independent format ($line)" ;; esac
# 日本語ロケールでも曜日が英語3文字で出る(%aが「土」にならない)。期待値を同じ方法で作らず、形式そのものを検査する。
line_ja="$(LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8 AGENTS_CONF="$ST" AGENT_SELF=me AGENTS_PROBE=/nonexistent bash "$HOOKS/status-line.sh")"
[[ "$line_ja" =~ Limited:\ 利用上限\(復帰:\ [0-9]{4}-[0-9]{2}-[0-9]{2}\((Sun|Mon|Tue|Wed|Thu|Fri|Sat)\)[0-9]{2}:[0-9]{2}:[0-9]{2}\+09:00\) ]] && ok || bad "status line: the weekday stays English under a Japanese locale ($line_ja)"
printf '#!/bin/bash\n' >/dev/null
[ -z "$(AGENTS_CONF="$NOJOB" AGENT_SELF=a AGENTS_PROBE=/nonexistent bash "$HOOKS/status-line.sh")" ] && ok || bad "status line: nothing when no other agent is installed"
s=$(new_sid); shown=""
for i in 1 2 3 4 5 6 7; do
  run reminder.sh "$(jq -cn --arg s "$s" --arg i "$i" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"p",prompt_id:$i}')" AGENTS_CONF="$ST" AGENT_SELF=me AGENTS_PROBE=/nonexistent
  case "$OUT" in *"【状態行】"*) shown="$shown$i" ;; esac
done
[ "$shown" = "147" ] && ok || bad "status line is handed over on prompts 1, 4, 7 only (got: $shown)"
s=$(new_sid); run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"p",prompt_id:"a"}')" AGENTS_CONF="$ST" AGENT_SELF=me AGENTS_PROBE=/nonexistent AGENT_JOB=1
case "$OUT" in *"【状態行】"*) bad "no status line inside a background job" ;; *) ok ;; esac
rm -rf "$AGENT_STATE_DIR/unavailable" "$AGENT_STATE_DIR/probe-cache.txt"

# ---------- markdownlint hook ----------
LINTER="$TMP_HOME/fake-lint.sh"
cat >"$LINTER" <<'LEOF'
#!/bin/bash
# fake markdownlint-cli2: reports a long-line finding for every line, plus MD040 on line 1 of a file named bad*
f="${@: -1}"; n=0
while IFS= read -r l; do n=$((n+1)); echo "$f:$n:121 error MD013/line-length Line length [Expected: 120; Actual: 200]"; done <"$f"
case "$f" in */bad*) echo "$f:1 error MD040/fenced-code-language Fenced code blocks should have a language specified" ;; esac
LEOF
chmod +x "$LINTER"
mkdir -p "$TMP_HOME/proj"
printf 'English only line\n日本語を含む行は長さの指摘を受けない\n<!-- marker agent=x -->\n' >"$TMP_HOME/proj/doc.md"
res="$(MD_LINT_CMD="$LINTER" python3 "$HOOKS/md-lint.py" "$TMP_HOME/proj/doc.md")"; rc=$?
[ "$rc" = 1 ] && [ "$(printf '%s\n' "$res" | wc -l | tr -d ' ')" = 1 ] && case "$res" in *":1:121 error MD013"*) true ;; *) false ;; esac && ok || bad "md-lint: MD013 is dropped for Japanese lines and one-line markers only (rc=$rc: $res)"
printf 'ひとつだけ日本語\n' >"$TMP_HOME/proj/ja.md"
MD_LINT_CMD="$LINTER" python3 "$HOOKS/md-lint.py" "$TMP_HOME/proj/ja.md" >/dev/null && ok || bad "md-lint: a Japanese-only file is clean"
printf 'x\n' >"$TMP_HOME/proj/bad.md"
s=$(new_sid)
run md-lint.sh "$(pl "$s" Edit "$(jq -cn --arg p "$TMP_HOME/proj/bad.md" '{file_path:$p}')")" TMPDIR=/var/empty MD_LINT_CMD="$LINTER"
expect_code "md-lint hook: findings are returned with exit 2" 2 "$RC"
case "$ERR" in *MD040*) ok ;; *) bad "md-lint hook: the findings are in stderr" ;; esac
run md-lint.sh "$(pl "$s" Edit "$(jq -cn --arg p "$TMP_HOME/proj/ja.md" '{file_path:$p}')")" TMPDIR=/var/empty MD_LINT_CMD="$LINTER"; expect_code "md-lint hook: clean file passes" 0 "$RC"
run md-lint.sh "$(pl "$s" Edit "$(jq -cn --arg p "$TMP_HOME/proj/bad.txt" '{file_path:$p}')")" TMPDIR=/var/empty MD_LINT_CMD="$LINTER"; expect_code "md-lint hook: non-markdown is ignored" 0 "$RC"
run md-lint.sh "$(pl "$s" Edit "$(jq -cn --arg p "/tmp/bad.md" '{file_path:$p}')")" TMPDIR=/var/empty MD_LINT_CMD="$LINTER"; expect_code "md-lint hook: scratch locations are ignored" 0 "$RC"
run md-lint.sh "$(pl "$s" Bash '{"command":"ls"}')" TMPDIR=/var/empty MD_LINT_CMD="$LINTER"; expect_code "md-lint hook: non-edit tools are ignored" 0 "$RC"
run md-lint.sh "$(pl "$s" Edit "$(jq -cn --arg p "$TMP_HOME/proj/bad.md" '{file_path:$p}')")" TMPDIR=/var/empty MD_LINT_CMD="$LINTER" AGENT_JOB=1; expect_code "md-lint hook: skipped inside background jobs" 0 "$RC"
run md-lint.sh "$(pl "$s" Edit "$(jq -cn --arg p "$TMP_HOME/proj/bad.md" '{file_path:$p}')")" TMPDIR=/var/empty MD_LINT_CMD=/nonexistent/linter; expect_code "md-lint hook: fails open when the linter cannot run" 0 "$RC"

# ---------- agy: lint findings reach the model through PreInvocation ----------
ADAPTER="$HOOKS/agy-adapter.sh"
mkdir -p "$TMP_HOME/proj"; printf 'x\n' >"$TMP_HOME/proj/agybad.md"
conv="agy-$(uuidgen)"
post="$(jq -cn --arg c "$conv" --arg p "$TMP_HOME/proj/agybad.md" '{conversationId:$c,toolCall:{name:"write_to_file",args:{TargetFile:$p}}}')"
out="$(TMPDIR=/var/empty MD_LINT_CMD="$LINTER" bash "$ADAPTER" md-lint.sh PostToolUse <<<"$post")"
[ "$out" = "{}" ] && ok || bad "agy adapter: PostToolUse answers {} (got $out)"
pre="$(jq -cn --arg c "$conv" '{conversationId:$c,invocationNum:2}')"
out="$(bash "$ADAPTER" pending PreInvocation <<<"$pre")"
case "$out" in *ephemeralMessage*MD013*) ok ;; *) bad "agy adapter: the parked findings are injected by PreInvocation ($out)" ;; esac
out="$(bash "$ADAPTER" pending PreInvocation <<<"$pre")"
[ "$out" = "{}" ] && ok || bad "agy adapter: findings are injected only once (got $out)"
post_ok="$(jq -cn --arg c "$conv" --arg p "$TMP_HOME/proj/ja.md" '{conversationId:$c,toolCall:{name:"write_to_file",args:{TargetFile:$p}}}')"
TMPDIR=/var/empty MD_LINT_CMD="$LINTER" bash "$ADAPTER" md-lint.sh PostToolUse <<<"$post_ok" >/dev/null
[ "$(bash "$ADAPTER" pending PreInvocation <<<"$pre")" = "{}" ] && ok || bad "agy adapter: a clean file parks nothing"

# ---------- agy: research-job guard (fail closed, only inside a job) and the per-turn status line ----------
GUARD="$HOOKS/agy-job-guard.sh"
g() { # tool tool_input_json [VAR=val...] -> exit code of the guard
  local t="$1" ti="$2"; shift 2
  env "$@" bash "$GUARD" <<<"$(jq -cn --arg t "$t" --argjson ti "$ti" '{tool_name:$t,tool_input:$ti}')" >/dev/null 2>&1; echo $?
}
[ "$(g run_command '{"CommandLine":"rm -rf /"}')" = 0 ] && ok || bad "guard: does nothing outside a research job"
[ "$(g run_command '{"CommandLine":"ls"}' AGENT_JOB=1)" = 2 ] && ok || bad "guard: no shell inside a job"
[ "$(g write_to_file '{"TargetFile":"/x"}' AGENT_JOB=1)" = 2 ] && ok || bad "guard: no file writes inside a job"
[ "$(g view_file '{"AbsolutePath":"/etc/passwd"}' AGENT_JOB=1)" = 2 ] && ok || bad "guard: no local file reads inside a job"
[ "$(g browser_get_dom '{}' AGENT_JOB=1)" = 2 ] && ok || bad "guard: no browser tools inside a job"
[ "$(g search_web '{"query":"rust"}' AGENT_JOB=1)" = 0 ] && ok || bad "guard: web search is allowed"
[ "$(g read_url_content '{"Url":"https://docs.example.org/a?b=1"}' AGENT_JOB=1)" = 0 ] && ok || bad "guard: any public https page is allowed"
for u in 'file:///etc/passwd' 'http://localhost:8080/x' 'http://127.0.0.1/' 'http://192.168.1.5/' 'http://10.0.0.1/' 'http://172.16.3.4/' 'http://169.254.169.254/latest' 'https://user:pw@example.com/' 'http://[::1]/' 'http://2130706433/' 'https://printer.local/' 'ftp://example.com/' 'https://example.com/?k=ghp_abcdefghijklmnopqrstuvwxyz0123456789'; do
  [ "$(g read_url_content "$(jq -cn --arg u "$u" '{Url:$u}')" AGENT_JOB=1)" = 2 ] && ok || bad "guard: refuses $u"
done
[ "$(g read_url_content '{}' AGENT_JOB=1)" = 2 ] && ok || bad "guard: a fetch without a URL is refused"
echo 'not json' | AGENT_JOB=1 bash "$GUARD" >/dev/null 2>&1; expect_code "guard: unreadable input is refused (fail closed)" 2 "$?"
out="$(AGENT_JOB=1 bash "$ADAPTER" agy-job-guard.sh PreToolUse <<<"$(jq -cn '{conversationId:"c",toolCall:{name:"run_command",args:{CommandLine:"ls"}}}')")"
case "$out" in *'"decision":"deny"'*) ok ;; *) bad "agy adapter: the guard's refusal is a hard deny ($out)" ;; esac
out="$(AGENT_JOB=1 bash "$ADAPTER" agy-job-guard.sh PreToolUse <<<"$(jq -cn '{conversationId:"c",toolCall:{name:"search_web",args:{query:"x"}}}')")"
case "$out" in *'"decision":"allow"'*) ok ;; *) bad "agy adapter: web search passes the guard ($out)" ;; esac

# the status line once per user turn (invocationNum 0), every 3rd turn from the first
rm -rf "$AGENT_STATE_DIR/unavailable"; printf 'x\n  up      ready    1.0\n' >"$AGENT_STATE_DIR/probe-cache.txt"
conv="agy-$(uuidgen)"; shown=""
for i in 1 2 3 4 5 6 7; do
  out="$(AGENTS_CONF="$ST" AGENTS_PROBE=/nonexistent bash "$ADAPTER" pending PreInvocation <<<"$(jq -cn --arg c "$conv" '{conversationId:$c,invocationNum:0}')")"
  case "$out" in *"【状態行】"*) shown="$shown$i" ;; esac
  # a second model call inside the same turn never counts
  AGENTS_CONF="$ST" AGENTS_PROBE=/nonexistent bash "$ADAPTER" pending PreInvocation <<<"$(jq -cn --arg c "$conv" '{conversationId:$c,invocationNum:1}')" >/dev/null
done
[ "$shown" = "147" ] && ok || bad "agy: the status line comes on turns 1, 4, 7 only (got: $shown)"
out="$(AGENT_JOB=1 AGENTS_CONF="$ST" AGENTS_PROBE=/nonexistent bash "$ADAPTER" pending PreInvocation <<<"$(jq -cn --arg c "agy-job-$conv" '{conversationId:$c,invocationNum:0}')")"
[ "$out" = "{}" ] && ok || bad "agy: no status line inside a background job"
rm -f "$AGENT_STATE_DIR/probe-cache.txt"

# ---------- limit-check: a limit lifted early is noticed ----------
printf '#!/bin/bash\necho OK\n' >"$BIN/stub-ping-ok"; printf '#!/bin/bash\necho "usage limit reached. Try again at %s" >&2; exit 1\n' "$(date -v+2d '+%Y-%m-%d %H:%M:%S')" >"$BIN/stub-ping-limit"
printf '#!/bin/bash\necho "network down" >&2; exit 1\n' >"$BIN/stub-ping-fail"; chmod +x "$BIN"/stub-ping-*
LC_CONF="$TMP_HOME/lc.conf"
cat >"$LC_CONF" <<'CONFEOF'
[runtime]
order = ok lim fail noping
[ok]
label = Okay
bin = stub-ping-ok
ping = stub-ping-ok
[lim]
bin = stub-ping-limit
ping = stub-ping-limit
[fail]
bin = stub-ping-fail
ping = stub-ping-fail
[noping]
bin = stub-ping-ok
CONFEOF
rm -rf "$AGENT_STATE_DIR/unavailable" "$AGENT_STATE_DIR/limit-check" "$AGENT_STATE_DIR/alerts"; mkdir -p "$AGENT_STATE_DIR/unavailable"
soon=$(( $(date +%s) + 3600 ))
for a in ok lim fail noping; do printf '%s\tlimit\n' "$soon" >"$AGENT_STATE_DIR/unavailable/$a.txt"; done
AGENTS_CONF="$LC_CONF" bash "$HOOKS/limit-check.sh"
[ ! -e "$AGENT_STATE_DIR/unavailable/ok.txt" ] && ok || bad "limit-check: an agent that answers has its limit marker removed"
grep -q "Okay の使用上限が解除" "$AGENT_STATE_DIR/alerts/limit-lifted-ok.txt" 2>/dev/null && ok || bad "limit-check: a notice is queued when a limit was lifted"
[ "$(cut -f1 "$AGENT_STATE_DIR/unavailable/lim.txt")" -gt $(( $(date +%s) + 100000 )) ] && ok || bad "limit-check: a refusal naming a new time moves the marker"
[ "$(cut -f1 "$AGENT_STATE_DIR/unavailable/fail.txt")" = "$soon" ] && ok || bad "limit-check: an unrelated failure leaves the marker alone"
[ "$(cut -f1 "$AGENT_STATE_DIR/unavailable/noping.txt")" = "$soon" ] && ok || bad "limit-check: an agent without a ping template is not touched"
printf '%s\tlimit\n' "$soon" >"$AGENT_STATE_DIR/unavailable/ok.txt"
AGENTS_CONF="$LC_CONF" bash "$HOOKS/limit-check.sh"
[ -e "$AGENT_STATE_DIR/unavailable/ok.txt" ] && ok || bad "limit-check: at most one check per interval per agent"
AGENTS_CONF="$LC_CONF" bash "$HOOKS/limit-check.sh" --force
[ ! -e "$AGENT_STATE_DIR/unavailable/ok.txt" ] && ok || bad "limit-check --force ignores the interval"
printf '%s\tlimit\n' "$(( $(date +%s) - 5 ))" >"$AGENT_STATE_DIR/unavailable/old.txt"
AGENTS_CONF="$LC_CONF" bash "$HOOKS/limit-check.sh" --force
[ ! -e "$AGENT_STATE_DIR/unavailable/old.txt" ] && ok || bad "limit-check: an expired marker is dropped"
rm -rf "$AGENT_STATE_DIR/unavailable" "$AGENT_STATE_DIR/limit-check" "$AGENT_STATE_DIR/alerts"

# ---------- one time format everywhere: 2026-10-10(Sat)11:42:34+09:00 ----------
[ "$(LC_ALL=ja_JP.UTF-8 TZ=America/New_York bash "$HOOKS/fmt-epoch.sh" 1791600154)" = "2026-10-10(Sat)11:42:34+09:00" ] && ok || bad "fmt-epoch: Asia/Tokyo, English weekday, +09:00 - whatever the locale and TZ"
TF='^[0-9]{4}-[0-9]{2}-[0-9]{2}\((Sun|Mon|Tue|Wed|Thu|Fri|Sat)\)[0-9]{2}:[0-9]{2}:[0-9]{2}\+09:00$'
mkdir -p "$AGENT_STATE_DIR/unavailable"; printf '%s\tlimit\n' "$(( $(date +%s) + 7200 ))" >"$AGENT_STATE_DIR/unavailable/stub-lim.txt"
PC="$TMP_HOME/probe.conf"; printf '[runtime]\norder = stub-lim\n[stub-lim]\nbin = stub-a\nversion = echo 1\n' >"$PC"
res="$(AGENTS_CONF="$PC" AGENTS_HOOKS_DIR="$HOOKS" AGENTS_REGISTRY=/nonexistent bash "$HOOKS/../bin/agents-probe.sh" --fresh --json 2>/dev/null; AGENTS_CONF="$PC" AGENTS_HOOKS_DIR="$HOOKS" AGENTS_REGISTRY=/nonexistent bash "$HOOKS/../bin/agents-probe.sh" --fresh 2>/dev/null | grep 'stub-lim')"
printf '%s' "$res" | grep -oE '復帰: [^ ]+: ' | sed -E 's/^復帰: //; s/: $//' | grep -qE "$TF" && ok || bad "probe shows the reset moment in the common format ($res)"
s=$(new_sid); run reminder.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro 30m x",prompt_id:"a"}')"
printf '%s' "$OUT" | sed -nE 's/.*〜([^〜]*)\)、ユーザー.*/\1/p' | grep -qE "$TF" && ok || bad "/ofuro shows its end time in the common format"
rm -rf "$AGENT_STATE_DIR/unavailable" "$AGENT_STATE_DIR/probe-cache.txt"

# ---------- agy: /ofuro is started from the transcript's last prompt ----------
conv="agy-ofuro-$(uuidgen)"; tdir="$TMP_HOME/agy-brain"; mkdir -p "$tdir"; tr="$tdir/$conv.jsonl"
mk_tr() { # prompt text -> a transcript whose last USER_INPUT is that prompt (agy's format)
  jq -cn --arg c "<USER_REQUEST>
$1
</USER_REQUEST>
<ADDITIONAL_METADATA>x</ADDITIONAL_METADATA>" '{step_index:0,source:"USER_EXPLICIT",type:"USER_INPUT",status:"DONE",content:$c}' >"$tr"
}
mk_tr "/ofuro 45m テストを直して"
out="$(AGENTS_CONF="$ST" AGENTS_PROBE=/nonexistent bash "$ADAPTER" pending PreInvocation <<<"$(jq -cn --arg c "$conv" --arg t "$tr" '{conversationId:$c,invocationNum:0,transcriptPath:$t,workspacePaths:["/work/repo"]}')")"
case "$out" in *ephemeralMessage*お風呂モード開始*45分間*テストを直して*) ok ;; *) bad "agy: /ofuro in the transcript starts bath mode through the adapter ($out)" ;; esac
[ -f "$AGENT_STATE_DIR/ofuro/$conv.json" ] && [ "$(jq -r '.session_id' "$AGENT_STATE_DIR/ofuro/$conv.json")" = "$conv" ] && ok || bad "agy: the ofuro state file is bound to the conversation id"
# the Stop hook then sees it (same session id): it blocks the stop while bath mode is active
sj="$(AGENT_STATE_DIR="$AGENT_STATE_DIR" bash "$ADAPTER" ofuro-guard.sh Stop <<<"$(jq -cn --arg c "$conv" '{conversationId:$c,terminationReason:"model_stop",fullyIdle:true}')")"
case "$sj" in *'"decision":"continue"'*) ok ;; *) bad "agy: Stop continues while bath mode is active ($sj)" ;; esac
mk_tr "/ofuro off"
out="$(AGENTS_CONF="$ST" AGENTS_PROBE=/nonexistent bash "$ADAPTER" pending PreInvocation <<<"$(jq -cn --arg c "$conv" --arg t "$tr" '{conversationId:$c,invocationNum:0,transcriptPath:$t,workspacePaths:["/work/repo"]}')")"
case "$out" in *お風呂モードを終了*) ok ;; *) bad "agy: /ofuro off ends it ($out)" ;; esac
[ ! -f "$AGENT_STATE_DIR/ofuro/$conv.json" ] && ok || bad "agy: /ofuro off removes the state file"
conv2="agy-plain-$(uuidgen)"; mk_tr "ふつうの依頼です"
AGENTS_CONF="$ST" AGENTS_PROBE=/nonexistent bash "$ADAPTER" pending PreInvocation <<<"$(jq -cn --arg c "$conv2" --arg t "$tr" '{conversationId:$c,invocationNum:0,transcriptPath:$t}')" >/dev/null
[ ! -f "$AGENT_STATE_DIR/ofuro/$conv2.json" ] && ok || bad "agy: an ordinary prompt does not start bath mode"

# ---------- ofuro-run.sh launcher ----------
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"$HOME/claude-args.txt"\n' >"$BIN/claude"; chmod +x "$BIN/claude"
CLAUDE_BAK=""
out="$(PATH="$BIN:/usr/bin:/bin" bash "$HOME_REPO/ofuro-run.sh" 2h "テストを直す" 2>&1)"; sleep 1
case "$out" in *起動しました*) ok ;; *) bad "ofuro-run starts in the background ($out)" ;; esac
grep -qx "/ofuro 2h テストを直す" "$HOME/claude-args.txt" && grep -qx "auto" "$HOME/claude-args.txt" && ok || bad "ofuro-run passes /ofuro <time> <task> and auto mode ($(tr '\n' '|' <"$HOME/claude-args.txt"))"
PATH="$BIN:/usr/bin:/bin" OFURO_MODEL=sonnet bash "$HOME_REPO/ofuro-run.sh" -f 30m "x y" >/dev/null 2>&1
grep -qx "/ofuro 30m x y" "$HOME/claude-args.txt" && grep -qx "sonnet" "$HOME/claude-args.txt" && ok || bad "ofuro-run -f with a model"
PATH="$BIN:/usr/bin:/bin" bash "$HOME_REPO/ofuro-run.sh" -f "時間を省略した任務" >/dev/null 2>&1
grep -qx "/ofuro 時間を省略した任務" "$HOME/claude-args.txt" && ok || bad "ofuro-run without a time leaves the /ofuro default"
PATH="$BIN:/usr/bin:/bin" bash "$HOME_REPO/ofuro-run.sh" >/dev/null 2>&1; expect_code "ofuro-run without a task is a usage error" 2 "$?"
rm -f "$BIN/claude" "$HOME/claude-args.txt"

# ---------- .agent-handoff/ stays out of Git ----------
res="$(bash "$HERE/handoff-exclude-test.sh" 2>&1 | tail -1)"
case "$res" in *"failed=0"*) ok ;; *) bad "handoff-exclude unit tests ($res)" ;; esac
hr="$TMP_HOME/hrepo"; mkdir -p "$hr" && git -C "$hr" init -q . && mkdir -p "$hr/.agent-handoff" && echo x >"$hr/.agent-handoff/STATE.md"
run handoff-exclude-hook.sh "$(pl "$(new_sid)" Write "$(jq -cn --arg p "$hr/.agent-handoff/STATE.md" '{file_path:$p}')")"
expect_code "handoff hook exits 0" 0 "$RC"
grep -qx '/.agent-handoff/' "$hr/.git/info/exclude" && [ -z "$(git -C "$hr" status --porcelain)" ] && ok || bad "handoff hook: writing STATE.md excludes the folder from git"
rm -rf "$hr/.git/info/exclude"; mkdir -p "$hr/.git/info"
run handoff-exclude-hook.sh "$(pl "$(new_sid)" Write '{"file_path":"/work/repo/notes.md"}')"
[ ! -s "$hr/.git/info/exclude" ] && ok || bad "handoff hook: other files do nothing"
s=$(new_sid); run reminder.sh "$(jq -cn --arg s "$s" --arg c "$hr" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"x",prompt_id:"a",cwd:$c}')"; sleep 1
grep -qx '/.agent-handoff/' "$hr/.git/info/exclude" && ok || bad "reminder: the folder in the working directory is excluded on a prompt"

# ---------- danger guard: never wipe out the home directory, the root or a system directory ----------
out="$(python3 -W ignore "$HERE/danger-cases.py" "$HOOKS")"
[ -z "$out" ] && ok || bad "danger_check: $out"
out="$(python3 -W ignore "$HERE/danger-cases-review.py" "$HOOKS")"
[ -z "$out" ] && ok || bad "danger_check (review cases): $out"
out="$(python3 -W ignore "$HERE/danger-cases-review2.py" "$HOOKS")"
[ -z "$out" ] && ok || bad "danger_check (second review): $out"
out="$(python3 -W ignore "$HERE/danger-cases-review3.py" "$HOOKS")"
[ -z "$out" ] && ok || bad "danger_check (third review): $out"
cdhome="$(python3 "$HOOKS/danger_check.py" --cwd "$HOME" <<<'rm -rf *')"; [ -n "$cdhome" ] && ok || bad "danger_check: rm -rf * with the home directory as cwd"
cdsub="$(python3 "$HOOKS/danger_check.py" --cwd "$HOME/proj" <<<'rm -rf *')"; [ -z "$cdsub" ] && ok || bad "danger_check: rm -rf * inside a project is fine"
printf '%s\n' "$HOME/precious" >"$HOME/.config-danger-test" 2>/dev/null; mkdir -p "$HOME/.config/ai-agent-config"; printf '# mine\n~/precious\n' >"$HOME/.config/ai-agent-config/danger-paths.txt"
[ -n "$(python3 "$HOOKS/danger_check.py" --cwd /tmp <<<'rm -rf ~/precious')" ] && ok || bad "danger-paths.txt adds a protected place"
rm -f "$HOME/.config/ai-agent-config/danger-paths.txt" "$HOME/.config-danger-test"
s=$(new_sid)
run danger-guard.sh "$(bashpl "$s" 'rm -rf ~')"; expect_code "danger guard: denies rm -rf ~" 2 "$RC"
case "$ERR" in *"破壊的な削除の拒否"*) ok ;; *) bad "danger guard: the reason is on stderr" ;; esac
run danger-guard.sh "$(bashpl "$s" 'rm -rf build')"; expect_code "danger guard: an ordinary rm -rf passes" 0 "$RC"
run danger-guard.sh "$(bashpl "$s" 'rm -rf ~' '{"agent_id":"sub-1"}')"; expect_code "danger guard: a subagent is not exempt" 2 "$RC"
run danger-guard.sh "$(bashpl "$s" 'rm -rf ~')" AGENT_DELEGATED_BY=orch; expect_code "danger guard: a delegated run is not exempt" 2 "$RC"
run danger-guard.sh "$(pl "$s" run_terminal_cmd '{"command":"rm -rf ~"}')"; expect_code "danger guard: any tool that carries a command line is checked" 2 "$RC"
run danger-guard.sh "$(pl "$s" Read '{"file_path":"/etc/hosts"}')"; expect_code "danger guard: tools without a command line are ignored" 0 "$RC"
run danger-guard.sh 'not json'; expect_code "danger guard: fails open on a malformed payload" 0 "$RC"
mkdir -p "$TMP_HOME/.agent-state/ofuro"; s2=$(new_sid)
run reminder.sh "$(jq -cn --arg s "$s2" '{session_id:$s,hook_event_name:"UserPromptSubmit",prompt:"/ofuro 30m x",prompt_id:"a"}')"
run danger-guard.sh "$(bashpl "$s2" 'rm -rf ~')"; expect_code "danger guard: /ofuro does not lift it" 2 "$RC"
run danger-guard.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:["bash","-lc","rm -rf ~"]},cwd:"/tmp"}')"; expect_code "danger guard: a command that arrives as an argv array" 2 "$RC"
out="$(bash "$HOOKS/agy-adapter.sh" danger-guard.sh PreToolUse <<<"$(jq -cn --arg h "$HOME" '{conversationId:"c",workspacePaths:["/tmp"],toolCall:{name:"run_command",args:{CommandLine:"rm -rf *",Cwd:$h}}}')")"
case "$out" in *'"decision":"deny"'*) ok ;; *) bad "danger guard through the agy adapter uses the command's own working directory ($out)" ;; esac
run danger-guard.sh "$(jq -cn --arg s "$s" --arg h "$HOME" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"shell",cwd:"/tmp",tool_input:{command:["bash","-lc","rm -rf *"],workdir:$h}}')"; expect_code "danger guard: the tool's own working directory (workdir) counts" 2 "$RC"
run danger-guard.sh "$(jq -cn --arg s "$s" '{session_id:$s,hook_event_name:"PreToolUse",tool_name:"exec_command",tool_input:{script:"rm -rf ~"}}')"; expect_code "danger guard: a command carried in a script field" 2 "$RC"
out="$(bash "$HOOKS/agy-adapter.sh" danger-guard.sh PreToolUse <<<"$(jq -cn '{conversationId:"c",toolCall:{name:"run_command",args:{CommandLine:"rm -rf ~"}}}')")"
case "$out" in *'"decision":"deny"'*) ok ;; *) bad "danger guard through the agy adapter is a hard deny ($out)" ;; esac

# ---------- logger ----------
rm -f "$AGENT_STATE_DIR/delegation-log.jsonl"
s=$(new_sid)
run logger.sh "$(bashpl "$s" 'codex exec "x"')"
run logger.sh "$(bashpl "$s" 'echo "codex exec x"')"
n=$(wc -l <"$AGENT_STATE_DIR/delegation-log.jsonl" | tr -d ' ')
[ "$n" = 1 ] && ok || bad "logger records only real launches (got $n lines)"

echo "passed=$pass failed=$fail"
exit "$fail"
