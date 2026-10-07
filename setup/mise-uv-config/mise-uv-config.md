# mise/uvのバージョン管理構成

このMac(nbsさんの環境)の設定。プロジェクトのコードとは無関係。

## 何のためのものか

`mise`を唯一のツールチェーン管理者にし、その上で各言語のパッケージマネージャ(uv/npm/cargo)がライブラリ依存を管理する、という2層構成にしている。

```text
mise ── 「どのランタイム本体を使うか」(python/node/deno/rust/uv自体...)
  └─ npm/pnpm / uv / cargo ── 「どのライブラリ・パッケージを使うか」
```

唯一の穴: `uv`(Python)と`rustup`(Rust)は"自分でランタイム本体も管理できる"機能を内蔵しているため、miseの指定を無視して自分の管理下に逃げることがある。

| 言語/ツール | 自前バージョン管理機能 | 現状 |
| --- | --- | --- |
| Deno | 無し(`deno upgrade`は手動コマンドのみ) | miseが唯一の管理者。何もしなくて良い |
| Rust | あり(rustup + `rust-toolchain.toml`) | mise側が`RUSTUP_TOOLCHAIN`環境変数を強制exportしており、`rust-toolchain.toml`より優先度が高い。既に安全 |
| Python(uv) | あり(uv自前のPythonダウンロード機能) | このディレクトリの設定で対処 |
| Node(npm/pnpm) | あり(Corepack + `packageManager`フィールド) | 現状どのプロジェクトにも`packageManager`フィールドは無く、リスク未発生(将来注意) |

Python側の穴は2つの独立したグローバル設定で塞ぐ:

1. **`~/.zshrc`**(`mise activate zsh`の直後): `export UV_PYTHON_PREFERENCE=only-system`
   uvに「自前でPythonをDLするな、mise/システムが提供するPythonを使え」と指示する。
2. **`~/.config/mise/config.toml`**: `[settings] locked = true` / `idiomatic_version_file_enable_tools = ["python"]`
   これが無いと`.python-version`はmiseから完全に無視され、常にグローバル`[tools] python`の値にフォールバックする(値がたまたま一致していると誤動作に気づけない落とし穴)。これを足して初めて`.python-version`が唯一の情報源として機能する。

### エスケープハッチ(プロジェクト単位)

特定プロジェクトだけuv自前管理に戻したい場合、そのプロジェクトの`mise.toml`に以下を書けば、グローバル設定をそのプロジェクトだけ上書きできる(検証済み):

```toml
[env]
UV_PYTHON_PREFERENCE = "managed"
```

### バージョン解決の優先順位(現在の構成)

1. `--python X`(コマンド単発指定)
2. `mise.toml`の`[tools] python = "X"`(書けば最優先になるが、通常は書かない — 書くと`.python-version`と二重管理に逆戻りする)
3. `.python-version`ファイル(唯一の情報源、上記②の設定が前提)
4. ③が無ければ → システムpython

### バージョンを切り替えたい時の作法

```bash
mise install python@X.Y.Z   # 先にmiseへ実体を入れる(uvが自動でやってくれるわけではない)
uv python pin X.Y.Z          # .python-versionを書き換え
uv sync                       # .venvを自動で作り直す(rm -rf不要)
```

## 設置先とコード

```text
mactl/
  setup/mise-uv-config/
    mise-uv-config.md         → このファイル
    install-mise-uv-config.sh → 上記2箇所への設定投入を行うスクリプト
```

`~/.zshrc`と`~/.config/mise/config.toml`はどちらもこのマシン固有の他の内容(エイリアス・他ツールの`[tools]`バージョン等)と同居しているファイルなので、`setup/ai-agent-config/`のような全文コピー方式は使えない。代わりに:

- `~/.zshrc`は`mise activate zsh`の行を目印に、該当設定が未挿入なら直後へ挿入する(既にあれば何もしない)。挿入前に`.bak.<timestamp>`のバックアップを取る。
- `~/.config/mise/config.toml`は`mise settings set`コマンド経由で書く。これは`[settings]`テーブルだけを編集し、このマシン固有の`[tools]`テーブル(実際に入れているランタイムのバージョン)には触れない。

## 使い方

```bash
cd mactl
./setup/mise-uv-config/install-mise-uv-config.sh
```

mise自体は前提条件(このスクリプトはmiseを新規インストールしない)。`~/.zshrc`に`mise activate zsh`の行が無い場合はエラーで止まるので、先にmiseのセットアップを済ませてから実行する。

再実行しても安全(冪等)。既に設定済みの項目はスキップ/同じ値への再設定になるだけで、重複挿入や`[tools]`の破壊は起きない。

## 検証で分かった落とし穴

- `idiomatic_version_file_enable_tools`未設定だと`.python-version`は完全に無視される。前提条件を忘れると「動いているように見えて実は無視されている」事故が起きる。
- `mise activate`はshimではなくPATH直接書き換え方式。cdした対話シェルでのみ自動切り替わりが効く。非対話プロセス(CI・単発スクリプト実行)ではこの切り替えは発生しないので、その場合は明示的にPATHを通すか`mise exec`を使う。
- 新バージョンはuvが自動でmiseに依頼するわけではない。`mise install python@X`を先に叩く必要がある(uvは「PATH上に既にあるものを拾う」だけ)。
- `locked = true`環境で新規に`mise.toml`(pythonツールエントリ入り)を作ると、そのプロジェクト用`mise.lock`が無い限りエラーになる。`.python-version`方式ならこの問題自体を回避できる。
