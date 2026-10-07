# やり残した作業

2026-10-07 時点で、実装が完了していない作業、検証できていない事項、人の手が要る作業の一覧です。導入手順は [setup-guide.md](setup-guide.md)、設計は [ai-agent-config.md](ai-agent-config.md) を参照してください。

## 人の手が要る作業

- [ ] **変更をコミットする。** 作業ツリーの変更はまだコミットしていない。`git status` と `git diff` で内容を確認してから行う。
- [ ] **`/doctor prompt-audit` を実行する。** 指示ファイルの古い記述・存在しない参照・矛盾を検出する、Claude Code の対話コマンド。新しいセッションで実行する。
- [ ] **`/context` で `AGENTS.md` の実際の読み込み量を測る(任意)。** 共通ルールは、import・symlink・祖先ディレクトリの3経路で見つかるが、いずれも同じファイルを指しており、内容の一致は `diff-ai-agent-config.sh` が検査している。`/doctor` の推定では約1.4k tokens(最大約4.1k)。
- [ ] **Muse に `muse login` する(Muse を使う場合のみ)。** 下記の `PreToolUse` の検証に必要。契約層の選択が絡む可能性があるので、内容を確認してから行う。

## 検証済み(2026-10-07、Codex の使用上限が解除されたあと)

Codex の使用上限は、予定(2026-10-10 11:42)より早く解除された。上限は不定期に解除される(リセットチケット等)ため、`limit-check.sh` が定期的に確かめ、解除を検知したら記録を外す。

- **Codex の hook は動いている。** `UserPromptSubmit` の状態行が Codex の応答に出た。`apply_patch` は、委譲を口頭で宣言しても(環境変数が無いので)`【エージェント構成の事前承認】` で止まり、ファイルは作られなかった(Codex の `PreToolUse` が `apply_patch` の入力を渡し、終了コード2で操作を止めることを確認)。
- **Codex のペルソナは効いている。** 雑談で「迷ってはるなら…おいでやす」と京都方言になる。敬語・結論先行・補足の省略も出ている。
- **`agent-takeover.sh` は動く。** 引き継ぎの指示が STATE.md を読み、「次の一手」を実行して報告した(対話の起動部分は、同じ指示を非対話に置き換えて確認)。
- **Codex の `Bash` ゲートと、指示ファイルの直接編集の拒否も効く。** 委譲を口頭で宣言しても、別エージェントCLI(`agy -p`)の起動は `【エージェント構成の事前承認】` で、保護対象の指示ファイルへの `apply_patch` は `【指示ファイルの直接編集は不可】` で止まり、ファイルは変わらなかった(使い捨てのファイルと状態ディレクトリで実施)。
- **markdownlint の自動検査は Claude Code でも実際に発火する。** 指摘のある `.md` を書いた直後に、編集ツールの結果として指摘が返った。
- Codex は共通ルールを自分で守る(構成承認を、ツールを呼ぶ前に自分で求める)。このため、ゲートの実機確認には、口頭で委譲を宣言して承認を飛ばさせる必要があった。

## 未実装の機能

- [ ] **台帳の自動調査ジョブの、実際の初回実行を確認する。** 仕組み(落ちたエージェントを飛ばして次へ回す動作を含む)はテスト(スタブ)で確認済みで、台帳が14日を超えると自動で起動する。実際の調査が期待どおりの提案レポートを出すか、初回の結果を確認する(今は台帳の確認日が新しいので、14日後に初めて動く)。今のこのMacで調査を実行できるのは Claude だけ(Codex は使える状態、Museは未ログイン、agyは `--dangerously-skip-permissions` と `agy-job-guard.sh`(Web検索とページ取得以外を全拒否する、調査ジョブ専用のhook)で動く。実機で `agent-run.sh` 経由の調査が通り、シェル・ファイル読みが拒否されることも確認済み。優先順位は Claude → Codex → Muse → agy のため、Claudeが使えないときの代行になる)。
- [ ] **MuseとGrokのメモリの実際の保存先を確認する。** 公式に公開されていないため、候補の場所を `agents.conf` に登録してある。実際に使って作られたら、`find ~ -newer` などで場所を確かめ、`agents.conf` の `memory` を直す。
- [x] **agy での `/ofuro` の開始(実装済み)。** `PreInvocation` の `invocationNum` が0のとき、payload の `transcriptPath` から、そのターンのユーザーのプロンプトを読み、`/ofuro` なら `reminder.sh` に渡して開始する(状態は会話IDに結び付き、Stop hook の継続も同じ状態を見る)。単体テストと、agy の実機(`agy -p "/ofuro 1m ..."` で状態ファイルが会話IDで作られる)で確認済み。
- [x] **`.agent-handoff/` の `.git/info/exclude` への自動追記(実装済み)。** `handoff-exclude.sh`(Codex に委譲して作成し、レビューして採用)。編集ツールが `.agent-handoff/` に書いた直後(`handoff-exclude-hook.sh`)と、プロンプトごと(`reminder.sh`)に実行する。
- [x] **お風呂モードの非対話ランチャー(実装済み)。** `ofuro-run.sh [時間] <任務>`(配備先 `~/.knowledge/bin/ofuro-run.sh`)が `claude -p "/ofuro ..."` を起動する。`claude -p` でも `/ofuro` が hook で起動し、Stop hook で継続することを確認した。`/goal` と1つのプロンプトでは併用できない(`/ofuro` で始まる必要がある)ので、継続は Stop hook による(上限は連続30回の拒否と進捗なしの判定)。

## 未検証の事項

- [ ] **Muse の `PreToolUse` の入力と拒否の挙動、およびツール名。** 未ログインのため、モデル呼び出しを伴う検証ができていない。`UserPromptSubmit` がユーザー設定から発火することは確認済み。
- [ ] **Muse の `muse-adapter.sh`(無人実行を委譲先とみなす判定)の実機検証。** `permission_mode` が `bypassPermissions` になることは確認済みだが、ゲートがツール呼び出しで実際に素通しになるかは、モデル呼び出しが必要で未検証。
- [ ] **Codex の `Bash` ゲートでの `AGENT_DELEGATED_BY` の素通し。** hookプロセスに環境変数が渡ることは `UserPromptSubmit` で確認済み。`Bash` ゲート自体の実機確認が残っている(上の検証待ちを参照)。
- [ ] **Grok Build の配線。** 未導入のため、skills の symlink と、Claude の設定の hook を読む挙動を検証していない。
- [ ] **使用上限の自動再開(`autoContinueAtUsageLimit`)が効くか(`/config` に行が出ない環境で)。** 設定の既定は有効だが、環境によっては `/config` に行が出ない(2026-10-07に確認)。実際に上限に当たったとき、リセット後に再開するかを見る。`claude -p`(非対話)での自動待機は、公式文書に記載が無い。
- [ ] **実行中のセッションが、settings.json の hook 変更をいつ取り込むか。** ツール次第で、新しいセッションからは確実に有効になる。
- [ ] **agy の `/ofuro` 以外の `PreToolUse` 経路。** 編集ツールのうち、`replace_file_content` と `multi_replace_file_content` の入力は未確認(`write_to_file` は確認済み)。

## 既知の制約

- **指示ファイルの直接編集の拒否は、エディタ系のツール呼び出しが対象。** `Bash` のリダイレクト(`>`、`sed -i` など)による書き換えは対象外。検出は `diff-ai-agent-config.sh` の `DRIFT` に頼る。
- **メモリの収穫の対象: Claude・Codexは確認済み。** agyは永続メモリを持たない(会話の記録のみ)。Muse・Grokは、保存先が公開されておらず候補を登録しただけ。
- **agy の構成承認ゲートは、非対話の `--dangerously-skip-permissions` 実行では止まらない。** 決定が `ask` で、そのフラグでは自動承認されるため(拒否 `deny` は、そのフラグでも効く。調査ジョブの `agy-job-guard.sh` はこれを使う)。対話の agy では、ネイティブの承認プロンプトが出る。`deny` にすると、agy にはユーザーのプロンプト単位の目印が無く、解除できずに詰まる。
- **Cowork セッションでは、ユーザースコープの `@AGENTS.md` の import が、workspace の外のパスとして無視される。** コピーに替えても解消しない(制約として扱う)。
- **probe は、各CLIの残りの利用枠を取得できない。** 使用上限を検知した側が、`~/.agent-state/unavailable/<agent>.txt` に復帰時刻を記録する。解除は不定期に早まるので、`limit-check.sh` がリマインドの度に(30分に1回まで)最小の実呼び出し(`agents.conf` の `ping`)で確かめ、通れば記録を外す。使える状態から新たに上限に達したことは、実際に使って失敗するまで分からない。

## 後片付け

- [ ] **旧ログの扱いを決める。** `~/.claude/delegation-hooks/delegation-log.jsonl`(約930KB)は、旧hookが書いた誤検知入りのログ。新しいログは `~/.agent-state/delegation-log.jsonl` に出る。不要なら削除する。
- [ ] **互換shimを撤去する。** `~/.claude/hooks/delegation/` の旧パス用shimは、移行のために1バージョン分だけ残している。実行中のセッションが無くなったら、`manifest.tsv` の `legacy-hook-shims` の行を外して撤去する。
- [ ] **バックアップを整理する。** `~/.agent-state/backups/` は、`install.sh` を実行するたびに増える。不要になった古いものを削除する。
- [ ] **スクラッチの一時ファイルを確認する。** 調査・検証で作った使い捨てファイルは、セッションのスクラッチ領域にあり、リポジトリや本番の設定には影響しない。
