# 起動時に自動実行したいスクリプト用の汎用フォルダ(login-items.d)

このMac(nbsさんの環境)の設定。プロジェクトのコードとは無関係。

## 何のためのものか

macOSで「PCの再起動・ログインのたびに何かを自動実行したい」場合、通常は`launchd`用の`.plist`を1個ずつ作る必要があり、やりたいことが増えるたびにplistが増えて管理が煩雑になる。

これを避けるため、**「実行可能スクリプトを1個のフォルダに置くだけで、次回ログインから自動実行される」**という仕組みを1つだけ用意してある。新しい「起動時にやりたいこと」が出てきても、plistを新規に作る必要はない。

## 構成

```
~/Library/Scripts/login-items.d/                          ← ★ここにスクリプトを置く
~/Library/Scripts/run-login-items.sh                       ← login-items.d/ の中身を順番に実行する共通ランナー
~/Library/LaunchAgents/com.nbs.login-items-runner.plist    ← ランナーをログイン時に起動するLaunchAgent定義
~/Library/Logs/login-items.log                             ← 実行ログ(どのスクリプトが成功/失敗したか)
```

## 設置先とコード

```
mactl/setup/login-items/
  login-items-startup-scripts.md              → このファイル
  run-login-items.sh                          → 設置先: ~/Library/Scripts/run-login-items.sh
  com.nbs.login-items-runner.plist.template   → install-login-items-runner.shが
                                                  __HOME__を実行時の$HOMEに置換して生成
                                                  設置先: ~/Library/LaunchAgents/com.nbs.login-items-runner.plist
  install-login-items-runner.sh               → 上記の生成・配置とlaunchctl登録を行うスクリプト
```

[cursor-claude-codex-sidebar-fix.md](../cursor-sidebar-icon-patch/cursor-claude-codex-sidebar-fix.md)側と同じ理由(launchdが`~`や`$HOME`を展開できない)で`.plist`はテンプレート化してあり、

```bash
mactl/setup/login-items/install-login-items-runner.sh
```

を実行するだけで再設置できる。

**注意**: これで復元できるのはランナー本体だけ。`~/Library/Scripts/login-items.d/`に置いていた個別のスクリプトはこのリポジトリの管理対象外なので、別途コピーする必要がある。

## 使い方

1. 実行したい処理をシェルスクリプトとして書く
2. `~/Library/Scripts/login-items.d/` に置く
3. `chmod +x` で実行権限を付ける

これだけで、次回のPC再起動・ログイン時から自動的に実行されるようになる。plistの編集や`launchctl`操作は不要。

- スクリプトは名前順に実行される
- 1つのスクリプトが失敗(0以外の終了コード)しても、他のスクリプトの実行は止まらない
- 各スクリプトの標準出力・標準エラー出力は、実行ログ(`~/Library/Logs/login-items.log`)にそのスクリプト名のタグ付きでまとめて記録される

## 今すぐ試したいとき(再起動を待たずに)

```bash
~/Library/Scripts/run-login-items.sh
```

を手動実行すれば、`login-items.d/`の中身がその場で全部実行される。

## ランナー自体を止めたいとき

```bash
launchctl bootout gui/$(id -u)/com.nbs.login-items-runner
```

(`login-items.d/`の中身自体は消えないので、再度`launchctl bootstrap ... com.nbs.login-items-runner.plist`すれば復活する)

## 注意点

- **`WatchPaths`(特定フォルダの変化を検知して即実行)のような特殊なトリガーはこのランナーには無い**。あくまで「ログイン時に実行」のみ。[cursor-claude-codex-sidebar-fix.md](../cursor-sidebar-icon-patch/cursor-claude-codex-sidebar-fix.md)のCursor拡張機能パッチのように「特定フォルダの変化を検知したら即座に再実行したい」場合は、この汎用フォルダではなく専用の`.plist`(`WatchPaths`付き)を別途作る必要がある。
- macOS Ventura以降は、新しいLaunchAgentを登録すると「バックグラウンド項目が追加されました」という通知が出ることがある。これは正常な動作(システム設定 > 一般 > ログイン項目 で一覧・無効化できる)。
