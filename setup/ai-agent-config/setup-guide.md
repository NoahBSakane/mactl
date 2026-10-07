# 導入手順

AIコーディングエージェントの共通設定(指示ファイル・skills・hook・台帳)を、新しいMacや別ユーザーアカウントへ導入する手順です。設計と運用の詳細は [ai-agent-config.md](ai-agent-config.md)、導入後に残る作業は [remaining-work.md](remaining-work.md) を参照してください。

## 前提

- macOS で、`bash`、`git`、`jq`、`python3`、`rsync` が使えること。`jq` が無ければ `brew install jq` で入れます。
- 各エージェントのCLI(Claude Code、Codex、Antigravity の `agy`、Muse Code、Grok Build)は、入っているものだけが対象です。入っていないものの配備は自動でスキップされ、後から導入して `install.sh` を再実行すれば追加されます。
- 配備先はすべて `$HOME` 基準です。ユーザー名には依存しません。

## 手順1: リポジトリを取得する

```bash
git clone https://github.com/NoahBSakane/mactl.git ~/Repo/mactl
cd ~/Repo/mactl/setup/ai-agent-config
```

すでに取得済みなら `git pull` で最新にします。

## 手順2: 配備前に状態を確認する

```bash
./diff-ai-agent-config.sh -b
./install.sh -n
```

各行の状態は次のとおりです。

- `OK`: すでに一致している。
- `MISSING`: まだ配備されていない。
- `UPDATE`: リポジトリが新しい。前回の配備から live 側は変更されていないので、そのまま更新できる。
- `DRIFT`: live 側が、前回の配備後に(または配備前から)リポジトリと違う内容になっている。
- `SKIP`: 対象のCLIが入っていないので、配備しない。

## 手順3: 配備する

```bash
./install.sh
```

何も付けずに実行すると、計画(各行が何をするか)を表示し、「実行しますか? [y/N]」と確認します。`y` で配備し、それ以外では何も変更せずに終わります。

| オプション | 動作 |
| --- | --- |
| `-n` / `-N` | 計画だけ表示して終了(`-N` は変更される内容の差分つき) |
| `-y` / `-Y` | 確認なしで実行(`-y` は要約だけ、`-Y` は計画と配備した行も表示) |
| `-f` / `-F` | live側が編集されているファイルも、退避してから上書き(`-F` は台帳も種へ戻す) |
| `-r` / `-R` | 配備を元に戻す(`-R` は戻すと変わる差分も表示) |

規則は「小文字は簡潔、大文字は詳細・徹底」です。

端末でない実行(パイプやcronなど)で `-y`/`-Y` が無いと、計画を表示するだけで実行しません。

`DRIFT` の行があると、何も変更せずに中止します。まっさらなMacなら、初回は `MISSING`(未配備)になるだけで、そのまま配備できます。すでに指示ファイルがあるMacでは、初回は `DRIFT` になるのが普通です。その場合は、次の順に進めてください。

1. `./diff-ai-agent-config.sh` で、差分(失われる内容)を確認する。
2. そのMacの指示ファイルに、残したい内容があれば、先にリポジトリ側へ反映する(まだ何も配備していないMacでは、手で `src/` に書き写すか、いったん配備したあとで Claude Code に `/reconcile-agent-config` を頼む)。
3. 内容を確認済みなら、`./install.sh -f` で上書きする。

上書きする前の内容は、毎回 `~/.agent-state/backups/<時刻>/` に退避されます。

## 手順4: 配備を確認する

```bash
~/.knowledge/bin/agents-probe.sh --fresh --check
./diff-ai-agent-config.sh -b
./tests/hooks-test.sh
./tests/install-test.sh
./tests/public-check-test.sh
./tests/handoff-exclude-test.sh
```

期待する結果は次のとおりです。

- probe が、導入済みのエージェントを `ready` で表示する。
- diff の終了コードが 0 で、`DRIFT` や `MISSING` が無い。
- 2つのテストが、`failed=0` で終わる。

## 手順5: エージェントごとの手作業

自動化できず、人が1回だけ行う作業です。

### Claude Code

- 配備すると、`~/.claude/settings.json` の `permissions.defaultMode`(自動モード `auto`)と `skillOverrides`(使わない同期skillの無効化)が、リポジトリの値で**上書きされる**。手で変えた値は、次の `install.sh` で戻る(`diff-ai-agent-config.sh` は `UPDATE` と報告する)。変えたい場合は `src/claude-settings-enforced.json` を直す。他のキーは触らない。
- 使用上限の自動再開は、設定 `autoContinueAtUsageLimit`(既定で有効)です。`/config` に「Continue automatically at usage limit」の行が出る環境と出ない環境があります(出ない環境があることを確認済み)。出ない環境では、設定を足さずに既定に任せ、待てないときは `~/.agents/skills/orchestrate-agents/references/failover.md` に従います。
- 新しいセッションを開く。実行中のセッションは起動時の指示を保持しているため、新しい指示とhookは新しいセッションから確実に有効になります。
- 離席中に自動で進めるお風呂モード(`/ofuro`)を使う前に、権限モードを auto にする(`Shift+Tab`)。

### Codex

- `codex` を起動し、`/hooks` で、管理対象のhook(`~/.agents/hooks/` 配下を指すもの)を信頼する。信頼するまで、Codex ではhookが動きません。hookの定義が変わると、再度の信頼が必要になります。

### Antigravity(agy)

- 手作業は不要です。次のコマンドで、共有skillsが見えることを確認できます。

```bash
agy -p "あなたが使えるskillの名前を列挙して" --model gemini-3.8-flash-low
```

### Muse Code

- 使う場合だけ、`muse login` を実行する(または環境変数 `META_API_KEY` を設定する)。ログインのときに契約プランの選択を求められる可能性があるため、画面の案内を確認してから進めてください。
- Muse は、他のエージェントの個人rules(`~/.claude/CLAUDE.md`、無ければ `~/.codex/AGENTS.md`)を自動で取り込みますが、`@AGENTS.md` の import は解決しません。そのため `install.sh` は、この自動取り込みを設定で止め、Muse専用のrules(`~/.config/muse/AGENTS.md`)に共通ルールを置きます。

### Grok Build

- 導入したら、`./install.sh` を再実行する。`~/.grok/AGENTS.md` と共有skillsのsymlinkが追加されます。

## 日常の運用

- **ルールを足す・変える:** エージェントは、配備された指示ファイルを直接編集できません(hookが拒否します)。エージェントが `propose-rule` skill で提案を `~/.knowledge/rule-proposals.md` に溜め、リマインドが知らせたら、`triage-rules` skill(エージェントに「提案を検討して」と頼む)で検討して、承認した内容を `src/` に反映します。
- **指示ファイルを直す:** 共通ルールは `src/shared-rules.md` だけを直し、`./install.sh` で `~/AGENTS.md` へ反映する(他のエージェントは、そのsymlink経由で同じファイルを読む)。live 側を直接編集した場合は、`/reconcile-agent-config` でリポジトリへ取り込む。
- **台帳を更新する:** probe が「確認が14日を超えた」と知らせたら、区切りの良いところで `refresh-registry` skill を実行する。
- **離席する:** `/ofuro [時間] [任務]`。時間を指定しなければ2時間。戻ったら、`~/.agent-state/ofuro-report-*.md` のレポートを確認する。
- **Claude Code が使えなくなった:** `~/.knowledge/bin/agent-takeover.sh codex|agy|muse [作業ディレクトリ]` で、別のエージェントに引き継ぐ。事前に `.agent-handoff/STATE.md` を更新しておく。

## 元に戻す

```bash
./install.sh -l
./install.sh -r <時刻>
./install.sh -r
```

`-r` は最新の配備を、`-r <時刻>` は指定した配備を戻します(`-R` は差分も表示。どれも確認あり。`-y` で確認なし、`-n` で計画だけ)。設定ファイル(`settings.json` など)は、管理対象のhookだけを外します。配備後にあなたが変更した他の設定は残ります。

## トラブルシュート

| 症状 | 確認すること |
| --- | --- |
| `install.sh` が「DRIFT のため中止」と出る | `./diff-ai-agent-config.sh` で差分を確認する。内容に問題が無ければ `-f` |
| 編集や外部CLIの実行が「構成の事前承認」で止まる | 設計どおりの動作。質問UIで構成を提示して承認を取るか、ユーザーの次のプロンプトで解除される |
| Codex で hook が動かない | `/hooks` で信頼したか確認する |
| agy で skills が見えない | `~/.gemini/config/skills.json` が絶対パスで登録されているか確認する |
| probe が `limit` と表示する | 使用上限の期間中。`~/.agent-state/unavailable/<agent>.txt` の期限が過ぎると戻る |
| hook が誤って止める | `~/.agent-state/` を確認する。hook自体の不具合なら、`./install.sh -r` で戻して報告する |

## このリポジトリを自分で編集して push する場合

- 別のアカウント(フォークなど)で運用するなら、`./setup-git-account.sh <あなたのアカウント>` を実行する。`origin` のURLと、その `gh` アカウントのトークンを使う認証、公開前の検査(push 時の hook)を、このクローンだけに設定する。未ログインなら、端末で `gh auth login -h github.com -p https -w`。
- 社内名・人名など、公開リポジトリに書けない語は、`~/.config/ai-agent-config/public-denylist.txt`(非公開)に書くと、push 前の検査が止める。

## 前提のツールの点検

配備の前に `./doctor.sh` を実行すると、必須のツール(`jq`・`python3` 3.8以上・`git` ほか)と、任意のツール(`gh`・`node`)の有無が分かり、足りないものには入れ方(`brew install ...`)が出ます。`install.sh` も、最初に必須のツールだけを自動で確かめ、足りなければ何が足りないかを示して止まります。`python3` が無いと、hook が何も言わずに働かなくなるので、必須にしています。

## 用語

この文書と、関連する文書に出てくる言葉です。

| 言葉 | 意味 |
| --- | --- |
| live側 | このMacの実際の場所(`~/AGENTS.md` など)に置かれて、エージェントが読んでいるファイル。対して「リポジトリ側」は、この git の中の `src/` |
| 種(seed) | 最初の1回だけ置かれるファイル。あとは live 側が正本で、使いながら育てる(`install.sh` は上書きしない) |
| ドリフト(`DRIFT`) | live 側が、前回の配備のあとに(または配備前から)リポジトリと違う内容になっていること |
| hook | エージェントが何かをする直前・直後に動く小さなスクリプト。許可の確認や記録をする |
| ゲート | hook のうち、構成の承認が済むまで編集や別エージェントの起動を止めるもの |
| 配線 | エージェントの設定に hook やリンクを登録して、実際に動く状態にすること |
| probe(`agents-probe.sh`) | どのエージェントが導入・認証済みで使えるかを、その場で調べるスクリプト |
| 台帳(`~/.knowledge/ai-agents.md`) | 各エージェントの仕様と、用途ごとの評価(格付けA〜D: A=独立したベンチマーク、B〜C=公式・ベンダーの情報、D=根拠なし)をまとめた文書 |
| お風呂モード(`/ofuro`) | 離席中に、質問せず推奨案で作業を進めるモード |
| skill | エージェントが手順どおりに使う、指示の束(`propose-rule` など)。あなたは「提案しておいて」のように頼むだけでよい |
