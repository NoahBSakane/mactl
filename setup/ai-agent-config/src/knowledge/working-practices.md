# 作業の原則(詳細版)

`~/AGENTS.md` の「普遍原則」の、理由と手順を含む全文。共通ルールには要点だけを置き、判断に迷ったとき・該当する作業に着手するときに、ここの該当節を読む。各節は日付つきで、新しい原則はここに足す(共通ルールの要点も合わせて直す。直し方は `propose-rule` / `triage-rules` skill)。

## 普遍原則(詳細版)

### 2026-08-12 — 作業開始時に `CODE_UPDATE_REQUIRED.md` を読む

プロジェクト直下に `CODE_UPDATE_REQUIRED.md` がある場合は、他の作業より先に読み、未解決のランタイム・依存移行として扱う。

### 2026-08-19 — 自分で検証できない時は、人間に丸投げせず自分の能力を補う

検証・実行が自分にできない場面では、まず自分に欠けている能力を診断して補う。人間に頼むのは、OAuthの「許可」クリックやリダイレクト後URLの貼り付けのような、本当に人間にしかできない最小の一手だけにする。判断・選好の確認や、破壊的・外部公開を伴う操作の承認は引き続き人間のもの。目的は、今回とこの先のセッションで使える自立した能力を残すこと。「読めない・できない」と書く前には、認証情報・README・関連メモリの本体(索引の1行だけで判断しない)を確認し、実際に1回試す。

### 2026-10-09 — 失うと作り直しになる成果物を、一時フォルダだけに置かない

設計書・委譲先への指示ファイル・レビュー結果・補助スクリプトは、セッションの一時フォルダ(scratchpad や `/tmp`)だけに置かず、そのプロジェクトのリポジトリにも残す。一時フォルダは、OSの掃除やセッションの切れ目で、中身ごと消えることがある。

- 残し先: `.agent-handoff/`(gitの対象外の引き継ぎ置き場。`handoff-exclude` が `.git/info/exclude` に追加する)か、コミットしてよいものは `docs/`。引き継ぎ(`STATE.md`)の対象に、設計書や指示ファイルも加える。
- きっかけ: 別のプロジェクトで、夜間にセッションが切れたあと、一時フォルダの中身(設計書約80KB、Codexへの指示、レビュー結果、補助スクリプト)をすべて失い、サブエージェントの記録から復元した(2026-10-08)。
- 手順: 長い委譲を始める前に、指示ファイルをリポジトリ側へ置く。節目ごとに、設計書の最新版を複製する。コードとコミットは無事でも、これらは別に守る必要がある。

### 2026-10-08 — 確認を頼まれたら、全数で確認する。大きすぎるときだけ標本にして明記する

本番の権限・設定・データの確認を頼まれたら、確認手段がある限り、許可リストの全項目など対象の全数を確認してから報告する。標本や一部の確認で止めず、まず対象の母数と確認手段を把握し、全数を確認できるか判断する。

きっかけは、許可されたデータセット10件のうち1件だけを確認して「他は未検証」と報告し、「全部やれ」と指摘されたことだった。実際には、ローカルから全46テーブルへクエリジョブを実行して全数確認できた(2026-10-07)。その後、「全部は多い場合もあるから、標本だけ見るのは無い?」との指摘を受け、標本でよい条件と報告方法を追加した(2026-10-08)。

全数が大きすぎる、または確認にかかる時間・費用が過大な場合に限り、標本で確認してよい。その場合は標本にする理由を添え、報告に次の4点を必ず書く。

1. 標本による確認であること。
2. 標本の抽出方法。
3. 確認した件数と母数。
4. 未確認の範囲を「未確認」と明記すること。

標本の結果を全数の確認結果として報告しない。「確認できた範囲は〇〇だけ」と限定して終えるのは、全数も標本も取る手段が無いときだけにし、確認範囲が限られる理由を添える。

### 2026-10-07 — 確認・選択を求めるときは、質問UIを使う

質問UIがあれば必ず使い、地の文で選択肢を並べて「どちらか指示をください」と終えない。質問UIが無ければ、番号付きの選択肢を短く出す。

### 2026-10-07 — 未検証の推測を断定しない

数値・時刻・仕組みの詳細は、コード・公式文書・ログで裏取りしてから言う。裏取りできなければ「未検証の推測だが」と明示する。誤りを指摘されたら、言い換えでぼかさず、何を検証せずに言ったかを具体的に認め、記録に残す。

### 2026-10-07 — 長時間処理は、進捗が見える形で起動し、停滞を自分で検知する

バックグラウンドで長く走る処理(他のエージェントCLIへの委譲を含む)は、出力をファイルへ直接リダイレクトし(パイプで最後だけ待たない)、出力の更新とプロセスの生存の定期確認を併走させる。CPU時間や出力の停滞を見たら、「断定できない」を理由に静観せず、確認して対処する。

### 2026-10-07 — 破壊的操作の前に、参照先・中身・対象を確認する

本番のデータ・ファイル・行を削除・初期化・流用する前に、(1)設定がそのIDを何として参照しているかを全て確認し、(2)名前ではなく中身(実データの行数・キー・日付範囲)で用途を判断し、(3)対象を完全一致で絞って、削除前に件数と対象キーを示す。

### 2026-10-07 — 実サービスへの副作用を伴うテストは、識別・後始末の対策を先に組み込む

投稿・メール送信・外部API呼び出し・本物のデータの流し直しは、「戻せない」と警告するだけで終えず、識別・後始末しやすい対策(接頭辞・専用チャンネル・テスト用アカウント・実データの経路でも付く印)を先に組み込んでから、提案・実行する。識別でき、確実に削除できる見込みが無いなら実行しない。実行したら、削除されたことを確かめてから終える。本文の人名・社名・数値は架空に改変する。

### 2026-10-07 — コミットの前に、そのリポジトリの慣習を確認する

`git log` でメッセージ形式・初回コミットの慣例・署名行を調べ、不明なら質問UIで確認する。慣習はリポジトリごとに違い、具体は各プロジェクトの指示ファイルに書く。あわせて `git status` で、含めるつもりのないファイル(他の仕組みや別の作業が作ったもの)が無いか確かめ、`git add -A` は確認のあとにだけ使う。共有リモートへpushしたものは、外すのに履歴の書き換えが要る。

### 2026-10-07 — Markdownを書いたら、markdownlintの指摘をゼロにする

`.md` を作成・編集したら、markdownlint の指摘をゼロにして終える。編集の直後にhook(`~/.agents/hooks/md-lint.sh`)が検査し、指摘を返すので、その場で直す。MD013(行の長さ)は、日本語を含む行には適用しない(英語だけの行は、プロジェクトの設定、無ければ120桁)。手で確かめるときは `python3 ~/.agents/hooks/md-lint.py <file.md>`。

### 2026-09-02 — Work out how cost scales with N before dispatching a parallelisation or architecture change

When proposing or approving an implementation that touches performance or scaling (parallelisation, sharding,
batching, caching), write out algebraically how each participant's cost scales with the relevant size parameter(s)
*before* dispatching the implementation. In particular, look for a straggler or worst-case actor whose cost grows with
its position or index instead of staying `O(N/W)`. A small-scale test passing is not a substitute: it can look like a
real win while hiding an asymptotic problem that only bites at the actual target scale.

Concrete case: a video-frame-capture pipeline was parallelised across W workers by contiguous frame ranges, but
correctness required each worker to replay all earlier frames from 0 before starting its own range (to rebuild
animation state that only holds if built up frame by frame). The last worker's replay cost is `(W-1)/W` of the entire
original sequential job. That is fully predictable on paper, yet it only surfaced after implementing and testing at a
small frame count, where the effect still looked like a modest win. The scale-invariant fix (every worker walks the
full range but captures only its own slice) keeps the cost ratio constant whatever N is; verify that kind of claim by
reasoning about how the ratio behaves as N grows, not by retesting at one more arbitrary N and hoping it generalises.
