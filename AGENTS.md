# mactl(このリポジトリで作業するエージェント向け)

Mac のセットアップ・保守・掃除を `mactl` にまとめたリポジトリ(`setup/` の下に、サブフォルダごとに独立した1機能の設定インストーラがある。全て `$HOME` 基準で動き、installは再実行しても安全)。応答は日本語(共通ルールどおり)。

## `setup/ai-agent-config/` を触るとき

- **正本は `setup/ai-agent-config/src/` と `manifest.tsv`。** live側(`~/AGENTS.md`、`~/.claude/CLAUDE.md` 等)を直接編集した場合は、`reconcile-agent-config` skill でrepoへ取り込む。台帳(`~/.knowledge/ai-agents.md`)だけは live側が作業用の正本。
- `install.sh` は、live側が前回のinstall以降に編集されている(`DRIFT`)と中止する。先に `diff-ai-agent-config.sh` で差分を見る。
- 新しい配備物は `manifest.tsv` に1行足す。manifestに無いものは管理しない。
- **`CLAUDE.md` / `AGENTS.md` という名前のファイルを、このリポジトリのルート以外に置かない。** 作業中のエージェントが自動で読み込み、グローバル指示と二重になる。グローバル指示の正本は `src/shared-rules.md`・`src/claude-user.md`・`src/codex-persona.md`。
- マシン固有の事実(導入状況・特定の1台にしか無い設定・利用プラン)を、指示文や台帳に書かない。取得できるものは `agents-probe.sh` に任せる。
- **このリポジトリは公開。** 社内・個人の固有名、ID、人名、メール、絶対パス、秘密を、コード・文書・テストに書かない(一般名・プレースホルダにする)。`setup/ai-agent-config/public-check.py` が検査し、push 時に自動で走る(`setup-git-account.sh` が設置)。自分用の語は `~/.config/ai-agent-config/public-denylist.txt`(非公開)。
- 変更したら `setup/ai-agent-config/tests/` の `hooks-test.sh`・`install-test.sh`・`public-check-test.sh`・`handoff-exclude-test.sh` を実行し(まとめては `mactl check`)、全件パスを確認する。hookは「失敗したら通す(fail-open)」が原則で、拒否は明示的な終了コード2だけ。

## pull / push

- このリポジトリの pull・push・fetch は、GitHub の **`NoahBSakane` アカウント**(このリポジトリの持ち主。フォークして別のアカウントで運用するなら、読み替えて `./setup-git-account.sh <アカウント>`)で行う(他のプロジェクトは別のアカウントで、`gh` の有効アカウントもそれ)。`gh auth switch` で有効アカウントを変えない。変えると、他のプロジェクトの `gh` が別のアカウントで動く。
- 認証はこのクローンの `.git/config` にあり、コミットされない。新しいクローン・別のMacでは `./setup-git-account.sh` を実行する(冪等。`gh` のキーチェーンから `NoahBSakane` のトークンを引く認証にし、`gh` の有効アカウントは触らない)。`NoahBSakane` で未ログインなら、端末(Claude Code の外)で `gh auth login -h github.com -p https -w`。
- Claude Code の許可ルール(`git fetch`・`pull`・`push` を許可、強制 push・削除は確認)は `.claude/settings.json`(コミット対象)にある。自動モードの分類器は、**セッション中に `git remote set-url` で向き先を変えたリモートを信頼せず**、push を止める。リモートを変えたら、新しいセッションを開く。

## 関連

- [README.md](README.md) — リポジトリ全体の構成
- [setup/ai-agent-config/ai-agent-config.md](setup/ai-agent-config/ai-agent-config.md) — 設計と運用の詳細
