---
source_sha256: 921f35c9cb87db6ad7dffa5eeabb53f95a5a5d262cbb98ad67ad0ba1542ddfaa
---
# cybertrain をインストールする

## ブラウザーで試す

[GitHub Codespaces でプレイグラウンドを開く](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)と、何もインストールせずに cybertrain を試せます：ブラウザーで VS Code が開き、Spinel 2026.10.27.7020、`cybertrain` CLI、そして[チュートリアル](tutorial.md)のブログが作成済みの状態になっています（`cybertrain new blog`、記事のスキャフォールド、root ルート、最初のマイグレーション。サーバーがコンパイルなしで起動するよう、一度ビルド済みです）。開発サーバーはターミナルで動いており、アプリは記事一覧を表示した状態で新しいブラウザータブに開きます。アプリはコミットが 1 つの git リポジトリなので、変更した内容はソース管理に表示されます。アプリの `PLAYGROUND.md` には、ビューの編集から、ステップ 08（コメント）からのチュートリアルの続きまで、試せることが並んでいます。ビューの編集は次の再読み込みで反映されます。Ruby の編集は完全な再ビルド（約 1 分）になり、その後サーバーは自動で再起動しますが、アプリのタブは自動では再読み込みされません。そこでは `cybertrain new` がネットワークなしで動きます。

- GitHub アカウントが必要で、codespace は自分の Codespaces の利用枠で動きます：GitHub の無料プランには毎月 120 コア時間と 15 GB・月のストレージが含まれており、プレイグラウンドが使うデフォルトの 2 コアのマシンで約 60 時間分です。GitHub はデフォルトで、アイドル状態の codespace を 30 分後に停止します。ストレージは削除するまで利用枠に数えられます。
- このフォルダー内のファイルの作成者を信頼するかを VS Code が尋ねてきたら、「Trust Folder & Continue」を選んでください：サーバーのターミナルはそのとき初めて起動します。
- アプリのタブが開かなかった場合（ポップアップブロッカー、または codespace が停止して再起動した場合）は、VS Code のポート 3000 の通知かポートビューで「Open in Browser」をクリックするか、`server` ターミナルにあるアプリの URL を Ctrl キーを押しながらクリックします。それぞれの場所は `PLAYGROUND.md` に示されています。
- 同じイメージはローカルでも動きます（linux/amd64 向けに公開されています。arm64 ではチェックアウトからビルドしてください）：

  ```sh
  docker run --rm -it --init -p 127.0.0.1:3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  その後 http://localhost:3000 を開きます。[playground/README.md](../../playground/README.md) で、イメージ、そのビルド方法、Codespaces の設定を説明しています。

## 必要なもの

- Spinel `2026.10.27.7020`（`Cybertrain::SPINEL_TAG`。[.github/workflows/ci.yml](../../.github/workflows/ci.yml) の `SPINEL_TAG` と同じリリース）。[saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)（`Cybertrain::SPINEL_REPOSITORY`）のリリースで、cybertrain が必要とする修正を本家のリリースより先に取り込んだ matz/spinel のフォークです。他のバージョンでは未テストです。手動でインストールする必要はありません：`cybertrain` コマンドが、初めて必要になったときにそのリリースを `~/.cybertrain` にビルドします（`cybertrain setup` は求めに応じてそれを行います）。ただし、そのリリースの `spinel` がすでに `PATH` 上にある場合は除きます — [CLI をインストールする](#installing-the-cli)を参照してください。
- そのビルドには：C ツールチェーン（`cc`、または `CC` で指定したコンパイラ）と `make` — Spinel はすべてのプログラムを C にコンパイルします — さらに `git` と `curl`。
- SQLite 3 のヘッダーとライブラリ（Debian/Ubuntu では `libsqlite3-dev`。macOS では Xcode のコマンドラインツールに含まれています） — モデルは gem ではなく、Spinel の FFI を直接使います。
- zlib のヘッダーとライブラリ（Debian/Ubuntu では `zlib1g-dev`。macOS では SDK に含まれています） — gzip されたリクエストボディ（`request.decoded_body`）は、同じ方法でバインドしたシステムの zlib で展開されます。
- Ruby 3.2+ と RubyGems。`cybertrain` コマンドのためだけに必要です（アプリケーションが CRuby 上で動くことはありません）。Spinel のビルドには Ruby の `prism` gem も必要で、Ruby 3.3 以上には同梱されています。Ruby 3.2 では `gem install prism` を実行します（Ruby の開発用ヘッダーが必要です。Debian/Ubuntu なら `ruby-dev`）。`cybertrain doctor` が確認します。
- OpenSSL のヘッダー（`libssl-dev`）は任意です：ない場合、Spinel は `openssl` パッケージなしでビルドされますが、cybertrain はこのパッケージを使いません。macOS で `openssl` を require するアプリケーションには、コンパイラのパス上に Homebrew の（keg-only の）OpenSSL が必要です：`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`。
- jemalloc の開発用パッケージ（`libjemalloc-dev`、`brew install jemalloc`）は任意です：アプリがこれを必要とするのは、その `spin.toml` に `allocator = "jemalloc"` と書いたときだけで、`cybertrain new` はこの行をコメントアウトして書き出します。本番環境では有効にする価値があります：examples/blog で毎秒のリクエスト数が 1.1〜1.4 倍になります（[docs/benchmark.md](../benchmark.md)）。

`cybertrain doctor` はこれらのツールとヘッダー、Spinel のインストールを確認します。必要なものが欠けている場合は、プラットフォームに応じたインストールコマンドも表示します。

フレームワークには独立したテストランナーはなく、自分自身でテストします。`spin` は Spinel に付属しており、`cybertrain spin` は `cybertrain` がインストールしたコピーを `PATH` に触れずに実行します（または、`cybertrain setup` が表示する `export
PATH=...` の行でそのコピーを `PATH` に入れ、`spin` を直接呼び出します）：

```sh
cybertrain spin test
```

は `test/` 以下のすべてのプログラムをコンパイルして実行し、その出力をコミット済みのスナップショット `test/<name>.rb.expected` と比較します — minitest や RSpec は Spinel の下では動きません。テストメソッドをリフレクションで見つけるためで、AOT コンパイラには実行時にリフレクションする対象がありません。`cybertrain spin test
--regen test/<name>.rb` は CRuby での出力からスナップショットを書き直します。FFI 経由で SQLite に触れるいくつかのテストは、代わりにコンパイル済みバイナリからスナップショットを取ります（[spikes/NOTES.md](../../spikes/NOTES.md)、ルール 23）。`script/regen-snapshot
test/<name>.rb` がこのビルドしてから取り込む手順を代わりに行い、差分の統計を表示します。

## CLI をインストールする

```sh
gem install cybertrain
cybertrain new blog    # 初回は Spinel もインストール（数分）
cd blog
cybertrain g scaffold article title:string body:text
cybertrain db migrate
cybertrain server      # http://127.0.0.1:3000
cybertrain build       # 本番用: dist/
```

`cybertrain` コマンドは素の Ruby で書かれており、gem はこれを CRuby（3.2 以降）で実行します。フレームワークも Spinel も gem には含まれません。コマンドは次のとおりです（`cybertrain help` で表示されます）：

- `cybertrain new NAME [--path DIR | --version V | --git URL [--ref R]]
  [--skip-spin]` は NAME にアプリケーションを作成し、その中で `spin lock` と `spin run gen` を実行します。必要なら先に Spinel をインストールします。
- `cybertrain generate scaffold NAME field:type ...`（エイリアスは `g scaffold`）は、カレントディレクトリのアプリケーションにリソースを追加します。
- `cybertrain generate authentication` は、そのアプリケーションにメールアドレスとパスワードによるサインインを追加します：users と sessions のテーブル、`User` と `Session` のモデル、サインインとサインアップのコントローラーとビュー、ルート、`ApplicationController` の `before_action`、そしてテストです（[サインインを追加する](tutorial.md#authentication)を参照）。`--invite-only` を付けるとサインアップのページはありません：ユーザーは `./NAME user EMAIL` で作成し、ユーザーがまだいない間は、最初のユーザーを `/setup` ページでも作成できます。このページはサーバー自身のマシンにだけ応答し、起動時の警告が表示するワンタイムトークンを必要とします。
- `cybertrain generate attachment MODEL FIELD [--any]` は、スキャフォールド済みのモデルにファイルアップロードを追加します：5 つのメタデータカラム、モデルのメソッドとコールバック、ダウンロードのアクション、ルート、フォームのフィールド、そしてテストです（[ファイルアップロードを追加する](tutorial.md#attachments)を参照）。スキャフォールドのフィールド `cover:attachment` も同じことを行います。
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

`spin` を実行するすべてのコマンド（`new`、`db`、`server`、`build`、`spin`）は、まず `Cybertrain::SPINEL_TAG` のリリースの Spinel が使えることを確かめます。`PATH` 上の `spinel`（`spin` を伴うもの）の `spinel --version` がそのリリースを報告すれば、それをそのまま使います。そうでなければ、`cybertrain` が `~/.cybertrain/spinel/2026.10.27.7020/` 以下に置いているコピーを使います。それもなければ、`cybertrain` が `Cybertrain::SPINEL_REPOSITORY` のリリースタグからそのコピーをビルドします（`git clone`、`make deps`、`make -j`、`make install PREFIX=...`）。ビルドは一度だけで、数分かかります。ビルドのログは `~/.cybertrain/log/spinel-2026.10.27.7020-build.log` です（手順が失敗すると、その最後の数行が表示されます）。ビルドに必要なツールが欠けている場合、`cybertrain` はビルドを始める前に、どれが足りないかを伝え、プラットフォームに応じたインストールコマンドを表示します。`PATH` 上にある別リリースの `spinel` が使われたり変更されたりすることはありません：`cybertrain` は自前のコピーを持ちます（そしてインストールするときにそう伝えます）。

`cybertrain setup` は同じことを求めに応じて行います。さらに、自前のコピーが使われている場合は、`spin` を自分で実行するために、それを `PATH` に加える行を表示します（`~/.cybertrain/bin` には使用中のリリースを指す `spinel` と `spin` のリンクがあるので、リリースが上がってもこの行はそのまま使えます。`cybertrain spin ...` には `PATH` はまったく必要ありません）：

```sh
export PATH="$HOME/.cybertrain/bin:$PATH"
```

2 つの環境変数がこれらすべてを上書きします：`CYBERTRAIN_HOME` は `~/.cybertrain` の代わりになり（スペース、引用符、`$`、`:` を含まないパスにします。Spinel の Makefile と `PATH` がこれらを扱えないためです）、`CYBERTRAIN_SPINEL_HOME=PREFIX` は既存のインストールを強制します — そのとき `cybertrain` は `PREFIX/bin` にある（`spinel` が `PREFIX` の直下にあれば `PREFIX` 自体にある）`spinel` と `spin` を使い、それらがそのリリースでなければエラーで停止します。

`cybertrain new` はアプリケーションを書き出し、その `spin.toml` は CLI と一致するリリースを指します（`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "v0.3.1" }`）。次に Spinel がインストールされていることを確認し、`spin lock`（spin がフレームワークをキャッシュ `~/.cache/spin/packages/` に取得し、コミットを `spin.lock` に固定します）と `spin run gen` を実行します。`rails new` が `bundle install` を実行するのと同じようなものです。そして次の手順を表示します。フレームワークのファイルはアプリに一切コピーされません。`spin.toml` と `spin.lock` をコミットしてください。Spinel のインストールか、2 つの `spin` ステップのいずれかが失敗した場合、ファイルは残したまま `new` は終了コード 1 で終了し、原因を解消した後に実行すべきコマンドを表示します（Spinel の場合：`cybertrain setup` を実行し、続いて新しいディレクトリで `cybertrain spin
lock && cybertrain spin run gen`）。

`--skip-spin` はファイルを書き出すだけです：Spinel のインストールも、`spin lock` も、`spin run gen` も行いません。`--path DIR` は代わりにローカルのチェックアウトに依存し、`--git URL [--ref R]` は URL にあるフレームワーク（ブランチまたはタグ R）に、`--version V` は cybertrain が `spin-index` に登録された後、インデックスのバージョンに依存します。`--path`、`--version`、`--git` はひとつだけ指定してください。`--ref` には `--git` が必要です。

cybertrain 自体を開発するときは、チェックアウトから CLI を実行し（`spin install` は `bin/cybertrain.rb` を `~/.local/bin/cybertrain` にビルドします。`ruby -I.
bin/cybertrain.rb` でも動きます）、`cybertrain
new NAME --path ~/src/cybertrain`（チェックアウトのある場所に合わせて）でそれに依存するアプリを作ります。
