# Claude Code / Codex CLIの指示ファイルを他Macへ複製する

このMac(nbsさんの環境)の設定。プロジェクトのコードとは無関係。

## 何のためのものか

Claude Code / Codex CLIには、モデル選択方針・外部CLI(Codex/Gemini CLI)への委譲ルール・応答スタイルのペルソナなど、このMacで積み上げてきた個人設定が入っている。これらは`~`直下や`~/.claude`・`~/.codex`に置かれたただのテキストファイルなので、OS再インストールや別のMacへの引っ越しでは何もしなければ消える。このリポジトリにスナップショットとして置いておき、`install.sh`一発で復元できるようにしてある。

## 構成

```
~/AGENTS.md              ← 共通ルールの実体(Claude Code/Codex CLI両方が守る、ツール非依存のルールのみ)
~/.claude/AGENTS.md      ← ~/AGENTS.md へのsymlink。Claude Codeは`AGENTS.md`というファイル名自体を
                            認識しないため、`~/.claude/CLAUDE.md`の1行目`@AGENTS.md`でこれをimportして
                            読ませている(importはimportする側のファイルと同じディレクトリを基準に解決される
                            ため、`~/.claude/CLAUDE.md`から見た`@AGENTS.md`はこのsymlinkを指す)
~/.claude/CLAUDE.md      ← Claude Code専用の指示(`@AGENTS.md`で上記をimportしつつ、Claude専用の内容を追記)
~/.codex/AGENTS.md       ← Codex CLI専用の実ファイル。Codexのグローバル指示は`$CODEX_HOME`(=~/.codex)
                            直下の`AGENTS.md`固定で、`~/AGENTS.md`という場所自体を知らずimportもできない
                            ため、共通ルールをここに手動で転記してある。加えて応答スタイルのペルソナなど
                            Codex固有の指示も含む。
```

`~/AGENTS.md`自身の末尾にもこの関係性の説明が書いてある。

なお、CodexとAntigravity CLI(`agy`)はどちらも、作業中のリポジトリのgitルートから作業ディレクトリまでを遡って`AGENTS.md`(agyは`GEMINI.md`も)を自動検出・連結する仕組みを持つ。つまりこの`mactl`リポジトリで作業している間は、Codexは上の`~/.codex/AGENTS.md`(グローバル)とリポジトリ直下の`AGENTS.md`(プロジェクトスコープとして自動検出)の両方を読んでおり、`~/.codex/AGENTS.md`への手動転記が意味を持つのは、あくまでmactlの外・他プロジェクトで作業する時だけになる。agyも同じ自動検出は持つが、Skills/Plugins/MCPと違ってRules(`AGENTS.md`/`GEMINI.md`)にはグローバルスコープという概念自体が無く、`~/AGENTS.md`を持たせても他プロジェクトからは参照されない。共通ルールの対象を「Claude Code / Codex CLI」の2つに絞っているのはこのため。

## 設置先とコード

```
mactl/
  AGENTS.md                    → 設置先: ~/AGENTS.md(repo直下にある理由はルートのREADMEを参照)
  CLAUDE.md                    → 設置先: ~/.claude/CLAUDE.md(同上)
  setup/ai-agent-config/
    ai-agent-config.md         → このファイル
    codex-AGENTS.md            → 設置先: ~/.codex/AGENTS.md
    install.sh                 → 上記3つの配置(+ ~/.claude/AGENTS.mdのsymlink作成)と、下記hook
                                  スクリプトの配置・~/.claude/settings.jsonへのマージを1本で行う
                                  インストーラ(AGENTS.md/CLAUDE.mdは二つ上の階層=repo直下から読む)
    diff-ai-agent-config.sh    → repo側とlive側、3組それぞれの機械的diffを取るだけのスクリプト
```

## 使い方

### このMac上で最新化する(生きているファイル → リポジトリ)

普段の編集はClaude Code/Codexとの対話中に`~/.claude/CLAUDE.md`等を直接書き換える形で行われる。このリポジトリ側のファイルは自動追従しないので、他Macへ配る前に必ず最新を取り込む:

```bash
cd mactl
cp ~/AGENTS.md ./AGENTS.md
cp ~/.claude/CLAUDE.md ./CLAUDE.md
cp ~/.codex/AGENTS.md ./setup/ai-agent-config/codex-AGENTS.md
```

これは単純な上書きコピーなので、repo側にしか無い変更(他Macで直接編集した等)を吹き飛ばす可能性がある。食い違いがないか先に確認したい・あるいはどちらか一方を採用するか統合するか判断したい場合は、`/reconcile-agent-config`スキル([.claude/skills/reconcile-agent-config/](../../.claude/skills/reconcile-agent-config/SKILL.md))を使う。

### 他Macへ持っていく(リポジトリ → 生きているファイル)

1. `git clone`(または既存クローンなら`git pull`)で他Macへこの`mactl`リポジトリを持ってくる
2. 転送先で`mactl/setup/ai-agent-config/install.sh`を実行する。これ1本で指示ファイルの配置と委譲hookの設置の両方を行う

## 注意点

- installスクリプトは既存ファイルを**バックアップなしで上書き**する。他Mac側で個別カスタムを既に加えている場合は、上書き前にそちらを先に確認・退避すること(迷ったら`/reconcile-agent-config`で差分を見てから判断する)。
- `~/AGENTS.md`と`~/.codex/AGENTS.md`は内容が一部重複しているが別ファイル。CodexはグローバルスコープとしてCODEX_HOME直下の`AGENTS.md`しか見ず`~/AGENTS.md`という場所自体を認識しないため、共通ルールを変えたら両方に手で反映する。
- 設定文面はマシン固有の事実(利用プランの有無など)をベタ書きしないようにしてある。例えばGemini CLI(Antigravity CLI `agy`)まわりの記述は「無料枠のMacもあればWorkspace等の有償プランのMacもある」という前提で、どちらでも矛盾なく通じる書き方にしてある。新しく機種固有の事情を追記するときも、特定の1台にしか当てはまらない断定は避けること。

## エージェント委譲ルール遵守hook

Claude CodeがCLAUDE.mdの「エージェント構成の事前承認」を見落とさないよう、毎ターンのリマインド、セッション最初の編集時に一度だけ止めるspeed bump、外部CLI・サブエージェントの委譲監査ログを追加する。構成選択の意味判断や承認そのものを自動化するものではない。

構成ファイルは以下の通りである。

- `hooks/hooks-fragment.json`: `~/.claude/settings.json`へマージするhook定義
- `hooks/user-prompt-delegation-reminder.sh`: `UserPromptSubmit`で構成検討を促す
- `hooks/pre-edit-composition-check.sh`: 最初の`Write`・`Edit`系呼び出しだけをdenyする
- `hooks/post-tool-delegation-logger.sh`: 外部CLIと`Agent`・`Task`呼び出しを`~/.claude/delegation-hooks/delegation-log.jsonl`へ追記する
- `hooks/delegation-status.sh`: 過去24時間または指定セッションの委譲実績を集計する

設置は`install.sh`(指示ファイル側とまとめて1本で実行)が行う。`delegation-status.sh`は引数なしで過去24時間、セッションIDを渡すとそのセッション全期間を表示する。

```bash
~/.claude/hooks/delegation/delegation-status.sh
~/.claude/hooks/delegation/delegation-status.sh SESSION_ID
```

`install.sh`は指示ファイル3つ(AGENTS.md/CLAUDE.md/codex-AGENTS.md)は単純上書きするが、settings.jsonは他の個人設定と同居しているファイルなので、`hooks`キーだけをマージする(既存キーは保持)。同じhookは再実行時に重複追加せず、既存settings.jsonがある場合は同じディレクトリへ`settings.json.bak.<timestamp>`を作成してから、一時ファイルのJSON検証を通った内容だけを反映する。テスト時は`HOME`を一時ディレクトリへ差し替えられる。
