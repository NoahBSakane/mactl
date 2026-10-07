# Cursorの左サイドバーにClaude Code/Codexアイコンが出ない問題の対処

Cursorエディタというアプリ自体の設定・拡張機能ファイルへの対処であり、このリポジトリの他の内容(プロジェクトのコード)とは無関係。

## 症状

Cursorの左端のアイコン列(Explorer・検索・ソース管理が並ぶ「アクティビティバー」)に、本来並んでいるはずの **Claude Code** と **Codex**(`openai.chatgpt`拡張機能)のアイコンが出ず、右側の補助サイドバーの折りたたみ項目になってしまう。

## 原因

`anthropic.claude-code` と `openai.chatgpt` は、自分のアイコンをアクティビティバー(左)と補助サイドバー(右)のどちらに置くかを、拡張機能内部の条件分岐(「エディタが自己申告するVS Code APIバージョンが1.106以上か」)で決めている。Cursorはこの条件を満たすバージョンを名乗るため、放っておくと常に右側判定になる。

さらに両拡張機能は自動アップデートされるため、一度パッチしても新しいバンドルに入れ替わると症状が再発する。

## 対処

拡張機能本体の圧縮済みJSファイルを直接書き換えて、条件分岐を強制的に「アクティビティバー側」にする。

- Claude Code: `~/.cursor/extensions/anthropic.claude-code-*/extension.js` — 完全一致の文字列置換
- Codex: `~/.cursor/extensions/openai.chatgpt-*/out/extension.js` — 同種の判定関数を正規表現で検出して置換(minifyの変数名がビルドごとに変わっても追従できるように)

具体的なパターン・置換内容は [cursor-sidebar-icon-patch.sh](cursor-sidebar-icon-patch.sh) のコメントを参照(パッチ前に必ず`.bak-<日付>`というバックアップを同フォルダに残す)。

反映にはCursorの完全終了(`Cmd+Q`)→再起動が必要(拡張機能コードは起動時に読み込まれるため)。あわせて、Cursor独自の「統合サイドバー」機能(`Cmd+Option+U`で切替)はOFFにしておくこと。

## 設置先とコード

```text
mactl/setup/cursor-sidebar-icon-patch/
  cursor-claude-codex-sidebar-fix.md                → このファイル
  cursor-sidebar-icon-patch.sh                      → 設置先: ~/Library/Scripts/cursor-sidebar-icon-patch.sh
  com.nbs.cursor-sidebar-icon-patch.plist.template  → install-cursor-sidebar-icon-patch.shが
                                                        __HOME__を実行時の$HOMEに置換して生成
                                                        設置先: ~/Library/LaunchAgents/com.nbs.cursor-sidebar-icon-patch.plist
  install-cursor-sidebar-icon-patch.sh              → 上記の生成・配置とlaunchctl登録を行うスクリプト
```

`.plist`はlaunchdの制約上`~`や`$HOME`をそのまま書けないため、`__HOME__`プレースホルダ入りのテンプレートとして置いてあり、install時にその場の`$HOME`へ置換する。

再設置したい場合(初期化後・別のMac/別ユーザーに持っていく場合など)は

```bash
mactl/setup/cursor-sidebar-icon-patch/install-cursor-sidebar-icon-patch.sh
```

を実行するだけでよい。

**Macであること以外の前提には対応していない**(`launchd`・`plutil`・`~/.cursor/extensions/*-darwin-*`という命名などmacOS前提)。パッチが狙っている拡張機能内部のパターンは今のビルドのものであり、将来アップデートで実装のロジック自体が変わればパターンが見つからず何もしなくなる(安全に諦めるだけで壊れはしない)。

## 再発しないようにする自動化(launchd)

```text
~/Library/LaunchAgents/com.nbs.cursor-sidebar-icon-patch.plist   ← 定義(いつ実行するか)
~/Library/Scripts/cursor-sidebar-icon-patch.sh                    ← 実処理(パッチ本体、再実行しても安全)
~/Library/Logs/cursor-sidebar-icon-patch.log                      ← 実行ログ
```

このLaunchAgentは2つのタイミングで自動実行される:

1. **PCの再起動・ログイン時**(`RunAtLoad`)
2. **`~/.cursor/extensions`フォルダに変化があった時**=拡張機能がアップデートされた直後(`WatchPaths`)。再起動を待たずに再パッチされる。

基本的には「またアイコンが消えた」と思っても、Cursorを一度完全終了→再起動すれば直っているはず。

汎用の起動時フォルダ([login-items-startup-scripts.md](../login-items/login-items-startup-scripts.md))ではなく専用のLaunchAgentで動いている理由は、`WatchPaths`という汎用ランナーにはないトリガーを使っているため。

## トラブル時のチェックリスト

1. `~/Library/Logs/cursor-sidebar-icon-patch.log` の最後の数行を見て、直近でパッチが当たっているか確認(`WARN: target pattern not found`が出ていれば拡張機能側の実装が変わった可能性がある)
2. Cursorを完全終了(`Cmd+Q`)→再起動
3. `Cmd+Option+U`(統合サイドバー)がOFFになっているか確認
4. それでも直らなければ、拡張機能自体の内部実装(ロジックの形自体)が変わった可能性があるので、Claude Codeに「このファイルと`cursor-sidebar-icon-patch.sh`を見て、また同じ調査から」と頼む
