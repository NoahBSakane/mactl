#!/bin/bash
# install.sh / diff-ai-agent-config.sh / rollback against a throwaway HOME. Touches nothing real.
# Exit code = number of failed assertions.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="$(cd "$HERE/.." && pwd)"
export HOME="$(mktemp -d)"
unset AGENT_STATE_DIR
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
for c in codex agy muse grok; do printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/$c"; chmod +x "$FAKEBIN/$c"; done
export PATH="$FAKEBIN:$PATH"
# project rows: a private local manifest places files into projects found under ~/Repo
for pr in proj-a proj-b; do mkdir -p "$HOME/Repo/$pr" && git -C "$HOME/Repo/$pr" init -q . ; done
git -C "$HOME/Repo/proj-b" remote add origin https://example.org/team/proj-b.git
mkdir -p "$HOME/Repo/not-git" "$HOME/.config/ai-agent-config/tpl"
printf 'project rules\n' >"$HOME/.config/ai-agent-config/tpl/AGENTS.md"; printf '{"x":1}\n' >"$HOME/.config/ai-agent-config/tpl/settings.json"
printf 'remote only\n' >"$HOME/.config/ai-agent-config/tpl/remote.md"
printf 'lp-name\tproject\ttpl/AGENTS.md\tname=proj-a::AGENTS.md\talways\nlp-all\tproject\ttpl/settings.json\tall::.claude/settings.json\talways\tmanaged\nlp-remote\tproject\ttpl/remote.md\tremote=*example.org/team/*::docs/R.md\talways\n' >"$HOME/.config/ai-agent-config/local-manifest.tsv"
trap 'rm -rf "$HOME"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }
code() { if [ "$2" = "$3" ]; then ok; else bad "$1 (want $2, got $3)"; fi; }

# --- a "pre-existing" machine: old instruction files, a settings.json with unrelated keys and old hooks
mkdir -p "$HOME/.claude/hooks/delegation" "$HOME/.codex"
echo "old shared rules" >"$HOME/AGENTS.md"
echo "old claude" >"$HOME/.claude/CLAUDE.md"
ln -s "$HOME/AGENTS.md" "$HOME/.claude/AGENTS.md"
echo "old codex" >"$HOME/.codex/AGENTS.md"
printf 'model = "x"\nnotify = ["a"]\n\n[projects."/p"]\ntrust_level = "trusted"\n' >"$HOME/.codex/config.toml"
echo '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/my-codex-stop.sh"}]}]},"description":"mine"}' >"$HOME/.codex/hooks.json"
mkdir -p "$HOME/.gemini/antigravity-cli"; echo '{"colorScheme":"dark","permissions":{"allow":["command(my own tool)"]}}' >"$HOME/.gemini/antigravity-cli/settings.json"
mkdir -p "$HOME/.config/muse"
echo '{"schema_version":1,"tui":{"foreign_context_notice_shown":true}}' >"$HOME/.config/muse/settings.json"
cat >"$HOME/.claude/settings.json" <<EOF
{"model":"sonnet","permissions":{"allow":["Bash(ls *)"]},"autoMode":{"environment":["Source control: my own org"]},
 "hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"\$HOME/.claude/hooks/delegation/user-prompt-delegation-reminder.sh"},
                                         {"type":"command","command":"/usr/local/bin/my-own-hook.sh"}]}],
          "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"\$HOME/.claude/hooks/delegation/pre-edit-composition-check.sh"}]}]}}
EOF
for n in user-prompt-delegation-reminder pre-edit-composition-check post-tool-delegation-logger delegation-status scope-discipline-reminder; do
  echo "#!/bin/bash" >"$HOME/.claude/hooks/delegation/$n.sh"; chmod +x "$HOME/.claude/hooks/delegation/$n.sh"
done

# 1. existing live files differ from the repo -> refuse without --force
out="$(bash "$CFG/install.sh" -Y 2>&1)"; code "drift aborts" 3 $?
case "$out" in *DRIFT*) ok ;; *) bad "plan shows DRIFT rows" ;; esac
[ "$(cat "$HOME/AGENTS.md")" = "old shared rules" ] && ok || bad "abort leaves live untouched"

# 2. --dry-run changes nothing
bash "$CFG/install.sh" -n -f >/dev/null 2>&1; code "dry-run exits 0" 0 $?
[ "$(cat "$HOME/AGENTS.md")" = "old shared rules" ] && ok || bad "dry-run leaves live untouched"

# 3. --force installs, backing up the old content
bash "$CFG/install.sh" -f -y >/dev/null 2>&1; code "force install" 0 $?
cmp -s "$CFG/src/shared-rules.md" "$HOME/AGENTS.md" && ok || bad "AGENTS.md deployed"
[ -L "$HOME/.claude/AGENTS.md" ] && [ "$(readlink "$HOME/.claude/AGENTS.md")" = "$HOME/AGENTS.md" ] && ok || bad "claude AGENTS.md link"
[ -x "$HOME/.agents/hooks/gate.sh" ] && ok || bad "hooks deployed and executable"
[ -x "$HOME/.knowledge/bin/agents-probe.sh" ] && ok || bad "probe deployed"
[ -L "$HOME/.claude/skills/orchestrate-agents" ] && [ -f "$HOME/.claude/skills/orchestrate-agents/SKILL.md" ] && ok || bad "claude skill link resolves"
grep -q "old shared rules" "$(ls -d "$HOME"/.agent-state/backups/*/files/shared-rules)" 2>/dev/null && ok || bad "old AGENTS.md backed up"
[ -L "$HOME/.codex/AGENTS.md" ] && [ "$(readlink "$HOME/.codex/AGENTS.md")" = "$HOME/AGENTS.md" ] && ok || bad "codex AGENTS.md is a symlink to ~/AGENTS.md"
grep -q "developer_instructions = '''" "$HOME/.codex/config.toml" && grep -q "京都方言" "$HOME/.codex/config.toml" && grep -q '^model = "x"' "$HOME/.codex/config.toml" && ok || bad "codex persona block added, existing config.toml kept"
# settings.json: unrelated keys kept, old hook entries gone, foreign hook kept, new entries present
jq -e '.model=="sonnet" and .permissions.allow[0]=="Bash(ls *)"' "$HOME/.claude/settings.json" >/dev/null && ok || bad "unrelated settings preserved"
jq -e '[.. | .command? // empty | select(test("\\.claude/hooks/delegation"))] | length == 0' "$HOME/.claude/settings.json" >/dev/null && ok || bad "old hook entries removed"
jq -e '[.. | .command? // empty | select(. == "/usr/local/bin/my-own-hook.sh")] | length == 1' "$HOME/.claude/settings.json" >/dev/null && ok || bad "user's own hook kept"
jq -e '.hooks.PreToolUse | map(.matcher) | contains(["Bash","AskUserQuestion"])' "$HOME/.claude/settings.json" >/dev/null && ok || bad "new hook entries present"
grep -q "legacy shim" "$HOME/.claude/hooks/delegation/pre-edit-composition-check.sh" && ok || bad "legacy shim placed"

# 3b. other agents' wiring
jq -e '.description=="mine" and ([.. | .command? // empty | select(. == "/opt/my-codex-stop.sh")] | length == 1) and (.hooks.PreToolUse | map(.matcher) | contains(["Bash","apply_patch|Edit|Write"]))' "$HOME/.codex/hooks.json" >/dev/null && ok || bad "codex hooks merged, user's own hook and keys kept"
jq -e '.schema_version==1 and .tui.foreign_context_notice_shown==true and (.hooks.PreToolUse|length)==1' "$HOME/.config/muse/settings.json" >/dev/null && ok || bad "muse settings merged, other keys kept"
jq -e '.context.foreign_personal_rules==false and .context.foreign_personal_skills==false and .tui.foreign_context_notice_shown==true' "$HOME/.config/muse/settings.json" >/dev/null && ok || bad "muse foreign personal context switched off, other keys kept"
[ -L "$HOME/.config/muse/AGENTS.md" ] && [ "$(readlink "$HOME/.config/muse/AGENTS.md")" = "$HOME/AGENTS.md" ] && ok || bad "muse AGENTS.md is a symlink to ~/AGENTS.md"
jq -e '.["ai-agent-config"].PreToolUse|length==3' "$HOME/.gemini/config/hooks.json" >/dev/null && ok || bad "agy hooks.json has our named hook set"
jq -e --arg p "$HOME/.agents/skills" '.entries|map(.path)|index($p) != null' "$HOME/.gemini/config/skills.json" >/dev/null && ok || bad "agy skills.json registers shared skills"
jq -e '.colorScheme=="dark" and (.permissions.allow|index("command(my own tool)") != null and index("read_url(github.com)") != null and index("read_url(docs.claude.com)") != null)' "$HOME/.gemini/antigravity-cli/settings.json" >/dev/null && ok || bad "agy allow rules added, the user's own rule and settings kept (union)"
[ -L "$HOME/.gemini/AGENTS.md" ] && [ -L "$HOME/.grok/AGENTS.md" ] && [ -L "$HOME/.grok/skills/ofuro" ] && ok || bad "gemini/grok links"

# 3c. enforced settings are applied, and unrelated keys are kept
jq -e '.permissions.defaultMode=="auto" and (.skillOverrides|length)==14 and .permissions.allow[0]=="Bash(ls *)"' "$HOME/.claude/settings.json" >/dev/null && ok || bad "enforced settings applied, existing permissions kept"
jq -e '.autoMode.environment | index("Source control: my own org") != null and index("$defaults") != null and (map(select(test("NoahBSakane/mactl"))) | length) == 2' "$HOME/.claude/settings.json" >/dev/null && ok || bad "autoMode: our trusted-repo entries added, the user's own entry kept (union)"
[ -f "$HOME/.knowledge/gas-apps-script.md" ] && [ -f "$HOME/.knowledge/writing-styles.md" ] && ok || bad "knowledge seeds placed when absent"

# 4. idempotent; diff script agrees
out="$(bash "$CFG/install.sh" -y 2>&1)"; code "re-run exits 0" 0 $?
case "$out" in *"変更なし"*) ok ;; *) bad "second run is a no-op" ;; esac
bash "$CFG/diff-ai-agent-config.sh" --brief >/dev/null 2>&1; code "diff exits 0 when in sync" 0 $?

# 4b. enforcement: a value changed by hand is reset, keys the fragment does not mention survive
jq '.permissions.defaultMode="manual" | .skillOverrides["pdf"]="on" | .skillOverrides["my-own-skill"]="on"' "$HOME/.claude/settings.json" >"$HOME/s.tmp" && cat "$HOME/s.tmp" >"$HOME/.claude/settings.json"
bash "$CFG/diff-ai-agent-config.sh" --brief 2>&1 | grep -q "^\[UPDATE.*claude-settings-enforced" && ok || bad "hand-changed enforced value shows as UPDATE"
bash "$CFG/diff-ai-agent-config.sh" --brief >/dev/null 2>&1; code "diff reports the deviation (exit 1)" 1 $?
bash "$CFG/install.sh" -y >/dev/null 2>&1
jq -e '.permissions.defaultMode=="auto" and .skillOverrides["pdf"]=="off" and .skillOverrides["my-own-skill"]=="on" and .permissions.allow[0]=="Bash(ls *)"' "$HOME/.claude/settings.json" >/dev/null && ok || bad "install resets enforced values, keeps the rest"

# 4c. shared rules: every route that reads them yields the same content (checked by the diff script)
bash "$CFG/diff-ai-agent-config.sh" --brief 2>&1 | grep -q "共通ルールの一致: OK" && ok || bad "consistency check passes after install"
cp "$HOME/.claude/AGENTS.md" /dev/null 2>&1
rm -f "$HOME/.claude/AGENTS.md"; echo "different rules" >"$HOME/.claude/AGENTS.md"
bash "$CFG/diff-ai-agent-config.sh" --brief 2>&1 | grep -q "共通ルールの一致: NG" && ok || bad "a diverged ~/.claude/AGENTS.md is detected"
bash "$CFG/diff-ai-agent-config.sh" --brief >/dev/null 2>&1; code "divergence makes diff exit non-zero" 1 $?
bash "$CFG/install.sh" -f -y >/dev/null 2>&1
bash "$CFG/diff-ai-agent-config.sh" --brief 2>&1 | grep -q "共通ルールの一致: OK" && ok || bad "install --force restores the consistency"

# 4d. CLI behaviour: default = plan + confirm; -n/-N/-y/-Y/-f/-F/-R and clustered short options
echo "<!-- v2 -->" >>"$CFG/src/shared-rules.md"
out="$(bash "$CFG/install.sh" </dev/null 2>&1)"; code "default, no terminal: plan only, exit 0" 0 $?
case "$out" in *"非対話"*) ok ;; *) bad "non-interactive default says why it did not run" ;; esac
grep -q "v2" "$HOME/AGENTS.md" && bad "non-interactive default must not deploy" || ok
out="$(printf 'n\n' | AI_CONFIG_ASSUME_TTY=1 bash "$CFG/install.sh" 2>&1)"; case "$out" in *"中止しました"*) ok ;; *) bad "answering n aborts" ;; esac
grep -q "v2" "$HOME/AGENTS.md" && bad "answering n must not deploy" || ok
out="$(bash "$CFG/install.sh" -N 2>&1)"; case "$out" in *"<!-- v2 -->"*) ok ;; *) bad "-N shows the diff" ;; esac
grep -q "v2" "$HOME/AGENTS.md" && bad "-N must not deploy" || ok
bash "$CFG/install.sh" -n -y >/dev/null 2>&1; code "-n with -y is a usage error" 2 $?
out="$(printf 'y\n' | AI_CONFIG_ASSUME_TTY=1 bash "$CFG/install.sh" 2>&1)"; case "$out" in *"完了"*) ok ;; *) bad "answering y deploys" ;; esac
grep -q "v2" "$HOME/AGENTS.md" && ok || bad "answering y deployed the change"
sed -i '' '/<!-- v2 -->/d' "$CFG/src/shared-rules.md"
out="$(bash "$CFG/install.sh" -y 2>&1)"; case "$out" in *"["*"] "*) bad "-y prints no plan (summary only)" ;; *) ok ;; esac
grep -q "v2" "$HOME/AGENTS.md" && bad "-y deployed the revert" || ok
echo "<!-- v3 -->" >>"$CFG/src/shared-rules.md"
out="$(bash "$CFG/install.sh" -Y 2>&1)"; case "$out" in *"[UPDATE"*"deployed: shared-rules"*) ok ;; *) bad "-Y prints the plan and the deployed rows" ;; esac
sed -i '' '/<!-- v3 -->/d' "$CFG/src/shared-rules.md"; bash "$CFG/install.sh" -y >/dev/null 2>&1
echo "live registry edit 2" >>"$HOME/.knowledge/ai-agents.md"
bash "$CFG/install.sh" -y >/dev/null 2>&1; grep -q "live registry edit 2" "$HOME/.knowledge/ai-agents.md" && ok || bad "-y keeps the seeded registry"
bash "$CFG/install.sh" -Fy >/dev/null 2>&1; grep -q "live registry edit 2" "$HOME/.knowledge/ai-agents.md" && bad "-F resets the registry to the seed" || ok
last="$(ls -1 "$HOME/.agent-state/backups" | tail -1)"
bash "$CFG/install.sh" -r -n 2>&1 | grep -q "$last" && ok || bad "-r -n plans the rollback of the latest deployment"
bash "$CFG/install.sh" -R -n 2>&1 | grep -q "ロールバック計画" && ok || bad "-R -n plans the rollback with diffs"
[ -s "$HOME/.agent-state/protected-paths.txt" ] && grep -qx "$HOME/AGENTS.md" "$HOME/.agent-state/protected-paths.txt" && grep -qx "$HOME/.codex/AGENTS.md" "$HOME/.agent-state/protected-paths.txt" && ok || bad "install writes the protected instruction files list"
! grep -q "claude-settings\|settings.json" "$HOME/.agent-state/protected-paths.txt" && ok || bad "only instruction files are protected"

# 5. repo update flows through (live untouched since install -> UPDATE, not DRIFT)
cp "$CFG/src/shared-rules.md" "$HOME/shared-rules.orig"
echo "<!-- bump -->" >>"$CFG/src/shared-rules.md"
bash "$CFG/diff-ai-agent-config.sh" --brief 2>&1 | grep -q "^\[UPDATE" && ok || bad "repo change shows as UPDATE"
bash "$CFG/install.sh" -y >/dev/null 2>&1; code "update installs without --force" 0 $?
cp "$HOME/shared-rules.orig" "$CFG/src/shared-rules.md"
bash "$CFG/install.sh" -y >/dev/null 2>&1

# 6. live edit -> DRIFT -> install refuses
echo "my local edit" >>"$HOME/AGENTS.md"
bash "$CFG/diff-ai-agent-config.sh" --brief 2>&1 | grep -q "^\[DRIFT" && ok || bad "live edit shows as DRIFT"
bash "$CFG/install.sh" -y >/dev/null 2>&1; code "drifted live blocks install" 3 $?
grep -q "my local edit" "$HOME/AGENTS.md" && ok || bad "live edit survived"

# 7. seeded registry is never overwritten
echo "live registry edit" >>"$HOME/.knowledge/ai-agents.md"
bash "$CFG/install.sh" -f -y >/dev/null 2>&1
grep -q "live registry edit" "$HOME/.knowledge/ai-agents.md" && ok || bad "seed row keeps live content"
[ "$(cat "$HOME/Repo/proj-a/AGENTS.md" 2>/dev/null)" = "project rules" ] && [ ! -e "$HOME/Repo/proj-b/AGENTS.md" ] && ok || bad "project row: name= selector places the file only in the matching project"
[ -f "$HOME/Repo/proj-a/.claude/settings.json" ] && [ -f "$HOME/Repo/proj-b/.claude/settings.json" ] && [ ! -e "$HOME/Repo/not-git/.claude/settings.json" ] && ok || bad "project row: all selector reaches every git project and nothing else"
[ -f "$HOME/Repo/proj-b/docs/R.md" ] && [ ! -e "$HOME/Repo/proj-a/docs/R.md" ] && ok || bad "project row: remote= selector matches on the origin URL"
echo "my own edit" >"$HOME/Repo/proj-a/AGENTS.md"; echo '{"x":2}' >"$HOME/Repo/proj-a/.claude/settings.json"
bash "$CFG/install.sh" -y >/dev/null 2>&1; code "project row (managed): an edited copy is reported as drift and not overwritten" 3 $?
[ "$(cat "$HOME/Repo/proj-a/.claude/settings.json")" = '{"x":2}' ] && ok || bad "project row (managed): drift leaves the edit alone"
bash "$CFG/install.sh" -f -y >/dev/null 2>&1
[ "$(cat "$HOME/Repo/proj-a/AGENTS.md")" = "my own edit" ] && ok || bad "project row (seed): a project's own edit is never overwritten, even with -f"
[ "$(cat "$HOME/Repo/proj-a/.claude/settings.json")" = '{"x":1}' ] && ok || bad "project row (managed): -f restores the template"

# doctor.sh: the must-have tools are checked first, with a way to get each missing one
bash "$CFG/doctor.sh" >/dev/null 2>&1; code "doctor passes when the tools are there" 0 $?
nojq="$(mktemp -d)"; for t in bash python3 git awk sed find shasum dirname basename mktemp cat; do ln -s "$(command -v $t)" "$nojq/$t"; done
out="$(PATH="$nojq" /bin/bash "$CFG/install.sh" -n 2>&1)"; rc=$?
[ "$rc" = 1 ] && grep -q "jq" <<<"$out" && grep -q "brew install jq" <<<"$out" && ok || bad "install.sh stops with the missing tool and how to get it (rc=$rc)"
rm -rf "$nojq"

# 8. rollback of the first install brings the old machine back
first="$(ls -1 "$HOME/.agent-state/backups" | head -1)"
bash "$CFG/install.sh" -r "$first" -y >/dev/null 2>&1
[ "$(cat "$HOME/.claude/CLAUDE.md")" = "old claude" ] && ok || bad "rollback restores CLAUDE.md"
jq -e '[.. | .command? // empty | select(test("\\.agents/hooks"))] | length == 0' "$HOME/.claude/settings.json" >/dev/null && ok || bad "rollback removes our hook entries"
jq -e '.model=="sonnet"' "$HOME/.claude/settings.json" >/dev/null && ok || bad "rollback keeps unrelated settings"
jq -e '.autoMode.environment == ["Source control: my own org"]' "$HOME/.claude/settings.json" >/dev/null && ok || bad "rollback takes only our autoMode entries out"
jq -e '.description=="mine" and ([.. | .command? // empty | select(test("agents/hooks"))] | length == 0) and ([.. | .command? // empty | select(. == "/opt/my-codex-stop.sh")] | length == 1)' "$HOME/.codex/hooks.json" >/dev/null && ok || bad "rollback unmerges codex hooks, keeps the user's"
jq -e '.tui.foreign_context_notice_shown==true and (has("hooks")|not) and (has("context")|not)' "$HOME/.config/muse/settings.json" >/dev/null && ok || bad "rollback unmerges muse hooks and context"
[ ! -e "$HOME/.config/muse/AGENTS.md" ] && ok || bad "rollback removes muse AGENTS.md"
[ ! -e "$HOME/Repo/proj-b/docs/R.md" ] && [ ! -e "$HOME/Repo/proj-a/.claude/settings.json" ] && ok || bad "rollback removes the files placed into projects"
jq -e '.colorScheme=="dark" and .permissions.allow==["command(my own tool)"]' "$HOME/.gemini/antigravity-cli/settings.json" >/dev/null && ok || bad "rollback takes only our allow rules out"
[ ! -e "$HOME/.gemini/config/hooks.json" ] || jq -e 'has("ai-agent-config")|not' "$HOME/.gemini/config/hooks.json" >/dev/null && ok || bad "rollback removes agy hook set"

echo "passed=$pass failed=$fail"
exit "$fail"
