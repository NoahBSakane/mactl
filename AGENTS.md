# mac-setup(このリポジトリで作業するエージェント向け)

nbsさんの個人Mac設定を再現可能にするためのスナップショット集。サブフォルダごとに独立した1機能で、全て `$HOME` 基準で動き、installは再実行しても安全。応答は日本語(共通ルールどおり)。

## `ai-agent-config/` を触るとき

- **正本は `ai-agent-config/src/` と `manifest.tsv`。** live側(`~/AGENTS.md`、`~/.claude/CLAUDE.md` 等)を直接編集した場合は、`reconcile-agent-config` skill でrepoへ取り込む。台帳(`~/.knowledge/ai-agents.md`)だけは live側が作業用の正本。
- `install.sh` は、live側が前回のinstall以降に編集されている(`DRIFT`)と中止する。先に `diff-ai-agent-config.sh` で差分を見る。
- 新しい配備物は `manifest.tsv` に1行足す。manifestに無いものは管理しない。
- **`CLAUDE.md` / `AGENTS.md` という名前のファイルを、このリポジトリのルート以外に置かない。** 作業中のエージェントが自動で読み込み、グローバル指示と二重になる。グローバル指示の正本は `src/shared-rules.md`・`src/claude-user.md`・`src/codex-persona.md`。
- マシン固有の事実(導入状況・特定の1台にしか無い設定・利用プラン)を、指示文や台帳に書かない。取得できるものは `agents-probe.sh` に任せる。
- 変更したら `ai-agent-config/tests/hooks-test.sh` を実行し、全件パスを確認する。hookは「失敗したら通す(fail-open)」が原則で、拒否は明示的な終了コード2だけ。

## 関連

- [README.md](README.md) — リポジトリ全体の構成
- [ai-agent-config/ai-agent-config.md](ai-agent-config/ai-agent-config.md) — 設計と運用の詳細
