# mac-setup

nbsさんの個人Mac設定を再現可能にするためのスナップショット集。サブフォルダごとに独立した1機能が入っており、それぞれのinstallスクリプト(`install.sh` など)を実行すれば新しいMac・別ユーザーアカウントにも再設置できる(全て`$HOME`基準で解決するためユーザー名を問わず動き、いずれも再実行安全)。

## 構成

| ディレクトリ | 内容 |
| --- | --- |
| [ai-agent-config/](ai-agent-config/ai-agent-config.md) | Claude Code / Codex / Antigravity CLI(`agy`)/ Muse Code / Grok Build に共通する運用(応答言語・司令塔の振る舞い・委譲手順)と、skills・hook・台帳を他Macへ複製する仕組み |
| [cursor-sidebar-icon-patch/](cursor-sidebar-icon-patch/cursor-claude-codex-sidebar-fix.md) | Cursorの左サイドバーにClaude Code/Codexアイコンが出ない問題への対処(launchdで自動・再パッチ) |
| [login-items/](login-items/login-items-startup-scripts.md) | ログイン時に自動実行したいスクリプトを置くだけで動く汎用フォルダの仕組み(login-items.d) |

## ルートの `AGENTS.md` / `CLAUDE.md` について

どちらもこのリポジトリで作業するための小さな指示で、グローバル指示のコピーではない。グローバル指示の正本は [ai-agent-config/src/](ai-agent-config/src/) にあり、`CLAUDE.md` / `AGENTS.md` とは別の名前で置いている(作業中のエージェントに自動で二重に読み込まれないようにするため)。詳細は [ai-agent-config/ai-agent-config.md](ai-agent-config/ai-agent-config.md)。

## 他Macへ持っていく

AIエージェント設定の導入手順と用語は、[ai-agent-config/setup-guide.md](ai-agent-config/setup-guide.md) を先に読んでください。

`git clone`(または既存クローンなら`git pull`)でこのリポジトリを取得し、各ディレクトリのinstallスクリプトを実行する。
