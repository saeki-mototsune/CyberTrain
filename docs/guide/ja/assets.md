---
source_sha256: 2ffd6596d62c339b9ae69a076e7d8aefbabe8f7fecc3d1ea104fb1bf3be7dd06
---
# アセット

Rails 8 と同じ配置のスタイルシート、画像、JavaScript：`spin run gen` がダイジェスト付きで `public/assets/` に書き出し、CSS の `url()` 参照を書き換え、マニフェストとインポートマップをバイナリにコンパイルします。タグヘルパーはダイジェスト付きのパスを書き、サーバーはそれを 1 年間キャッシュさせます。

## ソースと論理パス

```text app/
app/assets/stylesheets/application.css    application.css
app/assets/images/logo.svg                logo.svg
app/javascript/application.js             application.js
app/javascript/controllers/hello.js       controllers/hello.js
vendor/javascript/chart.js                chart.js
```

`app/assets/` の直下にあるディレクトリはそれぞれがルートで、`app/javascript/` と `vendor/javascript/` もルートです：ファイルの論理パスはそのルートより下のパス（上の右の列）で、ヘルパーが受け取る名前です。二つのルートに同じ論理パスがあると、`spin run gen` は両方のファイルを挙げて止まります。ドットファイル（`.keep`）とシンボリックリンクのディレクトリは飛ばします。シンボリックリンクのファイルは、そのツリーの中を指していれば読み、外を指すものやどこも指さないものがあれば gen は止まります。空白や制御文字を含むパスは拒否されます。別の CSS ビルド（Sass、Tailwind）は `app/assets/builds/` に書き出せます。そこもほかと同じルートです。

## ダイジェストと保持

`spin run gen` は各ファイルを `public/assets/<name>-<digest>.<ext>` として書きます。ダイジェストは内容の SHA-256 の先頭 16 進 8 文字（Propshaft の短いダイジェスト）です：`application.css` は `application-1a2b3c4d.css` になります。`gen/assets.rb` には、論理パスからダイジェスト付きパスへの表が生成された `case` として、インポートマップとそのプリロードとともに入り、バイナリにコンパイルされます。そのため、プログラムの横に要るのは `public/assets/` だけです。変更したファイルには新しい名前が付き、古いファイルが書き換えられることはありません。

デプロイ前に読み込んだページや、ローリングデプロイ中にまだ動いている古いプロセスが、HTML に書かれたものを取得できるよう、古いダイジェストも残します：gen は論理パスごとに現在のダイジェストとその前の二つを残し、それより古いファイルを消します。Propshaft の `assets:clean` が三つの版を残すのと同じです。履歴は `public/assets/.manifest`（論理パスごとに 1 行：パスと、最大三つのダイジェスト）にあるので、`gen/assets.rb` はソースだけで決まり、`spin run gen -- --check` が比べるのもそれだけです。`public/assets/` はビルドの成果物です：`cybertrain new` が書く `.gitignore` には `/public/assets/` があり、`cybertrain build` とイメージのビルドが gen を実行します。

開発ループは `app/assets/**`、`app/javascript/**`、`vendor/javascript/**` を監視するので、スタイルシートを保存すると gen が走り、次のページは新しいダイジェストを読み込みます。

## CSS の `url()`

スタイルシートの中でアセットを指す `url()` は、Propshaft のコンパイラと同じくダイジェスト付きのパスに書き換えられます。スタイルシートは自分が指すファイルの後にダイジェストを取るので、使っている画像が変われば、スタイルシート自身のダイジェストも変わります：

```css
.brand { background: url("logo.svg") no-repeat; }
/* in public/assets/application-1a2b3c4d.css: */
.brand { background: url("/assets/logo-8177afd7.svg") no-repeat; }
```

パスはスタイルシートの**論理**ディレクトリを基準に解決します（先頭の `/` はルートから）：`application.css` からなら、`logo.svg` は論理パス `logo.svg` で、`../images/logo.svg` はルートより上に出るのでアセットではありません。`?query` や `#fragment` はダイジェスト付きのパスの後に残ります。`data:`、`http:`、`https:`、`//`、`#`、`%23` のターゲットはそのままにします。それ以外でアセットでないターゲットは書いたまま残り、gen が警告を出します。互いを指し合うスタイルシートの循環があると gen は止まります（`CSS url() cycle: a.css -> b.css -> a.css`）。

## ヘルパー

```erb
<%= stylesheet_link_tag "application" %>        <%# <link rel="stylesheet" href="/assets/application-1a2b3c4d.css"> %>
<%= javascript_include_tag "legacy" %>          <%# <script src="/assets/legacy-5e6f7a8b.js"></script> %>
<%= image_tag "logo.svg", alt: "CyberTrain", size: "32x32" %>
<%= asset_path "logo.svg" %>                    <%# /assets/logo-8177afd7.svg %>
```

名前に拡張子がなければ、`stylesheet_link_tag` は `.css` を、`javascript_include_tag` は `.js` を付けます。どちらも `nonce: true` を取り、`stylesheet_link_tag` は `media:` も取ります。スキーム付きの URL（または `//`、`data:`）はそのまま書き、`/` で始まるパスも同じです。知らない論理名は、開発とテストでは `Cybertrain::Assets::UnknownAsset` を発生させ（`asset "logo.png" is not in app/assets, app/javascript or vendor/javascript (run spin run gen)`）、本番では一度だけログに書いて `/assets/<name>` を出力します。すべてのシグネチャは[テンプレート言語](template-language.md#helpers-and-the-form-builder)にあります。

## インポートマップ

```ruby
# config/importmap.rb
pin "application"
pin "@hotwired/turbo", to: "https://cdn.jsdelivr.net/npm/@hotwired/turbo@8.0.12/dist/turbo.es2017-esm.js"
pin "chart", to: "chart.js", preload: false
pin_all_from "app/javascript/controllers", under: "controllers"
```

gen はこのファイルをテキストとして読み、実行はしません：`pin name, to:, preload:` と `pin_all_from dir, under:, preload:`、コメントと空行です。それ以外の行があると gen は止まります。スキームのない `to:` はアセットの論理パスで、`to:` のない pin は `<name>.js` を指します。`pin_all_from` はディレクトリの下の `.js` ファイルをすべて `<under>/<.js を除いたパス>` として、`index.js` は `under` そのものとして pin します。`preload:` の既定は true です（importmap-rails 2）。レイアウトでは、

```erb
<%= javascript_importmap_tags %>
```

が `<script type="importmap">`、プリロードする pin ごとの `<link rel="modulepreload">`、`<script type="module">import "application"</script>` を書きます。[Content Security Policy](requests.md#content-security-policy-force_ssl-and-hosts) が有効なら、どれにもリクエストの nonce が付きます。`bin/importmap pin` はありません：ライブラリを `vendor/javascript/` にコピーして pin するか、URL を pin してください。Turbo は同梱していません。

## 配信

静的ファイルのミドルウェアは、gen が書いたダイジェスト（`gen/assets.rb` の現在のもの、または起動時に読む `public/assets/.manifest` の残したもの）を名前に持つ `/assets/` 以下のファイルを、`Cache-Control: public, max-age=31536000, immutable` で返します。ファイルが変わることはないので ETag は要りません。`public/` のそれ以外のもの（アプリが `public/assets/` に置いたダイジェストなしのファイルも）は `max-age=3600` のままです。実際のパスが `public/` の外に出るファイルは返しません：`public/assets` を `public/` の外のディレクトリへのシンボリックリンクにするデプロイ（Capistrano の共有ディレクトリ）は、代わりにそこへマウントかバインドマウントしてください。`public/` を自分で返すリバースプロキシは自分のヘッダーを送るので、そちらで `/assets/` に同じ 1 年の immutable なキャッシュを付けてください。

## `public/style.css` を移す

アセットができる前に作ったアプリは `public/style.css` を普通のファイルとして返し、そのまま動きます。移すには：

```shell ターミナル — アプリのディレクトリ
mkdir -p app/assets/stylesheets app/javascript
git mv public/style.css app/assets/stylesheets/application.css
echo '/public/assets/' >> .gitignore
```

`app/views/layouts/application.html.erb` の `<link rel="stylesheet" href="/style.css">` の行を `<%= stylesheet_link_tag "application" %>` に置き換え（`config/importmap.rb` を作ったら `<%= csp_meta_tag %>` と `<%= javascript_importmap_tags %>` も足します）、スタイルシートが指す画像を `app/assets/images/` に移して `url("logo.svg")` のような参照にし、`spin run gen` を実行します。

## Kamal の `asset_path`

新しいイメージを作るデプロイ（Kamal、Docker）は、現在のダイジェストしか持っていきません。`cybertrain new` が書く `config/deploy.yml` には

```yaml
asset_path: /app/public/assets
```

があるので、Kamal は切り替えのあいだ、前のリリースのファイルを新しいコンテナへ引き継ぎます：デプロイ前に読み込んだページも、HTML に書かれた CSS と JavaScript を取得できます。古い `config/deploy.yml` にはこの行を足してください。
