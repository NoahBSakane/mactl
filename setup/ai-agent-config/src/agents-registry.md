# AIコーディングエージェント台帳(スペックと適切用途)

導入状況・バージョン・モデル一覧は保存しない。`~/.knowledge/bin/agents-probe.sh` が毎回各CLIから取得する。
確認日と、台帳が記載するフラグは、各エージェントの見出し直下のコメント(`verified` / `flags`)に持つ。確認日が14日を超えるとprobeが知らせ、`refresh-registry` skill で再調査する(作業は止めない)。
根拠の格付け: A=独立ベンチ / B=第三者の報告 / C=公式の機能記述のみ / D=根拠なし。出典と日付は各項に付ける。

## 共通事項

- 全エージェント共通のhook拒否: **終了コード2 + stderrに理由**(Claude・Codex・Grok公式、Muse第三者)。agyのみJSON `decision: deny`。
- 委譲して起動するときは、環境変数 `AGENT_DELEGATED_BY=<自分のセッション>` を付ける(委譲先のhookが承認を再要求しないため)。hookへの引き継ぎは、Claude Code・Codex・agyで実機確認済み(2026-10-07)。**Museはhookへ渡す環境変数を許可リスト(HOME LANG LOGNAME PATH PWD SHELL SHLVL TMPDIR USER)に絞るため渡らない**ので、`--disable-approval` 等の無人実行(`permission_mode` が `bypassPermissions` になる)で判別する。外部CLIへ渡す文に秘密情報を入れない。
- 司令塔の判断材料: 導入済み(probe) かつ 該当用途の根拠がA〜Cにあるものだけを委譲候補に出す。

## Claude Code(`claude`)

<!-- verified agent=claude date=2026-10-06 -->
<!-- flags agent=claude cmd="" : --print --permission-mode --model --effort --allowedTools -->

- 非対話: `claude -p "<prompt>"`(`--output-format stream-json`)。承認: `--permission-mode auto|dontAsk|bypassPermissions`、`--dangerously-skip-permissions`(隔離環境のみ)。
- モデル/思考: `--model <alias|id>`、`--effort <level>`。サブエージェントのmodelは alias(sonnet/opus/haiku/fable)か完全ID。
- 指示: `~/.claude/CLAUDE.md`。AGENTS.mdは、CLAUDE.mdが無い時だけ読む(v2.1.277〜)ので `@AGENTS.md` で取り込む。import最大4段、相対パスはimport元基準。
- skills: `~/.claude/skills/<name>/SKILL.md`(symlink可)。`~/.agents/skills` は読まない。
- hook: settings.json。入力に `agent_id`(サブエージェント内のみ)、`permission_mode`。`if: "Bash(codex exec *)"` で絞り込み可。
- 自走: `/goal`(auto mode併用で無人)。上限: 設定 `autoContinueAtUsageLimit`(v2.1.234〜、既定で有効)で、リセット後に自動再開(claude.ai契約の対話。`/config` の「Continue automatically at usage limit」の行は、環境によって表示されない。表示されない環境がある=確認 2026-10-07。`-p` は記載なし)。
- メモリ: `~/.claude/projects/<プロジェクト>/memory/*.md`(自動メモリ。`MEMORY.md` は索引)。**確認済み 2026-10-07**
- 許可ルール(**実機確認 2026-10-07**): ヘッドレス(`-p`)は対話の承認ができず、許可の無いツールは自動で拒否される(「no output produced — a tool required the "read_url" permission …」)。設定は `~/.gemini/antigravity-cli/settings.json` の `permissions.allow`(ヘッドレスもこれを読む。プロジェクト単位は `~/.gemini/config/projects/` が優先)。書式は `command(<バイナリ サブコマンド>)`・`read_file(<絶対パス>)`・`write_file(<絶対パス>)`・`mcp(<server>/<tool>)`・`read_url(<ドメイン>)`・`execute_url(<ドメイン>)`(CLI同梱の説明は `*` の全許可を禁じている)。**Web検索 `search_web` は許可ルール不要**(ルール無しで無人実行できた)。**ページ取得 `read_url` はドメインごとのルールが要る**(ルール無しは拒否、`read_url(example.com)` と公式ドキュメントのドメインは取得できた)。
- 読み取り専用のWeb調査(ヘッドレス): `agents.conf` の `research` に置いてある。許可ルールの `read_url` はドメイン単位でワイルドカードが無く(`*`・`*.com`・無指定は通らない)、hookが `allow` を返しても、`permissionOverrides` を付けても、無人では拒否される(いずれも実機確認 2026-10-07)。そこで `--dangerously-skip-permissions` で動かし、調査ジョブの間だけ有効な PreToolUse hook `agy-job-guard.sh`(拒否 `deny` はこのフラグでも効く)が、Web検索とページ取得以外の全ツール(シェル・ファイル・ブラウザ・MCP)を拒否し、内部アドレス・認証情報つき・秘密らしき文字列を含むURLも拒否する。ガードは失敗時に拒否側へ倒れる(他のhookは通す側)。実機で、取得は通り、`run_command` と `view_file` は拒否された。`~/.gemini/antigravity-cli/settings.json` の許可ルール(`agy-settings-allow`)は、対話のagyでの便宜。
- 適切用途: AA Coding Agent Index(2026-10-05): Sonnet 5.5 (max) 68.4 / Opus 5.5 (max) 66.0(格付けA、BenchLM転載)。

## Codex CLI(`codex`)

<!-- verified agent=codex date=2026-10-06 -->
<!-- flags agent=codex cmd="exec" : --approve-for-me --model --config --sandbox -->

- 非対話: `codex exec "<prompt>"`、コードレビュー: `codex review`。承認: `--approve-for-me`(単体で使う。`--sandbox` と併用不可=実機確認)、`--dangerously-bypass-approvals-and-sandbox`。
- モデル: `-m <slug>`、effort: `-c model_reasoning_effort="low|medium|high|xhigh|max|ultra"`。一覧: `codex debug models`(JSON。各モデルの `description` が階級を示す: workhorse/frontier/fast)。
- 指示: `~/.codex/AGENTS.md`(`AGENTS.override.md` が優先)。importなし。合計32KiB(`project_doc_max_bytes`)。
- skills: `~/.agents/skills`、repoの `.agents/skills`(symlink可、`agents/openai.yaml` で暗黙起動を制御)。
- hook: `~/.codex/hooks.json`(`{"hooks":{イベント:[{matcher,hooks:[…]}]}}`)。既定で有効だが、**新規・変更されたhookは `/hooks` で人が信頼するまでスキップ**される(自動化での一時回避は `--dangerously-bypass-hook-trust`)。入力は `session_id`・`turn_id`・`tool_name`(シェルは `Bash`、編集は `apply_patch`)・`tool_input.command`(apply_patchはパッチ本文)・`permission_mode`・`prompt`(`UserPromptSubmit` は実機確認 2026-10-06)。拒否は終了コード2、またはClaude互換の `hookSpecificOutput.permissionDecision`。
- 利用枠: 使用上限に当たると `codex exec` が失敗し、メッセージに復帰時刻が出る。probeは残枠を取得できないので、失敗を検知した側が `~/.agent-state/unavailable/codex.txt` に記録する。`agent-run.sh` はエラー文の解除時刻(`limit-reset.py`)を使い、読めないときだけ6時間後とする。probeと状態行は、解除日時を秒まで表示する。
- メモリ: `~/.codex/memories/`(`memory_summary.md`・`MEMORY.md` が要約、`raw_memories.md`・`rollout_summaries/` が生ログ。gitリポジトリ)。**確認済み 2026-10-07**
- 自走: `/goal`(v0.128〜、第三者)。
- 適切用途: 既存リポジトリの修正・テスト・バグ修正(格付けA: AA Coding Agent Index GPT-6.1 Sol xhigh 62.9 / medium 61.4 / low 57.2、Terminal-Bench 2.0 は GPT-5.5 で82.2%(公式leaderboard 2026-06-07))。他者コードのレビュー: ベンダー実施の比較で適合率70%・再現率30%(格付けB〜C)。

## Antigravity CLI(`agy`)

<!-- verified agent=agy date=2026-10-06 -->
<!-- flags agent=agy cmd="" : --print --model --effort --dangerously-skip-permissions -->

- 非対話: `agy -p "<prompt>" --model <id>`。承認: `--dangerously-skip-permissions`。モデル名にeffortが内包(`--effort` も可)。一覧: `agy models`。
- 指示: グローバル `~/.gemini/AGENTS.md`・`~/.gemini/GEMINI.md`・`~/.gemini/config/{AGENTS,GEMINI}.md`(**実機確認 2026-10-06**)。プロジェクトは cwd からrepo rootまで遡る。ファイル上限24KB、rules合計20,000トークン。
- skills: グローバルの設定ルートは `~/.gemini/config/`。`skills/<name>/SKILL.md`、または `skills.json` の `entries` に**絶対パス**で登録する(`~/` は `must be an absolute path` として拒否される。実機確認 2026-10-06)。
- hook: `~/.gemini/config/hooks.json`(名前付きの集合 `{名前:{イベント:[…]}}`。プロジェクトは `.agents/hooks.json`。**実機確認 2026-10-06**)。入力はcamelCase(`conversationId`・`workspacePaths`・`toolCall.name`/`args`)。シェルは `run_command`(`CommandLine`)、編集は `write_to_file`(`TargetFile`)。`PreToolUse` の出力は `{"decision":"allow|deny|ask","reason":…}`(denyは「tool call denied by pre-tool hook」として返る。`--dangerously-skip-permissions` の実行では `ask` は自動承認される)。`PostToolUse` は空の `{}` だけを返せる(他のキーは読み込みエラー)。モデルへ何かを伝えるのは `PreInvocation`(モデル呼び出しの前。`{"injectSteps":[{"ephemeralMessage":"…"}]}` で注入。`invocationNum` は、ユーザーのターンの最初の呼び出しで0、ツール結果を受けて呼び直すたびに増える。**実機確認 2026-10-07**)と `PostInvocation`(`terminationBehavior: force_continue` も可)。
- メモリ: 永続メモリは持たない(会話の記録 `~/.gemini/antigravity-cli/brain/`・`conversations/` のみ。`knowledge/` は空)。第三者の記録を参照。**確認 2026-10-07**
- 読み取り専用のWeb調査(ヘッドレス): 実用的な設定が無い。Webツール(`read_url` 等)ごとに許可ルールが要り、代替の `--dangerously-skip-permissions` はWebの内容を読む無人ジョブには使えない。そのため `agents.conf` に `research` を置いていない。
- 適切用途: 大規模コンテキスト読解・マルチモーダル・調査(格付けB)。コーディング指数: Gemini 3.8 Flash (high) 41.9、Gemini 4 Argon (high) 63.8(格付けA、後者は環境によっては `agy models` に出ない)。

## Muse Code(`muse`)

<!-- verified agent=muse date=2026-10-06 -->
<!-- flags agent=muse cmd="exec" : --no-foreign-personal-context --approval-mode --disable-approval --yolo --trust-workspace --reasoning-effort --workspace -->

- 非対話: `muse exec "<prompt>"`。承認: `--approval-mode untrusted|on-request|never`、`--disable-approval`(サンドボックス維持)、`--yolo`(両方無効)。workspaceのrules/skillsは `--trust-workspace` で読む。
- 思考: `--reasoning-effort none|minimal|low|medium|high|xhigh|max|ultra`。モデル解決: `muse model-profile show <model> --effort <tier>`。認証: `muse login` または `META_API_KEY`。
- 指示: 各階層で `AGENTS.md` → `CLAUDE.md` → `.agents/AGENTS.md` → `.claude/CLAUDE.md` の先勝ち。ユーザー単位の専用rulesは `$XDG_CONFIG_HOME/muse/AGENTS.md`(symlinkでも読まれる。**実機確認 2026-10-07**)。加えて他エージェントの個人rulesを既定で取り込むが、読むのは `~/.claude/CLAUDE.md` があればそれ、無ければ `$CODEX_HOME/AGENTS.md` の**どちらか1つだけ**で、`@AGENTS.md` のimportは解決しない(**実機確認 2026-10-07**)。止めるには `settings.json` の `context.foreign_personal_rules=false`(skillsは `context.foreign_personal_skills=false`。実機確認済み)、または実行ごとに `--no-foreign-personal-context`。
- skills: `~/.agents/skills`、`$XDG_CONFIG_HOME/muse/skills`、`~/.claude/skills`、`$CODEX_HOME/skills`。取り込み: `muse skills import --from claude|codex`。
- hook: `<project>/.muse/hooks.json`(`schema_version`・`hooks`・matcherグループの3層)、ユーザーsettings(`~/.config/muse/settings.json` の `hooks`。**実機確認 2026-10-06**、workspaceの信頼は不要)、`managed_hooks_path`。15イベント(Claude互換+LLM呼び出し系)。`UserPromptSubmit` の入力は `hook_event_name`・`prompt`・`session_id`・`turn_id`・`cwd`・`model`・`permission_mode`(**実機確認 2026-10-06**)。拒否は終了コード2または `{"decision":"block"}`。`PreToolUse` の入力は `tool_name`・`tool_input`・`tool_use_id`(第三者実測)。
- メモリ: 内蔵メモリがある(範囲は personal / personal_project / project=`<repo>/.agents/memory`)。個人用の保存先は公式に公開されておらず、まだ作られてもいない(未ログイン)。`~/.config/muse/memory/`・`~/.local/share/muse/memory/` を候補として `agents.conf` に登録。**未確認 2026-10-07**
- 読み取り専用のWeb調査(ヘッドレス): `muse exec ... --disable-approval --disable-write --disable-shell --no-foreign-personal-context`(未ログインのため未検証)
- 適切用途: 長時間のバックグラウンド作業・中断再開(格付けB)、低コスト。コーディング指数: Spark 1.3 (max) 54.3(格付けA)。

## Grok Build(`grok`)

<!-- verified agent=grok date=2026-10-06 -->
<!-- flags agent=grok cmd="" : --always-approve --model --effort --worktree -->

- 非対話: `grok -p "<prompt>" -m <id>`。承認: `--always-approve`(別名 `--yolo`)。effort: `--effort <level>`。worktree: `-w`。一覧: `grok models`、設定の確認: `grok inspect`。導入: `curl -fsSL https://x.ai/cli/install.sh | bash`。
- 指示: グローバル `~/.grok/`。`AGENTS.md`・`CLAUDE.md`・`CLAUDE.local.md`・`.grok/rules/*.md` を読み、深い階層が優先。
- skills: `~/.grok/skills/`、`./.grok/skills/`、`~/.grok/config.toml` の追加パス。
- hook: `~/.grok/hooks/*.json`。Claudeの `.claude/settings.json` のhookも読む。拒否は終了コード2。
- メモリ: 機能がある(`grok memory clear [--workspace|--global|--all]`、`/memory`、`--experimental-memory`)。保存先のパスは公式に公開されていない(markdownファイルで、プロジェクト単位とグローバルの2つの範囲)。`~/.grok/memory/` を候補として `agents.conf` に登録。**未確認 2026-10-07**
- 適切用途: 並列サブエージェント・plan mode・worktree隔離(格付けC)。コーディング指数: Grok 4.7 (xhigh) 56.3(格付けA)。新規生成・レビューの適性に独立根拠は無い(格付けD)。

## 代行先の優先順位

<!-- verified agent=failover date=2026-10-07 -->

Claude Codeが使えないときに、司令塔を代行させる順序。probeで `ready` のものから、上位を選ぶ。

1. Codex
2. agy
3. Muse(Grokは導入されていれば、適切用途に従う)

根拠(Artificial Analysis Coding Agent Index、BenchLMの転載、2026-10-05時点。格付けA)と、導入・配線の状況:

- Codex: GPT-6.1 Sol (xhigh) 62.9、(medium) 61.4。外部CLIで最上位。
- agy: 確認時点で選べたモデルでは Gemini 3.8 Flash (high) 41.9。指数はMuseより低いが、導入・認証済みで、共通rules・共有skills・hook(ゲート)の配線を実機確認済み。Gemini 4 Argon (high) 63.8 は、確認時点の `agy models` には出なかった。
- Muse: Spark 1.3 (max) 54.3。指数はagyより高いが、認証が未完で、ゲートの実機検証も未了のため3番目にしている。
- Grok: Grok 4.7 (xhigh) 56.3(未導入)。

指数だけでなく、認証と配線の状況で決めている。状況が変われば入れ替える(例: Museがログイン済みで、ゲートの実機検証が済めば、agyより上にしてよい)。

## 機械が読む設定

エージェント固有の機械可読な情報(コマンド名、ツール名、メモリの場所、ヘッドレス実行のテンプレート)は、`~/.agents/hooks/agents.conf` にある(リポジトリの `src/hooks/agents.conf`)。この台帳は人間向けの仕様と評価で、スクリプトはこの台帳の本文を読まない(読むのは `verified` と `flags` のコメントだけ)。エージェントを足す・外すときは、両方を直す。

## 更新の扱い

- スペック(コマンド・フラグ・パス): `agents-probe.sh --check` が、上の `flags` コメントのフラグが各CLIの `--help` に残っているかを検査する。消えていれば通知が出る(承認フラグ等の破壊的変更の可能性)。
- 適切用途: `refresh-registry` skill が、公式文書と独立ベンチマークで再調査して更新する。出典URLと日付と格付けを必ず付ける。コマンド・フラグ・承認方式の変更は、根拠を添えてユーザーに確認してから反映する。
- このファイルは live 側(`~/.knowledge/ai-agents.md`)が作業用の正本で、repoの `src/agents-registry.md` は初期配備用の種。反映は reconcile-agent-config skill で行う。
