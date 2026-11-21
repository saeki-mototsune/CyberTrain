---
source_sha256: 45a936279cc9a0eb9a65fd3141efb6218521a5d3bb4a7b17ee0efb2db4fe9659
---
# アップグレード

アプリケーションを新しい CyberTrain のリリースに移す方法です。手順はどのリリースでも同じです：以下の各節が 1 つのステップで、順番に並び、それぞれにコマンドと正しい結果の見え方があります。手順のほかに個々のリリースが求めることは [バージョンごとの注意点](#notes-by-version) にあります。

## 始める前に

いまアプリケーションが使っているリリースの上で、戻ってこられる状態から始めます：

```shell ターミナル — アプリのディレクトリ
git status --short
cybertrain version
cybertrain test
```

<!-- list: points -->
- `git status --short` が何も表示しないこと：すべてコミット済みなので、以降の各ステップがそれぞれ別の差分として見えます。
- `cybertrain version` は、コマンドのリリースを表示します。アプリケーションのリリースは、`spin.lock` の `[lock.cybertrain]` にある `version` です。この 2 つは同じで、違えば `cybertrain test` が止まります。
- `cybertrain test` が通ること。いま失敗するテストは、古いリリースの上で先に直します：後からでは、アップグレードが原因の失敗と見分けがつきません。
- 本番に今日のバックアップがあること（[運用：バックアップ、VACUUM、ヘルスチェック](background-and-operations.md#operations-backups-vacuum-health-check)）。リリースによっては、データベースに保存されているものが変わります。

何かを変える前に、移行先のリリースの注意点を読んでください。リリースを飛ばすアプリケーションは、間にあるすべてのリリースの注意点を古い順に読みます。

## 新しいコマンドをインストールする

gem とフレームワークは同じタグからリリースされ、各リリースは 1 つの Spinel リリースに向けて書かれていて、アプリケーションをそれでコンパイルします（[Spinel のインストールの仕組み](install.md#how-spinel-is-installed)）。そのため、アップグレードは新しいコマンドと、それがピン留めする Spinel から始めます：

```shell ターミナル — 任意のディレクトリ
gem install cybertrain -v X.Y.Z
cybertrain version
cybertrain doctor
cybertrain setup
```

`cybertrain version` は `cybertrain X.Y.Z` と表示します。`cybertrain doctor` の出力は、リリースとそのピンの行 `cybertrain X.Y.Z, pinned to Spinel SPINEL_TAG` で始まり、その Spinel がこのマシンにあれば `spinel    ok` の行があります。あれば、`cybertrain setup` は `nothing to install` と伝えます。このリリースでピンが動いていないときがそうです。なければ、`cybertrain setup` は新しい Spinel を `~/.cybertrain/spinel/<release>/` にビルドします。数分かかり、古いものはそのまま残り、`~/.cybertrain/bin` のリンクは新しいものを指すようになります。

spin を実行するコマンドは、最初に必要になったときに同じインストールを自分で行います。次のステップの `cybertrain spin lock` もその 1 つです。ここで `cybertrain setup` を実行して決まるのは、いつ待つかだけです。

## バージョンを変える

`cybertrain` コマンドは、フレームワークが自分と別のリリースであるアプリケーションを拒否します（[アプリを新しいリリースに移行する](install.md#moving-an-app-to-a-new-release)）。そのため、アプリケーションを 2 つのファイルでコマンドに合わせます：

1. `spin.toml`：`[dependencies]` の `cybertrain` の行が新しいタグを指すようにします（`ref = "vX.Y.Z"`）。
2. `spin.lock`：何もないところから書き直します：

```shell ターミナル — アプリのディレクトリ
rm spin.lock
cybertrain spin lock
```

`locked 1 package(s)` と表示され、`git diff spin.lock` は `[lock.cybertrain]` の新しい `version` と新しい `ref`（タグのコミット）を示します。`rm` をしないと、`spin lock` はロック済みのコミットをそのまま保ち、差分は空です。ほかの依存があるアプリケーションや、spin のインデックスのバージョンに依存するアプリケーションは、[アプリを新しいリリースに移行する](install.md#moving-an-app-to-a-new-release) のとおりにロックし直します。

`cybertrain new` が書いたファイルのうち 2 つにも、リリースが書かれています。アプリケーションにあれば変えてください：

<!-- list: points -->
- `Dockerfile`：`gem install cybertrain -v X.Y.Z`。イメージはそのコマンドでビルドされ、バージョンがロックされたものと違うと、その中の `cybertrain build` が止まります。
- `.github/workflows/ci.yml`：`setup-cybertrain@` の後のタグ（[継続的インテグレーション](testing.md#continuous-integration)）。

コマンドと `spin.lock` が一致するまで、`server`、`build`、`db`、`test`、`generate` は、spin を実行したりファイルを書いたりする前に、終了ステータス 1 と「`error: this application's framework is cybertrain A.B.C (spin.lock), but this cybertrain command is X.Y.Z.`」で止まります。`cybertrain spin ...` は検査されません。

## 再生成して差分を読む

`gen/` の生成コードはコミットされていて、新しいフレームワークのジェネレーターはそれを違う形で書くことがあります（[ビルド時のコード生成](how-it-works.md#build-time-code-generation)）：

```shell ターミナル — アプリのディレクトリ
SPIN_DEBUG=1 cybertrain spin run gen
git status --short gen/
git diff gen/
```

ジェネレーターは、変えたファイルごとに `wrote`、それ以外に `identical` と表示します。差分を読んでください：アプリケーションがコンパイルするコードのうち、そのリリースで変わった部分です。バージョンの注意点に「`spin run gen` の後で」とあるものは、このステップで済みます。差分が空なら、そのリリースはそこで何も変えていません。

ジェネレーターがアプリケーションのコードの何かを拒否するときは、何を拒否したかを伝えるメッセージとともに止まります。何を変えるかはリリースの注意点にあります。変えたらコマンドをもう一度実行してください。

## ジェネレーターをもう一度実行する

ジェネレーターが `app/`、`config/`、`test/` に書いたコードはアプリケーションのもので、`spin run gen` はそれに触れません。そうしたコードを最新にできるジェネレーターは、アプリケーションの中でもう一度実行します。いまのところ、それは `generate authentication` で、それを使っているアプリケーションが対象です：

```shell ターミナル — アプリのディレクトリ
cybertrain generate authentication > authentication.upgrade 2>&1
patch -p1 < authentication.upgrade
```

アプリケーションを生成したときのオプション（`--invite-only`、`--confirmable`）を渡してください。ジェネレーターは足りないファイルと、足りない列のマイグレーションを書き出し、違う内容で書くはずの既存のファイルには手を付けずに、それぞれ `manual` の行と差分を表示します。`patch -p1` がそれらの差分を適用します。自分で編集したファイルの差分は手で適用し、`manual` の行が「置き換えられた」と示すファイルは削除してください（[ジェネレーターをもう一度実行する](authentication.md#running-the-generator-again)）。

もう一度実行して `manual` の行が出なければ、このステップは完了です。そこで `authentication.upgrade` を削除します。ほかのジェネレーター（`scaffold`、`attachment`、`job`、`helper`、`component`）は新しいコードを書くだけです。以前に書いたコードについてリリースが変えることは、そのリリースの注意点に載っています。

## データベースをマイグレートする

```shell ターミナル — アプリのディレクトリ
cybertrain db migrate
cybertrain db status
```

`db migrate` は、ジェネレーターが足したマイグレーションごとに `== <version> <Name>: migrating` と表示して適用し、`db/schema.rb` と `gen/` のモデルを書き直します。その後 `db status` はすべての行で `up` を示します。フレームワークが持つテーブル（`cybertrain_jobs`）にマイグレーションは要りません：そのテーブルに最初に触れたプロセスが、足りない列を足します。

保存済みのデータの形式を変えるリリースは、注意点で `db` のコマンドを指定します。ここで開発用のデータベースに対して実行し、デプロイのときに本番のデータベースに対してもう一度実行します（[デプロイ](#deploy)）。そうしたコマンドは 2 回実行しても安全です。

## バージョンの注意点を適用する

[バージョンごとの注意点](#notes-by-version) にあるそのリリースの節を、トピックごとに確認します。各項目には、何が変わり、どう対応するかが書いてあります。アプリケーションが使っていないものについての項目は、何もしなくてかまいません。

ほとんどの項目は、次のステップでコンパイルエラーや失敗するテストとして見つかります。見つからないのは、保存済みのデータ、クッキー、ログなど、アプリケーションのコードの外にあるものについての項目です：ログを読むスクリプト、プロキシ、監視など。それらは読んで確認してください。

## テストを実行する

```shell ターミナル — アプリのディレクトリ
cybertrain test
cybertrain build
```

`cybertrain test` はテストを新しいフレームワークに対してコンパイルし、通ります。`cybertrain build` は、本番で動くバイナリ `dist/<app>` をビューを埋め込んでコンパイルします。新しいリリースが必須とする設定がないと、そのバイナリは起動時に、その設定の名前を含むメッセージとともに止まります。デプロイの前に、本番と同じやり方で一度起動してください（[本番のリハーサル](../deploy.en.md#2-6-a-production-rehearsal)）。

その後、各ステップが変えたものをすべてコミットします：`spin.toml`、`spin.lock`、`gen/`、`db/`、ジェネレーターのファイル、そして自分の編集です。

## デプロイ

次の順番で行います：

1. アプリケーションをビルドするすべてのマシンに新しいコマンドをインストールし（[デプロイのチュートリアル](../deploy.en.md#upgrading-the-framework) ではサーバー、Kamal では `Dockerfile`）、そこで `cybertrain setup` を実行します。コマンドと `spin.lock` が違うと、デプロイのビルドが止まります。
2. 注意点が挙げる設定とシークレットを環境に追加します（[設定と環境変数](configuration.md#configuration-and-environment-variables)）。
3. バックアップを取ります。
4. 注意点が求める場合は、最初の新しいプロセスが起動する前に、古いプロセス（`server`、`worker`、`feeds`）をすべて止めます（[プロセスの役割](background-and-operations.md#process-roles)）。
5. いつもどおりデプロイします：ビルド、`./<app> migrate`、注意点が指定する `db` のコマンド、そして新しいプロセスの順です。

戻すには、前のビルドに切り替えて再起動します（[ロールバック](../deploy.en.md#rolling-back)）。それでマイグレーションが巻き戻ることはなく、保存済みのデータを書き換えた `db` のコマンドも元には戻りません。古いリリースが書き換え後のデータを読めるとリリースの注意点に書かれていない限り、そうしたコマンドの後で戻すことは、ステップ 3 のバックアップをリストアすることを意味します。

## リリースごとに必要なステップ

どのリリースでも、すべてのステップを実行します。リリースがそのステップを必要としないときは、ほとんどがすぐに終わります。必要かどうかは各ステップ自身が示します：

| ステップ | することがないのは |
| --- | --- |
| 新しいコマンドをインストールする | コマンドは、なし。その Spinel は、`cybertrain setup` が `nothing to install` と伝えるとき |
| バージョンを変える | なし：どのリリースでも変わります |
| 再生成する | `git status --short gen/` が何も表示しないとき |
| ジェネレーターをもう一度実行する | 実行しても `manual` の行も `create` の行も出ないとき |
| マイグレートする | `cybertrain db status` に `down` の行がないとき |
| 注意点を適用する | そのリリースの節が下にないとき |
| テスト、デプロイ | なし |

パッチリリース（`X.Y.Z` から `X.Y.Z+1`）は互換性に関わる変更を含まず、注意点もありません。マイナーリリース（`X.Y` から `X.Y+1`）は含むことがあり、そのときは下に節があります（[互換性の契約](../compatibility.md#changing-a-contract)）。

## バージョンごとの注意点

この後の節には、手順のほかに各リリースが求めることを、新しい順に載せます。節の名前は前後 2 つのリリースで、中はトピックごとに分かれています。リリースの注意点はここにだけ書きます：各トピックのガイドはいまのフレームワークを説明し、上の手順はどのリリースの名前も挙げません。

## 0.4 から 0.5 へ

### 0.4 から：リクエスト

0.4 向けに書いたアプリで変わること：

- どのセッションも一度だけ終わります：暗号化した Cookie は以前の署名付きのものを読めないので、ユーザーはもう一度サインインします。`Session.load` や `Session.dump` を呼ぶコードは、導いた鍵 `Crypto.derive_key(secret, SessionStore::SESSION_KEY_LABEL)` を渡します。生の秘密鍵を渡すと `Encryptor::Error` になります。
- どのアプリも OpenSSL をリンクします（[インストール](install.md#requirements)）。以前の `cybertrain new` が書いた Dockerfile には、ビルド段に `libssl-dev`、実行段に `libssl3t64` が要ります。
- フォーマットを取るルートでは、動的セグメントが `.` を取り込まなくなりました：ドットを含む id のルートには `format: false` が要ります。
- 手で書いた `url_resolver` のラムダは三つの引数 `->(name, args, options)` を取ります。`Gen::Routes.url_resolver` を渡しているアプリは `spin run gen` だけで済みます。
- `params.permit` は `Hash{String => Object}` を返します：値を String として使う前に `Cast.str` か `.to_s` を呼んでください。
- `rate_limit` はキャッシュで数えます：`store: :memory` で以前のプロセスごとのカウンターになり、一つのコントローラーの二つの制限にはそれぞれの `name:` が要り、nil か `""` を返す `by:` のメソッドは例外を発生させ、何も描画しない `with:` のメソッドの後には 429 が続きます。
- 数値のヘルパーは、数でない値と、0 から 100 の範囲外の精度で例外を発生させます（nil はテンプレートでは従来どおり `""` になります）。
- コントローラーやモデルの `include A, B` は、Ruby と同じく B を先に include します。コンサーンでないモジュールの `include` は Ruby に任されます。
- すべての ETag が一度変わります（リクエストのフォーマットとビルドのダイジェストを含むようになったため）。`Accept` で決まった応答は `Vary: Accept` を送り、html のフォールバックは `text/html` か `*/*` を挙げるどの `Accept` にも働きます。html にフォールバックしうるリクエスト（`application/json, text/html`）は、そのフォーマットだけを求めるリクエストとは別の ETag を持ちます。`Accept` の `text/html;q=0` には、`*/*` が並んでいても html のフォールバックは働きません（html しかないアクションでは 406）。`If-None-Match: *` は、`last_modified:` だけで検証した応答からも 304 を受け取ります。
- `permit` と `expect` は、Array でないフィルターで `ArgumentError` を発生させます。存在しないレイアウトを指す `layout` は `MissingTemplate` を発生させます（既定の `application` レイアウトは省略可能なままです）。ジャーの Cookie が 4096 バイトを超えると `Session::CookieOverflow` を発生させます。
- `public/style.css` はそのまま動きます。`app/assets/stylesheets/` への移動は任意です（[アセット](assets.md#moving-publicstylecss)）。
- バリデーションメッセージは同梱の辞書から来ます（[国際化](i18n.md#models-and-validation-messages)）。英語の文面は同じですが、3 つだけ違います：`:base` のメッセージの頭に "Base" が付かなくなり、`_id` で終わる属性は "id" なしで呼ばれ（"Article id can't be blank" ではなく "Article can't be blank"）、長さの上限 1 は "1 character" になります。これらのメッセージを比べるテストは変わります。
- `format:` なし、または書式名つきの `time_tag` は `I18n.l` で整形されます（英語のページでは以前と同じ英語の文面です）。
- gen は `gen/locales.rb`（`config/locales/` がなければ空）を書き、`app/mailers/**/*.rb` を読み込みます。`cybertrain new` は `config/locales/en.yml` を書きます。古いアプリケーションも足せます。
- `allow_unauthenticated_access` はフレームワークのメソッドになりました。0.4 のジェネレーターが `ApplicationController` に書いたものも動き続け、そちらが優先されます。`cybertrain generate authentication` をもう一度実行すると、パスワードリセット、ロックアウト、ログインしたままにする、アカウントページ、管理者ユーザーが加わり、0.4 が書いたファイルの差分が表示されます（[0.4 から：認証](#from-04-authentication)）。

### 0.4 から：モデルとデータベース

以下の変更はどれも、CyberTrain 0.4 向けに書いたアプリケーションを一回で直せるものです：

1. `has_many` の読み出しは Array ではなくリレーションを返します：Array にしかないメソッド（`map`、`select`、`[]`、`+`）の前に `.to_a` を付けてください。テンプレートは変わりません。
2. 日時は Rails の形で保存されます：更新のあとで一度 `db normalize` を実行してください（[日時と `db normalize`](models.md#datetimes-and-db-normalize)）。それまでは、二つの形が混ざったカラムは形の順に並びます。
3. `as_json` と `to_json` は時刻を `2026-10-05T09:00:00.000Z` と書きます（以前は `2026-10-05T09:00:00Z`）：テストの JSON のスナップショットが変わります。
4. `t.date` の属性は String ではなく `Date` です：`strftime` はそのまま使え、連結には `to_s` が要ります。NOT NULL の日付カラムは存在を検証するようになりました。
5. `optional: true` のない宣言した `belongs_to` は外部キーを検証します。宣言していないものは変わりません。
6. Integer の端を持つ `where(x: a..b)` は範囲の条件です（以前は Range のテキストとの等値で、一致することはありませんでした）。Time と Date の端は `where_between` を使います。
7. `Cybertrain::Cast.iso8601` は表示用の形です：これで SQL のテキストを組み立てていたコードは `Cast.sql_datetime` に替え、`Cast.binds` は Time を保存用の形でバインドします。
8. `validates` の行の `allow_blank: true` は、Rails と同じく、その行の `presence` にも空の値を通させます（以前は `length` にだけ効きました）。
9. すべてのモデルが持つようになったメソッドと同じ名前のカラム（`update_columns`、`destroy_dependents`、`run_custom_validations` など）は `<column>_column` として生成されます（[カラム名](models.md#column-names)）。
10. `belongs_to` の読み出しは、外部キーが変わるまで読んだ親を覚えています（以前は呼ぶたびに読みました）：別のプロセスによる変更を見るには `reload` を呼んでください。

### 0.4 から：認証

0.4 が生成したアプリケーションで、`cybertrain generate authentication` をもう一度実行します（[ジェネレーターをもう一度実行する](#run-the-generators-again)）。

[test/fixtures/auth_04_app.upgrade.diff](../../test/fixtures/auth_04_app.upgrade.diff) は、0.4 が生成したサインアップ型のアプリケーションに対する出力の全体です。

<!-- list: points -->
- `ApplicationController` の 0.4 のブロックは `include Authentication` になります。`--force` がそれを置き換えるのは、0.4 が書いたとおりのままのときだけです。
- `--confirmable` では、sessions と registrations のコントローラーの差分に `IMPORTANT:` の行が付きます：適用するまで、未確認のアカウントはサインインできない理由を知らされず、サインアップしてもリンクがメールされません。0.4 のアプリケーションではコンサーンは新しいファイルで、確認の検査とともに書き出されるので、それらの差分が適用されなくても、未確認のアカウントにセッションを始めません（そして `WARN [<request id>] no session started: user <id> has not confirmed its address` をログに出します）。
- アップグレードの際、すべてのセッションは一度終わります（クッキーが暗号化されたため）。

### 0.4 から：設定

デフォルトのうち 2 つが 0.4 の後で変わりました（[設定と環境変数](configuration.md#configuration-and-environment-variables)）：

- レンダリングのネストは無制限でしたが、`max_render_depth`（デフォルトは 12）までになりました。パーシャルのツリーがより深いアプリケーション（スレッド形式のコメント、カテゴリーメニュー）は、この設定を引き上げるまでテンプレートエラーになります。
- `job_poll_interval` は 5 秒でしたが 1 秒になりました：ジョブは専用のスレッドで実行され、手の空いたスレッドは 1 秒ごとに仕事を探します。

### 0.4 から：ジョブ

- `cybertrain_jobs` に `concurrency_key` の列と `discarded` の状態が加わります。テーブルに最初に触れたプロセスが列を足します。状態を列挙するコード（`Job.state_count` を使うダッシュボード）は `discarded` を足してください。`Job.prune_done` が消すのは、これまでどおり `done` の行だけです。
- `every` のタスクは、再起動の後に最初からやり直すのではなく、時刻表から続きます。プロセスが止まっている間に過ぎた間隔は、起動時に 1 回実行されます。
- ジョブを実行するアプリケーションは、最初の新しいプロセスが起動する前に、古いプロセスをすべて止めます（[デプロイ](#deploy) のステップ 4）。0.4 は実行中のジョブのハートビートを書かないので、新しいプロセスはそのジョブを放棄されたものと見なしてキューに戻し、古いプロセスと並んでもう一度実行します。
- 既存の種類にキーを与えること（`limits_concurrency ... key:`）は、この停止を前提にしています。最初の新しいプロセスが、それ以前にキューに入った `queued` の行にキーを付けます（ペイロードにそのフィールドがない行の id はログに出します）。古いプロセスが残した `running` の行は、回収されるときにキーが付きます。
- `jobs` は組み込みのコマンドになりました。`jobs` という名前のアプリケーションのコマンドは、名前を変えてください。

### 0.4 から：ログとエラー報告

- ログの行の形がすべて変わります。行頭の角括弧のレベル（`[INFO]`）が、時刻、レベル、タグに置き換わります：`2026-11-14T09:30:00.132Z INFO [<request id>] Completed 200 in 3ms`。ログを読むもの（スクリプトの `[ERROR]` の grep、アラート）も合わせて変えます。行を丸ごと探していたテストは、レベルとメッセージを別々に探します（`" ERROR "` とメッセージ。[0.4 から：テスト](#from-04-tests)）。
- アプリケーションが返すすべてのレスポンスが `X-Request-Id` を持ちます（サーバーが読めないリクエストに返す 400 と 413 は除きます）。それを付けていたプロキシの値は、プロキシが信頼されているときだけ使われます。
- `cybertrain_jobs` に `request_id` の列が増えます。最初にテーブルに触ったプロセスが足します。
- テキストのログ行は次の行に続かなくなりました。メッセージやタグの中の改行と復帰は `\n` と `\r` として書かれます。複数行のメッセージを数行から読んでいたものは、エスケープを読みます。
- `handle` という名前のモデルの列は `handle_column` として読むようになりました。`users.handle` の列を持つアプリケーションは、`user.handle` の呼び出しを `user.handle_column` に変えます（クエリは SQL の名前のままです）。テキストでない `request_id` や `release` の列は gen が拒否します（[列の名前](models.md#column-names)）。
- `cybertrain test` は、`config/app.rb` が設定していない限り、エクスポートされた `CYBERTRAIN_LOG_FORMAT` と `CYBERTRAIN_SENTRY_DSN` を無視します（テストはテキストの行を読み、何も送りません）。`generate authentication` が書くパスワードのテストは、`with_config` の中で JSON の行を止めるようになりました。テストを `log_format :json` で動かしている、以前に生成したアプリケーションは、ジェネレーターを再実行するか、その変更を写してください。
- `require "cybertrain"` は、Sentry の送信側を通じて `HttpClient` と TLS 層をリンクするようになりました。

### 0.4 から：テスト

- `test/test_helper.rb` を加え（[テストを書く](testing.md#writing-a-test)）、サポートファイルが読み込み時にしていたこと（`AppTest.boot`、`BlogTest.boot`、データベースのマイグレート）をそこから外してください：テストプログラムは最初のテストの前に新しいデータベースで起動し、2 回目の起動は時間がかかるだけです。
- CI のステップを `spin test` から `cybertrain test` に変えてください。
- 同じトップレベルのヘルパーや定数を定義する 2 つのファイル（0.4 のジェネレーターが書いたように、それぞれにある `new_client`）は一緒に拒否されます：ヘルパーを `test/support/` に移すか、どちらかの名前を変えてください。
- 各テストの前にすべてのテーブルが空になるので、あとのテストが前のテストの作った行に頼ることはもうできません：そのようなデータはフィクスチャか `setup` に移してください。
- 時計の差し込み口はなくなりました：`Cybertrain::Cache.clock=`、`Cache.system_clock`、`RateLimit.current_time=`、`SessionStore#fixed_now=`、`Application.status_now=`、`Background.supervisor_clock=`。`travel_to`、`travel`、`freeze_time` を使ってください。ブロックの形なら、自分で `ensure` を書かなくても時刻が戻ります。
- テストのメールは `Cybertrain::Mailer.deliveries` に保持されます。`Test::SmtpReceiver` でメールを読むテストは、先に `Cybertrain.config.mail_delivery_method = :smtp` を設定します。
- 0.4 の `generate helper` が書いたヘルパーのテストはトップレベルの `render_inline(source)` を定義しており、これはフレームワークのものとぶつかります：そのファイルの中で、呼び出しも含めて `render_helper_template` に名前を変えてください。
- `1.month.ago` は `Time.current.months_ago(1)` と書きます。
- `assert_equal` は Minitest の 2 行のテキストで失敗します。通るテストのスナップショットは変わりません。
- `cybertrain generate authentication` をもう一度実行すると、クラスの形のテストを書き出し、それらが置き換える古いファイル（`test/authentication.rb`、`test/support/app_test.rb` など）をそれぞれ示します。`--force` でそれらを削除します。
- 角括弧のレベルで始まるログの行を丸ごと探していたテストは、レベルとメッセージを別々に探します（`" ERROR "` と `"password reset mail not sent: "`）。行はいまは時刻で始まり、リクエストの ID を持つことがあります（[ログ](logs-and-errors.md#logs)）。
- エクスポートされた `CYBERTRAIN_LOG_FORMAT` や `CYBERTRAIN_SENTRY_DSN` はテストに届かなくなりました。それらでテストするには、`config/app.rb` で設定するか、テストで DSN を代入します。
