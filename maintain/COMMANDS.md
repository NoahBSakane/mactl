# mactl コマンド一覧

## Mac全体の保守

```sh
mactl
```

実行内容を表示して確認後、アプリ・言語環境・対象プロジェクトの更新、安全なキャッシュ整理、監査と検証をまとめて行います。

```sh
mactl -y
```

最初の確認だけ省略して一括実行します。管理者パスワードが必要な場合の入力は省略されません。

管理者パスワードは開始時に一度だけ入力し、実行中はsudo認証を安全に維持します。パスワードをコマンド引数や履歴へ保存しません。

```sh
mactl plan
```

変更せず、更新候補と対象プロジェクトの監査結果を表示します。

```sh
mactl projects
```

`.mac-maintain` のあるプロジェクトだけ、依存関係の更新・監査・テスト・ビルドを実行します。

```sh
mactl clean
```

pnpm store prune → npm cache verify → uv cache prune → brew cleanup --prune=all → アプリキャッシュ許可リストの順で整理します。最後の処理は `cleanup/mac-cleanup.sh --apply --only app-caches` に委ねます。

```sh
mactl report
```

ディスク、macOS更新候補、Homebrew、mise、セキュリティーの状態を変更せず表示します。

```sh
mactl commands
mactl --help
```

この一覧、または短いヘルプを表示します。

## セットアップと詳細清掃

```sh
mactl setup
mactl setup -y
```

実行する4本を表示し、y/N確認後に mise-uv-config → ai-agent-config → login-items → cursor-sidebar-icon-patch の順にインストーラを実行します。失敗した時点で非0終了し、後続は実行しません。`-y` は最初の確認を省略します。mise の導入・zshでの有効化と jq 等の前提は [README](../README.md) を参照してください。

```sh
mactl doctor
mactl check
mactl push-setup
```

`doctor` は、必要なツール(jq・python3 3.8以上・git ほか)の有無を確認し、足りないものの入れ方を表示します。`check` は ai-agent-config のテスト4本と、公開リポジトリに載せてよいかの検査(`public-check.py`)を実行します。`push-setup` は、このクローンを持ち主のアカウント(`NoahBSakane`)で pull/push できるようにします(`gh` のログインが先に要ります)。

```sh
mactl clean --deep --list
mactl clean --deep --only app-caches
mactl clean --deep --apply --only app-caches
```

`clean --deep` 以降の引数は詳細清掃スクリプトへそのまま渡します。引数なしは dry-run で、`--apply` を付けた場合だけ削除します。`-y` は `--apply` の代わりになりません。カテゴリ・除外・安全検証は [詳細清掃の説明](../cleanup/mac-cleanup.md) を参照してください。

## 個別の保守処理

| コマンド | 処理 |
| --- | --- |
| `mactl update-system` | Homebrew / App Store の更新 |
| `mactl update-tools` | mise / ランタイム / 言語パッケージ管理ツールの更新 |
| `mactl ensure-firewall` | ファイアウォールが無効なら有効化 |

通常は sudo 認証維持を含む `mactl` の一括実行を使います。個別の `update-system` / `ensure-firewall` は従来どおり有効な sudo 認証が必要です。

## プロジェクトの探索先

既定は `$HOME/Repos`、除外は `$HOME/Repos/fan-n-sakane`。それぞれ環境変数 `MACTL_PROJECT_ROOT` / `MACTL_EXCLUDED_PROJECT_ROOT` で変更できます。Makefile の探索と project-maintain.zsh の境界判定に共通で反映します。既存の参加印 `.mac-maintain` は名前を変更しません。

## Denoへ移行したプロジェクト

### ASPAaaG

```sh
cd "$HOME/Repos/Noah B. Sakane/ASPAaaG"
deno install --frozen
deno task check
deno task open
```

Apps Scriptへ反映する時だけ、次を実行します。

```sh
deno task deploy
```

### zk

```sh
cd "$HOME/Repos/n3b4s5/zk"
deno install --frozen
deno task dev
deno task dev:worker
deno task build
```

Workerへ反映する時だけ、次を実行します。

```sh
deno task deploy:worker
```

### qr-overlay

```sh
cd "$HOME/Repos/n3b4s5/qr-overlay"
deno install --frozen
deno task dev
deno task build
```

## 安全上の境界

- macOS本体の更新は報告だけで、自動インストールしません。
- LINE・UTM・壁紙・Claude・Codexは、再生成できる単純キャッシュだけを削除します。
- 保守のプロジェクト探索・更新では `$HOME/Repos/fan-n-sakane` 以下を既定で除外します。詳細清掃の `repo-artifacts` は独立した明示選択カテゴリです。
- `.mac-maintain` は、そのプロジェクトを依存関係の自動更新・監査・検証の対象にする印です。
- CodexのHomebrew引継ぎと通常更新は、`/Applications/ChatGPT.app` のアプリ本体を管理します。ユーザーデータを一括削除しません。別工程のキャッシュ清掃は `~/.codex/cache` 等の許可リスト内の中身に限ります。
- Codexが起動中なら、現在のタスクを切断しないようCodexだけ引継ぎ・更新・キャッシュ整理を保留します。Codexを終了してから `mactl` を実行すると処理されます。
- `brew uninstall --cask --zap chatgpt` はCodexの設定・キャッシュ・ローカルデータまで削除し得るため、完全初期化を意図する時以外は実行しないでください。
