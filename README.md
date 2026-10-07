# mactl

Mac のセットアップ・保守・掃除を `mactl` にまとめたリポジトリ。既存の mac-maintain の更新順序・確認・sudo 認証維持・プロジェクト検証を引き継ぐ。ユーザー固有のパスは `$HOME` から解決する。

## 新しいMacでの手順

前提は macOS、Git、GNU Make（Homebrew の `make`）、導入・zsh有効化済みの mise、jq、python3（3.8以上）。`mactl doctor` で確認できる。setup は既存インストーラによる設定の復元で、Homebrew・mise 本体を導入するものではない。mise の有効化行は [mise-uv-config の説明](setup/mise-uv-config/mise-uv-config.md) を参照。

```sh
git clone https://github.com/NoahBSakane/mactl.git
cd mactl
./install.sh
export PATH="$HOME/.local/bin:$PATH"
mactl setup
```

`install.sh` は `~/.local/bin/mactl` → このクローンの `bin/mactl` のリンクを設置する。既存リンクは張り直し、通常ファイルは `.bak.<日時>` に退避する。再実行可能。クローンを移動した場合は再実行する。`~/.local/bin` はシェルの PATH にも追加しておく。

`setup` は実行内容を表示し、y/N 確認後に **mise-uv-config → ai-agent-config → login-items → cursor-sidebar-icon-patch** の順で実行する。失敗した時点で停止し、非0終了する。`mactl setup -y` で確認を省略できる。ai-agent-config は manifest 駆動で、配備先のファイルが前回の配備のあとに編集されていると、何も変えずに中止する(`DRIFT`)。確認の仕方と用語は [setup-guide.md](setup/ai-agent-config/setup-guide.md)。`DRIFT` で止まると、`mactl setup` の後続(login-items・cursor-sidebar-icon-patch)も実行されないので、`setup/ai-agent-config/diff-ai-agent-config.sh` で差分を見てから、`install.sh -f` を実行する。login-items.d 内の個別スクリプトはこのリポジトリに含まれない。

保守には既存環境の Homebrew、mas、mise 管理下の各言語ツールを使用する。GNU Make は `/opt/homebrew/opt/make/libexec/gnubin/make` を優先し、なければ PATH の `gmake` を使う。mise 本体は `$HOME/.local/bin/mise`。App Store 更新の mas は従来の `/opt/homebrew/bin/mas` を使用する。

## コマンド一覧

| コマンド | 内容 |
| --- | --- |
| `mactl` / `mactl maintain` | 確認・sudo 認証後、更新・整理・監査を一括実行 |
| `mactl -y` | 一括実行の最初の確認を省略（sudo 認証は省略しない） |
| `mactl setup` | 設定インストーラ4本を順番に実行 |
| `mactl doctor` | 必要なツール(jq・python3 ほか)の有無を確認し、足りないものの入れ方を表示 |
| `mactl check` | ai-agent-config のテストと、公開前の検査(`public-check.py`)を実行 |
| `mactl push-setup` | このクローンを、持ち主のアカウント(`NoahBSakane`)で pull/push できるよう設定(`setup-git-account.sh`) |
| `mactl plan` | 更新候補・対象プロジェクトの監査結果を表示 |
| `mactl update-system` | Homebrew / App Store 更新 |
| `mactl update-tools` | mise / ランタイム / 言語ツール更新 |
| `mactl ensure-firewall` | ファイアウォールを確認し、無効なら有効化 |
| `mactl clean` | pnpm prune → npm verify → uv prune → brew cleanup → app-caches を実行 |
| `mactl clean --deep [引数...]` | 詳細清掃スクリプトへ引数を渡す。既定 dry-run |
| `mactl projects` | `.mac-maintain` のあるプロジェクトだけ更新・監査・検証 |
| `mactl report` | ディスク・macOS更新候補・開発環境・セキュリティーの状態表示 |
| `mactl help` / `mactl --help` | 短いヘルプ |
| `mactl commands` | [詳しいコマンド一覧](maintain/COMMANDS.md) |

一括実行の順序は update-system → update-tools → ensure-firewall → clean → projects → report。macOS本体は更新候補の報告だけで、自動インストールしない。個別の update-system / ensure-firewall は有効な sudo 認証が必要。

```sh
mactl clean --deep --list
mactl clean --deep --only app-caches             # 削除せず確認
mactl clean --deep --apply --only app-caches     # 許可リストの中身だけ削除
```

`--deep` 以降は清掃スクリプトの引数をそのまま渡す。`--apply` だけが削除を有効にし、`-y` は代わりにならない。`app-caches` は LINE・UTM・壁紙・Claude・Codex の旧許可リストを継承し、ChatGPT プロセス起動中は Codex のキャッシュ整理を deferred として保留する。詳細なカテゴリ・除外・安全検証は [清掃の説明](cleanup/mac-cleanup.md) に記載。

プロジェクト探索は既定 `$HOME/Repos`、除外は `$HOME/Repos/fan-n-sakane`。環境変数 `MACTL_PROJECT_ROOT` / `MACTL_EXCLUDED_PROJECT_ROOT` で上書きできる。参加印 `.mac-maintain` と既存の移行レポート判定は互換性を維持する。詳細清掃の `repo-artifacts` は別の明示選択カテゴリで、探索先は `MAC_CLEANUP_REPO_ROOTS` が制御する。

## 構成

| パス | 内容 |
| --- | --- |
| [install.sh](install.sh) / [bin/mactl](bin/mactl) | コマンドの設置 / zsh の入口 |
| [Makefile](Makefile) | 保守ターゲット・setup の実行順序 |
| [maintain/](maintain/COMMANDS.md) | プロジェクト保守スクリプトとコマンド一覧 |
| [cleanup/](cleanup/mac-cleanup.md) | Bash 3.2 対応の詳細清掃（既定 dry-run） |
| [setup/mise-uv-config/](setup/mise-uv-config/mise-uv-config.md) | mise / uv の管理設定 |
| [setup/ai-agent-config/](setup/ai-agent-config/ai-agent-config.md) | Claude Code / Codex / Antigravity CLI(`agy`)/ Muse Code / Grok Build に共通する運用(応答言語・司令塔の振る舞い・委譲手順)と、skills・hook・台帳を他Macへ複製する仕組み。導入手順と用語は [setup-guide.md](setup/ai-agent-config/setup-guide.md) |
| [setup/login-items/](setup/login-items/login-items-startup-scripts.md) | ログイン時のスクリプト実行ランナー |
| [setup/cursor-sidebar-icon-patch/](setup/cursor-sidebar-icon-patch/cursor-claude-codex-sidebar-fix.md) | Cursor のサイドバーアイコン修正 |

ルートの `AGENTS.md` / `CLAUDE.md` は、このリポジトリで作業するための小さな指示で、グローバル指示のコピーではない。グローバル指示の正本は [setup/ai-agent-config/src/](setup/ai-agent-config/src/) にあり、`CLAUDE.md` / `AGENTS.md` とは別の名前で置いている(作業中のエージェントに自動で二重に読み込まれないようにするため。詳細は [ai-agent-config.md](setup/ai-agent-config/ai-agent-config.md))。旧 `~/.local/bin/mac-maintain` は `mactl` へのシンボリックリンクに置き換え、旧 `~/.config/mac-maintenance/` は `~/.config/mac-maintenance.bak-20260930` に退避した(このMacでの移行作業。`install.sh` 自体は旧ツールに触れない)。
