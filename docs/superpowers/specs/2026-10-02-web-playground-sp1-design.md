# web playground SP1: 共有イメージ、Codespaces、サイトの入口、Cookie の設定

2026-10-02。ブランチ `web-playground`。前提: SP1 の決定（2026-10-02 にユーザーが案 A で承認、
オーケストレーターの裁定を含む）、コンテナスパイク、クラウド IDE 調査、VS Code web スパイクの各メモ。
本文の「スパイク」は Apple M5（10 CPU）の Docker Desktop 上、linux/arm64 での計測で、精度は ±15 % 程度。
本 spec が決めた細部には「（本 spec での決定）」と付け、§13 に一覧にした。

## 1. 目的

### 1.1 依頼と 3 つのサブプロジェクト

依頼（Saeki）: cybertrain をインストールなしでブラウザから試せる場所を作る。VS Code がブラウザで開き、
VS Code の中のブラウザでアプリをプレビューできる、jsfiddle くらい手軽なもの。途中から追加の依頼として、
訪問者が望めば「Deploy now」で Saeki がホストするサーバーにデプロイできる仕組み（GitHub ログイン必須）。

| | サブプロジェクト | 使うインフラ | 依存 |
| --- | --- | --- | --- |
| SP1 | 共有コンテナイメージ、「Open in Codespaces」、サイトと README の入口、フレームワークの小変更 | GHCR と Codespaces（自前のサーバーなし） | なし |
| SP2 | ログイン不要のホスト型プレイグラウンド（訪問者ごとのコンテナ + code-server、エディタ内プレビュー） | Saeki の VPS とドメイン | SP1 のイメージ |
| SP3 | Deploy now（GitHub ログイン、サンドボックスでビルド、Saeki のサーバーで公開） | SP2 のサーバーと制御面 | SP2 |

各サブプロジェクトは spec → plan → 実装を順に回す。本書は SP1 だけを扱う。

### 1.2 SP1 が届けるもの

1. イメージ `ghcr.io/saeki-mototsune/cybertrain-playground`（公開、linux/amd64）: Ubuntu 24.04、
   このチェックアウトから作った CLI と Spinel、`cybertrain new` をネットワークなしで通すフレームワークの
   ミラー、ビルド済みのチュートリアルのブログ `/workspace/blog`（§4、§5）。
2. `.devcontainer/devcontainer.json`: このイメージで Codespaces を開き、開発サーバーを端末で起動し、
   エディタ内プレビューでアプリを見せる（§6）。
3. 入口: `site/playground.html`（"Try it in your browser"）、トップと tutorial からのリンク、README の節、
   `playground/README.md`（§7）。
4. CI: イメージのビルド、スモークテスト、GHCR への公開（§8）。
5. フレームワークの変更（同じ PR、0.2.1 として出す）: 待ち受けアドレスとセッション Cookie の
   SameSite / Partitioned を環境変数で変えられるようにする（§3）。Codespaces のプレビューは
   クロスサイトの iframe なので、今の `SameSite=Lax` ではフォームの POST が全部 403 になる。

### 1.3 訪問者の体験

1. サイトの "Try it in your browser"（ナビ、トップのヒーロー、tutorial の Step 00 から）を開き、
   **Open in GitHub Codespaces** を押す。リンクは
   `https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`。未ログインなら GitHub のログインを
   経由して同じ URL に戻る。`quickstart=1` なので、既存の codespace があれば「Resume」、なければ
   ボタン 1 つの「Create codespace」ページが出て、どちらも必ずブラウザ版 VS Code で開く。
   作成ページには誰の枠で課金されるか（訪問者本人）が表示される。
2. **Create codespace** を押す。既定の 2 コア / 8 GB のマシンができ、イメージ（圧縮 143 MB、スパイク値）
   を pull して起動する。作成からエディタ表示までの時間は未計測（§10.3 L1 で計る）。
3. ブラウザ版 VS Code が `/workspace/blog` をフォルダとして開く。エクスプローラにはブログのファイル、
   ソース管理にはコミット 1 つのクリーンな git リポジトリが見える。
4. `postAttachCommand` が端末で `playground-server` を実行する。バナー（アプリの URL、ガイドの場所、
   編集の待ち時間）を出し、`code` コマンドが使えれば `PLAYGROUND.md` を開き、`cybertrain server` を
   前面で起動する。ビルド済みなので何もコンパイルせず、バインドまで 1 秒未満
   （スパイク: バイナリがある状態での起動 0.08〜0.48 s）。端末に `* Listening on http://127.0.0.1:3000`。
5. ポート 3000 が転送され（private）、`onAutoForward: "openPreview"` がエディタ内のプレビュー
   （Simple Browser）を `https://<codespace名>-3000.app.github.dev/` で開く。ルートルートで記事一覧が出る。
6. プレビューの中で記事を作る。Codespaces の中では Cookie が `SameSite=None; Secure; Partitioned` に
   なるので（§3、§6.3）、CSRF トークンとセッションが iframe でも往復し、303 で詳細ページに進む。
7. `PLAYGROUND.md` の「試すこと」:
   - ビューを編集して保存し、プレビューを再読み込み: 次のリクエストで反映（スパイク: 20 ms 未満、11 回すべて）。
   - モデルに検証を足して保存: 端末で再ビルドが走り、約 1 分でサーバーが自分で再起動する
     （スパイク: 1〜4 CPU で 45〜53 s。Codespaces の 2 コア amd64 は未計測）。短い本文で保存すると
     "Body is too short (minimum is 10 characters)"。
   - チュートリアルの Step 08（コメントの scaffold）から続ける。
   - 新しいアプリ: `cybertrain new` はミラー経由でネットワークなしに通る（スパイク: 3.6 s）。
   - プレビューは自動では再読み込みしない（ライブリロードは無い）。
8. 終わったら codespace を削除する（存在する間ストレージが訪問者の枠に数えられる）。

### 1.4 引用する計測値

| 項目 | 値 | 出典 |
| --- | --- | --- |
| イメージの大きさ | ディスク 607 MB、圧縮 143 MB | スパイク（arm64） |
| クリーンビルド | 156 s（10 CPU）、うち Spinel のビルド 41.5 s | スパイク |
| アイドル時 | 22 MB PSS、サーバーバイナリ 7.9 MB RSS、CPU 0.2 % | スパイク |
| ビルド済みでの起動 | 0.08〜0.48 s | スパイク（CPU 制限 0.5〜10） |
| ビューの編集 | 次のリクエストで反映（20 ms 未満） | スパイク |
| Ruby の編集 → 新しい動作 | 45〜53 s（1〜4 CPU）、0.5 CPU で約 2 分 | スパイク |
| ミラー経由の `cybertrain new` | ネットワークなしで 3.6 s、ミラー 1.1 MB | スパイク |
| Codespaces の無料枠 | Free: 月 120 コア時間 + 15 GB-月（2 コアで約 60 時間）、Pro: 180 + 20 | GitHub の課金ドキュメント（調査 A4） |

## 2. スコープ外

- SP2（ログイン不要のホスト型）と SP3（Deploy now）。両者のボタンは各サブプロジェクトが足す。
  `site/playground.html` には今は存在しないものへのリンクを置かない。
- arm64 イメージの公開。Dockerfile 自体はアーキテクチャに依らない（スパイクは arm64 でビルド）ので、
  arm64 の利用者はチェックアウトからビルドする。
- ブラウザのライブリロード、シードデータ、VS Code の拡張（Marketplace 含む）。
- Codespaces のプレビルドの設定（オーナーの任意作業、§11）、`hostRequirements`、テンプレートリポジトリ。
- `SPIN_DEBUG=1` による再ビルド短縮（ループでは未計測。§12）。
- フレームワークの `X-Frame-Options` / CSP、Host / Origin の検査（今は送っておらず検査もしない）。
- code-server を入れたステージ（SP2）、イメージの軽量化（Debian slim、サニタイザ削除など）。
- 転送ポートの public 化、Safari 専用の回避策（文書で案内するだけ、§10.3 L6）。
- イメージ内の `sudo`。

## 3. フレームワークの変更

### 3.1 問題

Codespaces の Web 版エディタのプレビューは「webview（`vscode-cdn.net`）の中の iframe」で、アプリは
クロスサイトの文脈で動く。`SameSite=Lax` の Cookie はそこでは保存も送信もされず、cybertrain の CSRF 検査が
すべてのフォーム POST に 403 を返す。`SameSite=None; Secure` なら動き、サードパーティ Cookie を
ブロックしたブラウザでは `SameSite=None; Secure; Partitioned` だけが動く（調査 A9.2 の Chrome 154 実験、
code-server の実 Simple Browser でも同じ結果）。

設定は `config/app.rb` ではなく環境変数で変える。設定はバイナリにコンパイルされるので、環境変数なら
ビルド済みのサンプルにも訪問者が新しく作るアプリにも再ビルドなしで効く。フレームワークは特定の
ベンダーに依らない: `cybertrain/` の中で `CODESPACES` を見ない。Codespaces を検出して変数を
設定するのはイメージの側（§6.3）。

### 3.2 環境変数と属性

既存の変数と同じ流儀で、`Config#initialize` が読み、`config/app.rb` が上書きできる。

| 変数 | 属性 | 未設定・空 | 値の意味 |
| --- | --- | --- | --- |
| `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`（今と同じ） | 空でない値はそのまま `TCPServer.new` に渡す（`0.0.0.0` で全インターフェース）。検証しない。バインドできない値は今の `c.host` と同じ扱い（使用中・特権ポートは `error: ...` で終了 1、名前解決できない等は TCPServer の例外のまま） |
| `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"` | `Lax` / `Strict` / `None` のどれか（大文字小文字も含めて完全一致）。それ以外は起動時エラー（§3.4） |
| `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false` | `1` または `true` のときだけ `true`。それ以外の値（`0`、`false`、`yes` など）は `false` でエラーにしない |

- 大文字小文字を区別する（本 spec での決定）: 値はそのままヘッダに出し、文書とエラーメッセージが正しい綴りを示すため。
- `CYBERTRAIN_SESSION_PARTITIONED` の不明な値をエラーにしない（本 spec での決定）: スクリプトが `1` を入れる
  オン・オフの切り替えで、`0` や `false` を拒むと不親切になるだけだから。
- イメージは `CYBERTRAIN_HOST` を設定しない。ローカルの Docker では `-e CYBERTRAIN_HOST=0.0.0.0` を付けるのが
  文書化された使い方（§7.4）。Codespaces の転送は 127.0.0.1 で足りる（調査 A5）。

### 3.3 Secure の規則

- `session_same_site` が `None` のとき、セッション Cookie は `session_secure` に関係なく必ず `Secure` を付ける
  （ブラウザは `Secure` の無い `None` を拒む）。
- `session_partitioned` が真のときも必ず `Secure` を付ける（本 spec での決定）: MDN の Set-Cookie は
  `Partitioned` に `Secure` を必須としており、付けないとブラウザが Cookie ごと捨てるため。
- 規則は `Cookies.serialize` に置く（本 spec での決定）: どの Cookie にも当てはまるブラウザの規則なので最下層で
  一度だけ守らせ、`SessionStore` と `Config` に派生フラグを持たせない。`Config#session_secure` は設定値の
  ままで、意味は「`None` / `Partitioned` でなくても `Secure` を付ける」になる。

### 3.4 検証と起動時エラー

- 検査は `Application#boot` で、埋め込みビューの検査の直後、`resolve_secret!` の前に行う。
  `config/app.rb` が動いた後なので、環境変数と `c.session_same_site = ...` の両方を一度に検査できる。
  `DB::CLI`（`bin/db.rb`、`cybertrain db migrate`）は boot しないので影響しない。
- 判定とメッセージは `Config#session_same_site_error`（テストできる純粋なメソッド）。`boot` はそれが空でなければ
  `puts "error: #{message}"`、`STDOUT.flush`、`exit(1)`（既存の埋め込みビュー検査と同じ形）。
- 表示（値が `lax` のとき）:

  ```
  error: CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got "lax")
  ```

- Spinel の制約（spikes/NOTES.md）: 判定は `==` の連鎖で書き、`include?` を使わない（規則 14 / 29）。
  未設定の表現は `""`（規則 11）。新しいメソッド名は他のクラスと衝突しない名前にする（規則 10 / 34 / 41）。

### 3.5 変更するファイルとシグネチャ

`cybertrain/config.rb`（クラス冒頭のコメントの変数一覧にも 3 つを足す）:

```ruby
attr_accessor :env, :host, :port, :database_path, :secret_key_base, :views_root, :public_root, :layout,
              :log_level, :session_cookie_name, :session_max_age, :session_secure, :session_same_site,
              :session_partitioned, :pool_size, :static_files, :csrf, :workers, :secret_key_path

# CYBERTRAIN_HOST, or "127.0.0.1" when it is unset or empty.
def self.default_host
  configured = ENV["CYBERTRAIN_HOST"] || ""
  configured.empty? ? "127.0.0.1" : configured
end

# CYBERTRAIN_SESSION_SAME_SITE, or "Lax" when it is unset or empty.
def self.default_session_same_site
  configured = ENV["CYBERTRAIN_SESSION_SAME_SITE"] || ""
  configured.empty? ? "Lax" : configured
end

# True only for CYBERTRAIN_SESSION_PARTITIONED=1 or =true.
def self.default_session_partitioned
  configured = ENV["CYBERTRAIN_SESSION_PARTITIONED"] || ""
  configured == "1" || configured == "true"
end

# initialize の中（他は今のまま）:
#   @host = Config.default_host
#   @session_secure = production?
#   # SameSite of the session cookie: "Lax", "Strict" or "None" (boot checks
#   # it). "None" is for an app shown inside another site's frame, such as an
#   # editor's preview; it always adds Secure (Cookies.serialize).
#   @session_same_site = Config.default_session_same_site
#   # Partitioned (CHIPS): with None, the cookie survives third-party cookie
#   # blocking inside such a frame. Adds Secure too.
#   @session_partitioned = Config.default_session_partitioned

# The error Application#boot reports (and exits 1 on) when session_same_site
# is not a value browsers accept; "" when it is one.
def session_same_site_error
  value = @session_same_site
  return "" if value == "Lax" || value == "Strict" || value == "None"

  "CYBERTRAIN_SESSION_SAME_SITE / session_same_site must be Lax, Strict or None (got \"#{value}\")"
end
```

`cybertrain/http/cookies.rb`:

```ruby
# same_site "None" and partitioned both require Secure (browsers drop such a
# cookie without it), so either adds Secure whatever `secure` says.
def self.serialize(name, value, path: "/", max_age: -1, http_only: true, same_site: "Lax", secure: false,
                   partitioned: false)
  out = +"#{name}=#{URI.encode_www_form_component(value)}"
  out << "; Path=#{path}"
  out << "; HttpOnly" if http_only
  out << "; SameSite=#{same_site}"
  out << "; Max-Age=#{max_age}" if max_age >= 0
  out << "; Secure" if secure || partitioned || same_site == "None"
  out << "; Partitioned" if partitioned
  out
end
```

`cybertrain/middleware/session_store.rb`（コメントに same_site / partitioned の意味を足す）:

```ruby
def initialize(app, secret:, cookie_name: "_cybertrain_session", max_age: 1209600, secure: false,
               same_site: "Lax", partitioned: false)
  # 既存の 4 つに加えて @same_site = same_site; @partitioned = partitioned
end

# call の中:
set_cookie = Cookies.serialize(@cookie_name, Session.dump(ctx.session, @secret), max_age: @max_age,
                               secure: @secure, same_site: @same_site, partitioned: @partitioned)
```

`cybertrain/application.rb`:

```ruby
# build_stack
app = SessionStore.new(app, secret: c.resolve_secret!, cookie_name: c.session_cookie_name,
                            max_age: c.session_max_age, secure: c.session_secure,
                            same_site: c.session_same_site, partitioned: c.session_partitioned)

# boot: embedded_views_missing? の検査の直後、c.resolve_secret! の前
same_site_error = c.session_same_site_error
unless same_site_error.empty?
  puts "error: #{same_site_error}"
  STDOUT.flush
  exit(1)
end
```

`cybertrain/cli/templates.rb` の `config_app`（と、同じ文面の `examples/blog/config/app.rb`）の冒頭コメント:

```ruby
# Application settings; see Cybertrain::Config for every option.
# Environment variables (PORT, CYBERTRAIN_ENV, CYBERTRAIN_DATABASE,
# CYBERTRAIN_SECRET_KEY_BASE, CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE,
# CYBERTRAIN_SESSION_PARTITIONED) are read before this block runs.
```

`examples/blog/config/app.rb` も直す（本 spec での決定）: テンプレートの出力と同じ一覧を書いており、
片方だけ古くなるのを避けるため。コメントだけなので `gen/` は変わらない。

### 3.6 Set-Cookie の例

値の部分を `<v>` とする。

| 設定 | ヘッダ |
| --- | --- |
| 既定（development） | `_cybertrain_session=<v>; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600` |
| production | `_cybertrain_session=<v>; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600; Secure` |
| `SAME_SITE=Strict` | `_cybertrain_session=<v>; Path=/; HttpOnly; SameSite=Strict; Max-Age=1209600` |
| `SAME_SITE=None` | `_cybertrain_session=<v>; Path=/; HttpOnly; SameSite=None; Max-Age=1209600; Secure` |
| `SAME_SITE=None` + `PARTITIONED=1`（Codespaces） | `_cybertrain_session=<v>; Path=/; HttpOnly; SameSite=None; Max-Age=1209600; Secure; Partitioned` |
| `PARTITIONED=1` のみ | `_cybertrain_session=<v>; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600; Secure; Partitioned` |

### 3.7 テスト（house style: `test/<name>.rb` + `.expected`、`spin test`）

- `test/cookies.rb`（CRuby と Spinel で同じ出力。`.expected` は CRuby から、NOTES 規則 23）に 2 つ:
  - `serialize with same_site None adds Secure even when secure is false`:
    `serialize("s", "v", same_site: "None")` が `"s=v; Path=/; HttpOnly; SameSite=None; Secure"`。
  - `serialize with partitioned appends Partitioned and implies Secure`:
    `serialize("s", "v", partitioned: true)` が `"s=v; Path=/; HttpOnly; SameSite=Lax; Secure; Partitioned"`、
    `serialize("s", "v", max_age: 60, same_site: "None", partitioned: true)` が
    `"s=v; Path=/; HttpOnly; SameSite=None; Max-Age=60; Secure; Partitioned"`。
  - 既存の 3 つの serialize テストは変更なしで通ること（既定の出力は変わらない）。
- `test/session.rb` に 1 つ: `SessionStore passes same_site and partitioned to its Set-Cookie`:
  `SessionStore.new(SessionWriter.new, secret: SECRET, same_site: "None", partitioned: true)` の Cookie が
  `"; SameSite=None; Max-Age=1209600; Secure; Partitioned"` で終わる。
- `test/application.rb`（FFI を使うので `.expected` はコンパイル済みバイナリの出力から:
  `./build/test/application > test/application.rb.expected`）:
  - `CONFIG_ENV` に `CYBERTRAIN_HOST`、`CYBERTRAIN_SESSION_SAME_SITE`、`CYBERTRAIN_SESSION_PARTITIONED` を足す。
  - `config defaults in development` に `assert_equal "Lax", c.session_same_site` と `refute c.session_partitioned`。
  - 新規 `CYBERTRAIN_HOST, CYBERTRAIN_SESSION_SAME_SITE and CYBERTRAIN_SESSION_PARTITIONED override the defaults`:
    `0.0.0.0` / `None` / `1` で `host`、`session_same_site`、`session_partitioned` が変わる。`true` でも真。
  - 新規 `empty CYBERTRAIN_HOST and CYBERTRAIN_SESSION_SAME_SITE count as unset; only 1 and true turn partitioning on`:
    空文字で `"127.0.0.1"` と `"Lax"`、`0` / `false` / `yes` で偽。
  - 新規 `session_same_site_error is empty for Lax, Strict and None and names the valid values otherwise`:
    3 つの正しい値で `""`、`"lax"` で §3.4 の文面（`error: ` を除いた部分）と完全一致。
  - 新規 `the stack's session cookie follows session_same_site and session_partitioned`: 既存の
    `log_level :none, static_files and csrf switch their middleware off` と同じ作り方で、`session_same_site = "None"`、
    `session_partitioned = true` の Config から Application を作り、セッションに書く既存の `/visit` ルートを
    `Context` で `app.call(ctx)` し、`ctx.response.cookies[0]` が
    `"; SameSite=None; Max-Age=1209600; Secure; Partitioned"` で終わることを確かめる。
- `test/integration_m1.rb` の `assert_equal "0.2.0", Cybertrain::VERSION` を `"0.2.1"` に。
- 起動時エラーの `exit(1)` 自体はユニットテストせず、`playground/smoke.sh` の F1（§8.2）が実バイナリで確かめる。

### 3.8 文書

- README「Configuration and environment variables」の表に 3 行を足す:

  | Variable | Attribute | Default |
  | --- | --- | --- |
  | `CYBERTRAIN_HOST` | `host` | `"127.0.0.1"`; `0.0.0.0` listens on every interface (containers) |
  | `CYBERTRAIN_SESSION_SAME_SITE` | `session_same_site` | `"Lax"`; also `Strict` or `None` (`None` always adds `Secure`); anything else stops the server at boot |
  | `CYBERTRAIN_SESSION_PARTITIONED` | `session_partitioned` | `false`; `1` or `true` adds `Partitioned` (and `Secure`) |

  続く段落の「Other attributes with fixed, overridable defaults」から `host` を外し、`session_secure` の説明を
  「`true` in production, which marks the session cookie `Secure`; `false` elsewhere, though `SameSite=None` and
  `Partitioned` add `Secure` anyway」に直す。表の後に 1 文: "Use `None` (with `CYBERTRAIN_SESSION_PARTITIONED=1`)
  only for an app shown inside another site's frame, such as the playground's Codespaces preview; the browser must
  reach the app over HTTPS."
- `docs/design.md` D14 の「セッション Cookie: production では `Secure` 属性を付ける」の直後に 1 行:
  「セッション Cookie の SameSite は `Config#session_same_site`（既定 `Lax`、`CYBERTRAIN_SESSION_SAME_SITE`、
  `Lax`/`Strict`/`None` 以外は起動時エラー）、`Partitioned` は `Config#session_partitioned`（既定 false、
  `CYBERTRAIN_SESSION_PARTITIONED`）。`None` か `Partitioned` のときは `session_secure` に関係なく `Secure`。
  待ち受けアドレスは `Config#host`（既定 `127.0.0.1`、`CYBERTRAIN_HOST`）。（2026-10-02、web playground SP1）」
- テンプレートと `examples/blog/config/app.rb` のコメント（§3.5）。

### 3.9 バージョン 0.2.1

`git grep -n '0\.2\.0'` で見つかったすべての箇所を変える（2026-10-02 時点）:

| ファイル | 箇所 |
| --- | --- |
| `cybertrain/version.rb` | `VERSION = "0.2.1"` |
| `spin.toml` | `version = "0.2.1"`（CI が VERSION との一致を検査する） |
| `README.md` | 153 行 `ref = "v0.2.1"`、618〜619 行（Releasing の例を `v0.2.1` と `cybertrain-0.2.1.gem` に） |
| `docs/deploy.md` | 160、237、326、334、737 行 |
| `site/index.html` | 227 行（`v0.2.1`）、241 行（`0.2.1 gem`、`v0.2.1` の 2 か所）、318 行 |
| `site/tutorial.html` | 142、164、300 行 |
| `test/integration_m1.rb` | 18 行 |
| `test/version.rb.expected` | 1 行 |
| `test/cli_new.rb.expected` | 200、206、245、283 行 |
| `test/cli_toolchain.rb.expected` | 5 行 |

変えないもの: `test/cli_new.rb` 175〜176 行の `--ref v0.2.0`（VERSION と無関係な明示の引数のテスト）、
`docs/superpowers/` 以下（当時の記録）。テンプレート（`cybertrain/cli/templates.rb`）と `examples/` は
バージョンを直書きしていない（`Cybertrain::VERSION` を使う / パス依存）。マージ後にオーナーが `v0.2.1` を
タグ付けして gem を push する（§11）。

## 4. イメージ

### 4.1 `playground/Dockerfile`（全文）

ビルドコンテキストはリポジトリのルート。ステージは公開しない補助の `cli-src` と、`toolchain`、`playground`。
`cli-src` を置くのは、gem の入力だけをキャッシュキーにして、フレームワークだけの変更で gem と Spinel の
層を再利用するため（本 spec での決定）。

```dockerfile
# syntax=docker/dockerfile:1
#
# The cybertrain playground image: Ubuntu 24.04, the cybertrain CLI and
# Spinel built from this checkout, a bare mirror of this repository for
# `cybertrain new`, and the tutorial blog prebuilt in /workspace/blog.
# .devcontainer/devcontainer.json (GitHub Codespaces) runs it; CI publishes
# it as ghcr.io/saeki-mototsune/cybertrain-playground. See playground/README.md.
#
#   docker build -f playground/Dockerfile --target playground -t cybertrain-playground .
#
# Always name the target: a later stage adds a browser editor.
# The context is the repository root and must hold the .git directory (a
# clone, not a git worktree, whose .git is a file): the mirror is made from
# it through a bind mount, so .git never lands in a layer.

ARG BASE_IMAGE=ubuntu:24.04

# ---------------------------------------------------------------------------
# Exactly the files cybertrain.gemspec packages, so that a change to the
# framework alone keeps the gem and Spinel layers cached. A file added to
# spec.files must be added here too (gem build fails otherwise).
FROM scratch AS cli-src
COPY cybertrain.gemspec README.md /src/
COPY exe/cybertrain /src/exe/
COPY cybertrain/version.rb cybertrain/cli.rb /src/cybertrain/
COPY cybertrain/cli/ /src/cybertrain/cli/
COPY cybertrain/generator/inflector.rb /src/cybertrain/generator/

# ---------------------------------------------------------------------------
FROM ${BASE_IMAGE} AS toolchain

LABEL org.opencontainers.image.source="https://github.com/saeki-mototsune/cybertrain" \
      org.opencontainers.image.title="cybertrain-playground" \
      org.opencontainers.image.description="Try cybertrain without installing it: Spinel, the cybertrain CLI and the tutorial blog, prebuilt." \
      org.opencontainers.image.licenses="MIT"

ARG DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8 \
    CYBERTRAIN_HOME=/opt/cybertrain \
    XDG_CACHE_HOME=/opt/cybertrain-cache \
    PATH=/opt/cybertrain/bin:${PATH}

# Ruby 3.2 for the CLI, a C toolchain, make, git, curl and the SQLite headers
# (what `cybertrain doctor` checks); gcc + libc6-dev rather than
# build-essential (no g++). procps: ps/pgrep for terminals and smoke.sh.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates curl git gcc make libc6-dev libsqlite3-dev procps ruby \
 && rm -rf /var/lib/apt/lists/*

# User dev, uid/gid 1000 (ubuntu:24.04 ships "ubuntu" with 1000: removed
# first). Nothing the prebuilt app needs lives in its home directory.
RUN set -eux; \
    if getent passwd 1000 >/dev/null; then userdel -r "$(getent passwd 1000 | cut -d: -f1)"; fi; \
    if getent group 1000 >/dev/null; then groupdel "$(getent group 1000 | cut -d: -f1)"; fi; \
    groupadd --gid 1000 dev; \
    useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash dev; \
    install -d -o dev -g dev /opt/cybertrain /opt/cybertrain-cache /opt/cybertrain-mirror /workspace

# `cybertrain new` writes git = "https://github.com/saeki-mototsune/cybertrain";
# these rules make git (and so spin) clone the mirror below instead.
RUN git config --system url."file:///opt/cybertrain-mirror/cybertrain.git".insteadOf \
        "https://github.com/saeki-mototsune/cybertrain" \
 && git config --system --add url."file:///opt/cybertrain-mirror/cybertrain.git".insteadOf \
        "https://github.com/saeki-mototsune/cybertrain.git"

# The CLI gem, built from this checkout's cybertrain.gemspec (not rubygems.org).
RUN --mount=type=bind,from=cli-src,source=/src,target=/tmp/cli-src \
    cd /tmp/cli-src \
 && gem build cybertrain.gemspec --output /tmp/cybertrain.gem \
 && gem install --local --no-document /tmp/cybertrain.gem \
 && rm /tmp/cybertrain.gem \
 && cybertrain version

USER dev
WORKDIR /home/dev

# Spinel (Cybertrain::SPINEL_TAG) into $CYBERTRAIN_HOME: the slow step
# (41.5 s on 10 CPUs in the spike).
RUN cybertrain setup && cybertrain doctor

# The framework mirror: this checkout's HEAD as a one-commit bare repository
# with the tag v<VERSION> forced onto it, so an image built from an untagged
# commit still resolves ref = "v<VERSION>". Owned by dev, the user who clones it.
RUN --mount=type=bind,source=.git,target=/tmp/checkout.git \
    set -eu; \
    if [ ! -d /tmp/checkout.git/objects ]; then \
      echo "playground/Dockerfile: the build context needs this repository's .git directory (a clone, not a worktree)" >&2; \
      exit 1; \
    fi; \
    version="$(ruby -e 'require "cybertrain/version"; print Cybertrain::VERSION')"; \
    mirror=/opt/cybertrain-mirror/cybertrain.git; \
    git init -q --bare --initial-branch=main "$mirror"; \
    git -C "$mirror" -c safe.directory='*' fetch -q --depth 1 --no-tags /tmp/checkout.git "+HEAD:refs/heads/main"; \
    git -C "$mirror" tag -f "v$version" main; \
    git -C "$mirror" rev-parse --verify -q "refs/tags/v$version" >/dev/null

# ---------------------------------------------------------------------------
FROM toolchain AS playground

USER root
COPY playground/profile.sh /etc/profile.d/cybertrain-playground.sh
COPY --chmod=0755 playground/playground-server /usr/local/bin/playground-server
# Interactive non-login shells read /etc/bash.bashrc only.
RUN echo '[ -r /etc/profile.d/cybertrain-playground.sh ] && . /etc/profile.d/cybertrain-playground.sh' >> /etc/bash.bashrc

USER dev
WORKDIR /workspace
# Tutorial step 02 (spin lock clones the mirror, then spin run gen).
RUN cybertrain new blog
WORKDIR /workspace/blog
# Step 03.
RUN cybertrain generate scaffold article title:string body:text
# Step 04: the root route.
COPY --chown=dev:dev playground/routes.rb config/routes.rb
# Step 07, then one full build: gen/ is current and build/bin/{gen,db,blog}
# exist, so the first `cybertrain server` compiles nothing. spin's freshness
# test compares mtimes: never copy this tree with anything but `cp -a`.
RUN cybertrain db migrate
RUN cybertrain spin run gen && cybertrain spin build blog
COPY --chown=dev:dev playground/PLAYGROUND.md PLAYGROUND.md
# One commit, so the Source Control view shows the visitor's own changes.
RUN git init -q -b main \
 && git add -A \
 && git -c user.name="cybertrain playground" -c user.email="playground@cybertrain.invalid" \
        commit -q -m "Tutorial steps 02-04 and 07: new, scaffold article, root route, db migrate" \
 && test -z "$(git status --porcelain)"

EXPOSE 3000
CMD ["playground-server"]
```

要点:

- 既定の `CMD` は `playground-server`（本 spec での決定）: `docker run` だけで開発サーバーが前面に出て、§7.4 の
  ローカルの使い方が 1 行になる。Codespaces は `image` 指定の構成では `overrideCommand` が既定で真なので
  CMD を使わない（devcontainer 仕様）。`docker run --init` を勧める（PID 1 がシグナルを転送・回収する）。
- `XDG_CACHE_HOME=/opt/cybertrain-cache`（本 spec での決定）: spin は `$XDG_CACHE_HOME/spin/packages`（フレームワーク）
  と `.../spin/native` を使う（Spinel `docs/spin.md`、`tools/spin.rb`）。spin の鮮度判定はこのキャッシュの
  mtime も見るので、ホームに置くと SP2 が tmpfs をホームに被せたときに最初の起動が全ビルドになる。
  「ツールチェーンはホームの外」という決定の意図に合わせ、キャッシュも `/opt` に置く。
- ミラーの持ち主は dev（本 spec での決定）: spin（dev）が clone する。所有者を揃えれば git の
  `safe.directory` 検査に一切かからない（スパイクは root が root 所有のミラーを clone しただけ）。
- ミラーは `--depth 1` の 1 コミット（本 spec での決定）: CI のチェックアウトは浅い（`fetch-depth: 1`）ので、
  ローカルの完全な clone からでも同じ中身になるよう揃える。spin は `git clone --depth 1 --branch v<VERSION>`
  しかしない。
- `insteadOf` を 2 つ（本 spec での決定）: git は一致した最長の接頭辞を使うので、`.../cybertrain` と
  `.../cybertrain.git` のどちらの URL もミラーそのものに書き換わる（1 本だけだと `.git` 付きの URL が
  `cybertrain.git.git` になり失敗する）。
- `/etc/bash.bashrc` から profile スクリプトを読む（本 spec での決定）: VS Code の端末がログインシェルとは
  限らないため、どちらの端末でも同じ変数を見せる。
- ビルドする CPU アーキテクチャはビルドマシンのもの。CI は linux/amd64 だけを公開する。

### 4.2 ビルドコンテキストと `.git`

`playground/Dockerfile.dockerignore`（新規）は許可リスト。BuildKit は `-f` で指定した Dockerfile と同じ場所の
`<Dockerfile 名>.dockerignore` をルートの `.dockerignore` より優先するので、この Dockerfile のビルドだけに効き、
同じルートをコンテキストにする他のビルド（SP2 以降）を巻き込まない（本 spec での決定）:

```
# Build context of playground/Dockerfile (the repository root). Only what the
# image uses is sent. .git stays: the image's framework mirror is made from
# it through a bind mount (never copied into a layer).
*
!.git
!README.md
!cybertrain.gemspec
!exe/
!cybertrain/
!playground/
```

- `.git` は `RUN --mount=type=bind` でそのステップの間だけ見え、どの層にも入らない。最終イメージにある
  git の中身は 1 コミットのミラーとサンプルアプリ自身の `.git` だけ。
- git worktree では `.git` がファイルなので、ミラーの手順が上の英文メッセージで止まる（仕様どおり）。
  ビルドは通常の clone で行う（playground/README.md に書く）。
- `gem build` の入力は `cli-src` のファイルだけ。gemspec の `spec.files` を増やしたら `cli-src` にも足す。

### 4.3 ミラーの意味

- `cybertrain new` の `spin.toml` はチュートリアルと同じ
  `cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v0.2.1" }` のまま。
- spin の clone はミラーに向き、ネットワークなしで通る（スパイク: 3.6 s、`spin.lock` はサンプルと同一）。
- ミラーのタグ `v<VERSION>` は「このイメージを作ったコミット」に強制的に付く。main から作ったイメージでは
  `v0.2.1` の中身はタグ付け後の main の内容になりうる。

### 4.4 ラベル

Dockerfile の `LABEL` は `org.opencontainers.image.source`（GHCR がパッケージをリポジトリに結び付ける）、
`title`、`description`、`licenses`。CI では `docker/metadata-action` のラベル（`source`、`revision`、
`created`、`version` など）が同名のものを上書きする。

### 4.5 焼き込むもの / 焼き込まないもの

焼き込む: apt のツールチェーン、CLI（チェックアウトの gemspec から）、Spinel（`/opt/cybertrain`）、spin の
キャッシュ（`/opt/cybertrain-cache`、`cybertrain new blog` が作る）、ミラー、ビルド済みサンプル（`spin.lock`、
`gen/`、`build/bin/{gen,db,blog}`、空のマイグレーション済み `storage/development.sqlite3`）、`PLAYGROUND.md`、
`playground-server`、profile スクリプト、git の書き換え規則。

焼き込まない: `tmp/secret_key`（起動ごとのコンテナで初回に生成。訪問者間で鍵を共有しない）、
`CYBERTRAIN_HOST` と Codespaces 用の変数（実行時に設定）、VS Code サーバー（Codespaces が実行時に入れる）、
code-server（SP2）、シードデータ、`sudo`、拡張機能。

### 4.6 SP2 が頼ってよい配置（約束）

| もの | 場所・値 |
| --- | --- |
| ユーザー | `dev`、uid/gid 1000、HOME `/home/dev`。サンプルの起動・再ビルドに必要なものはホームに無い |
| Spinel | `CYBERTRAIN_HOME=/opt/cybertrain`（`bin/` が PATH の先頭）、dev 所有 |
| spin のキャッシュ | `XDG_CACHE_HOME=/opt/cybertrain-cache`、dev 所有、`cybertrain new` と再ビルドが書く |
| ミラー | `/opt/cybertrain-mirror/cybertrain.git`、dev 所有、`/etc/gitconfig` の `insteadOf` 2 本 |
| サンプル | `/workspace/blog`、dev 所有、git リポジトリ（コミット 1 つ）、ビルド済み |
| 起動スクリプト | `/usr/local/bin/playground-server [APP_DIR]`（§6.2） |
| profile | `/etc/profile.d/cybertrain-playground.sh`（§6.3）、`/etc/bash.bashrc` から読む |
| ポート | 3000。`CYBERTRAIN_HOST` が無ければ 127.0.0.1 で待つ |
| 実行時に書く場所（アプリの外） | `/tmp`（spin の一時ファイル）、`/opt/cybertrain-cache`。アプリ内では `tmp/`、`storage/`、`build/`、`gen/` |
| ステージ | `toolchain`、`playground`。SP2 は `playground` の後に足す |

## 5. サンプルアプリとガイド

### 5.1 サンプルの状態

チュートリアルの Step 02（`cybertrain new blog`）、03（`cybertrain g scaffold article title:string body:text`）、
04（ルートルート）、07（`cybertrain db migrate`）を適用し、さらに 1 回フルビルドした状態。Step 05
（検証の追加）と 06（ArticlesController の手書き）は適用しない。05 はガイドの「試すこと」の 2 番目になる。
モデルは scaffold の既定どおり `validates :title, presence: true` だけを持つ。記事は 0 件。

`playground/routes.rb`（Step 04 と同じ内容）:

```ruby
Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
```

### 5.2 `playground/PLAYGROUND.md`（全文、`/workspace/blog/PLAYGROUND.md` に入る）

絶対パスを書かない（§6.5 のフォールバック 1 で置き場所が変わっても正しいように）。

````markdown
# cybertrain playground

This is the blog from the cybertrain tutorial, already set up: `cybertrain new blog`,
the article scaffold, the root route and the first migration (tutorial steps 02, 03,
04 and 07). The development server runs in the terminal below and the preview shows
the app.

The preview does not reload by itself: after a change, press its reload button.

## Try this

1. **Edit a view.** Change the `<h1>` in `app/views/articles/index.html.erb`, save,
   reload the preview. Views are read from disk on every request, so there is
   nothing to build.
2. **Add a validation.** In `app/models/article.rb`, add this line inside the class
   and save:

   ```ruby
   validates :body, presence: true, length: { minimum: 10 }
   ```

   Ruby is compiled, so the terminal shows a rebuild. After about a minute the
   server restarts by itself: an article with a short body now fails with "Body is
   too short (minimum is 10 characters)". If a change does not compile, the previous
   build keeps serving and every page shows the compiler's message at the top.
3. **Carry on with the tutorial** from step 08, "Scaffold comments":
   https://saeki-mototsune.github.io/CyberTrain/tutorial.html#scaffold-comment
   Stop the server first (Ctrl-C in its terminal), run the step's commands in a new
   terminal, then start it again with `cybertrain server`.

The Source Control view shows what you changed: the app is a git repository with
one commit.

## Start a fresh app

```sh
cd ..
cybertrain new shop && cd shop
cybertrain g scaffold product name:string
cybertrain db migrate
cybertrain server
```

Stop the blog's server first: both use port 3000. `cybertrain new` needs no network
here, and the first `cybertrain server` of a new app compiles it (about a minute).

## Good to know

- The Ports view's "Open in Browser" on port 3000 shows the app in a normal tab.
  Inside the preview, pop-ups and `confirm()` dialogs do not work.
- When you are done, delete the codespace at https://github.com/codespaces: its
  storage counts against your quota for as long as it exists.
- Everything else is in the README: https://github.com/saeki-mototsune/cybertrain#readme
````

- 再ビルドを「約 1 分」と書く（本 spec での決定、決定書の「約 30 秒」を改める）: スパイクの実測は 1〜4 CPU で
  45〜53 s（10 CPU の速い arm64）で、Codespaces の 2 コア amd64 はそれより速くなる根拠がない。§10.3 L7 で
  実測し、2 分を超えたら文面を実測値に直す。
- `<h1>` はある: scaffold の index は `<h1>Articles</h1>` を書き、フォームは `errors.full_messages` を出す
  （`cybertrain/cli/templates.rb`）。

## 6. Codespaces

### 6.1 `.devcontainer/devcontainer.json`（全文）

リポジトリの既定の構成（`devcontainer_path` なしの文書化されたリンクで選ばれる）。

```jsonc
{
  "name": "cybertrain playground",
  "image": "ghcr.io/saeki-mototsune/cybertrain-playground:latest",
  "remoteUser": "dev",
  "workspaceFolder": "/workspace/blog",
  "postCreateCommand": "",
  "postAttachCommand": { "server": "playground-server" },
  "forwardPorts": [3000],
  "portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "customizations": {
    "vscode": {
      "settings": { "files.autoSave": "off" }
    }
  }
}
```

- `hostRequirements` は書かない（既定の 2 コア。訪問者の枠の消費を抑える）。
- `postCreateCommand: ""` は GitHub のテンプレートと同じく既定の自動設定を止める。
- `postAttachCommand` はアタッチのたびに走るので、`playground-server` は冪等（§6.2）。
- `files.autoSave: "off"`（本 spec での決定）: 開発サーバーは保存ごとに再ビルドし、ビルド中の保存は次の
  ビルドになる（スパイク §4）。遅延の自動保存だと打鍵の切れ目ごとに約 1 分のビルドが走るので、VS Code の
  既定に依らず止める。devcontainer の設定は Remote スコープで、訪問者の User 設定より優先される。
- `label` は Ports ビューの表示名。
- `customizations.codespaces.openFiles` は使えない（クローン内の相対パスだけ）。ガイドはバナーと `code` で出す。

### 6.2 起動スクリプト `playground/playground-server`（全文、`/usr/local/bin/playground-server`）

```bash
#!/usr/bin/env bash
# playground-server [APP_DIR]
#
# Starts `cybertrain server` for the playground's app (default
# /workspace/blog) in the foreground of this terminal. GitHub Codespaces runs
# it from postAttachCommand on every attach, so a second run must not start a
# second server: it prints where the app is and exits 0.
set -u

app="${1:-/workspace/blog}"
port="${PORT:-3000}"

# The toolchain on PATH; in a codespace, the cookie settings the editor's
# preview needs (SameSite=None; Secure; Partitioned).
. /etc/profile.d/cybertrain-playground.sh

if [ "${CODESPACES:-}" = "true" ] && [ -n "${CODESPACE_NAME:-}" ]; then
  url="https://${CODESPACE_NAME}-${port}.${GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN:-app.github.dev}/"
else
  url="http://localhost:${port}/"
fi

# One server per port. `cybertrain server` inherits the lock and holds it
# until it exits.
exec 9>"/tmp/playground-server-${port}.lock"
if ! flock -n 9; then
  echo "playground-server: the dev server is already running: ${url}"
  exit 0
fi
if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
  echo "playground-server: port ${port} is already in use, so no second server is started: ${url}"
  exit 0
fi
if [ ! -f "${app}/spin.toml" ]; then
  echo "playground-server: ${app} is not a cybertrain app (no spin.toml)" >&2
  exit 1
fi

cat <<EOF

  cybertrain playground
  App    ${url}
  Guide  ${app}/PLAYGROUND.md

  Views reload on the next request. A Ruby change rebuilds the app (about a
  minute), then the server restarts by itself. Reload the page to see either.
  Ctrl-C stops the server; run playground-server to start it again.

EOF

# Open the guide once per container, when this terminal has VS Code's `code`.
marker="${app}/tmp/.playground-guide-opened"
if [ -f "${app}/PLAYGROUND.md" ] && [ ! -e "$marker" ] && command -v code >/dev/null 2>&1; then
  timeout 5 code --reuse-window "${app}/PLAYGROUND.md" >/dev/null 2>&1 && touch "$marker"
fi

cd "$app" || exit 1
exec cybertrain server
```

振る舞い:

- 冪等: `flock`（util-linux、ubuntu の必須パッケージ）のロックを `cybertrain server` が引き継ぐので、
  再アタッチで走った 2 回目は「already running」と URL を出して 0 で終わる。訪問者が別の端末で手で起動した
  サーバー（ロックなし）は `/dev/tcp` の接続確認で検出して同じく 0 で終わる。Ctrl-C でサーバーが止まれば
  ロックも外れ、次のアタッチでまた起動する。
- バナー: アプリの URL（Codespaces では `CODESPACE_NAME` と `GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN` から
  組み立てた転送 URL、それ以外は `http://localhost:3000/`）、ガイドの場所、編集の待ち時間、止め方と再起動。
  文面はプレビューにも新しいタブにも当てはまる言い方にする（§6.5 のフォールバック 2 で書き換え不要）。
- Codespaces の変数: profile スクリプトを読み込むので、`CODESPACES=true` なら
  `CYBERTRAIN_SESSION_SAME_SITE=None` と `CYBERTRAIN_SESSION_PARTITIONED=1` が入った状態で起動する。
- ガイドは `code` があるときコンテナごとに 1 回だけ開く（本 spec での決定: 目印をアプリの `tmp/` に置く。
  `tmp/` は `.gitignore` 済みで、停止・再開をまたいで残る。毎回開くと閉じた訪問者の邪魔になる）。
  `code` が無い・繋がらない場合は 5 秒で諦め、バナーだけが案内する。
- 引数 `APP_DIR` はフォールバック 1（`/workspaces/blog`）と smoke.sh の E1 のため（本 spec での決定）。
- `PORT` があればそのポートを使う（`cybertrain server` も `PORT` を読む）。

### 6.3 profile スクリプト `playground/profile.sh`（全文、`/etc/profile.d/cybertrain-playground.sh`）

```sh
# /etc/profile.d/cybertrain-playground.sh -- installed by playground/Dockerfile.
# The toolchain lives under /opt, so the home directory holds nothing the
# prebuilt app needs (playground/README.md).
export CYBERTRAIN_HOME=/opt/cybertrain
export XDG_CACHE_HOME=/opt/cybertrain-cache
case ":${PATH}:" in
  *:/opt/cybertrain/bin:*) ;;
  *) PATH="/opt/cybertrain/bin:${PATH}"; export PATH ;;
esac
# In a GitHub Codespace the editor's preview is an iframe inside a webview on
# another site (vscode-cdn.net): a SameSite=Lax session cookie is dropped
# there and every form POST gets 403. Codespaces sets CODESPACES=true.
# Defaults only: a value already set (for a test) wins.
if [ "${CODESPACES:-}" = "true" ]; then
  export CYBERTRAIN_SESSION_SAME_SITE="${CYBERTRAIN_SESSION_SAME_SITE:-None}"
  export CYBERTRAIN_SESSION_PARTITIONED="${CYBERTRAIN_SESSION_PARTITIONED:-1}"
fi
```

- POSIX sh で書く（`/etc/profile` は sh からも読まれる）。PATH は二重に足さない。
- 既定値として入れ、上書きしない（本 spec での決定）: §10.3 L5 の対照実験
  （`CYBERTRAIN_SESSION_SAME_SITE=Lax CYBERTRAIN_SESSION_PARTITIONED=0 playground-server`）ができるように。

### 6.4 ディープリンク

`https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`（文書化された形。既定ブランチ、既定の構成、
ブラウザ版 VS Code）。ブランチを試すときは `https://codespaces.new/saeki-mototsune/CyberTrain/tree/<branch>?quickstart=1`。
`codespaces.new/...` は `github.com/codespaces/new/...` への 301 でクエリを保つ（調査 A2）。リポジトリ名の
大文字小文字（実体は `cybertrain`）はサイトの他の GitHub リンクと同じ `CyberTrain` にそろえ、§10.3 L1 で
このリンクそのものを押して確かめる。

### 6.5 実機でしか確かめられない 2 点とフォールバック

**1. `workspaceFolder` が `/workspaces` の外。** Codespaces は `workspaceFolder` を尊重する（devcontainers/spec
PR #123）が、クローンの外のパスでの実例は見つかっていない（調査 A7、未検証）。エディタがそこで開かなければ、
作成時にビルド済みのアプリを `/workspaces/blog` に `cp -a`（mtime を保つので再ビルドしない。前提は smoke.sh の
E1 で CI が毎回確かめる）し、そこを開く。代替の `devcontainer.json`（全文）:

```jsonc
{
  "name": "cybertrain playground",
  "image": "ghcr.io/saeki-mototsune/cybertrain-playground:latest",
  "remoteUser": "dev",
  "workspaceFolder": "/workspaces/blog",
  "onCreateCommand": "test -e /workspaces/blog || cp -a /workspace/blog /workspaces/blog",
  "postCreateCommand": "",
  "postAttachCommand": { "server": "playground-server /workspaces/blog" },
  "forwardPorts": [3000],
  "portsAttributes": {
    "3000": { "label": "cybertrain", "onAutoForward": "openPreview" }
  },
  "customizations": {
    "vscode": {
      "settings": { "files.autoSave": "off" }
    }
  }
}
```

`onCreateCommand` は既定の `waitFor`（`updateContentCommand`）より前に終わるので、エディタはコピー後に繋がる。
この形では作業が `/workspaces` の下に残り、「Rebuild Container」でも消えない。前提: `/workspaces` に dev
（uid 1000）が書けること（§10.3 L2 で `touch` して確かめる）。書けない場合は SP1 の Codespaces ボタンを
出さずにオーナーへ戻す（§10.3 の判定表）。

**2. private な転送ポートでの `openPreview`（2026-09-14 ごろからの GitHub 側の変化）。** 二つの第三者プロジェクトが、
private ポートのサインインが iframe の中で完了しない（空のパネル、"Verifying session" のまま）と報告している
（調査 A9.4、GitHub は未発表）。プレビューが読み込めなければ、ポート 3000 だけを新しいタブで開く:

```jsonc
"portsAttributes": {
  "3000": { "label": "cybertrain", "onAutoForward": "openBrowser" }
}
```

あわせて文面を「プレビュー」から「新しいタブ」に替える（バリアント B）:

| 場所 | 既定の文 | バリアント B |
| --- | --- | --- |
| `PLAYGROUND.md` 1 段落目 | "The development server runs in the terminal below and the preview shows the app." | "The development server runs in the terminal below and the app opened in a new browser tab (if it did not, use the Ports view's "Open in Browser" on port 3000)." |
| `PLAYGROUND.md` 2 段落目 | "The preview does not reload by itself: after a change, press its reload button." | "The page does not reload by itself: after a change, reload its tab." |
| `PLAYGROUND.md` Try this 1 | "reload the preview" | "reload the app's tab" |
| `PLAYGROUND.md` Good to know 1 | 既定の 2 文 | "If the app's tab did not open (a pop-up blocker), use the Ports view's "Open in Browser" on port 3000." |
| README と `site/playground.html` | "and the app in the editor's preview" / "the preview" | "and the app in a new browser tab" / "the app's tab"、ポップアップの文はバリアント B の Good to know 1 と同じ文に置き換え |

バナー（§6.2）は両方に当てはまる文面なので替えない。どちらの場合も Cookie の設定は残す（新しいタブでも
`None; Secure; Partitioned` は動き、訪問者が手でプレビューを開いたときに効く）。

### 6.6 訪問者に必要なもの（調査 A4、A5、A9.3）

- GitHub アカウント（未ログインの訪問はログインに飛ばされ、同じ URL に戻る）。
- 本人の Codespaces 枠。Free: 月 120 コア時間 + 15 GB-月、Pro: 180 + 20。2 コアは 2 倍で数えるので Free で
  約 60 時間。個人アカウントのリポジトリは訪問者の分を払えない。既定以外のイメージは、コンテナとファイルが
  訪問者のストレージ枠に数えられる（このイメージはディスク 607 MB、スパイク値）。
- 既定のアイドル停止 30 分（5〜240 分で変更可）、最長 12 時間、停止した codespace は既定 30 日で削除。
- ブラウザ: Chromium 系を推奨（Firefox と Safari には既知の問題、シークレットモードや広告ブロッカーで
  エディタ自体が動かないことがある）。

## 7. サイトと README

### 7.1 置き場所

| 入口 | 場所 |
| --- | --- |
| 新しいページ | `site/playground.html`（静的、JavaScript なしで動く、ブランドの規則どおり） |
| 主ナビ | `index.html`、`tutorial.html`、`playground.html` の `nav.nav-links` で Tutorial と GitHub の間に `Playground` |
| トップのヒーロー | `index.html` の `.hero-main .cta-row` の 2 番目に `Try it in your browser`（btn-ghost） |
| tutorial | Step 00（`#requirements`）の最後に `p.note` を 1 つ |
| README | 新しい節「Try it in the browser」（Status 段落の後、「Requirements」の前）と「Learn more」の 1 項目目 |
| イメージの文書 | `playground/README.md` |

`index.html` の closer とフッターは変えない。サイトの内容規則（site/README.md）に従い、ページの主張と
コマンドはすべて README の新しい節（§7.4）に根拠を置く。ブランド（BRAND.md）: 金色はロゴの光の帯だけ。
新しい色、外部への読み込み（バッジ画像を含む）を足さない。既存のクラスを使い、CSS の追加は
レイアウトの 1 規則 `.step > .cta-row { margin-top: 28px; }` だけ（ステップの中にボタンの行を置くのはこのページが
初めてで、`.cta-row` の上余白はヒーローと closer にしか無いため。本 spec での決定）。

### 7.2 `site/playground.html`

`<head>` は `tutorial.html` と同じ構成（favicon、フォント、style.css、`site.js` を defer、og:image）で、
次の 4 つだけを替える:

```html
<title>Try it in your browser · CyberTrain</title>
<meta name="description" content="Open the CyberTrain tutorial blog in a GitHub Codespace: VS Code in your browser, the development server running, the app in the editor's preview. Or run the same image locally with Docker.">
<meta property="og:title" content="Try CyberTrain in your browser">
<meta property="og:description" content="The tutorial blog, already scaffolded and migrated, in VS Code in your browser. Needs a GitHub account; runs on your own Codespaces quota.">
```

ヘッダーは `tutorial.html` のものをそのまま使い、ナビの `Playground` に `aria-current="page"` を付ける
（Tutorial からは外す）。フッターは `index.html` のものをそのまま使う。`<main>` の中身（全文）:

```html
<main id="main">

<div class="wrap">
  <header class="doc-hero">
    <p class="crumb"><a href="index.html">CyberTrain</a><span aria-hidden="true"> / </span><span>Playground</span></p>
    <h1>Try it in your&nbsp;browser</h1>
    <p class="doc-intro">The blog from the <a href="tutorial.html">tutorial</a>, already created, scaffolded and migrated, opens in VS Code in your browser, with its development server running in a terminal and the app in the editor's preview. Nothing to install: GitHub Codespaces runs it on a cloud machine.</p>
    <dl class="doc-meta">
      <div><dt>You need</dt><dd>A GitHub account</dd></div>
      <div><dt>It runs on</dt><dd>Your own Codespaces quota, on the default 2-core machine</dd></div>
      <div><dt>You get</dt><dd>VS Code, Spinel <code>2026.09.12</code>, the <code>cybertrain</code> CLI and the blog</dd></div>
    </dl>
  </header>
</div>

<div class="wrap doc">
  <nav class="toc" aria-label="Playground sections">
    <details class="toc-d" open>
      <summary class="toc-sum"><span class="toc-title">On this page</span><span class="toc-count" data-count aria-hidden="true"></span><span class="toc-chev" aria-hidden="true"></span></summary>
      <div class="toc-bar" aria-hidden="true"><span data-bar></span></div>
    <ol>
      <li><a href="#open"><span class="toc-n">01</span>Open a codespace</a></li>
      <li><a href="#what-opens"><span class="toc-n">02</span>What opens</a></li>
      <li><a href="#try"><span class="toc-n">03</span>What to try</a></li>
      <li><a href="#docker"><span class="toc-n">04</span>Run it with Docker</a></li>
      <li class="toc-x"><a href="#where-next"><span class="toc-n">&rarr;</span>Where next</a></li>
    </ol>
    </details>
  </nav>

  <article class="doc-body">

  <section class="step" id="open" aria-labelledby="h-open">
    <p class="stage"><span class="stage-k">You are here<span class="sr-only">:</span></span>One click <span aria-hidden="true">&middot;</span> GitHub Codespaces</p>
    <h2 id="h-open"><span class="step-num" aria-hidden="true">01</span>Open a codespace</h2>
    <p class="why"><span class="why-k">Why</span><span class="why-t">VS Code in your browser, on a cloud machine that runs on your own GitHub quota.</span></p>
    <div class="cta-row">
      <a class="btn btn-primary" href="https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1" rel="noopener">Open in GitHub Codespaces<span class="btn-arrow" aria-hidden="true">&rarr;</span></a>
      <a class="btn btn-ghost" href="tutorial.html">Read the tutorial</a>
    </div>
    <p class="note">A GitHub account is required, and the codespace runs on your own Codespaces quota: GitHub's free plan includes 120 core-hours and 15&nbsp;GB-month of storage a month, about 60 hours on the default 2-core machine the playground uses. GitHub stops an idle codespace after 30 minutes by default; its storage counts until you delete it.</p>
  </section>

  <section class="step" id="what-opens" aria-labelledby="h-what-opens">
    <h2 id="h-what-opens"><span class="step-num" aria-hidden="true">02</span>What opens</h2>
    <ul class="points">
      <li>The blog with tutorial steps 02, 03, 04 and 07 done: <code>cybertrain new blog</code>, the article scaffold, the root route and the first migration, built once so the server starts without compiling.</li>
      <li>A terminal running <code>cybertrain server</code>.</li>
      <li>The app in the editor's preview, showing the article list.</li>
      <li><code>PLAYGROUND.md</code>, the short guide to what to try.</li>
      <li>Source Control: the app is a git repository with one commit, so it shows exactly what you change.</li>
    </ul>
  </section>

  <section class="step" id="try" aria-labelledby="h-try">
    <h2 id="h-try"><span class="step-num" aria-hidden="true">03</span>What to try</h2>
    <ul class="points">
      <li><strong>Edit a view.</strong> It shows on the next reload: views are read from disk on every request.</li>
      <li><strong>Add a validation.</strong> Ruby is compiled, so a Ruby change is a full rebuild, about a minute, after which the server restarts by itself.</li>
      <li><strong>Carry on with the tutorial</strong> from <a href="tutorial.html#scaffold-comment">step 08, Scaffold comments</a>.</li>
      <li><strong>Start a fresh app.</strong> <code>cybertrain new</code> works in the codespace with no network.</li>
    </ul>
    <p class="note">The preview does not reload by itself: press its reload button after a change. Inside the preview, pop-ups and <code>confirm()</code> dialogs do not work; the Ports view's &ldquo;Open in Browser&rdquo; shows the app in a normal tab.</p>
  </section>

  <section class="step" id="docker" aria-labelledby="h-docker">
    <h2 id="h-docker"><span class="step-num" aria-hidden="true">04</span>Run it with Docker</h2>
    <p class="why"><span class="why-k">Why</span><span class="why-t">The same image runs on your own machine.</span></p>
    <figure class="code" data-lang="shell">
<figcaption><span class="code-path">terminal &mdash; any directory</span><span class="code-lang">shell</span></figcaption>
<pre tabindex="0" role="region" aria-label="Code: run the playground image"><code><span class="ln cmd">docker run --rm -it --init -p 3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground</span></code></pre>
</figure>
    <p>Then open <code>http://localhost:3000</code>. The published image is <code>linux/amd64</code>; on an arm64 machine, build it from a checkout as <a href="https://github.com/saeki-mototsune/CyberTrain/blob/main/playground/README.md" rel="noopener"><code>playground/README.md</code></a> describes.</p>
  </section>

  <section class="step step-last" id="where-next" aria-labelledby="h-where-next">
    <h2 id="h-where-next"><span class="step-num" aria-hidden="true">&rarr;</span>Where next</h2>
    <ul class="next-list">
      <li><a href="tutorial.html"><span class="next-t">The tutorial</span><span class="next-d">The blog from <code>cybertrain new</code> to <code>cybertrain build</code>.</span></a></li>
      <li><a href="https://github.com/saeki-mototsune/CyberTrain/blob/main/playground/README.md" rel="noopener"><span class="next-t"><code>playground/README.md</code></span><span class="next-d">The image, building it, and the Codespaces setup.</span></a></li>
      <li><a href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener"><span class="next-t">CyberTrain on GitHub</span><span class="next-d">The source, the README and releases.</span></a></li>
      <li><a href="index.html"><span class="next-t">CyberTrain home</span><span class="next-d">Overview, features and how it works.</span></a></li>
    </ul>
  </section>

  </article>
</div>

</main>
```

`playground/README.md` へのリンクは main に入った時点で生きる（Pages は main への push で公開される）。
イメージはマージ前にブランチから公開して実機で確認する（§10.3）ので、ページが公開された時点でボタンは動く。

### 7.3 `index.html` と `tutorial.html` の変更

- 主ナビ（3 ページ共通）に Tutorial と GitHub の間で `<li><a href="playground.html">Playground</a></li>`。
- `index.html` のヒーローの CTA を 3 つにする:

  ```html
  <div class="cta-row">
    <a class="btn btn-primary" href="tutorial.html">Get started<span class="btn-arrow" aria-hidden="true">&rarr;</span></a>
    <a class="btn btn-ghost" href="playground.html">Try it in your browser</a>
    <a class="btn btn-ghost" href="https://github.com/saeki-mototsune/CyberTrain" rel="noopener">View on GitHub</a>
  </div>
  ```

- `tutorial.html` の Step 00 の最後の要素の後に:

  ```html
  <p class="note">No machine to install on? The <a href="playground.html">playground</a> opens this blog in a GitHub Codespace with steps 02, 03, 04 and 07 already done.</p>
  ```

- バージョンの表記（§3.9）。

### 7.4 README の新しい節（全文）

```markdown
## Try it in the browser

[Open the playground in GitHub Codespaces](https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1)
to try cybertrain without installing anything: VS Code opens in your browser with
Spinel 2026.09.12, the `cybertrain` CLI and the blog from the walkthrough below
already created (`cybertrain new blog`, the article scaffold, the root route and
the first migration, built once so the server starts without compiling), its
development server running in a terminal and the app, showing the article list,
in the editor's preview. The app is a git repository with one commit, so Source
Control shows what you change. `PLAYGROUND.md` in the app lists what to try, from
editing a view to carrying on with the walkthrough's comments. A view edit shows
on the next reload; a Ruby edit is a full rebuild, about a minute, after which the
server restarts by itself; the preview does not reload by itself. `cybertrain new`
works there with no network.

- A GitHub account is required, and the codespace runs on your own Codespaces
  quota: GitHub's free plan includes 120 core-hours and 15 GB-month of storage a
  month, about 60 hours on the default 2-core machine the playground uses. GitHub
  stops an idle codespace after 30 minutes by default; its storage counts until
  you delete it.
- Inside the preview, pop-ups and `confirm()` dialogs do not work; the Ports
  view's "Open in Browser" shows the app in a normal tab.
- The same image runs locally (it is published for linux/amd64; on arm64, build
  it from a checkout):

  ```sh
  docker run --rm -it --init -p 3000:3000 -e CYBERTRAIN_HOST=0.0.0.0 ghcr.io/saeki-mototsune/cybertrain-playground
  ```

  Then open http://localhost:3000. [playground/README.md](playground/README.md)
  describes the image, building it and the Codespaces setup.
```

「Learn more」の 1 項目目を "[Homepage](...), [tutorial](...) and [playground](https://saeki-mototsune.github.io/CyberTrain/playground.html) — ..."
に直す。「Releasing」の 3 の後に 4 を足す: "4. The tag also publishes the playground image
`ghcr.io/saeki-mototsune/cybertrain-playground:X.Y.Z` (and `latest`) through
[.github/workflows/playground-image.yml](.github/workflows/playground-image.yml); check that run."

### 7.5 `playground/README.md` の構成（英語）

1. **What this is**: the image, who uses it (`.devcontainer/devcontainer.json` now, the hosted playground later),
   the published name and tags (`latest` = main, `X.Y.Z` = release tag), linux/amd64 only.
2. **Run it**: the `docker run` line of §7.4; `docker run --rm -it IMAGE bash` for a shell; `--init` and why;
   `CYBERTRAIN_HOST=0.0.0.0` and why the image does not set it.
3. **Build it**: `docker build -f playground/Dockerfile --target playground -t cybertrain-playground .` from a regular
   clone (not a git worktree), always with `--target`; works on arm64 too; what the build needs (network for apt,
   rubygems is not used, GitHub for Spinel); about 2.5 minutes on 10 CPUs (spike).
4. **What is inside**: the table of §4.6 in English, the stages, what is not baked in (§4.5), the mirror and its
   `insteadOf` rules (and that clones of `https://github.com/saeki-mototsune/cybertrain` inside the image therefore
   get the one-commit mirror; `GIT_CONFIG_NOSYSTEM=1 git clone ...` reaches GitHub).
5. **The scripts**: `playground-server [APP_DIR]` (idempotence, banner, guide), the profile script and the
   Codespaces cookie settings, with the reason (cross-site preview iframe, §3.1) and the framework variables.
6. **Codespaces**: the devcontainer settings one by one and why; the link; the Ports → Open in Browser fallback;
   edits outside `/workspaces` are lost on "Rebuild Container" (a rebuild resets the blog to the image); delete the
   codespace when done; the results of the live check (§10.3) with the measured times.
7. **Smoke test**: `bash playground/smoke.sh IMAGE`, what it checks (§8.2), how long it takes.
8. **CI and publishing**: the workflow, its triggers and tags, the manual run with a chosen tag.
9. **Owner's one-time steps**: §11 の 2・8。
10. **Limitations**: amd64 only; no live reload; Ruby edits cost a rebuild; the sample's `spin.lock` pins the commit
    the image was built from; repositories whose URL starts with `https://github.com/saeki-mototsune/cybertrain`
    are redirected too.

## 8. CI

### 8.1 `.github/workflows/playground-image.yml`（全文）

```yaml
# Builds the playground image (playground/Dockerfile, target playground) for
# linux/amd64, smoke-tests it (playground/smoke.sh) and, except on pull
# requests, pushes the tested image to GHCR: latest from main, X.Y.Z and
# latest from a tag vX.Y.Z, the given tag on a manual run.
# See playground/README.md.
name: Playground image

on:
  pull_request:
    paths:
      - "playground/**"
      - ".devcontainer/**"
      - "cybertrain/**"
      - "cybertrain.gemspec"
      - "spin.toml"
      - "exe/**"
      - ".github/workflows/playground-image.yml"
  push:
    branches: [main]
    # GitHub does not evaluate path filters for tag pushes: every v* tag builds.
    tags: ["v*"]
    paths:
      - "playground/**"
      - ".devcontainer/**"
      - "cybertrain/**"
      - "cybertrain.gemspec"
      - "spin.toml"
      - "exe/**"
      - ".github/workflows/playground-image.yml"
  workflow_dispatch:
    inputs:
      tag:
        description: "Tag to push to ghcr.io/saeki-mototsune/cybertrain-playground (latest, X.Y.Z or a test name)"
        required: true
        default: "test"

permissions:
  contents: read
  packages: write

concurrency:
  group: playground-image-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  IMAGE: ghcr.io/saeki-mototsune/cybertrain-playground

jobs:
  image:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4

      - name: devcontainer.json parses
        run: npx --yes @devcontainers/cli@0 read-configuration --workspace-folder . > /dev/null

      - uses: docker/setup-buildx-action@v3

      - name: Tags and labels
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.IMAGE }}
          flavor: |
            latest=false
          tags: |
            type=raw,value=latest,enable=${{ github.event_name == 'push' && (github.ref == 'refs/heads/main' || startsWith(github.ref, 'refs/tags/v')) }}
            type=semver,pattern={{version}},enable=${{ startsWith(github.ref, 'refs/tags/v') }}
            type=raw,value=${{ inputs.tag || 'manual' }},enable=${{ github.event_name == 'workflow_dispatch' }}

      - name: Build (linux/amd64, target playground)
        uses: docker/build-push-action@v6
        with:
          context: .
          file: playground/Dockerfile
          target: playground
          platforms: linux/amd64
          load: true
          tags: cybertrain-playground:ci
          labels: ${{ steps.meta.outputs.labels }}
          cache-from: type=gha,scope=playground-image
          cache-to: type=gha,mode=max,scope=playground-image

      - name: Smoke test
        run: bash playground/smoke.sh cybertrain-playground:ci

      - name: Log in to GHCR
        if: github.event_name != 'pull_request'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Push the tested image
        if: github.event_name != 'pull_request'
        env:
          TAGS: ${{ steps.meta.outputs.tags }}
        run: |
          test -n "$TAGS" || { echo "no tag to push"; exit 1; }
          for tag in $TAGS; do
            docker tag cybertrain-playground:ci "$tag"
            docker push "$tag"
          done
```

- `context: .`（パスのコンテキスト）を明示する。Git コンテキストにすると `.git` が届かない。
- テストしたイメージそのものを `docker tag` + `docker push` で出す（本 spec での決定）: 押すものと試したものが
  同じバイト列になる。`load: true` なので来歴証明（provenance）は付かず、GHCR に unknown/unknown の行が出ない。
- キャッシュは GitHub Actions のキャッシュ（`type=gha`、`mode=max`）。フレームワークだけの変更なら apt、gem、
  Spinel の層が当たり、ミラーとサンプルの層（コミットごとに変わる）だけを作り直す。
- `.devcontainer/**` の変更には JSONC として読めるかの検査を当てる（本 spec での決定）。許可リスト
  `playground/Dockerfile.dockerignore` は `playground/**` に含まれる。README.md は gem に入るがトリガーに
  しない（文書の編集のたびに走らせない）。
- 実機確認の間だけ、`on.push.branches` と `latest` の条件にブランチ `web-playground` を足す（§10.3）。
  「TEMP: live check」と印を付けた 1 コミットにし、マージ前に取り除く。
- フォークからの PR はトークンが読み取り専用になるが、PR では push しないので問題ない。

### 8.2 `playground/smoke.sh IMAGE` の仕様

- 使い方: `bash playground/smoke.sh IMAGE`。ホストに bash 3.2 以上、docker、curl があればよい（macOS の bash でも
  動くように連想配列と `date +%N` を使わず、時間は `SECONDS` で計る）。期待するバージョンはスクリプトの場所から
  `../cybertrain/version.rb` を読む。引数が無ければ使い方を出して 2 で終わる。
- 各検査は `PASS <ID> <説明>` / `FAIL <ID> <説明> (<詳細>)` を 1 行出し、失敗しても残りを続ける（主コンテナが
  上がらなければ A・D は FAIL として飛ばす）。最後に `smoke: N passed, M failed`、失敗があれば関係するコンテナの
  `docker logs` の末尾 40 行を出し、終了コード 1。全部通れば 0。
- 作ったコンテナは `trap ... EXIT` で `docker rm -f` する。ホスト側ポートは `-p 127.0.0.1::3000`（空きポート）で
  取り、`docker port` で読む。

| ID | 検査 | 方法 | 上限 |
| --- | --- | --- | --- |
| G1 | ユーザーが `dev`、uid 1000 | `docker run --rm IMAGE id -un` / `id -u` | 30 s |
| G2 | `cybertrain version` が `cybertrain <VERSION>` | `docker run --rm IMAGE cybertrain version` | 30 s |
| G3 | `cybertrain doctor` が 0 で終わる | `docker run --rm IMAGE cybertrain doctor` | 60 s |
| G4 | `CYBERTRAIN_HOME=/opt/cybertrain`、`XDG_CACHE_HOME=/opt/cybertrain-cache`、`CYBERTRAIN_HOST` が未設定 | `docker run --rm IMAGE sh -c '...'` | 30 s |
| G5 | サンプルの `spin.toml` に `cybertrain = { git = "https://github.com/saeki-mototsune/cybertrain", ref = "v<VERSION>" }` | `grep -F` | 30 s |
| G6 | サンプルの git: 作業ツリーがクリーン、コミットが 1 つ、`PLAYGROUND.md` が追跡されている | `git status --porcelain`、`git rev-list --count HEAD`、`git ls-files PLAYGROUND.md` | 30 s |
| G7 | `tmp/secret_key` が無く、`build/bin/blog` が実行可能 | `test` | 30 s |
| A1 | 主コンテナ（`docker run -d --init -p 127.0.0.1::3000 -e CYBERTRAIN_HOST=0.0.0.0 IMAGE`、既定の CMD）の `GET /articles` が公開ポート経由で 200 | ホストの curl をポーリング | `docker run` から 30 s |
| A2 | ログに `=> Booting cybertrain <VERSION>` と `* Listening on http://0.0.0.0:3000` | `docker logs` | A1 の後 |
| A3 | 起動で何もコンパイルしていない: `build/bin/blog` の mtime がイメージのものと同じ | `stat -c %Y`（イメージ側は `docker run --rm IMAGE stat ...`） | A1 の後 |
| A4 | `GET /` が 200 で本文に `<h1>Articles</h1>` | curl | 5 s |
| A5 | `GET /articles/new` に 32 文字以上の `authenticity_token`、Set-Cookie が `; Path=/; HttpOnly; SameSite=Lax; Max-Age=1209600` で終わる（`Secure` も `Partitioned` も無い） | curl + Cookie jar | 5 s |
| A6 | トークンと Cookie 付きの `POST /articles`（タイトル `Smoke <時刻>`、本文 10 文字以上）が 303 で `Location: /articles/<id>`、その GET が 200 でタイトルを含む | curl | 5 s |
| A7 | トークンも Cookie も無い `POST /articles` が 403 | curl | 5 s |
| A8 | ビューの編集: `docker exec` で `app/views/articles/index.html.erb` の末尾に `<p id="smoke-view-edit">view edit</p>` を足すと、次の `GET /articles` に含まれる | curl をポーリング | 3 s |
| A9 | モデルの編集: `app/models/article.rb` の `class Article` の次の行に `validates :body, presence: true, length: { minimum: 10 }` を足すと、新しいトークンと Cookie での `POST /articles`（本文 `short`）が 422 になる。ログに `Build succeeded`、その後 `GET /articles` が 200 | 毎回新しい jar で POST をポーリング | 300 s |
| A10 | 実行中のコンテナに `tmp/secret_key` ができている（初回起動で生成） | `docker exec ... test -s` | A9 の後 |
| D1 | `docker exec C playground-server` が 0 で終わり、出力に `already running` | `docker exec` | 10 s |
| D2 | アプリのサーバープロセスがちょうど 1 つ | `docker exec C pgrep -c -f '^/workspace/blog/build/bin/blog( \|$)'` が `1` | D1 の後 |
| C1 | Codespaces を装ったコンテナ（`-e CODESPACES=true -e CODESPACE_NAME=smoke -e GITHUB_CODESPACES_PORT_FORWARDING_DOMAIN=app.github.dev`、既定の CMD）で `GET /articles/new` の Set-Cookie が `; Path=/; HttpOnly; SameSite=None; Max-Age=1209600; Secure; Partitioned` で終わる | コンテナ内の curl | 30 s |
| C2 | そのログのバナーに `https://smoke-3000.app.github.dev/` | `docker logs` | C1 の後 |
| F1 | `-e CYBERTRAIN_SESSION_SAME_SITE=lax` で起動したコンテナが 0 以外で終わり、出力に `must be Lax, Strict or None (got "lax")` | `docker run --rm`（`timeout` 付き） | 60 s |
| E1 | `cp -a /workspace/blog /tmp/blog-copy && exec playground-server /tmp/blog-copy` のコンテナで、コンテナ内の `GET /articles` が 200、コピーの `build/bin/blog` の mtime がイメージと同じ（フォールバック 1 の前提: `cp -a` しても再ビルドしない） | コンテナ内の curl、`stat` | 30 s |
| B1 | `--network none` で `git ls-remote https://github.com/saeki-mototsune/cybertrain` が `refs/tags/v<VERSION>` を返す（書き換えが効いている） | `docker run --rm --network none` | 30 s |
| B2 | 同じく `cd /tmp && cybertrain new offline` が 0、`spin.toml` の `ref = "v<VERSION>"`、`spin.lock` が `/workspace/blog/spin.lock` と同一（`cmp`） | 1 つのコンテナで続けて実行 | 180 s |
| B3 | 続けて `cybertrain spin build offline` が 0、`build/bin/offline` がある | B2 と同じコンテナ | B2 と合わせて 420 s |

所要時間の目安: CI で 4〜8 分（A9 と B3 の 2 回のコンパイルが大半）。

## 9. 変更対象

| 区分 | ファイル | 内容 |
| --- | --- | --- |
| 変更 | `cybertrain/config.rb` | 3 属性、`default_host` / `default_session_same_site` / `default_session_partitioned`、`session_same_site_error`、コメント |
| 変更 | `cybertrain/http/cookies.rb` | `serialize` に `partitioned:`、None / Partitioned で `Secure` |
| 変更 | `cybertrain/middleware/session_store.rb` | `same_site:`、`partitioned:` |
| 変更 | `cybertrain/application.rb` | `build_stack` で渡す、`boot` で検査 |
| 変更 | `cybertrain/version.rb`、`spin.toml` | 0.2.1 |
| 変更 | `cybertrain/cli/templates.rb`、`examples/blog/config/app.rb` | `config/app.rb` のコメント |
| 変更 | `test/cookies.rb`(+`.expected`)、`test/session.rb`(+`.expected`)、`test/application.rb`(+`.expected`) | §3.7 |
| 変更 | `test/integration_m1.rb`、`test/version.rb.expected`、`test/cli_new.rb.expected`、`test/cli_toolchain.rb.expected` | 0.2.1 |
| 変更 | `README.md` | 新しい節、設定の表、Learn more、Releasing、バージョン |
| 変更 | `docs/design.md` | D14 に 1 行 |
| 変更 | `docs/deploy.md` | バージョン |
| 変更 | `site/index.html` | ナビ、ヒーローの CTA、バージョン |
| 変更 | `site/tutorial.html` | ナビ、Step 00 のヒント、バージョン |
| 新規 | `site/playground.html` | §7.2 |
| 変更 | `site/assets/style.css` | `.step > .cta-row` の上余白 1 規則（§7.1） |
| 変更 | `site/README.md` | ページの一覧に `playground.html` |
| 新規 | `playground/Dockerfile` | §4.1 |
| 新規 | `playground/README.md` | §7.5 |
| 新規 | `playground/PLAYGROUND.md` | §5.2 |
| 新規 | `playground/routes.rb` | §5.1 |
| 新規 | `playground/playground-server` | §6.2（git のモード 755 でも置くが、Dockerfile は `--chmod` で頼らない） |
| 新規 | `playground/profile.sh` | §6.3 |
| 新規 | `playground/smoke.sh` | §8.2 |
| 新規 | `playground/Dockerfile.dockerignore` | §4.2 |
| 新規 | `.devcontainer/devcontainer.json` | §6.1 |
| 新規 | `.github/workflows/playground-image.yml` | §8.1 |

`.github/workflows/ci.yml` と `pages.yml` は変えない（ci.yml の `spin test` が §3.7 を回し、版の一致検査も
そのまま効く。pages.yml は `site/**` の変更で新しいページを公開する）。

## 10. テスト・検証

### 10.1 自動

- `spin test`（ci.yml、Ubuntu と macOS）: §3.7 の追加と更新。`.expected` の作り方は NOTES 規則 23 のとおり
  （cookies / session は CRuby、application は Spinel のバイナリ）。
- `playground-image.yml`: PR と main への push とタグで、イメージのビルドと §8.2 の全項目。押すのは
  スモークテストが通ったイメージだけ。

### 10.2 ローカル

1. 通常の clone で `docker build -f playground/Dockerfile --target playground -t cybertrain-playground:local .`
   （arm64 の Mac でもそのまま通る）。
2. `bash playground/smoke.sh cybertrain-playground:local` が `0 failed`。
3. devcontainer CLI（最初の公開の後）: `docker tag cybertrain-playground:local ghcr.io/saeki-mototsune/cybertrain-playground:latest`
   してから `npx @devcontainers/cli up --workspace-folder .`（CLI が pull して置き換えた場合は GHCR の amd64 版が
   エミュレーションで動くので、そのまま続けてよい）。期待: 成功し、
   `npx @devcontainers/cli exec --workspace-folder . sh -c 'id -un; pwd'` が `dev` と `/workspace/blog`。
   `postAttachCommand` は `up` では走らないので、`npx @devcontainers/cli exec --workspace-folder . playground-server`
   を別の端末で起動し、`npx @devcontainers/cli exec --workspace-folder . curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/articles`
   が `200`。ローカルの CLI はリポジトリを `/workspaces/<名前>` にマウントするので、`workspaceFolder` の
   Codespaces での振る舞いの代わりにはならない（§10.3 L2 が本番）。

### 10.3 Codespaces 実機チェックリスト（調査 §6 から）

確認はマージ前に、ブランチ `web-playground` から行う（本 spec での決定）: サイトのボタンが確認より先に
公開されるのを避け、フォールバックが要ってもこの PR の中で直せるようにするため。

1. 確認の間だけ、ワークフローの `on.push.branches` と `latest` の条件に `web-playground` を足す
   （「TEMP: live check」と印を付けた 1 コミット。§11 の 4 で取り除く）。手動実行（`workflow_dispatch`）は
   ワークフローがデフォルトブランチに入るまで使えないので、この一時的なトリガーでブランチから `latest` を押す。
   `latest` はこれが最初の公開で、壊すものが無い。
2. ブランチを push し、"Playground image" の実行が `latest` を押すのを待つ。オーナーがパッケージを Public にする
   （§11 の 2）。
3. 新しいブラウザプロファイル（`app.github.dev` の Cookie が無い状態）の Chrome で、オーナーの GitHub
   アカウントにサインインし、`https://codespaces.new/saeki-mototsune/CyberTrain/tree/web-playground?quickstart=1`
   を開く（ブランチの `devcontainer.json` が使われる）。所要 20 分程度、1 コア時間未満。

結果（時間を含む）は `playground/README.md` の Codespaces の節に書く。フォールバックが要ればこの PR の中で
直し、変えた項目を確かめ直す。

| # | 確かめること | 期待する結果 | 違ったとき |
| --- | --- | --- | --- |
| L1 | リンク → Create codespace → エディタ表示 → プレビュー表示までの時間 | 作成ページに「quick start」の 1 ボタンと課金先（本人）が出る。時間を記録する | 記録するだけ。2 分を超えるならプレビルド（§11 の 8）を検討する |
| L2 | `workspaceFolder`（実機項目 1） | エクスプローラのルートが BLOG でアプリのファイルが見える。端末の `pwd` が `/workspace/blog`。ソース管理に blog リポジトリ、変更 0。あわせて `ls -ld /workspaces` と `touch /workspaces/.probe && rm /workspaces/.probe` の結果を記録 | エディタが別の場所で開く・エラーなら §6.5 のフォールバック 1 の構成に替えて L2〜L5 をやり直す。`/workspaces` に書けずフォールバック 1 も使えないなら、Codespaces のボタンを出さずにオーナーへ戻す |
| L3 | 端末と環境 | `server` の端末にバナーと `* Listening on http://127.0.0.1:3000`。新しい端末で `uname -m` が `x86_64`、`echo $CODESPACES` が `true`、`echo $CYBERTRAIN_SESSION_SAME_SITE` が `None` | 変数が無ければ profile の読み込み経路（ログイン / 非ログイン）を調べて直す |
| L4 | 自動プレビュー（実機項目 2） | Listening の行から 10 秒以内に、手を触れずにプレビューが記事一覧を表示 | 空白や "Verifying session" のままなら、Ports → Open in Browser を一度開いてからプレビューを再読み込み。それで動くなら既知の不具合と判断し、§6.5 のフォールバック 2 とバリアント B の文面に替える |
| L5 | プレビュー内の Cookie と CSRF | New article → 作成で 303 → 詳細ページ（403 にならない）。プレビューのフレームの DevTools で `location.ancestorOrigins` に `vscode-cdn.net` の webview の origin が出る。端末で `curl -s -D - -o /dev/null http://127.0.0.1:3000/articles/new \| grep -i set-cookie` が `SameSite=None; Max-Age=1209600; Secure; Partitioned`。対照: サーバーを止め、`CYBERTRAIN_SESSION_SAME_SITE=Lax CYBERTRAIN_SESSION_PARTITIONED=0 playground-server` で作成すると 403（問題が実在する確認）。確認後は Ctrl-C して `playground-server` で戻す | 既定設定で 403 なら Cookie の行と `ancestorOrigins` を記録してオーナーへ戻す（設計の前提が崩れている） |
| L6 | Firefox と Safari | それぞれ L4〜L5 の作成が通る | 通らないブラウザがあれば、README の節、`site/playground.html` の note、`PLAYGROUND.md` の Good to know に "In <browser>, use the Ports view's "Open in Browser" instead of the preview." を足す |
| L7 | 編集のループ | ビューの編集が再読み込みで出る。検証の追加で再ビルドが走り、保存からサーバー再起動までの時間を記録 | 120 秒を超えたら、「about a minute」を実測を丸めた値（例 "about two minutes"）に、README、`site/playground.html`、`PLAYGROUND.md`、バナーで同時に直す |
| L8 | `postAttachCommand` の再実行 | ブラウザのタブを再読み込み、閉じて github.com/codespaces から開き直す。どちらでもサーバーは 1 つ（端末で `pgrep -c -f '^/workspace/blog/build/bin/blog( \|$)'` が `1`）、新しい端末は `already running` を出すか古い端末が復元される | 2 つ目が立つなら `playground-server` の検出を直す |
| L9 | 停止と再開 | github.com/codespaces で Stop → 開く。サーバーが再び起動し、作った記事が残っている | 起動しなければ `postStartCommand` の併用を検討してオーナーへ戻す |
| L10 | ガイドの自動表示 | `PLAYGROUND.md` が開いたかを記録 | 開かなくても変更しない（バナーが案内する）。README に結果を書く |
| L11 | 新しいアプリ | ブログのサーバーを止め、`cd .. && cybertrain new shop && cd shop && cybertrain g scaffold product name:string && cybertrain db migrate && cybertrain server` が通る | 失敗の出力を記録してオーナーへ戻す |
| L12 | 後片付け | codespace を削除する | なし |

## 11. オーナーの手作業

1. ブランチ `web-playground` の push を認める（push 自体はオーケストレーターが行う）。"Playground image" の
   実行がブランチから `latest` を公開する（§10.3 の 1〜2。初回はキャッシュが無く 10〜15 分程度）。
2. 公開されたらすぐ、GitHub のパッケージ `cybertrain-playground` の設定で可視性が Public であることを確かめ、
   private なら Public にする。リポジトリ `saeki-mototsune/cybertrain` に結び付いていることを確かめる
   （無ければ Connect repository）。
3. §10.3 の実機確認（オーナー自身、またはオーナーがサインインしたブラウザをオーケストレーターが操作）。
4. フォールバックや文面の修正はこの PR の中で行い、変えた項目を確認し直す。済んだら一時的なトリガー
   （「TEMP: live check」のコミット）を取り除く。
5. CI が通った PR をマージする。Pages がサイトを公開し、main の実行が `latest` を押し直す。
6. `git tag v0.2.1 && git push origin v0.2.1`（リリースのタグは確認済みの構成を含む）。
   タグの "Playground image" の実行が `0.2.1` と `latest` を押したことを確かめる（走っていなければ Run workflow を
   tag `0.2.1`、続いて `latest` で実行する）。続けて `gem build cybertrain.gemspec && gem push cybertrain-0.2.1.gem`
   （README「Releasing」）。
7. 以後、イメージを手で出し直すときは Run workflow（main で、tag を指定）。
8. 任意: Codespaces のプレビルド（Settings → Codespaces → Set up prebuild、ブランチ main、構成
   `.devcontainer/devcontainer.json`、リージョンを絞る）。費用はオーナー持ち（スナップショットのストレージと
   Actions の分、調査 A3）。

## 12. リスクと未確定事項

- **Codespaces の未検証事項**: `/workspaces` の外の `workspaceFolder`、private ポートでの自動プレビュー、
  Firefox / Safari での Cookie、作成時間、`postAttachCommand` の再実行の仕方、`code` コマンドの有無、
  `userEnvProbe` で profile の変数が端末に届くか。すべて §10.3 で確かめ、判定表のとおりに直す。
- **2 コア amd64 での再ビルド時間**は未計測（スパイクは arm64 で 45〜53 s）。長すぎれば文面を直し（L7）、
  別の変更で `SPIN_DEBUG=1`（スパイクの単発計測でコンパイル約 25 s、ループでは未計測、モードの印が変わるので
  サンプルもその設定でビルドし直す必要がある）を検討する。
- **`insteadOf` は接頭辞の一致**: URL が `https://github.com/saeki-mototsune/cybertrain` で始まる別のリポジトリ
  （例 `.../cybertrain-foo`）もミラーに向き、イメージ内でフレームワークを clone すると 1 コミットのミラーが
  返る。回避は `GIT_CONFIG_NOSYSTEM=1 git clone ...`（playground/README.md に書く）。
- **サンプルの `spin.lock`** はイメージを作ったコミットを固定する。main から作ったイメージでは、そのコミットは
  GitHub の `v0.2.1` タグのコミットと違いうるので、アプリをイメージの外に持ち出すと lock が合わない可能性がある。
- **`latest` は可変**: 壊れた main のイメージはボタンを壊す。スモークテストに通ったものしか押さないことで抑える。
  devcontainer をタグ固定にしない（決定どおり `latest`）。
- **Rebuild Container** は `/workspaces` の外を消す（調査 A7）。既定の構成では訪問者の編集が失われる
  （ブログがイメージの状態に戻る）。playground/README.md に書く。フォールバック 1 の形ではこの問題は無い。
- **パスフィルタとタグ**: 「タグの push ではパスフィルタを評価しない」という GitHub の仕様に頼る。§11 の 6 で
  実行を確かめ、走らなければ手動実行で補う。
- **マージと `latest`**: 実機確認はマージ前にブランチから押した `latest` で行う。マージ後は main の実行が
  同じ内容の `latest` を押し直すだけなので、サイトのボタンが公開される時点でイメージは Public で確認済み。
  確認の後にイメージの入力へ触れる変更をブランチに足した場合は、マージ前にもう一度ブランチから押して
  該当項目を確かめる。一時的なトリガーの取り忘れは §11 の 4 と plan の最終タスクで防ぐ。
- **GHCR の可視性**はオーナーの手作業（§11 の 2）。private のままだと Codespaces がイメージを pull できない。
- **git worktree からのローカルビルド**は §4.2 のとおり止まる（通常の clone を使う）。
- **将来の `X-Frame-Options`**: docs/design.md D14 は `X-Frame-Options: SAMEORIGIN` を予定の既定に挙げている。
  入れるときは切り替え可能にしないとプレビューが壊れる（VS Code web スパイク: SAMEORIGIN で iframe が
  `chrome-error://` になる）。
- **`confirm()` とポップアップ**はプレビューの iframe の sandbox で動かない（`allow-modals` / `allow-popups` なし）。
  サンプルの scaffold は使わないが、訪問者が足した `data-confirm` の削除ボタンは黙って何もしない。文書で案内する。

## 13. 本 spec での決定（一覧）

1. `CYBERTRAIN_SESSION_SAME_SITE` は大文字小文字を区別した完全一致（§3.2）。
2. `CYBERTRAIN_SESSION_PARTITIONED` は `1` / `true` 以外をすべて偽とし、エラーにしない（§3.2）。
3. `Partitioned` も `Secure` を強制する（§3.3）。
4. None / Partitioned → Secure の規則は `Cookies.serialize` に置く（§3.3）。
5. `CYBERTRAIN_HOST` は検証しない（§3.2）。
6. `examples/blog/config/app.rb` のコメントもテンプレートと一緒に直す（§3.5）。
7. 補助ステージ `cli-src` で gem の入力だけをキャッシュキーにする（§4.1）。
8. `XDG_CACHE_HOME=/opt/cybertrain-cache` で spin のキャッシュもホームの外に置く（§4.1）。
9. ミラーは `/opt/cybertrain-mirror/cybertrain.git`、dev 所有、`--depth 1` の 1 コミット（§4.1）。
10. `insteadOf` を `.git` なし・ありの 2 本にする（§4.1）。
11. profile スクリプトを `/etc/bash.bashrc` からも読む（§4.1）。
12. イメージの既定の `CMD` を `playground-server` にする（§4.1）。
13. ガイドの再ビルド時間を「約 1 分」と書く（決定書の「約 30 秒」を実測に合わせて改める、§5.2）。
14. devcontainer に `files.autoSave: "off"` と `label` と `name` を足す（§6.1）。
15. `playground-server` は `flock` + ポート確認で冪等にし、`APP_DIR` 引数を取り、ガイドはコンテナごとに 1 回だけ開く（§6.2）。
16. profile の Codespaces 用変数は既定値として入れ、上書きしない（§6.3）。
17. CI はテストしたイメージを `docker tag` + `docker push` で出す（§8.1）。
18. 許可リストは `playground/Dockerfile.dockerignore` に置き（§4.2）、CI に devcontainer.json の読み取り検査を入れる（§8.1）。
19. スモークテストに E1（`cp -a` したコピーが再ビルドなしで起動する）を入れ、フォールバック 1 の前提を CI で毎回確かめる（§8.2）。
20. サイトのナビの表記は `Playground`、ヒーローのボタンは `Try it in your browser`、closer とフッターは変えない（§7.1、§7.3）。
21. Codespaces の実機確認はマージ前にブランチから行い（一時的な push トリガーで `latest` を公開）、`v0.2.1` のタグはマージ後に打つ（§10.3、§11）。

## 14. 実装後の差分（as built, 2026-10-02。実機確認は 2026-10-06〜07 に実施、§14.6）

ブランチ `web-playground` で plan の 8 タスクとタスクごとのレビュー、ブランチ全体のレビューと
1 回の修正を終えた時点の記録。開発機での確認: フルの `spin test` が 66/66（92 s）。Docker Desktop
（linux/arm64）で `--no-cache` のビルドが 146 s、そのイメージでスモークテストの 29 項目がすべて通過（130 s）、
イメージは圧縮 142 MB、ディスク 597 MB（§1.4 のスパイク値は 143 MB、607 MB）。

未実施: ブランチの push（オーナーの認証が要り、オーナーが後回しにした）。そのためイメージは未公開で、
ワークフローは GitHub で一度も走っておらず（amd64 のビルド、runner でのミラーの手順、GHCR への push は
未検証）、§10.3 の実機確認（L1〜L12）も済んでいない。それに頼る記述（`/workspaces` の外の `workspaceFolder`、
private ポートでの自動プレビュー、実際のプレビューでの Cookie、2 コアでの再ビルド時間など）は未検証で、
§6.5 のフォールバックは必要になっておらず適用もしていない。
ブランチの先頭のコミット「TEMP: live check: publish latest from web-playground」は §10.3 の 1 の一時トリガーで、
確認の後に取り消す。

**追記（2026-10-07）:** 上の「未実施」は解消した。ブランチは SP2 の `web-playground-sp2` と合わせた 1 本の PR #12 として
2026-10-06 にマージされ（ae6b957）、「Playground image」は PR でもマージ後の main でも GitHub で成功し（`image` ジョブが
615 秒）、`latest` は認証なしで pull できる公開のイメージになった。ブランチの先頭の「TEMP: live check」のコミットは PR に
含めず、一度も使っていない。§10.3 の実機確認は main の `latest` で行い、結果は §14.6 に書く。その結果、§6.5 のフォールバック 2
を適用し、Cookie の前提（§1、§3）の誤りを訂正し、Codespaces 用の Cookie の既定（§6.3）を外した。SP2 と SP3 は 2026-10-07
に中止した（SP2 のコードはツリーから外した）。

### 14.1 フレームワーク、イメージ、起動スクリプト（§3〜§6）

1. §3.7: `test/cookies.rb` の `.expected` は CRuby ではなく、コンパイル済みバイナリから
   `script/regen-snapshot test/cookies.rb` で作る。既存のテスト "parse of a malformed percent-escape does
   not raise (Spinel diverges from CRuby, which raises ArgumentError)" が CRuby では例外になり、出力が
   一致しないため。新しい serialize のテストは §3.7 の 2 つに "serialize writes Secure once when secure,
   same_site None and partitioned are all set"（3 つを全部指定しても `Secure` は 1 回、続けて `Partitioned`）
   を足した 3 つ。`session_secure` が真の本番アプリを他サイトの枠に出す場合のため（plan の Review Focus 5）。
2. §3.8・§9: `site/tutorial.html` の環境変数の表（README の表を行ごとに写したもの）にも同じ 3 行を同じ順と
   文面で足し、重複になった箇条 "The default bind host is `127.0.0.1`; `host` is a `Config` attribute that
   `config/app.rb` can set." を消した。§9 の対象から漏れていたが、site/README.md の内容規則（"when those
   change, change the site to match"）が求めるため。
3. §4.1: ミラーの手順の fetch は `git -C "$mirror" -c safe.directory='*' fetch ...` ではなく次の形:
   `git -C "$mirror" fetch -q --depth 1 --no-tags --upload-pack "git -c safe.directory='*' upload-pack" /tmp/checkout.git "+HEAD:refs/heads/main"`。
   バインドした `.git` は dev 以外（ローカルでは root）の所有に見え、git の所有者検査はローカルの fetch が
   起こす upload-pack の側で走り、fetch に付けた `-c` はそこへ渡らないため（spec の形では最初のビルドが
   "detected dubious ownership" で止まった）。§4.1 の「所有者を揃えれば git の `safe.directory` 検査に一切
   かからない」はミラーを clone する側の話で、ミラーを作る側には当たらない。設定は残さない（`/etc/gitconfig`
   は `insteadOf` 2 本だけ）。使い方のコメントのタグは §10.2 と同じ `cybertrain-playground:local`。
4. §5.2: `PLAYGROUND.md` の「Start a fresh app」の最後に 1 文 "The new app has no root route, so `/` shows
   "Not Found": its pages start at `/products`." を足した。新しいアプリの `config/routes.rb` は空で、
   プレビューの `/` がルーターの "Not Found" だけになり、失敗に見えるため。
5. §6.2（§13 の 15）: `playground-server` の検査はロックとポートの 2 つではなく 3 つ。ポートの後に
   `pgrep -u "$(id -u)" -f '^[^ ]*ruby[^ ]* [^ ]*/cybertrain server( |$)'` で同じユーザーの
   `cybertrain server`（手で起動し、コンパイル中で待ち受けていないもの）を探し、あれば次を出して 0 で終わる:
   `playground-server: a cybertrain server is already starting, so no second server is started: ${url}`。
   コンパイル中（Ruby の編集の後で約 1 分）の再アタッチが 2 つ目のサーバーを起こし、そのビルドが
   `build/bin/gen` を書き換えて、手で起動したサーバーを "Text file busy" で落としたため（修正前のイメージで
   新しい D4 が `while compiling: exit 137` で落ちたのが赤の証拠）。既知の限界: ポートではなくユーザー単位で、
   ブログが 3000 で動いている横での `PORT=4000 playground-server` は "already starting" と言って
   何も起動しない（playground/README.md に記載）。

### 14.2 サイトと README（§7）

6. §7.1・§7.3・§9: CSS は §7.1 の 1 規則 `.step > .cta-row { margin-top: 28px; }`（当初の「新しい CSS
   規則…を足さない」を実装前に 53b8159 で改めたもの）に加えてもう 1 つ、`@media (max-width: 440px)` の中の
   `.nav-links .nav-wide-only { display: none; }` と `.nav-links ul { gap: 12px; }`。3 ページの主ナビの
   "How it works" の `<li>` に class `nav-wide-only` を付けた。4 つ目のリンクで、375 px では "How it works"
   が 3 行（67 px、64 px のヘッダーより高い）に折れてリストが余白に 11 px はみ出し、360 / 320 px ではページが
   9 / 49 px 横に動いたため（実測）。最初の 400 px では 401〜437 px（412〜430 px の大きい電話）で 2 行に
   折れたので 440 px にした（441 px で 4 つのリンクが 3.8 px の余裕で 1 行に入る）。
7. §7.2: 01 の stage の行は "One click · GitHub Codespaces" ではなく "No install · GitHub Codespaces"。
   README は 1 クリックとは言っておらず（内容規則）、§1.3 の流れでもボタンの後に「Create codespace」か
   「Resume」（未ログインならサインインも）が要るため。README の "without installing anything" に合わせた。
8. §7.2・§9: `<body>` は §7.2 に書いていないが、tutorial と同じ `<body class="tutorial">`（900 px 未満で
   目次が固定バーになるときの `html:has(body.tutorial) { scroll-padding-top: 92px; }` を効かせる）。
   `site/README.md` は §9 のとおり冒頭の段落に `playground.html` を足し、`assets/site.js` の説明を "marks the
   current step in the contents lists" に広げた（目次を持つページが 2 つになったため）。
9. §7.4・§7.2・§7.5: 文書の `docker run` は `-p 3000:3000` ではなく `-p 127.0.0.1:3000:3000`（README、
   `site/playground.html`、playground/README.md の「Run it」で同じ 1 行）。`-e CYBERTRAIN_HOST=0.0.0.0`
   と合わせると開発サーバー（認証なし、開発用のエラーページ）がホストの全インターフェースに出て LAN から
   届くため（Linux では Docker の規則が ufw を迂回する）。`http://localhost:3000` はそのまま開ける。
10. §7.5・§12: playground/README.md は spec の次の記述を正した。
    - Build it: Spinel の `make deps` が prism と rbs の gem を取るので rubygems.org に接続する（§7.5 の 3 は
      "rubygems is not used"）。接続先の一覧に Docker Hub（`ubuntu:24.04`、`docker/dockerfile:1`）も足した。
    - URL が `https://github.com/saeki-mototsune/cybertrain` で始まる別のリポジトリは、ミラーに向くのでは
      なく clone できない（git は一致した接頭辞だけを置き換えるので、`…/cybertrain-foo` は存在しない
      `…/cybertrain.git-foo` になる）。§7.5 の 10 と §12 の「`insteadOf` は接頭辞の一致」はこの点が誤り。
    - 2 つの規則は push にも効く: その URL への `git push` は GitHub ではなくミラーに入る（Limitations に
      記載）。`pushInsteadOf` は足さず、§4.6 の約束（`insteadOf` 2 本）を保つ。Codespaces 自身の clone
      （`/workspaces` の下）はこの接頭辞に一致しない見込み: GitHub の API が返すリポジトリの正規名は
      `CyberTrain`（`clone_url` は `https://github.com/saeki-mototsune/CyberTrain.git`。§6.4 の「実体は
      `cybertrain`」は誤り）で、git は `insteadOf` の接頭辞を大文字小文字を区別して比べるので、その clone の
      `git pull` と `git push` は GitHub に向くはず。L2 で `git remote -v` を記録して確かめる。

### 14.3 CI とスモークテスト（§8）

11. §8.1（§13 の 18）: ワークフローは全文から次を変えた。
    - `actions/checkout@v4` に `persist-credentials: false`: 既定では `packages: write` の `GITHUB_TOKEN` が
      `.git/config` に残り、許可リストの `.git` ごとビルドコンテキストにも入るため。
    - `npx --yes @devcontainers/cli@0 read-configuration` の手順をやめ、手順 "devcontainer.json is valid JSON"
      で `jq empty .devcontainer/devcontainer.json`: `read-configuration` は壊れた JSONC も通し、公開の job に
      版を固定しない npm パッケージを持ち込むだけだったため。以後 `devcontainer.json` はコメントや末尾の
      カンマの無い厳密な JSON に保つ（§6.5 の代替もそうなっている）。
    - 2 つのパスの一覧に `cybertrain.rb`: ミラーが運ぶフレームワークの入口で、これだけの変更でもビルドする。
    - `provenance: false`: runner の Docker が containerd の image store だと `load: true` でも来歴証明が
      残って push され、GHCR に unknown/unknown の行が出うるため（§8.1 の「付かず」は従来の store の話）。
    - `cache-to` に `ignore-error=true`: リリースでは main とタグの実行が同じキャッシュに同時に書くので、
      書き出しの衝突でタグの実行が落ちて `X.Y.Z` が出ないように。
    - タグのときだけの手順 "The tag is v + Cybertrain::VERSION": タグ名が `v` + `cybertrain/version.rb` の
      `VERSION` でなければビルドの前に落ちる（付け間違えたタグを公開しない）。
12. §8.2: 26 項目ではなく 29 項目（plan の Review Focus から足した）。
    - D3: コンテナの再起動（Codespaces のアイドル停止と再開）の後、サーバーが 1 つだけ戻り、前の記事が残る。
      `docker restart` が 0 で終わり `.State.StartedAt` が変わったことも求める（再起動しなくても古い
      サーバーが他の条件を満たしてしまうため）。
    - D4: 手で起動した `cybertrain server` に触れない。コンパイル中は "is already starting"、待ち受け後は
      "is already in use" で、どちらも 0 で終わり、サーバーは 1 つ（項目 5）。
    - C3: `CODESPACES=true` で対話シェルとログインシェル（`bash -ic`、`bash -lc`）が Cookie の 2 変数を
      持つ（訪問者が新しい端末で起動したサーバーが 403 にならないため）。
    - B2・B3 は `/tmp` ではなく `/workspace` で走る（ガイドの「Start a fresh app」はブログの隣に作る）。
      落ちたときはそのログの末尾 40 行を `sed "s/^/  | /"` で字下げして出す（`--rm` で消える原因を残す）。
    - F1 は時間切れ（60 s で終わらずに消されたコンテナ）も失敗にする（§8.2 は「0 以外で終わり」）。
    - 時間: コンパイルは A9、D4、B3 の 3 回（§8.2 の目安は 2 回）。開発機で 130 s、CI では未計測。

### 14.4 検証（§10、§11）

13. §10.2 の 3: devcontainer CLI（0.89.0）の `up` は `postAttachCommand` を実行して終わるのを待つ（§10.2
    は「`up` では走らない」としていた）ので、前面のサーバーで返らない。ローカルの確認は
    `up --workspace-folder . --skip-post-attach` で行う。フラグなしの `up` を再アタッチとして走らせると、
    `playground-server` は "already running" で 0 で終わり、サーバーは 1 つのままだった。
14. §10.3・§11: 実機確認は 2026-10-06〜07 に実施した（結果は §14.6）。以下は実施前の記録。§11 の 1 の push はオーナーの手元での承認（SSH エージェント）が要る。
    チェックリストには最終レビューの観察を足した: L3 で `id`（`uid=1000(dev)` を期待し、違えば
    `"updateRemoteUserUID": false`）、L1・L3 で最初の起動が何かをコンパイルしたか、L2 で codespace の clone の
    `git remote -v`、L8 で `server` の端末をゴミ箱のアイコンで閉じた後のサーバーの数（開発ループは SIGHUP を
    再起動として扱うので、端末のない孤児が 3000 番とロックを持ち続けうる）、公開後のパッケージのページに
    unknown/unknown の行が無いこと、スモークテストの総時間（ローカルと CI）。フォールバックと L7 の書き換え
    では playground/README.md の該当する箇条も直す（文字列は plan の Task 9）。結果は playground/README.md
    （§7.5 の 6・7）に書き、この節も実測で更新する。

### 14.5 直さずに残したもの（最終レビューの「leave」など）

- 3 つ目の検査はユーザー単位（項目 5）。root 所有のロックが残ると、flock の失敗も "already running" と出る。
- `jq empty` は空のファイルや連結した複数の JSON 値も通す（`jq -e -s 'length == 1'` を足せば防げる）。
- `v*` のタグはプレリリースでも古いコミットでも `latest` を動かす。`v*` の ref の手動実行は `X.Y.Z` も押す。
- ヒーローの 3 つのボタンは約 901〜1299 px（1280 を含む）で 2 + 1 に折れる（ラベルはオーナーが変えてよい）。
- `config/app.rb` のコメント（テンプレートと examples/blog）の変数の一覧に `SPINEL_WORKERS` が以前から無い。
- smoke.sh を arm64 の機械で公開版（amd64）に当てると、docker の platform の警告で G1、G2、G4、G6 が落ちうる。
- B2 と B3 が両方落ちると、要約に出る B23 の出力の末尾 40 行から B2 のログが押し出されうる。
- イメージに `/tmp/sp_ossl_probe.c` が残る。`cybertrain new` が git の detached HEAD の助言を約 15 行出す。
- 「What opens」は `PLAYGROUND.md` が必ず開くように書いている（開くかは L10 で決まる）。
- §4.2 の worktree での停止は一度も走らせていない（worktree を作らない制約のため）。
- 別の仕事: 端末を閉じたとき開発ループが SIGHUP を再起動として扱うこと、Actions の SHA での固定。

### 14.6 実機確認の結果（2026-10-06〜07、§10.3）

環境: GitHub Codespaces の既定の機械（2 コア、8 GB RAM、32 GB、東南アジア）。イメージは main（PR #12 のマージ ae6b957）の
CI が出した `latest`。ブラウザは Chrome の新しいプロファイル（`app.github.dev` の Cookie なし）、リンクは
`https://codespaces.new/saeki-mototsune/CyberTrain?quickstart=1`。確認用の codespace は確認ごとに作って削除した。
前提の確認: マージ（ae6b957）、タグ v0.2.1、main の CI の成功、2 つのイメージの `latest` が認証なしで pull できること
（GHCR のマニフェストが 200）。

| 行 | 結果 | 観察 |
| --- | --- | --- |
| L1 | 記録 | 作成ページのボタンは「Create new codespace」の 1 つ（と「Change options」）で、課金先はそのページに出ない。ボタンからエディタの表示まで 21 秒、blog のファイルが出るまで 57 秒。ここで Workspace Trust のダイアログが出て、押すまで端末が始まらない（下の 1）。押してから 8 秒以内にバナーと Listening。最初の起動でコンパイルは走らなかった。 |
| L2 | 通過 | Explorer の根は `blog [Codespaces: …]` でアプリのファイルが見え、`pwd` は `/workspace/blog`、blog のリポジトリは変更 0。`ls -ld /workspaces` は `drwxrwxr-x dev root` で `touch` できる（フォールバック 1 は要らない）。codespace の clone の origin は `https://github.com/saeki-mototsune/CyberTrain`（大文字の C。イメージの `insteadOf` は小文字の URL だけに当たる）。 |
| L3 | 通過 | `server` の端末にバナーと `* Listening on http://127.0.0.1:3000`。`x86_64`、`CODESPACES=true`、`uid=1000(dev)`（ユーザーの再割り当てなし）。当時は Cookie の変数が `None` と `1` だった（下の訂正）。 |
| L4 | **不合格** | 自動で開いたプレビューは Chrome の「github.com refused to connect.」になった（小さい枠では壊れたページのアイコンだけ）。private ポートのサインインが iframe を github.com のページへ移し、そのページは枠に入れられないため。Ports → Open in Browser で通常のタブを一度開いて認証し、プレビューを再読み込みすると出る。codespace を Stop して再開するたびに、また必要になる。オーナーも同じ画面を見て、同じ手順で直した。→ 下の 2。 |
| L5 | 通過（対照は訂正） | 既定の設定で、プレビューの中の記事の作成は 303 で 403 にならなかった。Cookie の行は `HttpOnly; SameSite=None; Max-Age=1209600; Secure; Partitioned`。`location.ancestorOrigins` は `github.dev` の 3 つ（webview の origin も `*.github.dev` で、`vscode-cdn.net` ではない）。Lax の対照は下の訂正。 |
| L6 | 一部未確認 | オーナーが自分の環境で、記事を作ってエラーなしで通ることを確かめた。使ったブラウザは記録していない。Firefox と Safari を個別には確かめていない。 |
| L7 | 通過 | ビューの編集は再読み込みですぐ出る。モデルへの検証の追加は、保存からバイナリの書き込みまで 99 秒（2 vCPU）で、サーバーはその直後に再起動した。120 秒を超えないので「about a minute」は直していない。 |
| L8 | 通過 | ブラウザの再読み込みでも、タブを閉じて github.com/codespaces から開き直しても、端末とプレビューが復元され、サーバーは 1 つのまま。`playground-server` をもう一度走らせると "already running" で終了 0。`server` の端末をゴミ箱のアイコンで閉じると、アプリは親なし（ppid 1）の孤児として 3000 番で答え続ける（playground/README.md の限界の節に既出）。 |
| L9 | 通過 | Stop して Restart してから約 40 秒後に、`postAttachCommand` の新しい端末でサーバーが自動で起動し、L5 の記事も残っていた。プレビューは再び認証が要った。止めた codespace を一覧から開くと「Codespace is stopped」の画面になり、Restart を 1 回押す。 |
| L10 | 記録 | Trust を押した直後に `PLAYGROUND.md` が自動で開いた。それ以前は `README.md` がプレビュー表示で開いていた。 |
| L11 | 通過 | `cybertrain new shop` から scaffold、migrate、server までがすべて通った（Listening まで約 4 分。gen、db、アプリの順に、初回のコンパイルが走る）。3000 番での商品の作成は 403 になったが、L5 の対照実験の残骸が原因だった（下の訂正）。きれいなオリジンの 3001 番では、blog のあとに shop を動かしても作成できた。新しいアプリの `/` は "Not Found"（ガイドに書いてある）。 |
| L12 | 通過 | 削除した。 |

見つかったことと直し（ブランチ `codespaces-open-browser` の変更）:

1. **Workspace Trust のダイアログ**（仕様書に無かった）。初回に「Do you trust the authors of the files in this folder?」が出て、「Trust Folder & Continue」を押すまで `server` の端末が始まらず、サーバーも起動しない。`PLAYGROUND.md` の Good to know と README に一行足した。
2. **L4（§6.5 のフォールバック 2）。** `onAutoForward` を `openPreview` から `openBrowserOnce` に変えた（仕様書は `openBrowser` だが、開発ループの再起動のたびに 2 つ目のタブが開かないよう、最初の 1 回だけにした）。ガイドと README と `site/playground.html` は Variant B の文面にした（アプリは新しいタブで開く、再読み込みは「アプリのタブ」、ポップアップを止められたら Ports の Open in Browser）。あわせて、アプリのタブが一度開いたあとなら、Ports の「Preview in Editor」でエディタ内にも出せることを一行足した。
3. **`vscode-cdn.net` の誤り。** Codespaces のプレビューの webview は `*.github.dev` で、`vscode-cdn.net` ではなかった。`playground/README.md` と `profile.sh` の説明を直した（4 で説明ごと外れた）。
4. **Cookie の既定を外した**（下の訂正）。
5. 直していないもの: 再ビルドの「about a minute」（99 秒）、孤児のアプリ（既出）。

訂正（Cookie の前提）: 当初の前提（§1、§3、§6.3: Codespaces のプレビューは別サイトの iframe で、`SameSite=Lax` の Cookie は保存も送信もされず、すべてのフォームの POST が 403 になる）は、Codespaces では成り立たない。Public Suffix List（2026-10-01 版）に `github.dev` も `app.github.dev` も無く、エディタ（`<codespace>.github.dev`）、webview（`<id>.github.dev`）、アプリ（`<codespace>-3000.app.github.dev`）は、origin は別でも同じサイトである。何も残っていない新しい codespace で、サーバーを `SameSite=Lax`、`PARTITIONED=0` だけで起動し（署名鍵は替えない）、サインイン後のプレビューで記事を作ると、エラーなしで通った。L5 の最初の対照（Lax で 403）は、署名鍵を替えたために古い `SameSite=None; Partitioned` の Cookie が先に送られて新しい Cookie を隠していただけで、Lax が落ちた証拠ではなかった。同じ実験が 3000 番に残した Lax の Cookie がそのオリジンの `_cybertrain_session` を汚し、L11 の 403 を起こした（Cookie の名前を変えると通り、きれいな 3001 番では blog のあとの shop も通った）。2026-10-07 にオーナーの決定で、Codespaces 用の Cookie の既定（`profile.sh` の `None` と `Partitioned`）を外し、スモークテストの C1 は「既定の `SameSite=Lax` のまま」、C3 は「interactive と login のシェルが `/opt/cybertrain/bin` の `spin` を見つける」に替えた。フレームワークの変数（`CYBERTRAIN_SESSION_SAME_SITE`、`CYBERTRAIN_SESSION_PARTITIONED`）は 0.2.1 の一般的な機能として残す。この節より前の Cookie に関する記述は、設計時点の記録としてそのまま残す。教訓: 対照実験で署名鍵を替えてセッションを「リセット」しない。新しいオリジンを使う。

変更後のローカルの確認（ブランチの 44ff98f、arm64 の Docker Desktop）: イメージのビルドが成功し、スモークテストの 29 項目（Cookie の既定を外したあとの C1 と C3 を含む）がすべて通った。

ブランチの設定での確認（2026-10-07、`codespaces.new/saeki-mototsune/CyberTrain/tree/codespaces-open-browser`、新しい codespace、Chrome の新しいプロファイル、クライアントは 1 つ）: 接続して「Trust Folder & Continue」を押すと、5 秒以内に新しいタブが自動で開き（`pf-signin` を経由して）、アプリ（タイトル `Blog`）が表示された。ポップアップはブロックされなかった。Ruby のファイルを `touch` して再ビルドさせ、サーバーが再起動しても（`Build succeeded; restarting`）、2 つ目のタブは開かなかった。Stop して Restart した別の codespace では、信頼を押したあとにサーバーは起動したが、タブは開かなかった（コンソールに `Revived port: 3000` があり、ポートは前の接続で転送済みの扱い）。そのため、再開後は Ports の「Open in Browser」を使うと、README、`PLAYGROUND.md`、サイトに書いた。注意: 信頼のクリックからタブが開くまでは約 5 秒で、Chrome のユーザー操作の有効時間（約 5 秒）に近い。遅い環境や、ポップアップに厳しい Safari・Firefox では開かない可能性があり、そのための案内は文面にある。なお、最初の codespace では、作成ログのリンクを押して信頼のダイアログが早く出たあと、接続が数分止まり、別のタブで開き直すと繋がった（私の操作が原因と見ている。訪問者の経路ではない）。

未確認: Firefox と Safari（L6）、信頼のダイアログを「Cancel」したあとの復帰の手順（状態バーの Restricted Mode から信頼したときに、サーバーが自動で起動するか）。
