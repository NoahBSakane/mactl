# AIコーディングエージェントの設定を他Macへ複製する

個人のMacの設定。プロジェクトのコードとは無関係。

## 何を管理するか

Claude Code / Codex CLI / Antigravity CLI(`agy`)/ Muse Code / Grok Build といったエージェントに共通する運用(応答言語・司令塔としての振る舞い・委譲の手順)と、それを支える仕組み(skills・hook・台帳)。`~` 直下や `~/.claude` などに置かれる、ただのテキストファイルとスクリプトなので、OS再インストールや別のMacへの引っ越しでは何もしなければ消える。このリポジトリを正本にして、`install.sh` 一発で復元する。

## 設計の原則

1. **repoが正本、liveは配備物。** 配備するものは全て [manifest.tsv](manifest.tsv) に1行ずつ書き、install・diff・reconcile は同じmanifestを見る。manifestに無いものは管理しない。
2. **同一階層に `CLAUDE.md` と `AGENTS.md` は各1つまで。** このリポジトリのルートの2つは、このrepoで作業するための小さな指示で、グローバル指示のスナップショットではない(スナップショットは `src/` に、自動で読み込まれない名前で置く)。
3. **マシン固有の事実は保存しない。** 導入状況・バージョン・認証・モデル一覧は `agents-probe.sh` が毎回各CLIから取得する(出力は6時間だけキャッシュ)。
4. **常時読み込む指示は最小に。** 手順は skills(必要なときだけ読み込まれる)、仕様と評判は台帳に置く。
5. **hookは「止める」より「気づかせる」。** 内部エラーは常に通す(fail-open)。拒否できるのは明示的な終了コード2だけで、解除は1回の質問、またはユーザーの次のプロンプト。

## 配備先(manifest.tsv)

| 配備先 | 方式 | 内容 |
| --- | --- | --- |
| `~/AGENTS.md` | copy | 共通ルール(`src/shared-rules.md`)。言語・普遍原則・司令塔プロトコル・知識の索引 |
| `~/.claude/AGENTS.md`、`~/.gemini/AGENTS.md`(agy導入時)、`~/.grok/AGENTS.md`(grok導入時)、`~/.codex/AGENTS.md`(codex導入時)、`~/.config/muse/AGENTS.md`(Muse導入時) | link | すべて `~/AGENTS.md` へのsymlink(同じファイルそのもの) |
| `~/.claude/CLAUDE.md` | copy | Claude専用の補足(`src/claude-user.md`)。先頭で `@AGENTS.md` をimport |
| `~/.codex/config.toml` の `developer_instructions` | merge-codex-persona | Codexのペルソナ(`src/codex-persona.md`)を、管理ブロックとして入れる。モデルに見える開発者メッセージへ**追加**されることを `codex debug prompt-input` で確認済み。他の設定は触らず、自分で `developer_instructions` を書いている場合は何も変更しない(`ERROR`) |
| `~/.knowledge/ai-agents.md` | seed | 台帳。最初だけ配置し、以降は live側が作業用の正本(`refresh-registry` が更新) |
| `~/.knowledge/bin/agents-probe.sh`、`agent-takeover.sh`、`memory-harvest.sh`、`ofuro-run.sh` | copy | 状況の取得、別エージェントへの引き継ぎ起動、エージェントのメモリの収穫対象の一覧(いずれも `agents.conf` を読む)、お風呂モードの非対話起動(`claude -p "/ofuro ..."`) |
| `~/.knowledge/rule-proposals.md` | seed | ルール提案の受け箱(最初だけ配置) |
| `~/.knowledge/gas-apps-script.md`、`writing-styles.md` | seed | 知識ファイル(GASの運用の知見、Slack・Notionの書き方の好み)。最初だけ配置し、以降は live 側が正本。公開リポジトリに載るので、社内のリポジトリ名・クライアント名・ID・人名は一般名・プレースホルダに置き換えてある(この Mac の live 側は元のまま) |
| `~/.agents/hooks/` | copydir | hookスクリプトと、エージェント固有の情報を集めた `agents.conf` |
| `~/.agents/skills/<name>`、`~/.claude/skills/<name>`(symlink) | copydir / link | `orchestrate-agents`・`ofuro`・`refresh-registry`・`propose-rule`・`triage-rules` |
| `~/.claude/settings.json`、`~/.codex/hooks.json`、`~/.config/muse/settings.json` | merge-hooks | 管理対象のhookエントリだけをマージ(他のキーは触らない)。Codex・Museは導入時のみ |
| `~/.claude/settings.json` の `permissions.defaultMode` と `skillOverrides`(14本) | merge-enforce | `/doctor` で決めた設定(自動モード、使わない同期skillの無効化)を**上書きで強制**する。手で変えた値は次のinstallで戻り、diffは `UPDATE` として報告する。断片に書いていないキー(自分で足した `skillOverrides` など)は触らない |
| `~/.claude/settings.json` の `autoMode.environment` | merge-union | 自動モードの分類器に、信頼するリポジトリ(`github.com/NoahBSakane/mactl`、公開)を教える。分類器は `autoMode` をユーザー単位(`~/.claude/settings.json`)からしか読まないので、プロジェクトの設定では置けず、ここから配備する。配列は和集合で足し(`$defaults` を含む)、ユーザーが足した項目は消さない |
| `~/.config/muse/settings.json` の `context` | merge-muse-context | Museの他エージェントのrules・skillsの自動取り込みを止める |
| `~/.gemini/config/hooks.json`、`~/.gemini/config/skills.json` | merge-agy-hooks / merge-agy-skills | agyの名前付きhook集合(`ai-agent-config`)と、共有skillsの絶対パス登録。agy導入時のみ |
| `~/.gemini/antigravity-cli/settings.json` | merge-union | agyの無人調査用の許可ルール(`permissions.allow` の `read_url(<ドメイン>)`。`src/agy-settings-allow.json`)。配列は和集合で足し、ユーザーが足した許可は消さない。agy導入時のみ |
| `~/.grok/skills/<name>` | link | Grok導入時のみ |
| `~/.claude/hooks/delegation/` | shims | 旧パスへの互換shim(1バージョン分) |

## 使い方

```bash
setup/ai-agent-config/diff-ai-agent-config.sh -b       # 全行の状態(OK/UPDATE/MISSING/DRIFT/ERROR/SKIP)と共通ルールの一致
setup/ai-agent-config/install.sh                         # 計画を表示 → 「実行しますか? [y/N]」
setup/ai-agent-config/install.sh -n                      # 計画だけ(dry-run)。-N は変更される内容の差分つき
setup/ai-agent-config/install.sh -y                      # 確認なしで実行(計画は出さず要約だけ)。-Y は計画と配備した行も出す
setup/ai-agent-config/install.sh -f                      # live側が編集されていても、退避してから上書き。-F は台帳(seed)も種へ戻す
setup/ai-agent-config/install.sh -o <ID>                 # manifestの1行(1つの配備物)だけ
setup/ai-agent-config/install.sh -l                      # 退避(配備履歴)の一覧
setup/ai-agent-config/install.sh -r [時刻]               # 元に戻す(確認あり。時刻を省くと最新)。-R は戻すと変わる差分も表示
setup/ai-agent-config/tests/hooks-test.sh                # hookの固定入力テスト
setup/ai-agent-config/tests/install-test.sh              # install/diff/rollbackの一時HOMEテスト
setup/ai-agent-config/tests/public-check-test.sh         # 公開前の検査のテスト
setup/ai-agent-config/tests/handoff-exclude-test.sh      # .agent-handoff/ の除外のテスト
(まとめて実行: mactl check。公開前の検査 public-check.py も走る)
```

**オプションの規則: 小文字は簡潔(出力は少なめ・対象は狭い)、大文字は詳細・徹底(出力は多め・対象は広い)。** `-n`/`-N`(計画のみ・差分つき)、`-y`/`-Y`(要約だけ・計画も表示)、`-f`/`-F`(DRIFTの上書き・台帳の種への巻き戻しも)、`-r`/`-R`(戻す・差分つき)。長いオプション(`--yes`、`--dry-run`、`--force`、`--rollback` など)も使える。短いオプションは束ねられる(`-fy`)。端末でない実行で `-y`/`-Y` が無いと、計画を表示するだけで実行しない。

- **日常の編集:** 配備された指示ファイル(`~/AGENTS.md` など)は、エージェントが直接編集できない(hookが拒否する)。ルールの追加・変更は、提案(`propose-rule`)→検討(`triage-rules`)→ リポジトリの `src/` を直して `install.sh`、の順に行う。あなた自身がliveを直接編集した場合は、`diff-ai-agent-config.sh` で差分を見て、`/reconcile-agent-config`([.claude/skills/reconcile-agent-config/](../.claude/skills/reconcile-agent-config/SKILL.md))で取り込む。
- **他のMacへ:** `git clone`(または `git pull`)して `setup/ai-agent-config/install.sh`。初回は既存のliveファイルが `DRIFT` になるので、`diff-ai-agent-config.sh` で内容を確認してから `install.sh -f`(退避先は `~/.agent-state/backups/`)。
- 共通ルールを直すときは `src/shared-rules.md` だけを直す(`install.sh` が `~/AGENTS.md` へ反映し、他のエージェントはそのsymlink経由で同じファイルを読む)。

## プロジェクトへの配置(`project` 行)と、個人用の manifest

プロジェクトごとの指示(`AGENTS.md`)や `.claude/settings.json` のように、「各プロジェクトの中」に置きたいファイルは、`project` 行で配ります。

- **行**: manifest の列は `id`・`mode`(= `project`)・`src`(配るファイル)・`dest`(= `<セレクタ>::<プロジェクト内のパス>`)・`cond`・`flags`(タブ区切り)。セレクタは `name=<フォルダ名のglob>`・`remote=<originのURLのglob>`・`all`(全プロジェクト)。
- **配る先(プロジェクト)**: プロジェクトルート直下の git リポジトリです。ルートは、環境変数 `AI_CONFIG_PROJECT_ROOTS`(`:` 区切り)、無ければ `~/.config/ai-agent-config/project-roots`(1行1パス)、それも無ければ `~/Repo`・`~/repos`・`~/src`・`~/code`・`~/dev`・`~/projects` と、その1階層下(例: `~/<組織>/Repo`)です。
- **動作**: 既定は `seed`(無いときだけ置く。プロジェクト側の編集は上書きしない)。`managed` を付けると `copy` と同じで、テンプレートと同一に保ち、編集されたものはドリフトとして報告します(`-f` で戻す)。行は、プロジェクトごとに `id@フォルダ名` の1行として展開されるので、状態表示・退避・巻き戻しは他の行と同じです。
- **個人用の manifest**: 社内のプロジェクト名や、プロジェクト固有の指示は、公開リポジトリに置けません。`~/.config/ai-agent-config/local-manifest.tsv`(同じ書式。相対パスの `src` は、そのファイルのあるフォルダ基準)に書くと、リポジトリの manifest に続けて処理されます。テンプレートは、その隣のフォルダ(例: `~/.config/ai-agent-config/tpl/`)に置きます。これで、各 Mac のエージェントが、その Mac のプロジェクトに合わせて内容を育てられます(`seed` なので上書きされません)。

## 公開リポジトリに載せてよいかの検査(`public-check.py`)

このリポジトリは公開です。社内・個人の固有名、ID、人名、秘密が入らないよう、機械で検査し、直し方の提案とローカルでの穴埋めだけ、使っているエージェントに任せます。

- **機械的な検査(常時)**: メールアドレス、Slack ID、UUID、`/Users/<名前>/` のパス、秘密・トークンを探します。`public-check.py`(全追跡ファイル)、`--diff A..B`(追加された行だけ)、`--pre-push`(git の pre-push の入力)。`setup-git-account.sh` が `.git/hooks/pre-push` に設置するので、**push 時に自動で走り**、見つかれば止まります(確認して問題なければ `git push --no-verify`)。hook はスクリプトの移動に備えて、場所を `git ls-files` で探し、見つからなければ通します。
- **自分用の語**: 社内名・クライアント名・同僚の名前など、リポジトリに書けない語は、`~/.config/ai-agent-config/public-denylist.txt`(1行1正規表現、非公開)に書きます。既知の安全なヒット(テストの偽のキーなど)は、`setup/ai-agent-config/public-check.allow`(`規則<TAB>パスのglob`)。
- **提案(エージェント)**: `--suggest` は、ヒットを `agents.conf` の `ask`(道具なし・書き込みなしの質問用テンプレート)で、導入済みのエージェントに渡し、置き換え案を表で出させます。ファイルは編集しません。**ヒットの周辺の文が外部のモデルに渡る**ので、自分で指示したときだけ動きます。
- **穴埋め(その Mac のエージェント)**: 公開用に一般化した知識ファイルには、`<自分のSlackユーザーID>` のようなプレースホルダが残ります。`--localise` が `~/.knowledge/*.md` の残りを一覧し、`--localise --agent` は、導入済みのエージェントを対話で起動して、この Mac で分かる値で埋めさせます(分からないものはあなたに質問する)。ローカルの知識ファイルなので、リポジトリには戻りません。

## hook(`src/hooks/`)

| スクリプト | 役割 |
| --- | --- |
| `gate.sh`(PreToolUse) | 編集・外部CLI実行・サブエージェント/Workflow起動の前に、エージェント構成の提示を求める。サブエージェント内(`agent_id`)、委譲先(`AGENT_DELEGATED_BY`)、お風呂モード中は通す。クラスごとに、同じプロンプト内の再試行は拒否を続け、AskUserQuestionの実行かユーザーの次のプロンプトで解除する。スクラッチ・tmp・`~/.agent-state`・memoryへの書き込みと、`--help`・`models` 等の読み取り系は対象外。**配備された指示ファイル(`~/AGENTS.md`、`~/.claude/CLAUDE.md`、`~/.codex/AGENTS.md` など。symlinkは解決して判定)の編集は、サブエージェント内・委譲先・お風呂モード中でも常に拒否し、`propose-rule` へ誘導する**(Bashでのリダイレクトによる書き換えは対象外) |
| `danger-guard.sh` / `danger_check.py`(PreToolUse) | **ホーム・ルート・システムのディレクトリや、Documents などの個人フォルダ全体を消す・壊すコマンドを拒否する**(`rm -rf ~`・`rm -rf /*`・`rm -rf $VAR/*`・`find ~ -delete`・`mv ~`・`chmod -R ~`・`git clean`(ホームで)・`dd of=/dev/disk*`・`diskutil erase*`・`rsync --delete` でホームへ、ほか)。`bash -c`・`eval`・ヒアドキュメント(シェルや python へ渡すもの)・`$(...)`(`echo`・`pwd`・`whoami` などの単純なものは値を求める)・代入した変数・`cd`/サブシェルで変わる作業ディレクトリ(`cd` が失敗した場合も含めて、あり得る場所すべて)・シンボリックリンク・波括弧・`~ユーザー`・大文字小文字(macOS の既定は区別しない)・行継続・`if/for/{ }` の中・`sudo`/`env`/`nice`/`timeout`/`npx` などの包みを解いて判定する。`find`・`ls` の結果を `xargs rm` や `while read` へ渡す形、`base64 -d \| sh` も見る。リダイレクト(`2>/dev/null`)は除いて判定し、`rm -rf ~/Downloads/*.dmg` や `find ~ -name .DS_Store -delete` のように絞り込んだものは通す。サブエージェント・委譲先・お風呂モードでも**解除されない**。全ツールに掛かり(matcher は全て)、入力に実行するコマンドの文字列(文字列でも配列でも)があれば検査する(Grok など、シェルの道具の名前が分からないものも含む)。範囲を狭めた削除(`rm -rf ~/project/build`)は通る。保護する場所は `~/.config/ai-agent-config/danger-paths.txt`(1行1パス)で足せる。**限界(最善の努力)**: 削除をスクリプトファイルの中でするもの(`bash clean.sh`)、シェルの別名・関数、実行時に作られるコマンド名は見えない。内部エラーのときは通す(他のhookと同じ) |
| `secret-scan.sh`(PreToolUse) | 外部CLIへ渡すコマンド・プロンプトに秘密情報(鍵・トークン等)があれば拒否 |
| `mark-asked.sh`(PostToolUse) | AskUserQuestionの実行を記録して解除 |
| `reminder.sh`(UserPromptSubmit) | 初回と10回ごとの委譲リマインド、**初回と3回ごとの状態行(`status-line.sh`)の指示**、毎回の短い範囲確認、通知の表示、`/ofuro` の開始・終了、**初回と5回ごとの「未処理の義務」の通知**と、自動調査ジョブの起動 |
| `obligations.sh` | 未処理の義務を1行ずつ出力する(台帳の確認が14日超、届いた台帳更新提案、未検討のルール提案、未収穫のメモリ)。リマインドとprobeが使う |
| `registry-job.sh` | 台帳が14日を超えると、**自動で**調査を起動する。読み取り専用のWeb調査を、`agent-run.sh` が使えるエージェントで実行し、提案レポートを `~/.agent-state/proposals/` に作る。1日1回まで・同時に1本・ジョブ内からは起動しない・調査できるエージェントが無ければ起動しない |
| `status-line.sh` | 他のエージェントの状況を1行にする(導入済みのものだけ。使用上限中は解除日時を秒まで)。`reminder.sh` が最初のプロンプトと3回に1回、「この行を応答の末尾に添える」指示として渡す(agy は `UserPromptSubmit` 相当が無いので、`agy-adapter.sh` が `PreInvocation` の `invocationNum` が0のとき(ターンの先頭)を数えて、同じ指示を注入する) |
| `handoff-exclude.sh` / `handoff-exclude-hook.sh` | `.agent-handoff/`(引き継ぎ記録)をGitに入れないよう、`.git/info/exclude` へ自動で追記する(worktree・サブディレクトリ対応、重複しない)。編集ツールが書いた直後と、プロンプトごとに実行する |
| `doctor.sh`(リポジトリ直下の `setup/ai-agent-config/`) | 前提のツール(必須: jq・python3 3.8+・git・SHA-256・awk・sed・find、任意: gh・node)の点検と、足りないものの入れ方の案内。`install.sh` が最初に `--required` で呼び、足りなければ止める |
| `fmt-epoch.sh` | 時刻の表示形式を1つにそろえる(`2026-10-10(Sat)11:42:34+09:00`。Asia/Tokyo固定・英語3文字の曜日・コロン付きオフセット)。使用上限の復帰時刻(probe・状態行・通知)と `/ofuro` の終了時刻に使う |
| `limit-check.sh` | 使用上限が早く解除されていないかの定期確認。記録がある(使えないとされている)エージェントに、`agents.conf` の `ping`(最小の実呼び出し)を、30分に1回まで行う。通れば記録を外して通知し、新しい解除時刻が分かれば記録を動かす。`reminder.sh` がプロンプトごとにバックグラウンドで起動する |
| `agy-job-guard.sh` | agy の調査ジョブ専用のPreToolUse hook(`AGENT_JOB` があるときだけ有効。失敗時は拒否側)。Web検索とページ取得以外の全ツールと、内部アドレス・認証情報つき・秘密らしき文字列を含むURLを拒否する。これにより、agy の調査を `--dangerously-skip-permissions` で動かしても読み取り専用になる |
| `limit-reset.py` | エラー文から使用上限の解除時刻(ISO・`Oct 10th, 2026 11:42 AM`・`try again at 11:42 AM`・`in 2 hours`・epoch)を読む |
| `md-lint.sh` / `md-lint.py` | PostToolUse。編集された `.md` を markdownlint で検査し、指摘をエージェントへ返す(MD013は日本語を含む行に適用しない。設定の無いプロジェクトでは `markdownlint.json`)。Claude・Codex・Muse は PostToolUse の stderr(終了コード2)で返す。agy の PostToolUse は `{}` しか返せないため、`agy-adapter.sh` が指摘をセッションに保管し、次の `PreInvocation` hook が `ephemeralMessage` として注入する |
| `agent-run.sh` | 汎用のヘッドレス実行。`agents.conf` の順に、未導入・未認証・使用上限中のエージェントを飛ばして試し、使用上限の失敗を検知したら、エラー文が示す解除時刻(`limit-reset.py`が読む。読めなければ6時間後)までそのエージェントを「使えない」と記録して、次のエージェントへ回す |
| `agents.conf` / `agentconf.py` | エージェント固有の情報(下記) |
| `ofuro-guard.sh` | お風呂モード中の質問拒否と、Stop時の継続(上限回数と進捗なし判定で、無限に続かない) |
| `logger.sh`(PostToolUse) | 外部CLI起動とサブエージェントの監査ログ(`~/.agent-state/delegation-log.jsonl`、1MBで回転) |
| `status.sh` | 委譲実績の集計 |

コマンド文字列の判定と、指示ファイルの判定(realpath)は `parse_cmd.py` が行う(コマンドは構文解析し、引用符内・heredoc本文・`echo "codex exec"` は対象外)。拒否は **終了コード2 + stderrに理由** で、Claude Code・Codex・Grok(公式)とMuse(第三者報告)で共通。

## エージェント固有の情報は `agents.conf` に集める

スクリプトは、特定のエージェントの名前を持たない。どのCLIがあり、どう呼び、どのツール名がシェル・編集を意味し、メモリがどこにあるかは、すべて `src/hooks/agents.conf`(配備先は `~/.agents/hooks/agents.conf`)に書く。

| キー | 使う側 |
| --- | --- |
| `bin`、`version`、`auth`、`models` | `agents-probe.sh`(導入・認証・モデル) |
| `shell_tools`、`edit_tools`、`subagent_tools`、`readonly_subagents` | `gate.sh`・`secret-scan.sh`・`logger.sh`(hookのツール名の対応) |
| `exec_sub`、`exec_flag`、`nonexec_sub` | `parse_cmd.py`(他のエージェントCLIの実行の判定) |
| `memory` | `memory-harvest.sh`(メモリの収穫) |
| `research` | `agent-run.sh`(読み取り専用のWeb調査。台帳の自動調査) |
| `interactive` | `agent-takeover.sh`(別エージェントの起動) |
| `[runtime]` の `order`、`costly_models` | ヘッドレス実行の順序、お風呂モードで許可が要るモデル |

**エージェントを足す・乗り換える手順:** `agents.conf` に節を足し(または消し)、台帳(`ai-agents.md`)に人間向けの節を足し、設定ファイルを配備する行を `manifest.tsv` に足す。スクリプトは変えない。エージェント固有のコードは、そのエージェントの癖を吸収するアダプタ(`agy-adapter.sh`、`muse-adapter.sh`)だけに閉じ込めてある。

## お風呂モード(`/ofuro [時間] [任務]`)

離席中に自動で進めるモード。時間を指定しなければ2時間。状態はセッション単位(`~/.agent-state/ofuro/<session>.json`)。質問はせず、判断は `~/.agent-state/ofuro-journal.md` に記録し、終了時にレポート(完了/未完/保留/判断ログの要点)を書く。止まるのは、認証情報の漏洩・侵害の兆候・第三者への即時被害の場合だけ。Opus/Fableは、呼び出し時に指示があった場合だけ使う。詳細は `ofuro` skill。

## 台帳と更新

`~/.knowledge/ai-agents.md` は、各エージェントのスペック(コマンド・フラグ・指示ファイル/skills/hookの置き場)と、根拠格付き(A=独立ベンチ/B=第三者/C=公式の機能記述/D=根拠なし)・出典・日付付きの適切用途、代行先の優先順位だけを持つ。更新は、**待たずに自動で**進む。

1. `agents-probe.sh --check` が、台帳が記載するフラグの実在を検査する(消えれば通知)。
2. 確認日が14日を超えると、リマインド(初回と5回ごと)が「未処理の義務」として知らせ続け、同時に `registry-job.sh` が**自動で調査ジョブを起動**する。ジョブは `agent-run.sh` が、`agents.conf` の順(今は Claude → Codex → Muse)で、使えるエージェントに回す。あるエージェントが落ちている・使用上限・未ログインなら、**次のエージェントへ回る**。提案レポートが `~/.agent-state/proposals/` に届き(どのエージェントが調査したかも記録される)、通知が出る。
3. 届いた提案は、`refresh-registry` skill が検証して台帳へ反映する(適切用途は自動で反映してよい。コマンド・フラグ・承認方式の変更は、根拠を示してユーザーに確認する)。反映が終わるまで、義務の通知は続く。作業は止めない。

## ルール提案(指示ファイルへの追加・変更)

エージェントが指示ファイルを直接編集することは、hookが拒否する。ルールを足したいときは、次の流れにする。

1. **提案:** `propose-rule` skill が、`~/.knowledge/rule-proposals.md` に追記する(動機・想定範囲つき)。共通ルールが全エージェントへ指示している(Claude・Codex・agy・Museは、共通ルールがsymlink経由で届く)。
2. **収穫:** エージェントのメモリから、ふるまいに関わる好み・訂正を拾って提案にする。`memory-harvest.sh` が、`agents.conf` の `memory` に書かれた場所から、新しい・変わったメモリファイルを一覧する。場所は、Claude(`~/.claude/projects/*/memory/`)とCodex(`~/.codex/memories/`)は確認済み。agyは永続メモリを持たない(会話の記録のみ)。MuseとGrokはメモリ機能があるが、保存先が公式に公開されておらず、まだ作られてもいないので、候補の場所を登録してある(作られれば自動で拾う)。
3. **検討:** 未検討の提案が1件でもあると、リマインドが知らせる。`triage-rules` skill が、全体(`shared-rules.md`)・Claude固有・Codex固有・プロジェクト・知識・却下に振り分け、衝突を確認し、**ユーザーの承認を得て**、リポジトリの `src/` へ反映して `install.sh` で配備する。

## 各エージェントが読むもの

| エージェント | グローバルな指示 | skills | hook(配線済み) |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/CLAUDE.md`(`@AGENTS.md` をimport。**CLAUDE.mdがあるとAGENTS.mdは読まれない**。無い場合に限りv2.1.277以降が直接読む) | `~/.claude/skills`(symlink可) | settings.json(全機能) |
| Codex | `~/.codex/AGENTS.md`(`~/AGENTS.md` へのsymlink。importなし)。ペルソナは `config.toml` の `developer_instructions`(管理ブロック) | `~/.agents/skills` | `~/.codex/hooks.json`。**新規・変更されたhookは `codex` の `/hooks` で人が信頼するまでスキップされる**(1回の手作業) |
| agy | `~/.gemini/AGENTS.md` ほか(**実機確認済み**。プロジェクト側はcwdからrepo rootまで遡る) | `~/.gemini/config/skills.json` に**絶対パス**で `~/.agents/skills` を登録(**実機確認済み**) | `~/.gemini/config/hooks.json`(**実機確認済み**。`adapter` 経由) |
| Muse | `~/.config/muse/AGENTS.md`(専用。`~/AGENTS.md` へのsymlink)。他エージェントの個人rules(`~/.claude/CLAUDE.md`、無ければ `~/.codex/AGENTS.md` の**どちらか1つ**。`@AGENTS.md` は解決されない)の自動取り込みは、`settings.json` の `context.foreign_personal_rules=false` で止めている(**実機確認済み**) | `~/.agents/skills`(他エージェントのskillsの自動取り込みも `context.foreign_personal_skills=false` で止めている) | `~/.config/muse/settings.json` の `hooks`(`UserPromptSubmit` は実機確認済み)。hookには環境変数が渡らないため、ゲートは `muse-adapter.sh` 経由で、`permission_mode` が `bypassPermissions`/`dontAsk` の無人実行を委譲先とみなす |
| Grok | `~/.grok/` | `~/.grok/skills`(symlink。未導入のため未検証) | Claudeのsettings.jsonのhookを読む(未導入のため未検証) |

hookの機能差: Claude Code は全機能。Codex は、`apply_patch` と `Bash` のゲート・秘密スキャン・ログ・お風呂モードのStop継続・リマインド。agy は、`run_command` と `write_to_file` 系のゲート・秘密スキャン・ログ・Stop継続で、リマインド(`UserPromptSubmit` 相当)が無いため `/ofuro` の開始はhookでは行えない。Muse は、ツール名が未確認のため、ゲート等は名前が合ったときだけ働く(合わなければ通す)。

## 制約と未検証

- **agyのゲートは、非対話の `--dangerously-skip-permissions` 実行では止まらない。** 決定が `ask` で、そのフラグでは自動承認されるため(対話のagyでは、ネイティブの承認プロンプトが出る)。agyにはユーザーのプロンプト単位の目印が無く、`deny` にすると解除できずに詰まるので `ask` にしている。
- **Codexのペルソナ(`developer_instructions`)の効き方は、使用上限が明けるまで実機で確認できない。** モデルに見えるプロンプトに入ることは `codex debug prompt-input` で確認済み(開発者メッセージへの追加)。
- **指示ファイルの直接編集の拒否は、エディタ系のツール呼び出しが対象。** `Bash` のリダイレクト(`>`、`sed -i` など)による書き換えは対象外(検出は `diff-ai-agent-config.sh` の `DRIFT`)。
- **Codexのhookは、人が `/hooks` で信頼するまで動かない。** 信頼はhookの内容のハッシュに紐付く。ペイロードの `UserPromptSubmit` は実機で確認したが、`Bash` / `apply_patch` のツール名は公式文書に基づく(確認時、Codexが使用上限に達しており、モデル呼び出しを伴う実機テストができなかった)。
- Museの `PreToolUse` の入力と拒否の挙動は未検証(未ログイン)。`UserPromptSubmit` はユーザー設定からの発火を実機で確認済み。
- Grokは未導入のため、skillsのsymlinkとhookの共有は未検証。
- Claude の Cowork セッション(ユーザー向けの共同作業モード)では、ユーザースコープの `@AGENTS.md` のimportがworkspace外のパスとして無視される。
- 使用上限の自動待機が `claude -p`(非対話)で効くかは、公式文書に記載が無い。probeは各CLIの残枠を取得できないため、使用上限を検知した司令塔が `~/.agent-state/unavailable/<agent>.txt` に記録する(期限まで `limit` と表示される)。
- 実行中のセッションがsettings.jsonのhook変更をいつ取り込むかはツール次第。新しいセッションから確実に有効になる。

## 共通ルールの一致の保証

共通ルールは、複数の経路で読まれる(Claude Codeのimport、各エージェントのグローバルrules、祖先ディレクトリ)。**どの経路も、`~/AGENTS.md` というただ1つのファイルを指す**ので、内容が分かれる余地が構造上ない。

- `~/.claude/AGENTS.md`、`~/.gemini/AGENTS.md`、`~/.codex/AGENTS.md`、`~/.config/muse/AGENTS.md`、`~/.grok/AGENTS.md`(いずれも導入時)は、`~/AGENTS.md` へのsymlink。Museがsymlinkを読むことは実機で確認済み。Codexのペルソナは、別の仕組み(`developer_instructions`)で渡すので、AGENTS.mdを共有できる。
- `~/AGENTS.md`(実体)は `src/shared-rules.md` のコピー。
- `diff-ai-agent-config.sh` が、これらを毎回検査して「共通ルールの一致: OK / NG」を出し、NG なら終了コードが 1 になる。`install.sh -f` で直る。

## 管理しないもの

各エージェントが自動で溜めるメモリ(`~/.codex/memories`、`~/.claude/projects/*/memory` など)は、マシン固有で、個人の作業内容を含み、エージェント自身が更新する生成物なので、manifestでは管理しない。指示と食い違う記述が無いかを、時々確認するだけにする(`~/.codex/memories` は2026-10-07に確認済みで、Slack用絵文字の制作メモだけだった)。

## 注意

- `install.sh` は、前回のinstall以降にliveが編集されていると中止する(`-f` で退避してから上書き)。
- 設定文面にマシン固有の事実(利用プランなど)を書かない。台帳が持つのは、変わらない仕様と、日付付きの評価だけ。
