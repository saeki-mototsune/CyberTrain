# CLI `migration` / `server` / `build`、単一エントリ、views の埋め込み

2026-09-26。ブランチ `gem-distribution` の上に積む。前提となる決定は
docs/design.md（D12: 開発ループ、実行時解釈テンプレート）と README「Installing the CLI」。

## 1. 目的

理想の開発体験を、`spin` のコマンドを覚えずに `cybertrain` だけで通す。

```sh
gem install cybertrain
cybertrain new blog; cd blog
cybertrain g scaffold article title:string
cybertrain migration
cybertrain server            # http://127.0.0.1:3000
cybertrain build             # dist/ ができる
scp -r dist/ server:blog/ ; ssh server 'cd blog && ./blog migrate && ./blog'
```

`build` の成果物は、ビュー（`app/views/`）をバイナリに埋め込み、`public/` は同梱した
ディレクトリ `dist/`。ビューのエラーは今と同じ `articles/show.html.erb:12: ...` の形で
報告される。

## 2. スコープ外

- クロスビルド。`dist/` はビルドしたマシンと同じ OS・アーキテクチャでしか動かない
  （`libsqlite3` に動的リンク）。本番は deploy.md どおりサーバー上で `cybertrain build` する。
- `public/` の埋め込み。画像やフォントは大きく、Spinel が吐く C の巨大配列はコンパイラを
  著しく遅くする。本番では Caddy 等が `public/` を直接返す構成が標準なので外部のまま。
- 単一ファイル配布。SQLite の DB と `storage/`、`tmp/secret_key` は外に置く。
- 既存アプリの自動移行。pre-alpha なので、`bin/server.rb` + `bin/db.rb` のアプリは手で
  `bin/<name>.rb` に置き換える（README に一文書く）。

## 3. アプリの入口を 1 つにする

`cybertrain new NAME` が生成する `bin/` は `NAME.rb` と `gen.rb` の 2 つ。
`server.rb` と `db.rb` は廃止。`examples/blog` も `bin/blog.rb` に揃える。

```ruby
# bin/blog.rb（テンプレート）
require "cybertrain"
require_relative "../gen/views"      # 埋め込み版は CYBERTRAIN_ENV の既定を production にする
require_relative "../config/app"     # ので、config より先に読む
require_relative "../gen/app"
require_relative "../gen/migrations"

exit(Cybertrain::Main.run("blog", ARGV,
  router: Gen::Routes.build(Cybertrain::Router.new),
  url_resolver: Gen::Routes.url_resolver,
  views: Gen::Views::SOURCES))
```

`Cybertrain::Main.run(name, argv, router:, url_resolver:, views:)` は終了コードを返す。

| argv | 動作 |
| --- | --- |
| （なし） / `server` | `Application.new(router:, url_resolver:, views:, name:).run` |
| `3000` / `server 3000` | 同上、ポート指定（数値だけの形は dev loop の execv が使う既存の約束） |
| `migrate` | `DB::CLI.run(["migrate"])` |
| `db ARGS...` | `DB::CLI.run(ARGS)`（`status`, `rollback 1`, `schema:dump`, `create`） |
| `help` / その他 | 使い方を出して 1 |

`name` は開発ループのためのもの。`Dev::Rebuilder` の target が `"server"` 固定だったのを
`name` にし、再ビルドは `spin run gen && spin build <name>`、execv 先は `build/bin/<name>`。
`gen.rb` は generator と routes/schema を読むビルド時専用ツールなので統合しない。

`Application.port_argument(ARGV)` は Main から渡される argv を見るよう引数化する。

### 3.1 修正（2026-09-26 実装時）

開発時のマイグレーションは `bin/db.rb`（cybertrain + config/app + gen/migrations だけを読む）で
走らせる。`cybertrain migration` は `spin run gen` → `spin run db -- migrate` → `spin run gen`、
`cybertrain db ARGS...` は `spin run db -- ARGS...`。理由: `bin/<name>.rb` は gen/app 経由で
コントローラとモデルを読み込むが、`gen/models/<model>.rb` はスキーマにテーブルができて初めて
生成されるため、scaffold 直後の最初のマイグレーションはこのバイナリではコンパイルできない。
`./<name> migrate` は本番用（schema がコミット済み）として残し、`dist/` の配布物は 1 バイナリのまま。

## 4. views の埋め込み

### 4.1 Engine

`Template::Engine.new(root, cache: true, sources: nil)`。`sources` は
`{ "articles/show.html.erb" => "<h1>..." }` の Hash（キーは `app/views/` からの相対パス、
今 `File.join(@root, key)` に使っているものと同じ）。

- `sources` があれば、`template(name)` は Hash から引き、`Template.parse(src, key, key)`。
  無ければ `MissingTemplate, "Missing template #{key} (embedded)"`。常にキャッシュする
  （mtime 検査はしない）。`exists?(name)` も Hash で判定。
- `sources` が nil なら今どおりディスク。
- エラー位置: parse/interpret の報告は今もキー（テンプレート名）と行番号なので不変。
  `Dev::ErrorPage` の解析も不変。

`Views.configure(root, cache:, sources: nil)` で渡す。

### 4.2 生成: `gen/views.rb`

`spin run gen` が常に `gen/views.rb` を書く。

- 引数なし: `Gen::Views::SOURCES = {}` の空テーブル。これがコミットされる状態。
  view 編集で `gen/` は汚れない。
- `--embed-views`: `app/views/**` の全ファイル（layouts、partial 含む）を、キーを
  ソートして `String#inspect` のリテラルで書く。UTF-8 で読む。
  加えて末尾に `ENV["CYBERTRAIN_ENV"] = "production" if (ENV["CYBERTRAIN_ENV"] || "").empty?`
  を書く。ビルド済みバイナリは既定で production、dev ビルドは既定で development になり、
  `dist/` を転送して `./blog` だけで正しいモードで上がる。
- Spinel が `inspect` リテラル（`\n`, `\"`, `\\`, `\#{`, `\uXXXX`）を CRuby と同じ
  バイト列に解釈することはスパイクで確認済み（60 バイト一致）。
- 空 Hash リテラル `{}` の型推論が通らない場合は `{ "" => "" }` ではなく
  `Hash.new` 等の代替を実装時に選ぶ（空テーブルの判定は `empty?`）。

`--check` は `gen/views.rb` も対象（空テーブルが期待値）。

### 4.3 起動時の選択（Application#boot）

- `config.production?` かつ `views` が空 → `abort "views are not embedded: build with `cybertrain build`"`
  で起動しない。暗黙のフォールバックはしない。
- `production?` → `Views.configure(root, cache: true, sources: views)`。
- それ以外（development / test）→ 今どおりディスク、`cache: !development?`。

`Application.new` の `views:` は既定 `{}` で、フレームワークのテストは変更なし。

## 5. CLI

`cybertrain/cli.rb` に 4 コマンド追加。アプリ名は `spin.toml` の `[package] name = "…"`
から正規表現で読む（無ければ「アプリのディレクトリで実行してください」で 1）。
`spin` の起動は `exec`（`server`）か `system`（それ以外）で、出力はそのまま流す。

| コマンド | 実行内容 |
| --- | --- |
| `cybertrain migration` | `spin run gen` → `spin run NAME -- migrate` → `spin run gen`。scaffold 直後に gen を 2 回叩く手間を吸収する |
| `cybertrain db ARGS...` | `spin run NAME -- db ARGS...` |
| `cybertrain server` | `exec spin run NAME` |
| `cybertrain build` | 下記 |

### 5.1 `cybertrain build`

1. `spin run gen -- --embed-views`
2. `spin build NAME`
3. `spin run gen`（空テーブルに戻す。2 が失敗しても必ず実行）
4. `dist/` を組み立てる: `dist/NAME` ← `build/bin/NAME`、`dist/public/` ← `public/` を丸ごと
   置き換え、`dist/storage/` と `dist/tmp/` は無ければ作る（中身は消さない。
   `storage/` には DB、`tmp/secret_key` には鍵が入りうる）。
5. 最後に案内を出す:
   ```
   dist/blog       (production by default)
   dist/public/
   run:  cd dist && ./blog migrate && ./blog
   ```

出力先を `build/` ではなく `dist/` にするのは、`build/` が spin の出力先
（`build/bin/gen`、`.mode` ファイル）で、転送物に中間物を混ぜないため。
`dist/` は `.gitignore` に足す（`new` のテンプレートと本リポジトリ）。

`build` の手順（コマンド列と dist の組み立て）は `Cybertrain::CLI::Build` に分け、
コマンド列の生成と dist の組み立てを spin 無しでテストできる形にする。

## 6. 変更対象

- 新規: `cybertrain/main.rb`、`cybertrain/cli/build.rb`、`cybertrain/generator/views_emitter.rb`
- 変更: `cybertrain/template/engine.rb`、`cybertrain/views.rb`、`cybertrain/application.rb`、
  `cybertrain/dev/rebuilder.rb`、`cybertrain/generator/runner.rb`、`cybertrain/cli.rb`、
  `cybertrain/cli/new_app.rb`、`cybertrain/cli/templates.rb`（bin テンプレート、README、
  .gitignore）、`cybertrain.gemspec`（`cli/build.rb` を追加）
- examples/blog: `bin/blog.rb`、`gen/views.rb`、README、`test/support/blog_test.rb`
- 文書: README（Walkthrough を新コマンドに）、docs/deploy.md（`spin run db -- migrate` と
  `build/bin/server` を `cybertrain build` と `dist/notes` に）、docs/design.md 第 13 章に追記
- CI: gem e2e を `cybertrain migration` と `cybertrain build` に、examples/blog の
  「Generated code is fresh」はそのまま（空テーブルが期待値）

## 7. テスト

- `test/template_embedded.rb`（新規）: `sources:` 付き Engine の render、partial、
  missing のメッセージ、`exists?`。CRuby スナップショット。
- `test/gen_views.rb`（新規）: 一時ディレクトリの `app/views` から `--embed-views` の
  出力と、引数なしの空テーブル出力。改行・引用符・日本語を含むファイルで。
- `test/main.rb`（新規）: `Main.run` のディスパッチ（help、unknown、`db` への引き渡し）。
- `test/cli_build.rb`（新規）: コマンド列と、偽のバイナリ・public からの dist 組み立て。
- 既存の更新: `test/cli_new.rb`（生成ファイル一覧）、Rebuilder を参照するテスト
  （target 引数）、`test/application.rb`（production で views 空なら abort）。
- e2e（手動 + CI）: `examples/blog` で `cybertrain build` → `cd dist && ./blog migrate &&
  ./blog` を production で起動し、curl で index と、壊したテンプレートのエラー行が
  ログに出ることを確認する。

## 8. 実装後の差分（as built, 2026-09-26）

- Engine は `sources:` キーワードではなく `Engine.embedded(sources)`、Views は
  `Views.configure_embedded(sources)` で埋め込み表を受け取る（Spinel で nil を取りうる
  キーワード引数を避けるため）。
- 開発時のマイグレーション用に `bin/db.rb` を残した（§3.1）。`cybertrain migration` は
  `spin run gen; spin run db -- migrate; spin run gen`、`dist/NAME migrate` は本番用。
- CLI は `exec` ではなく `system` で spin を呼ぶ。Ctrl-C で CRuby が `system` から上げる
  `Interrupt` は gem の入口 `exe/cybertrain` で受け、バックトレースなしで終了コード 130 に
  する（`Build.run` の `ensure` による空テーブルへの復元はその前に走る）。
- `cybertrain server [PORT]` は先に `spin run gen` を実行し、PORT があれば
  `spin run NAME -- PORT` で渡す（数字以外は `error: PORT must be a number`）。
- `gen/views.rb` に埋め込むのは `app/views/` 以下の `*.erb` だけ。ドットファイル・
  ドットディレクトリとシンボリックリンクのディレクトリは辿らず、改行・復帰・タブ以外の
  制御バイトは `\u00XX` で書く。
- `gen/views.rb` は開発ループの再ビルドの契機にならない（`Dev::IGNORED`）。
  以前は `cybertrain build` が書き換えると起動中の `cybertrain server` が再ビルドし、
  その `spin run gen` が埋め込み中の表を空に戻していた。ただし両者とも
  `build/bin/NAME` を書くので、配布用ビルドの前にサーバは止める（README に記載）。
