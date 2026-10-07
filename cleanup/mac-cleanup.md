# Mac のストレージ清掃

開発ツールのキャッシュ、再取得できるテスト用ブラウザ、古いログをカテゴリ単位で整理するスクリプト。macOS 標準の Bash 3.2 で動作する。インストールや定期実行の登録は不要で、引数なしでは削除せず、対象パスと現在サイズを表示する。

## 使い方

`mactl clean --deep` で呼び出す（既定 dry-run）。以下はリポジトリ直下からの直接実行例。通常の `mactl clean` はパッケージ管理ツール4処理と `app-caches` だけを実行する。

```bash
./cleanup/mac-cleanup.sh                       # dry-run（既定）
./cleanup/mac-cleanup.sh --list                # 全16カテゴリの説明
./cleanup/mac-cleanup.sh --help
./cleanup/mac-cleanup.sh --only brew,npm,uv    # 選択して dry-run
./cleanup/mac-cleanup.sh --skip mise,logs      # 指定分を除外
./cleanup/mac-cleanup.sh --only huggingface    # モデルキャッシュを明示選択
./cleanup/mac-cleanup.sh --only repo-artifacts # 30日以上更新のないプロジェクトの成果物
./cleanup/mac-cleanup.sh --only repo-artifacts --older-than-days 0 # 日数制限をほぼ外して確認
```

実際の清掃は、対象を確認し、関連アプリ・ビルド・インストール処理を終了してから `--apply` を付けて行う。

```bash
./cleanup/mac-cleanup.sh --apply --only brew,npm,uv
./cleanup/mac-cleanup.sh --apply --skip mise
```

`--only` がなければ `huggingface`・`repo-artifacts` 以外が対象。`--only` と `--skip` の併用では `--skip` を優先する。同じ選択オプションの繰り返し指定はリストを追加する。未知のカテゴリ、不正な引数、root（`sudo` を含む）での実行は拒否する。`--list`・`--help` は表示後すぐ終了する。

## カテゴリと対象

以下の `~` は実行ユーザーの `$HOME`。ツールが `command -v` で見つからないカテゴリは黙ってスキップする。`pip` は `python3` と pip モジュールの存在を確認する。直接パスを扱う `xcode`・`browsers-test`・一般キャッシュ・ログは、専用ツールがなくてもファイルの有無で判断する。

| カテゴリ | 対象パス | `--apply` の処理 |
| --- | --- | --- |
| `brew` | `~/Library/Caches/Homebrew` | `brew cleanup -s --prune=all`。Homebrew 管理の旧版も対象 |
| `npm` | `~/.npm/_cacache` | `npm cache clean --force` |
| `pnpm` | `~/Library/pnpm/store` | `pnpm store prune`（未参照パッケージのみ） |
| `uv` | `~/.cache/uv` | `uv cache clean` |
| `pip` | `~/Library/Caches/pip` | `python3 -B -m pip cache purge` |
| `cargo` | `~/.cargo/registry/cache`、`~/.cargo/registry/src` | この2ディレクトリのみ削除。`index`・`bin` は保持 |
| `deno` | `~/Library/Caches/deno` | `deno clean --help` が成功すれば `deno clean`、未対応版では対象ディレクトリを削除 |
| `mise` | `~/Library/Caches/mise`、`~/.local/share/mise/installs` | `mise prune --yes` と `mise cache clear`。事前プレビューに警告・失敗があれば prune はスキップ |
| `xcode` | `~/Library/Developer/Xcode/DerivedData`、`~/Library/Developer/CoreSimulator/Devices` | DerivedData の中身のみ削除。`xcrun --find simctl` が成功する場合のみ、標準 device set を指定して `simctl delete unavailable` |
| `browsers-test` | `~/Library/Caches/ms-playwright`、`~/.cache/puppeteer` | 再ダウンロード可能な自動テスト用ブラウザを削除 |
| `app-caches` | LINE・UTM・wallpaper aerials・Claude・Codex・`~/.codex/cache` の固定32パス | 許可リストの各ディレクトリの中身だけ削除。ChatGPT 起動中は Codex の17パスを deferred として保留 |
| `user-caches` | `~/Library/Caches` 直下の各エントリ | ディレクトリの中身を削除し、エントリ自体は保持。通常ファイルはそのファイルを削除。下記除外あり |
| `dot-cache` | `~/.cache` 直下の各エントリ | エントリごと削除。下記除外あり |
| `huggingface` | `~/.cache/huggingface` | **既定無効**。`--only` に明示した場合だけ削除 |
| `repo-artifacts` | 既定 `~/Repos` 配下の条件に合う成果物ディレクトリ | **既定無効**。`--only` に明示し、更新日時・Git 追跡の条件を満たしたものだけ削除 |
| `logs` | `~/Library/Logs` 配下 | `find -type f -mtime +14` に一致する通常ファイルのみ削除。ディレクトリは保持 |

ツールのキャッシュ先は、表に示す `$HOME` 基準のパスを CLI 引数・環境変数で指定する。独自のキャッシュ設定先へ自動追従しないため、表示先と清掃先が一致する。mise も表の標準 data/cache ディレクトリを使用する。Homebrew 自身が管理するインストール先の旧版清掃は純正コマンドに委ねるため、`$HOME` 外にある Homebrew prefix にも作用する。

`user-caches` からは `com.apple.*`、`Homebrew`、`pip`、`deno`、`ms-playwright`、`pnpm`、`mise`、`com.anthropic.claudefordesktop`、`Codex`、`com.openai.codex` を除外する。最後の3つは `app-caches` が担当し、二重計上と保留・除外の迂回を防ぐ。`dot-cache` からは `codex-runtimes`、`huggingface`、`uv`、`puppeteer`、`mise` を除外する。カテゴリを `--skip` しても、一般キャッシュ経由で削除されることはない。旧配置の `.cache/mise` も保護するが、このスクリプトでは清掃しない。`CloudKit`・`FamilyCircle` など macOS が保護していて中身を列挙できないエントリは自動でスキップし、1エントリの削除失敗は警告にとどめて残りの清掃を続ける。

### アプリキャッシュ（app-caches）

旧 mac-maintain の許可リスト32パスを維持し、`$HOME` 基準で解決する。LINE 3パス・UTM 1パス・wallpaper aerials 1パス・Claude 10パス・Codex 17パスが対象。`mactl clean --deep --only app-caches` で全パスを表示でき、未作成パスと保留パスも表示する。Codex保留中のパスは容量合計に含めない。アプリのデータディレクトリ全体は削除せず、既存の `cleanup contents` とパス安全検証を通す。シンボリックリンクは親階層も含めてスキップする。

### リポジトリ内の成果物（repo-artifacts）

探索ルートは既定で `$HOME/Repos`。環境変数 `MAC_CLEANUP_REPO_ROOTS` にコロン区切りの絶対パスを指定すると置き換える。全要素を既存の `safe_path` で検証するため、空要素・`$HOME` 外・曖昧なパスは拒否し、シンボリックリンクを含むルートはスキップする。存在しないルートは対象なし。探索ルートが重複していても同じ成果物を二重計上しない。

```bash
MAC_CLEANUP_REPO_ROOTS="$HOME/Repos:$HOME/work" ./cleanup/mac-cleanup.sh --only repo-artifacts
```

| 成果物ディレクトリ名 | 直上の親に必要なファイル |
| --- | --- |
| `node_modules`、`.next`、`.nuxt`、`.turbo`、`.parcel-cache`、`.svelte-kit` | `package.json` |
| `target` | `Cargo.toml` |
| `.venv` | `pyproject.toml` / `requirements.txt` / `setup.py` / `uv.lock` のいずれか |

`dist`・`build` はソースや追跡ファイルの可能性があるため削除対象外。探索は `find -P` でリンクを辿らず、条件に合う成果物と `.git` は `-prune` で内部に降りない。

各成果物の親をプロジェクトとして、その配下の通常ファイルの最新 mtime を調べる。上表の条件に合う成果物（入れ子も含む）と `.git` は更新判定から除外し、`dist`・`build` や条件ファイルのない同名ディレクトリは除外しない。最新 mtime が処理開始時点から `N × 24時間` より前の場合だけ対象にする。`--older-than-days N` は0以上の整数のみ受け付け、既定30、繰り返し指定時は最後の値を使う。他カテゴリには影響しない。最近の更新があれば `skip: 最近更新(N日以内)` を表示する。0でも処理開始時刻以降の mtime はスキップする。判定対象の通常ファイルがなければ日数条件は通過する。

Git 作業ツリーを確認できないプロジェクトは理由を表示してスキップする。さらに各成果物に対して `git -C <親> ls-files -- <dir>` を実行し、追跡ファイルがあればスキップする。Git がない場合、追跡確認の失敗、更新日時の取得失敗は警告付きでスキップする。探索自体が失敗した場合はカテゴリ全体の処理を止める。dry-run では対象パスのサイズとプロジェクトごとの見込み合計を表示し、全体の合計にも算入する。削除は他カテゴリと同じ `cleanup()` のみを通る。

更新日時は未使用の目安であり、ファイルを書き換えずに利用中のプロジェクトまでは判別できない。実行時はビルド・開発サーバー・仮想環境の利用を終了する必要がある。

## 表示と見込み量

`du -skP` の割当済み容量を KiB / MiB / GiB に換算し、各パスと合計を表示する。存在しないパスは 0、読めないパスは警告を出して合計未算入とする。`logs` は年齢条件に合うファイルだけを測定する。`-mtime +14` は find の日数切り捨てに従うため、厳密な「現在から14日前」より古い側に寄る。

合計は**測定できたキャッシュ等の現在サイズを足した削減上限の目安**であり、確定した空き容量増加ではない。特に pnpm は store 全体を表示するが、削除するのは未参照分だけ。mise のインストール済みランタイム全体は参考表示にとどめ、合計に含めない。Homebrew のインストール先にある旧版と、利用不能なシミュレータの削減量も未算入。APFS の共有ブロック・スナップショット、ハードリンク、使用中ファイルの影響も受ける。

dry-run の Homebrew はサイズ表示のみ。mise は `mise prune --dry-run` の出力も表示する。実行後の空き容量は、`--apply` 時に表示される `df -h /System/Volumes/Data` の前後比較で確認する。カテゴリ単位の処理に失敗しても次へ進み、末尾にスクリプトの警告件数を表示する。部分的な失敗では終了コード 0 のままなので、警告出力も確認する。

## 安全対策と制約

- 削除操作は `cleanup()` に集約し、`--apply` がなければ直ちに戻る。dry-run では清掃コマンド、削除用 `find`、一時ファイルの作成は実行しない。pip の存在確認と mise のプレビューは macOS の `sandbox-exec` でファイルシステムへの書き込みを禁止する。pip は Python の bytecode 書き込みも無効化し、mise shim のランタイム自動インストールも無効化する。
- `sandbox-exec` が存在しない、または別のサンドボックス内で実行されて保護を開始できない場合、外部ツールの確認を無保護で再試行しない。この場合 pip の確認はスキップ、mise はサイズのみ表示して警告とする。通常の macOS ターミナルで実行することを想定する。
- 削除前に空パス、相対パス、`$HOME` 自体、`$HOME/` 外、`..`・`.`・重複スラッシュを含む曖昧なパスを拒否する。安全検証の失敗はカテゴリのエラー捕捉を通り越して即時中断する。
- 対象または親ディレクトリがシンボリックリンクならスキップする。`find -P`・`du -P` はリンクを辿らず、手動の再帰削除も内部リンクの参照先には進まない。対象ディレクトリ内のリンクそのものは、ディレクトリごとの削除に伴って消える場合がある。
- 中身の列挙は NUL 区切りの `find` で行い、隠しファイル・空ディレクトリ・空白や改行のあるファイル名に対応する。ログの年齢条件は削除直前にも確認する。
- 既定の探索先では `~/Downloads`、`~/Documents`、ゴミ箱、Cursor snapshots、アプリの `Application Support`（`app-caches` の固定許可リストを除く）、Xcode `Archives` は対象外。`repo-artifacts` の探索先を上書きすると指定先に上記の成果物判定を適用する。`huggingface` のモデルは再取得が重いため明示選択が必要。
- `app-caches` の Codex だけは `ps -axo ucomm=` の `ChatGPT` を検出して保留する。他のアプリの起動状況は自動判定しない。**アプリ起動中なら終了してから `--apply` 推奨**。ファイルの生成やパスの差し替えと同時に実行する用途は想定しない。清掃後は依存パッケージ・テスト用ブラウザ等の再取得が必要になる場合がある。
- mise の未使用判定は mise が追跡している設定に依存する。lockfile 等の解決警告が出た場合は prune を止め、キャッシュ清掃だけを試みる。未追跡プロジェクトやコマンドラインでのみ使うバージョンの必要性まで、このスクリプトでは判定しない。

## 検証

構文・カテゴリ一覧・アプリ許可リストは次で確認できる。削除は行わない。

```bash
bash -n cleanup/mac-cleanup.sh
# shellcheck が PATH にある場合のみ
shellcheck cleanup/mac-cleanup.sh
bin/mactl clean --deep --list
bin/mactl clean --deep --only app-caches
```

コマンドの仕様は [mise prune](https://mise.jdx.dev/cli/prune.html)、[mise のディレクトリ構成](https://mise.jdx.dev/directories.html)、[pnpm の storeDir](https://pnpm.io/settings#storedir)、[deno clean](https://docs.deno.com/runtime/reference/cli/clean/) を参照。
