---
source_sha256: f2fc66817b4de63dd2d3fa3ee4cdba0c25960cae6ec4de300b2cc3d671220cf2
---
# インストール

CyberTrain が手元のマシンに必要とするもの、`cybertrain` コマンドのインストール方法、そのすべてのコマンド、そしてこのコマンドが Spinel とフレームワークをどのようにインストールしてくれるかを説明します。

> [!NOTE]
> 何もインストールせずに CyberTrain を試すには、[プレイグラウンド](site:playground.html)を開いてください：GitHub Codespaces が、チュートリアルのブログ、`cybertrain` コマンド、Spinel `2026.10.27.7020` を、ブラウザーの中の VS Code で開きます。同じイメージは Docker を使ってローカルでも動きます。

## 必要なもの

- Spinel `2026.10.27.7020`（`Cybertrain::SPINEL_TAG`。[.github/workflows/ci.yml](../../.github/workflows/ci.yml) の `SPINEL_TAG` と同じリリース）。[saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)（`Cybertrain::SPINEL_REPOSITORY`）のリリースで、CyberTrain が必要とする修正を本家のリリースより先に取り込んだ matz/spinel のフォークです。他のバージョンでは未テストです。手動でインストールする必要はありません：`cybertrain` コマンドが、初めて必要になったときにそのリリースを `~/.cybertrain` にビルドします（`cybertrain setup` は求めに応じてそれを行います）。ただし、そのリリースの `spinel` がすでに `PATH` 上にある場合は除きます — [Spinel のインストールの仕組み](#how-spinel-is-installed)を参照してください。
- そのビルドには：C ツールチェーン（`cc`、または `CC` で指定したコンパイラ）と `make` — Spinel はすべてのプログラムを C にコンパイルします — さらに `git` と `curl`。
- SQLite 3 のヘッダーとライブラリ（Debian/Ubuntu では `libsqlite3-dev`。macOS では Xcode のコマンドラインツールに含まれています） — モデルは gem ではなく、Spinel の FFI を直接使います。
- zlib のヘッダーとライブラリ（Debian/Ubuntu では `zlib1g-dev`。macOS では SDK に含まれています） — gzip されたリクエストボディ（`request.decoded_body`）は、同じ方法でバインドしたシステムの zlib で展開されます。
- Ruby 3.2+ と RubyGems。`cybertrain` コマンドのためだけに必要です（アプリケーションが CRuby 上で動くことはありません）。Ruby 3.2 では、Spinel のビルドに `prism` gem も必要です（下記）。

`cybertrain doctor` はこれらのツールとヘッダー、Spinel のインストールを確認します。必要なものが欠けている場合は、プラットフォームに応じたインストールコマンドも表示します。

<details><summary>その他のパッケージ — Ruby 3.2 での prism、どちらも任意の OpenSSL と jemalloc</summary>

- Spinel のビルドには Ruby の `prism` gem が必要で、Ruby 3.3 以上には同梱されています。Ruby 3.2 では `gem install prism` を実行します（Ruby の開発用ヘッダーが必要です。Debian/Ubuntu なら `ruby-dev`）。`cybertrain doctor` が確認します。
- OpenSSL のヘッダー（`libssl-dev`）は任意です：ない場合、Spinel は `openssl` パッケージなしでビルドされますが、CyberTrain はこのパッケージを使いません。macOS で `openssl` を require するアプリケーションには、コンパイラのパス上に Homebrew の（keg-only の）OpenSSL が必要です：`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`。
- jemalloc の開発用パッケージ（`libjemalloc-dev`、`brew install jemalloc`）は任意です：アプリがこれを必要とするのは、その `spin.toml` に `allocator = "jemalloc"` と書いたときだけで、`cybertrain new` はこの行をコメントアウトして書き出します。本番環境では有効にする価値があります：examples/blog で毎秒のリクエスト数が 1.1〜1.4 倍になります（[docs/benchmark.md](../benchmark.md)）。

</details>

## CLI をインストールする

```shell ターミナル — 任意のディレクトリ
gem install cybertrain
cybertrain doctor
```

1 行目で RubyGems からコマンドをインストールし、2 行目で[必要なもの](#requirements)を確認します。そこから先は、`cybertrain new` から `cybertrain build` まで、[チュートリアル](tutorial.md#install)が続けます。

## `cybertrain` コマンド

`cybertrain help` はこれらのコマンドを表示します：

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` は NAME にアプリケーションを作成し、その中で `spin lock` と `spin run gen` を実行します。必要なら先に Spinel をインストールします。
- `cybertrain generate scaffold NAME field:type ...`（エイリアスは `g scaffold`）は、カレントディレクトリのアプリケーションにリソースを追加します。
- `cybertrain generate authentication` は、そのアプリケーションにメールアドレスとパスワードによるサインインを追加します：users と sessions のテーブル、`User` と `Session` のモデル、サインインとサインアップのコントローラーとビュー、ルート、`ApplicationController` の `before_action`、そしてテストです（[サインインを追加する](tutorial.md#authentication)を参照）。`--invite-only` を付けるとサインアップのページはありません：ユーザーは `./NAME user EMAIL` で作成し、ユーザーがまだいない間は、最初のユーザーを `/setup` ページでも作成できます。このページはサーバー自身のマシンにだけ応答し、起動時の警告が表示するワンタイムトークンを必要とします。
- `cybertrain generate attachment MODEL FIELD [--any]` は、スキャフォールド済みのモデルにファイルアップロードを追加します：5 つのメタデータカラム、モデルのメソッドとコールバック、ダウンロードのアクション、ルート、フォームのフィールド、そしてテストです（[カバー画像を追加する](tutorial.md#attachments)を参照）。スキャフォールドのフィールド `cover:attachment` も同じことを行います。
- `cybertrain db migrate` は生成を行い、未適用のマイグレーションを適用して、もう一度生成します（`spin run gen; spin run db -- migrate; spin run gen`）。`cybertrain migration` もエイリアスとして残されています。
- `cybertrain db COMMAND...` は `spin
  run gen` の後に、その他のデータベースコマンドを実行します：`status`、`rollback [N]`（実行後にもう一度生成します）、`schema:dump`、`create`。
- `cybertrain server [PORT]` は生成を行ってから開発サーバーを起動します（`spin run gen; spin run NAME`、または `spin run NAME -- PORT`。デフォルトのポートは 3000）。
- `cybertrain build` は `app/views/` を埋め込んで NAME をビルドし、`dist/`（バイナリ、`public/`、`storage/`、`tmp/`）を組み立てます。
- `cybertrain spin ARGS...` は、固定された Spinel で `spin` を任意のディレクトリから実行します（`cybertrain spin test`、`cybertrain spin run gen -- --check`）。
- `cybertrain setup [--force]` は Spinel `2026.10.27.7020` を `~/.cybertrain` にインストールします（そのリリースの `spinel` がすでに `PATH` 上にある場合を除く）。`--force` は `~/.cybertrain` 以下のコピーを再ビルドします。
- `cybertrain doctor` は C ツールチェーン、SQLite のヘッダー、Spinel のインストールを確認します。
- `cybertrain version` はバージョンを表示します。

`db`、`server`、`build` はアプリケーションの中で実行します。NAME はそのアプリケーションの `spin.toml` にある `[package] name` です。

## Spinel のインストールの仕組み

`spin` を実行するすべてのコマンド（`new`、`db`、`server`、`build`、`spin`）は、まず `Cybertrain::SPINEL_TAG` のリリースの Spinel が使えることを確かめます。`PATH` 上の `spinel`（`spin` を伴うもの）の `spinel --version` がそのリリースを報告すれば、それをそのまま使います。そうでなければ、`cybertrain` が `~/.cybertrain/spinel/2026.10.27.7020/` 以下に置いているコピーを使います。それもなければ、`cybertrain` が `Cybertrain::SPINEL_REPOSITORY` のリリースタグからそのコピーをビルドします（`git clone`、`make deps`、`make -j`、`make install PREFIX=...`）。ビルドは一度だけで、数分かかります。ビルドのログは `~/.cybertrain/log/spinel-2026.10.27.7020-build.log` です（手順が失敗すると、その最後の数行が表示されます）。

ビルドに必要なツールが欠けている場合、`cybertrain` はビルドを始める前に、どれが足りないかを伝え、プラットフォームに応じたインストールコマンドを表示します。`PATH` 上にある別リリースの `spinel` が使われたり変更されたりすることはありません：`cybertrain` は自前のコピーを持ちます（そしてインストールするときにそう伝えます）。

`cybertrain setup` は同じことを求めに応じて行います。さらに、自前のコピーが使われている場合は、`spin` を自分で実行するために、それを `PATH` に加える行を表示します：

```shell ターミナル — 任意のディレクトリ
export PATH="$HOME/.cybertrain/bin:$PATH"
```

`~/.cybertrain/bin` には使用中のリリースを指す `spinel` と `spin` のリンクがあるので、リリースが上がってもこの行はそのまま使えます。`cybertrain spin ...` には `PATH` はまったく必要ありません。

<details><summary>環境変数 — `CYBERTRAIN_HOME` は `~/.cybertrain` を移し、`CYBERTRAIN_SPINEL_HOME` は既存のインストールを使う</summary>

2 つの環境変数がこれらすべてを上書きします：

- `CYBERTRAIN_HOME` は `~/.cybertrain` の代わりになります（スペース、引用符、`$`、`:` を含まないパスにします。Spinel の Makefile と `PATH` がこれらを扱えないためです）。
- `CYBERTRAIN_SPINEL_HOME=PREFIX` は既存のインストールを強制します：そのとき `cybertrain` は `PREFIX/bin` にある（`spinel` が `PREFIX` の直下にあれば `PREFIX` 自体にある）`spinel` と `spin` を使い、それらがそのリリースでなければエラーで停止します。

</details>

## gem とフレームワーク

`gem install cybertrain` がインストールするのはコマンドであり、フレームワークではありません。gem は `cybertrain` コマンドで、手元のマシン上で CRuby（3.2 以降）で動く素の Ruby であり、Spinel の `spin` ツールを代わりに呼び出します。フレームワークも Spinel も gem には含まれません。フレームワークは、アプリが `spin.toml` で依存する Spinel のパッケージです：Spinel がそれをあなたのコードと一緒に事前（AOT）コンパイルするので、CRuby 上で動くことはなく、出荷されるのはこの部分です。`dist/` のバイナリは Ruby、gem、Spinel なしで動きます。

### `cybertrain new` が書き出すもの

`cybertrain new` はアプリケーションを書き出し、その `spin.toml` は CLI と一致するリリースを指します（`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`）。次に Spinel がインストールされていることを確認し、`spin lock`（spin がフレームワークをキャッシュ `~/.cache/spin/packages/` に取得し、コミットを `spin.lock` に固定します）と `spin run gen` を実行します。`rails new` が `bundle install` を実行するのと同じようなものです。そして次の手順を表示します。フレームワークのファイルはアプリに一切コピーされません。`spin.toml` と `spin.lock` をコミットしてください。

Spinel のインストールか、2 つの `spin` ステップのいずれかが失敗した場合、ファイルは残したまま `new` は終了コード 1 で終了し、原因を解消した後に実行すべきコマンドを表示します（Spinel の場合：`cybertrain setup` を実行し、続いて新しいディレクトリで `cybertrain spin lock && cybertrain spin run gen`）。

4 つのオプションが、書き出すものと実行するものを変えます：

- `--skip-spin` はファイルを書き出すだけです：Spinel のインストールも、`spin lock` も、`spin run gen` も行いません。
- `--path DIR` は代わりにローカルのチェックアウトに依存します（CyberTrain 自体を開発するときは、チェックアウトのある場所に合わせて `--path ~/src/cybertrain`）。
- `--git URL [--ref R]` は URL にあるフレームワーク（ブランチまたはタグ R）に依存します。
- `--version V` は、フレームワークが `spin-index` に登録された後、インデックスのバージョンに依存します。

`--path`、`--version`、`--git` はひとつだけ指定してください。`--ref` には `--git` が必要です。

### アプリを新しいリリースに移行する

gem とフレームワークは同じタグからリリースされるため、バージョンは一致します：0.3.1 の gem は、フレームワーク `v0.3.1` に依存するアプリを書き出します。アプリを新しいリリースに移行するには、gem を更新し、`spin.toml` を新しいタグに向けてから、アプリの中で次を実行します：

```shell ターミナル — アプリのディレクトリ
cybertrain spin lock
cybertrain spin run gen
```
