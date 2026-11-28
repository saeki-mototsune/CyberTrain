---
source_sha256: cf1537dadb7e4793a3711c9c9304361844186be00b34e509c948a963e106c132
---
# インストール

CyberTrain が手元のマシンに必要とするもの、`cybertrain` コマンドのインストール方法、そのすべてのコマンド、そしてこのコマンドが Spinel とフレームワークをどのようにインストールしてくれるかを説明します。

> [!NOTE]
> 何もインストールせずに CyberTrain を試すには、[プレイグラウンド](site:playground.html)を開いてください：GitHub Codespaces が、チュートリアルのブログ、`cybertrain` コマンド、固定された Spinel のリリースを、ブラウザーの中の VS Code で開きます。同じイメージは Docker を使ってローカルでも動きます。

## 必要なもの

- Spinel の、`Cybertrain::SPINEL_TAG` のリリース（[cybertrain/version.rb](../../cybertrain/version.rb)。`cybertrain doctor` が表示し、[.github/workflows/ci.yml](../../.github/workflows/ci.yml) の `SPINEL_TAG` と同じリリース）。[saeki-mototsune/spinel](https://github.com/saeki-mototsune/spinel)（`Cybertrain::SPINEL_REPOSITORY`）のリリースで、CyberTrain が必要とする修正を本家のリリースより先に取り込んだ matz/spinel のフォークです。他のバージョンでは未テストです。手動でインストールする必要はありません：`cybertrain` コマンドが、初めて必要になったときにそのリリースを `~/.cybertrain` にビルドします（`cybertrain setup` は求めに応じてそれを行います）。ただし、そのリリースの `spinel` がすでに `PATH` 上にある場合は除きます — [Spinel のインストールの仕組み](#how-spinel-is-installed)を参照してください。
- そのビルドには：C ツールチェーン（`cc`、または `CC` で指定したコンパイラ）と `make` — Spinel はすべてのプログラムを C にコンパイルします — さらに `git` と `curl`。
- SQLite 3 のヘッダーとライブラリ（Debian/Ubuntu では `libsqlite3-dev`。macOS では Xcode のコマンドラインツールに含まれています） — モデルは gem ではなく、Spinel の FFI を直接使います。
- zlib のヘッダーとライブラリ（Debian/Ubuntu では `zlib1g-dev`。macOS では SDK に含まれています） — gzip されたリクエストボディ（`request.decoded_body`）は、同じ方法でバインドしたシステムの zlib で展開されます。
- OpenSSL のヘッダーとライブラリ（Debian/Ubuntu では `libssl-dev`） — どのアプリケーションもリンクします：セッション Cookie と `cookies.encrypted` は Spinel の `openssl` パッケージによる AES-256-GCM で、Spinel はヘッダーがあるときだけこのパッケージをビルドします。macOS では Homebrew のもの（`brew install openssl@3`）を入れ、keg-only なのでコンパイラのパスに加えます：`export LIBRARY_PATH="$(brew --prefix openssl@3)/lib"
  CPATH="$(brew --prefix openssl@3)/include"`。
- Ruby 3.2+ と RubyGems。`cybertrain` コマンドと、開発サーバーの CRuby プレビューに必要です。プレビューにはさらに Ruby の `fiddle` ライブラリが必要です（libffi が要ります）。`fiddle` がなければ、`cybertrain server` はコンパイル版のループだけを実行します。デプロイしたアプリケーションが CRuby 上で動くことはありません。Ruby 3.2 では、Spinel のビルドに `prism` gem も必要です（下記）。

`cybertrain doctor` はこれらのツールとヘッダー、`PATH` 上の `ruby` が `fiddle` を読み込めるかどうか、Spinel のインストールを確認します。必要なものが欠けている場合は、プラットフォームに応じたインストールコマンドも表示します（`fiddle` がないことは数えません：サーバーはコンパイル版で動くからです）。

<details><summary>その他のパッケージ — Ruby 3.2 での prism、任意の jemalloc</summary>

- Spinel のビルドには Ruby の `prism` gem が必要で、Ruby 3.3 以上には同梱されています。Ruby 3.2 では `gem install prism` を実行します（Ruby の開発用ヘッダーが必要です。Debian/Ubuntu なら `ruby-dev`）。`cybertrain doctor` が確認します。
- OpenSSL のヘッダーを入れる前にビルドした Spinel には `openssl` パッケージがなく、アプリケーションのビルドが失敗します。ヘッダーを入れたら `cybertrain setup --force` で作り直してください。同じパッケージが TLS（`require "cybertrain/net/tls"`）と暗号化されたカラム（`encrypts`）にも使われます。
- jemalloc の開発用パッケージ（`libjemalloc-dev`、`brew install jemalloc`）は任意です：アプリがこれを必要とするのは、その `spin.toml` に `allocator = "jemalloc"` と書いたときだけで、`cybertrain new` はこの行をコメントアウトして書き出します。本番環境で頼る前に自分のアプリで測ってください：examples/blog では、2026-10-09 の計測で動的なページの毎秒のリクエスト数が 1.3〜1.4 倍、最新の計測ではページで数 % の差（1 コアで POST は 18% 増）でした（[docs/benchmark.md](../benchmark.md)）。

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
  [--skip-spin]` は NAME にアプリケーションを作成し、その中で `spin lock` と `SPIN_DEBUG=1 spin run gen` を実行します。必要なら先に Spinel をインストールします（CLI は gen と `bin/db.rb` を spin のデバッグモードでビルドします）。
- `cybertrain generate scaffold NAME field:type ... [parent:references] [--any]`（エイリアスは `g scaffold`）は、カレントディレクトリのアプリケーションにリソースを追加します。`parent:references` のフィールドは `parent_id` カラムになり、`--any` は添付ファイルのフィールド（後述）に対するものです。
- `cybertrain generate authentication [--invite-only] [--confirmable] [--force]` は、そのアプリケーションにメールアドレスとパスワードによるサインインを追加します：users と sessions のテーブル、`User` と `Session` のモデル、`ApplicationController` が include する `Authentication` コンサーン、サインイン、サインアップ、パスワードリセット、アカウントのコントローラーとビュー、ルート、`require_admin` で保護されたジョブページ、`bin/<app>.rb` と `bin/db.rb` に必要なサブシステムの行、そしてテストです。`--invite-only` はサインアップのページを省き、`--confirmable` は新しいアカウントに、サインインの前にメールでアドレスを確認させます。もう一度実行したとき、変更されるファイルについては差分を表示するだけですが、`--force` を付けると上書きします（[認証](authentication.md)）。
- `cybertrain generate attachment MODEL FIELD [--any] [--show-checks-nothing]` は、スキャフォールド済みのモデルにファイルアップロードを追加します：5 つのメタデータカラム、モデルのメソッドとコールバック、ダウンロードのアクション、ルート、フォームのフィールド、そしてテストです（[カバー画像を追加する](advanced-tutorial.md#attachments)を参照）。スキャフォールドのフィールド `cover:attachment` も同じことを行います。ダウンロードは `def show` の中のコードを実行しないので、独自のコードを持つ `show` は、空にするか、`--show-checks-nothing` でそのコードが誰も制限しないと示さない限り拒否されます。`show` が行うチェックは、先に `before_action` に移します。
- `cybertrain generate helper NAME [--force]` は `app/helpers/NAME_helper.rb` とテストを追加します。このモジュールのメソッドは、`spin run gen` を実行すればどのテンプレートからも呼べます（[アプリケーションのヘルパー](template-language.md#application-helpers)）。
- `cybertrain generate component NAME [attr[:type] ...] [--force]` はビューコンポーネントを追加します：`app/components/NAME_component.rb`、そのテンプレート、そしてテストです（[コンポーネント](template-language.md#components)）。
- `cybertrain generate job NAME [--retry Klass:wait:attempts ...] [--force]` は `app/jobs/NAME_job.rb` とテストを追加し、`bin/<app>.rb` と `bin/db.rb` に `require "cybertrain/jobs"` を加えます（[バックグラウンド処理](background-and-operations.md#background-work)）。
- `cybertrain generate mailer NAME [action ...] [--force]` は、名前ごとにアクションを一つ持つメーラークラス `app/mailers/NAME_mailer.rb` とそのビューとテストを追加し、アプリケーションのメーラーとメーラーのレイアウトがなければそれも書き、`bin/<app>.rb` と `bin/db.rb` に `require "cybertrain/mailer"` と `require "cybertrain/mailer/later"` を加えます（[メーラークラス](external-services.md#mailer-classes)）。
- `cybertrain db migrate` は生成を行い、未適用のマイグレーションを適用して、もう一度生成します（`SPIN_DEBUG=1 spin run gen; SPIN_DEBUG=1 spin run db -- migrate; SPIN_DEBUG=1 spin run gen`）。`cybertrain migration` もエイリアスとして残されています。
- `cybertrain db COMMAND...` は `SPIN_DEBUG=1 spin
  run gen` の後に、その他のデータベースコマンドを実行します：`status`、`rollback [N]`（実行後にもう一度生成します）、`schema`（マイグレーションを行わず、いまのデータベースから `db/schema.rb` を書き出します）、`schema:dump`、`create`、`backup` と `vacuum`（[運用](background-and-operations.md#operations-backups-vacuum-health-check)）、`normalize`（[日時と `db normalize`](models.md#datetimes-and-db-normalize)）。
- `cybertrain server [PORT] [--spinel]` は開発サーバーを起動します（デフォルトはアプリケーションのポート、つまり `PORT` か `c.port`。どちらも設定していなければ 3000）。変更の直後はアプリケーションが CRuby で動き、その間に Spinel がバックグラウンドでビルドし、ビルドが成功するとコンパイル済みのバイナリがポートを引き継ぎます。アプリケーションのレスポンスには `X-Cybertrain-Runtime: cruby` か `spinel` が付きます（[開発ループ](how-it-works.md#the-development-loop)）。`--spinel` はコンパイル版のループだけを実行し、変更のたびにビルドを待ちます（`SPIN_DEBUG=1 spin run gen`。`build/bin/NAME` より新しい Ruby ファイルがあれば `spin build NAME -- --incremental`。`spin run NAME`、または `spin run NAME -- PORT`）。
- `cybertrain build` は `app/views/` を埋め込んで NAME をビルドし、`dist/`（バイナリ、`public/`、`storage/`、`tmp/`）を組み立てます。
- `cybertrain test [FILE|DIR ...] [-n NAME|-n /TEXT/]` は生成し、`test/` 以下のすべてのテストを 1 つのプログラムにコンパイルして（何かが変わったときだけ）実行し、引数が指定したテストだけを残します（[アプリをテストする](testing.md#running-the-tests)を参照）。
- `cybertrain spin ARGS...` は、固定された Spinel で `spin` を任意のディレクトリから実行します（`cybertrain spin test`、`cybertrain spin run gen -- --check`）。
- `cybertrain secret [--hex]` は `CYBERTRAIN_SECRET_KEY_BASE` 用の新しいランダムなシークレットを表示します。`--hex` を付けると `CYBERTRAIN_ENCRYPTION_KEY` 用の新しい鍵を表示します。どちらも 16 進数 64 桁です。
- `cybertrain setup [--force]` は固定された Spinel のリリースを `~/.cybertrain` にインストールします（そのリリースの `spinel` がすでに `PATH` 上にある場合を除く）。`--force` は `~/.cybertrain` 以下のコピーを再ビルドします。
- `cybertrain doctor` は[必要なもの](#requirements)にあるものをすべて確認します：`git`、`make`、`curl`、C コンパイラ、SQLite・zlib・OpenSSL のヘッダー、`prism` gem、Ruby が `fiddle` を読み込めるかどうか（CRuby プレビューに必要です）、Spinel のインストールです。
- `cybertrain version` はバージョンを、`cybertrain help` はこの一覧を表示します。

`generate`、`db`、`server`、`build`、`test` はアプリケーションの中で実行します。NAME はそのアプリケーションの `spin.toml` にある `[package] name` です。

## Spinel のインストールの仕組み

`spin` を実行するすべてのコマンド（`new`、`db`、`server`、`build`、`test`、`spin`）は、まず `Cybertrain::SPINEL_TAG` のリリースの Spinel が使えることを確かめます。`PATH` 上の `spinel`（`spin` を伴うもの）の `spinel --version` がそのリリースを報告すれば、それをそのまま使います。そうでなければ、`cybertrain` が `~/.cybertrain/spinel/<SPINEL_TAG>/` 以下に置いているコピーを使います。それもなければ、`cybertrain` が `Cybertrain::SPINEL_REPOSITORY` のリリースタグからそのコピーをビルドします（`git clone`、`make deps`、`make -j`、`make install PREFIX=...`）。ビルドは一度だけで、数分かかります。ビルドのログは `~/.cybertrain/log/spinel-<SPINEL_TAG>-build.log` です（手順が失敗すると、その最後の数行が表示されます）。

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

3 つ目の `CYBERTRAIN_KEEP_SRC=1` は、ビルドがクローンした Spinel のソース（`~/.cybertrain/src/spinel-<SPINEL_TAG>/`）を、ビルド後に削除せずに残します。

</details>

## gem とフレームワーク

`gem install cybertrain` がインストールするのはコマンドであり、フレームワークではありません。gem は `cybertrain` コマンドで、手元のマシン上で CRuby（3.2 以降）で動く素の Ruby であり、Spinel の `spin` ツールを代わりに呼び出します。フレームワークも Spinel も gem には含まれません。フレームワークは、アプリが `spin.toml` で依存する Spinel のパッケージです：Spinel がそれをあなたのコードと一緒に事前（AOT）コンパイルし、出荷されるのはこの部分です。`dist/` のバイナリは Ruby、gem、Spinel なしで動きます。アプリケーションのコードが、フレームワークも含めて CRuby でも動くのは開発時だけです：`cybertrain server` は、コンパイル済みのバイナリが引き継ぐまで、アプリケーションの CRuby プレビューを配信します。

### `cybertrain new` が書き出すもの

`cybertrain new` はアプリケーションを書き出し、その `spin.toml` は CLI と一致するリリースを指します（`cybertrain = { git =
"https://github.com/saeki-mototsune/cybertrain", ref = "vX.Y.Z" }`。X.Y.Z は `cybertrain version` が表示するもの）。次に Spinel がインストールされていることを確認し、`spin lock`（spin がフレームワークをキャッシュ `~/.cache/spin/packages/` に取得し、コミットを `spin.lock` に固定します）と `SPIN_DEBUG=1 spin run gen` を実行します。`rails new` が `bundle install` を実行するのと同じようなものです。そして次の手順を表示します。フレームワークのファイルはアプリに一切コピーされません。`spin.toml` と `spin.lock` をコミットしてください。`bin/<app>.rb` と `bin/db.rb` は、オプションのサブシステムを除いたフレームワーク `cybertrain/core` を require します。サブシステムが必要なジェネレーターは、その行を追加します（[サブシステム](how-it-works.md#subsystems)）。あわせて、AI コーディングエージェント向けの指示（アプリケーションが Rails と異なる点と、変更を完了とする前に実行するチェック）である `AGENTS.md` と、それを Claude Code に読み込ませる `CLAUDE.md` も書き出します。

Spinel のインストールか、2 つの `spin` ステップのいずれかが失敗した場合、ファイルは残したまま `new` は終了コード 1 で終了し、原因を解消した後に実行すべきコマンドを表示します（Spinel の場合：`cybertrain setup` を実行し、続いて新しいディレクトリで `cybertrain spin lock && SPIN_DEBUG=1 cybertrain spin run gen`）。

4 つのオプションが、書き出すものと実行するものを変えます：

- `--skip-spin` はファイルを書き出すだけです：Spinel のインストールも、`spin lock` も、`spin run gen` も行いません。
- `--path DIR` は代わりにローカルのチェックアウトに依存します（CyberTrain 自体を開発するときは、チェックアウトのある場所に合わせて `--path ~/src/cybertrain`）。
- `--git URL [--ref R]` は URL にあるフレームワーク（ブランチまたはタグ R）に依存します。
- `--version V` は、フレームワークが `spin-index` に登録された後、そこにあるリリース V に依存します（`cybertrain = "V"`）：[インデックスのバージョン](#an-index-version)を見てください。

`--path`、`--version`、`--git` はひとつだけ指定してください。`--ref` には `--git` が必要です。

### インデックスのバージョン

`spin-index` は、spin がパッケージの名前を引く一覧です。フレームワークはまだ登録されていません：登録されるまでは、`--version` で作ったアプリで `spin lock` を実行すると `not in the index: cybertrain` と返り、リリースに依存する方法は `new` が既定で書き出すタグです。登録された後は、`cybertrain new NAME --version X.Y.Z` が `cybertrain = "X.Y.Z"` を書き出し、spin がそのリリースのコミットをインデックスから見つけ、`spin.lock` はタグの場合と同じ 3 つ（バージョン、リポジトリ、コミット）を固定します。そのため、どのコマンドも、`new` が書き出す CI のワークフローも、既定の場合と同じように動きます。`Gemfile` から想像するものと違う点が 3 つあります：

- **リリースをひとつ指定します。** 制約を満たすリリースのうち、spin が選ぶのは最新ではなく最も低いものです：`"~> X.Y"` は、X.Y 以上で次のメジャーバージョン未満のリリースのうち、インデックスにある最も低いものです（X.Y の範囲にとどまるのは `"~> X.Y.Z"` だけです）。後のリリースが公開されても、それは変わりません。ですから、正確なバージョン、つまり `cybertrain version` が表示するものを書いてください。V がそれ以外のとき、`new` は注意を表示します。
- **Spinel は引き続き `cybertrain` コマンドが用意します。** インデックスの項目は Spinel のリリースを指定しません。フレームワークはひとつのリリース、つまり `cybertrain setup` がビルドするものに向けて書かれ、それでテストされていて、同じバージョンの `cybertrain` コマンドがそれをインストールします。別の Spinel でビルドするプロジェクトで `spin add cybertrain` だけを実行する使い方は、テストされていません。
- **spin はインデックスの手元のコピーを読みます。** spin はインデックスを一度だけ `~/.cache/spin/` にクローンし、`spin lock` はそのコピーを更新しません。`spin search cybertrain` は更新し、最新のリリースを表示します。

### アプリを新しいリリースに移行する

gem とフレームワークは同じタグからリリースされるため、バージョンは一致します：X.Y.Z の gem は、フレームワーク `vX.Y.Z` に依存するアプリを書き出します。アプリを新しいリリースに移行するには、gem を更新し、`spin.toml` を新しいタグに向けてから、アプリの中で次を実行します：

```shell ターミナル — アプリのディレクトリ
rm spin.lock
cybertrain spin lock
cybertrain spin run gen
```

`spin lock` は、git の依存について固定済みのコミットを、`spin.toml` の `ref` が何に変わっても保ちます。先にロックを消すのはそのためです。ほかにも依存があるアプリでは、代わりに `spin.lock` から `[lock.cybertrain]` のテーブルと `[lock.spinel-http]` のテーブル（フレームワークが依存する HTTP の層）だけを消せば、ほかの固定は残ります。

[インデックスのバージョン](#an-index-version)に依存するアプリに `rm` は要りません。その場合は `spin lock` が固定を動かすからです。まず `cybertrain spin search cybertrain` を実行して spin のインデックスのコピーを更新し、`spin.toml` の `cybertrain =` の行のバージョンを新しいリリースに変えてから、`cybertrain spin lock` と `cybertrain spin run gen` を実行します。

両者が一致していることは、コマンドが確認します。`server`、`build`、`db`、`test`、`generate` は、spin を実行したりファイルを書き出したりする前に、spin がビルドするフレームワークのバージョン、つまりアプリの `spin.lock` に固定されたバージョンを、コマンド自身のバージョン（`cybertrain version`）と比べます：アプリをコンパイルする Spinel のリリースを決めるのはアプリではなくコマンドであり、コマンドのテンプレートとジェネレーターは、同じリリースのフレームワーク向けに書かれているからです。バージョンが異なると、コマンドは終了コード 1 で止まります：

```text 出力 — cybertrain build
error: this application's framework is cybertrain X.Y.Z (spin.lock), but this cybertrain command is A.B.C.
The command decides the Spinel release, the templates and the generators, so the two must be the same version. Either
  gem install cybertrain -v X.Y.Z    # the command the application is on
or point the cybertrain dependency in spin.toml at A.B.C (ref = "vA.B.C"), then relock from nothing (spin lock keeps a locked git commit)
  rm -f spin.lock && cybertrain spin lock
```

どちらか一方を行ってください。`cybertrain spin ...` は確認の対象にならないので、`cybertrain spin lock` はいつでも実行できます。インデックスのバージョンに依存している場合、メッセージは `cybertrain = "A.B.C"` と `cybertrain spin lock` だけを示します。spin が固定されたリリースをビルドするのは `spin.toml` がそれを許している間だけなので、`spin.toml` が指すバージョンがロックと違えば、すぐにそのバージョンが比べられます。範囲（`"~> X.Y"`）が固定されたリリースを許さなくなった場合は、`cybertrain spin lock` を実行するまで拒否されます。フレームワークのチェックアウトに依存するアプリ（`path = ...`）は確認されません。`spin.lock` のないアプリは、`spin.toml` が指すリリース（`"X.Y.Z"` または `ref = "vX.Y.Z"`）と比べられます。ブランチ、コミット、範囲はリリースを指さないので、確認されません。

ロックし直すことは、アップグレードの 1 ステップです。手順の全体と、各リリースがアプリケーションに対して変えることは、[アップグレード](upgrading.md) にあります。
