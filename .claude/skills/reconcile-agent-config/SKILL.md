---
name: reconcile-agent-config
description: mactlリポジトリ専用。manifest.tsv が管理する配備物(~/AGENTS.md、~/.claude/CLAUDE.md、~/.codex/AGENTS.md、台帳、skills、hook、settings.jsonのhook設定など)について、このMac上のlive側とrepo側(setup/ai-agent-config/src/)の食い違いを調べ、どちらを採用するか、両方の変更を1本に統合(止揚)するかを判断して両側に反映する。install.shが「DRIFTのため中止」と出した時にも使う。
---

# reconcile-agent-config

`mactl` リポジトリ専用。対象は `setup/ai-agent-config/manifest.tsv` の全行。manifestに無いものは管理対象外。

## 前提(事実)

- repo側が正本(`setup/ai-agent-config/src/`)。live側は配備物。ただし日常の編集は、エージェントとの対話中にlive側(`~/.claude/CLAUDE.md` 等)を直接書き換えて行われがちなので、食い違いは起こる。
- **台帳(`registry` 行)だけは live側(`~/.knowledge/ai-agents.md`)が作業用の正本。** `refresh-registry` skill が自動で更新するので、live側を採用してrepoへ取り込むのが基本(repo側は初期配備用の種)。
- 行の方式(`copy`・`seed`・`link`・`copydir`・`merge-*`・`shims`)の定義は、`setup/ai-agent-config/manifest.tsv` 冒頭のコメントが正本。
- 事実の訂正済み事項(古い記述を見つけたら直す): ClaudeCodeは、CLAUDE.mdが無いときに限り AGENTS.md を直接読むので、CLAUDE.mdがある環境では `@AGENTS.md` のimportが必要。agyにも `~/.gemini/AGENTS.md` のグローバルrulesがある(実機確認済み)。

## 手順

1. `setup/ai-agent-config/diff-ai-agent-config.sh` を実行する(判断はせず、全行の状態と差分を出す)。終了コード0なら全行一致で、以降は不要。
   - `OK` 一致 / `MISSING` 未配備 / `UPDATE` repoが新しい(liveは前回installのまま。そのままinstallで更新できる) / `DRIFT` liveが編集されている / `SKIP` 条件外(CLI未導入)
2. `DRIFT` の行について、差分のhunkごとに次のどれかを判断する:
   - **repo側を採用**: live側の変更が、このMac固有の一時的な事情によるもので、他のMacへ配る価値が無い
   - **live側を採用**: repo側が単に古く、live側の変更が最新の意図を反映している
   - **統合(止揚)**: 両側にそれぞれ意味のある変更が入っており、どちらかを切り捨てると情報が失われる。「後勝ち」や機械的なマージではなく、両方の意図を汲んで1つの自然な文章に書き直す
   - 判断に迷うhunkは推測で決めず、差分を具体的に示してユーザーに選んでもらう
3. 決めた内容を、**リポジトリの `setup/ai-agent-config/src/` の該当ファイルに書き**、`install.sh -f`(確認あり。`-fy` で確認なし)で live側へ配備する。配備された指示ファイル(`~/AGENTS.md`、`~/.claude/CLAUDE.md` など)を、エージェントが直接編集することは、hookが拒否する(あなた自身がliveを直接編集した場合の取り込み先も、`src/`)。片方だけ直すと、次回の diff で再び差分になる。
4. 反映後に `diff-ai-agent-config.sh` を再実行し、`OK` になったことを確かめる。repo側を変えたら、何が変わったかを要約する。コミットは指示があるまで実行しない。
5. 内容の大部分を書き換える場合は、書き換え前の内容を一度提示してから上書きする(`install.sh` は上書き前に `~/.agent-state/backups/` へ退避する)。

## 判断時の追加ルール

- マシン固有の事実(利用プランの有無、導入状況など)を指示文・台帳へベタ書きしない。live側にそうした記述が増えていたら、統合時にrepo側の一般化した書き方を優先する。取得できるものは `agents-probe.sh` の担当。
- `CLAUDE.md` / `AGENTS.md` という名前のファイルは、各階層に1つずつまで。manifestが管理するのは、`~/AGENTS.md`(共通ルールの実体)、`~/.claude/CLAUDE.md`、各エージェントの `AGENTS.md`(`~/AGENTS.md` への symlink。`protect` フラグの行が該当)。diff の「同一階層の指示ファイル重複」欄に出たものは、整理の候補としてユーザーへ示す。
- 共通ルールは `shared-rules.md` ただ1つが正本。各エージェントの `AGENTS.md` は、すべて `~/AGENTS.md` へのsymlinkで、Codexのペルソナは `config.toml` の管理ブロック(`developer_instructions`)。共通ルールを変えるときは `shared-rules.md` だけを直し、`install.sh` で反映する。
- このリポジトリで作業中は、ルートの `AGENTS.md` / `CLAUDE.md`(このrepo用の小さな指示)が、グローバル指示とは別に読み込まれている点を意識する。
- settings.json の hooks は、管理対象のエントリ(コマンドが `~/.agents/hooks/` 配下)だけが対象。他のキー(permissions・model 等)には触らない。
