---
source_sha256: 4d2f34b5565d3b155fb42b317bb2b8548de7e76aeab9e9f2f11e8cf44f6bd971
---
# リアルタイム：ブラウザーへのストリーム

開いているページに、再読み込みなしで変更を送ります：Server-Sent Events または WebSocket の上の Turbo Streams、アクション・ジョブ・フィードからのブロードキャスト、そして同じストリームを自前の JavaScript から使う方法です。

## ブロードキャストがページに届くまで

ページは名前の付いたストリームを 1 つ以上購読し、アプリケーションのどこからでも名前を指定してストリームにブロードキャストでき、購読しているページはすべて約 10 分の 1 秒以内にそのメッセージを受け取ります。

- **ストリームには名前がある。** 名前は短いテキストなら何でもよく（`"alerts"`）、レコードを渡すとそのテーブルと id が名前になります（`"articles:12"`、`Cybertrain::Stream.name_for(@article)`）。
- **ブロードキャストは 1 行。** `Cybertrain::Stream.broadcast(name, payload)` は、フレームワークがアプリケーションのデータベースに自分で作るテーブル `cybertrain_messages` に行を挿入します。`DB.transaction` の中では、トランザクションがコミットされたときだけメッセージが送られます。行なので、ブロードキャストはデータベースを共有するどのプロセスからでも動きます：リクエスト、`worker` プロセスのジョブ、フィードのコールバック、`Main.command`。
- **各 Web プロセスがテーブルをポーリングする。** `server` プロセスごとに 1 本のスレッド（ストリームのポーラー）が `stream_poll_ms`（100 ms）ごとに新しい行を読み、そのプロセスが抱えるブラウザーにそれぞれ渡します。1 分に 1 回、`stream_retention`（60 秒）より古い行を削除します。
- **ブラウザーは 1 つのエンドポイントにつなぐ。** `/cybertrain/stream` に Server-Sent Events（`EventSource`）か WebSocket で、読んでよいストリームを示す署名付きトークンを添えてつなぎます（[署名付きストリーム名](#signed-stream-names)）。

起動するものはありません：`./<app> server` がポーラーを動かし、エンドポイントを提供します。`config.stream_path = ""` で機能全体が無効になります。

## Turbo Streams

[Turbo](https://turbo.hotwired.dev) は、Rails 8 のアプリケーションと同じように、`<turbo-stream action="append" target="comments">` 要素からページを更新します。レイアウトで Turbo を読み込み（アセットパイプラインはありません：CDN か `public/` に置いたコピー）、`turbo_stream_from` でページを購読させます。ブロードキャスト、ストリームエンドポイント、ストリームのヘルパーには、`bin/<app>.rb` と `bin/db.rb` に `require "cybertrain/streams"` が必要です。ないと、`spin run gen` は最初の `turbo_stream_from` で止まり、その行を示します（[サブシステム](how-it-works.md#subsystems)）：

```erb app/views/layouts/application.html.erb（抜粋）
<head>
  <%= csrf_meta_tags %>
  <script type="module" src="https://cdn.jsdelivr.net/npm/@hotwired/turbo@8/dist/turbo.es2017-esm.js"></script>
</head>
```

```erb app/views/articles/show.html.erb（抜粋）
<%= turbo_stream_from @article %>
<div id="comments">
  <% @article.comments.each do |comment| %>
    <%= render "comments/comment", comment: comment %>
  <% end %>
</div>
```

`turbo_stream_from` は String とレコードをいくつでも受け取り、そのすべてに 1 つのトークンを持つ URL の `<turbo-stream-source>` 要素を 1 つ書き出します。Turbo はそれを `EventSource` として開きます。`turbo_stream_from @article, ws: true` とすると代わりに `ws://` の URL（HTTPS の後ろでは `wss://`）になり、Turbo はそれを WebSocket として開きます。どちらの場合も、ページにあなたの JavaScript は要りません。ただし Turbo は、失った WebSocket（ネットワークの切断、サーバーの再起動）を開き直しません。そのページは再読み込みされるまで更新を受け取れなくなります。`EventSource` なら自分で再接続し、見逃した分を再送してもらえます。WebSocket が必要でなければデフォルトのままにするか、自分の JavaScript で再接続してください（後述の `&after=`）。

あとは、何かを変えたアクションからブロードキャストします：

```ruby app/controllers/comments_controller.rb（抜粋）
def create
  @comment = Comment.new(comment_params)
  @comment.article_id = @article.id
  if @comment.save
    Cybertrain::Stream.broadcast_append_to(@article, target: "comments",
                                           partial: "comments/comment", locals: { comment: @comment })
  end
  redirect_to article_path(@article), status: :see_other
end
```

`broadcast_append_to(stream, target:, ...)` は内容をレンダリングし、`<turbo-stream>` 要素で包んでブロードキャストします。内容は、`locals:` を伴う `partial:`（`Cybertrain::Views.render_partial` がレンダリング）、`component:`（[ビューコンポーネント](template-language.md#components)）、`html:`（`SafeString` でなければエスケープ）のいずれかです。ターゲットは DOM の id か、レコードです。レコードの DOM id は `dom_id(record)`（`"comment_7"`）です。ほかも同じように動きます：`broadcast_replace_to`、`broadcast_update_to`、`broadcast_prepend_to`、`broadcast_before_to`、`broadcast_after_to`、`broadcast_remove_to(stream, target:)`、`broadcast_refresh_to(stream)`（Turbo 8 がモーフィングでページを再読み込みします）。

Turbo はリンクとフォームも fetch のリクエストに変えます（Turbo Drive）。scaffold はすでに Turbo の期待どおりに応答します：フォームが成功したら 303 のリダイレクト、失敗したらフォームをもう一度表示して 422 です。

### Turbo Stream でフォームに応答する

Turbo が送信するフォームは `text/vnd.turbo-stream.html` を受け付けます。リダイレクトの代わりにストリームで応答するには、要素を自分でレンダリングします。`Cybertrain::Turbo` がそれを組み立てます（`replace`、`update`、`append`、`prepend`、`before`、`after`、`remove`、`refresh`）：

```ruby
def destroy
  @comment = Comment.where(article_id: @article.id).find(params[:id])
  @comment.destroy
  if request.header("accept").to_s.include?("text/vnd.turbo-stream.html")
    render html: Cybertrain::Turbo.remove(@comment), content_type: "text/vnd.turbo-stream.html"
  else
    redirect_to article_path(@article), status: :see_other
  end
end
```

### ジョブ・タスク・フィードからブロードキャストする

ブロードキャストにリクエストは要らないので、ジョブがレンダリングして送れます：

```ruby config/app.rb（抜粋）
Cybertrain::Job.handle("price_refresh") do |payload|
  item = Item.find(Cybertrain::Cast.int(payload))
  item.refresh_price!
  Cybertrain::Stream.broadcast_replace_to("prices", target: item,
                                          partial: "items/price", locals: { item: item })
end
```

パーシャルは `Cybertrain::Views.render_partial` がレンダリングします。これはリクエストなしでレンダリングします：パスヘルパー（`item_path(item)`）は動き、リクエストを必要とするヘルパー（`csrf_token`、`params`、`flash`、`request_path`、`*_url`）は `Cybertrain::Views::OutsideRequest` を投げます（[リクエストの外でのレンダリング](template-language.md#rendering-outside-a-request)を参照）。ジョブはサーバーでも `worker` プロセスでも動き、ジョブが書いた行はすべてのサーバーのページに届きます。

## JavaScript から Server-Sent Events を使う

Turbo が駆動しないページ（チャート、ティッカー）では、ストリームを JSON で求めます。`stream_source_path` はトークンと `mode=json` 付きのエンドポイントのパスを、`signed_stream_name` はトークンだけを返します：

```erb app/views/dashboards/show.html.erb（抜粋）
<div id="price" data-src="<%= stream_source_path "prices", "alerts" %>"></div>
<script type="module">
  const el = document.getElementById("price");
  const source = new EventSource(el.dataset.src);
  source.addEventListener("prices", (event) => {
    const message = JSON.parse(event.data);   // {"stream":"prices","id":42,"data":"..."}
    el.textContent = JSON.parse(message.data).price;
  });
  source.addEventListener("alerts", (event) => console.log(JSON.parse(event.data).data));
</script>
```

`mode=json` では、各メッセージはそのストリームの名前を持つイベントで、データは `{"stream": ..., "id": ..., "data": ...}`、ペイロードは `data` に入ります（JSON は String としてブロードキャストします：`Stream.broadcast("prices", JSON.generate({ "price" => 12.5 }))`）。デフォルトの `mode=raw` では、ペイロードはそのまま普通の `message` イベントとして送られ、Turbo はそれを読みます。

接続が切れるとブラウザーは自分で再接続し、最後に見たイベントの id（`Last-Event-ID`）を送ります。するとエンドポイントは、まずそのストリームのメッセージのうち、id がそれより大きく、まだテーブルにあるもの（`stream_retention` の範囲内）をすべて再送するので、その間のものは失われません。それより長く離れていたページは再読み込みしてください。最初のイベントが届く前には、ブラウザーが送れる id がないので、その間に切れた接続には何も再送されません。ページが読み込み時に描いたものが、次のブロードキャストが届くまでの状態です。15 秒間何もなければコメント行（`: ping`）が送られ、プロキシが接続を開いたままにします。

## JavaScript から WebSocket を使う

同じ URL は WebSocket にも応答します。ページはそこから `ws://` か `wss://` の URL を作ります。パスとトークンは、この例のように `data-` 属性で渡してください：`<script>` 要素の中の `<%= %>` は HTML エスケープされ、ブラウザーはその場所ではデコードしません（`&amp;` がサーバーに届いてしまいます）。

```erb app/views/dashboards/show.html.erb（抜粋）
<div id="ticker" data-src="<%= stream_source_path "prices" %>" data-alerts="<%= signed_stream_name "alerts" %>"></div>
<script type="module">
  const el = document.getElementById("ticker");
  const scheme = location.protocol === "https:" ? "wss://" : "ws://";
  const socket = new WebSocket(scheme + location.host + el.dataset.src);
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (message.stream) console.log(message.stream, message.id, message.data);
  });
  socket.addEventListener("open", () => {
    socket.send(JSON.stringify({ subscribe: el.dataset.alerts }));
  });
</script>
```

`mode=json` では、各メッセージは同じ `{"stream", "id", "data"}` のエンベロープを持つテキストフレーム 1 つで、ページは接続中に JSON のテキストフレームを送ってストリームを変えられます：

| ページが送るもの | サーバーの応答 |
| --- | --- |
| `{"subscribe":"<token>"}` | `{"subscribed":["prices","alerts"]}`：接続が今読んでいるすべてのストリーム |
| `{"unsubscribe":"<token>"}` | `{"unsubscribed":["alerts"]}` |
| 検証できないトークン | `{"error":"bad token"}` |
| それ以外 | `{"error":"bad message"}` |

`mode=json` の接続は、トークンなしで開いてメッセージで購読することもできます。15 秒たってもストリームを 1 つも読んでいない接続は閉じられます（コード 1008）。WebSocket には `Last-Event-ID` がありません：再接続の後に追いつくには、URL に `&after=<the last id you saw>` を加えます。サーバーは 15 秒間何もなければ ping を送り、ping には応答します。ページからのバイナリフレームは無視されます。クローズコード：サーバーが止まるときは 1000、トークンが不正なら 1008、`stream_max_message` を超えるフレームには 1009、プロセスが満杯のときやページが遅れすぎたときは 1013 です。

## アクションからストリーミングする

アクションは、Rails の `ActionController::Live` のように自分のレスポンスを開いたままにできます：`stream` はアクションの後に接続のスレッドでブロックを実行し、ソケットを `Cybertrain::Sink` として渡します。

```ruby app/controllers/reports_controller.rb（抜粋）
def progress
  stream do |out|
    10.times do |i|
      out.write(Cybertrain::SSE.event(JSON.generate({ "done" => i * 10 }), event: "progress", id: i.to_s))
      break if out.wait_closed(1)   # クライアントが去ったら true
    end
  end
end
```

`stream(content_type: "text/event-stream", status: :ok)` は `Transfer-Encoding: chunked` で応答し、ブロックが戻ると接続を閉じます。`SSE.event(data, event: "", id: "", retry_ms: 0)` はイベントを 1 つ整形します。クライアントが去ると `out.closed?` が true になり、それ以降の書き込みは何もしません。ブロックはセッション、flash、ヘッダーに触れてはいけません：それらはレスポンスの先頭と一緒に送られています。

## 署名付きストリーム名

ページがストリームを読めるのは、それを名指すトークンがあるときだけです。トークンはストリーム名と、`secret_key_base` からストリーム専用に導出した鍵で作った HMAC-SHA256 の署名からなります（Rails の `turbo/signed_stream_verifier_key` と同じです）。そのためトークンがセッションクッキーとして通ることはありません。エンドポイントは署名を確かめ、セッションもデータベースも読みません。これは Turbo のモデルです：ページをレンダリングできた人は、そのストリームを読めます。トークンに期限はありません。`secret_key_base` を変えるとすべてのトークンが無効になり、そのデプロイをまたいで開いていたページは再読み込みされるまで受信が止まります（`EventSource` は 403 を最終的なものとして扱います）。

<!-- list: points -->
- 1 人のユーザーのためのストリームは、そのユーザーのレコードにちなんで名付けたストリーム `turbo_stream_from @user`（`"users:7"`）で、そのユーザーのページにだけレンダリングします。トークンを手に入れた人は誰でも、シークレットが変わらない限りそのストリームを読めます。
- トークンに期限はありません。`CYBERTRAIN_SECRET_KEY_BASE` を変えると、すべてのトークン（とすべてのセッション）が無効になります。
- トークンは URL に載るので、リバースプロキシのアクセスログに記録されます。フレームワーク自身のリクエストログは `[FILTERED]` と書きます。`/cybertrain/stream` についてはプロキシのログを止めるか、そのログをストリームと同じくらい非公開にしてください。
- トークンが不正か欠けていると、SSE では 403、WebSocket ではハンドシェイク直後の 1008 によるクローズになります。
- 名前は 1〜200 バイトで、制御文字とカンマを含みません。トークン 1 つには最大 16 個、接続 1 つには最大 64 個の名前が入ります。

## 上限と設定

`config/app.rb` で設定します（`c.stream_poll_ms = 250`）。範囲外の値なら、起動はメッセージを出して止まります。

| 設定 | デフォルト | 意味 |
| --- | --- | --- |
| `stream_path` | `"/cybertrain/stream"`（`CYBERTRAIN_STREAM_PATH`） | エンドポイントのパス。`""` でストリームを無効にします |
| `stream_poll_ms` | `100` | 各サーバープロセスが新しいメッセージを読む間隔（10 以上） |
| `stream_retention` | `60` | メッセージがテーブルに残る秒数。つまり再接続がどこまで追いつけるか |
| `stream_ping_interval` | `15` | ping までの無音の秒数。クライアントへの 1 回の書き込みが待てる時間でもあります |
| `stream_max_connections` | `1000` | プロセスあたりの開いたストリームの数。超えると SSE は 503、WebSocket は 1013 で閉じられます |
| `stream_max_message` | `65536` | ページからの WebSocket フレーム 1 つのバイト数（超えると 1009 で閉じます） |
| `stream_max_backlog` | `1000` | 遅いクライアント 1 つのために待つメッセージ数。超えると切り離されます（再接続して再送を受けます） |

開いたストリームは、ページが開いている間、接続 1 つとそのグリーンスレッドを占有します。nginx の後ろでは、レスポンスの `X-Accel-Buffering: no` ヘッダーがバッファリングを止めます。WebSocket では、プロキシが `Upgrade` と `Connection` を通す必要があります（Caddy と kamal-proxy は通します）。

## どのプロセスが何をするか

<!-- list: points -->
- **`./<app> server`** は、`CYBERTRAIN_WORKER=0` のときも含めて常にポーラーとエンドポイントを動かします：自分が抱えるブラウザーに配信するためです。ポーラーが動くまで、エンドポイントは 503（`stream poller is not running`）を返します。`serve` はポートを開く前にポーラーを始めるので、配信中のプロセスでこれが見えることはありません。
- **`./<app> worker`** と **`./<app> feeds`** は HTTP を提供せず、ポーラーも動かしません。そのブロードキャストは行であり、サーバーが配信します（[プロセスの役割](background-and-operations.md#process-roles)）。
- 1 つのデータベースを共有する複数のサーバーは、それぞれ自分のブラウザーにすべてのメッセージを、同じ順序・同じ id で配信します。

ページのストリームのテスト：[ストリームとコンポーネントのテスト](testing.md#testing-streams-and-components)。設計：[docs/design.md](../design.md) D36 と D37。

## フィードのヘルス

[WebSocket のフィード](external-services.md#consuming-websocket-feeds)は、HTTP を提供しない `feeds` のプロセスで動くことが多いので、そのヘルスはデータベースを通じて伝わります。フィードを動かす各プロセスの監視スレッドが、`feed_status_interval` 秒（10）ごとに、購読ごとに 1 行を `cybertrain_feeds` に書きます。このテーブルはフレームワークのものです（最初の使用時に作られ、`db/schema.rb` には含めません）。`server` のプロセスの `GET /up` はこれを読み、どれかの行について次のどちらかが成り立つと `503 feed stale` を返します：

<!-- list: points -->
- 書き手が古い：行が最後に書かれてから `health_feed_stale` 秒（180、`CYBERTRAIN_HEALTH_FEED_STALE`）より長くたっている。つまり、フィードを動かすプロセスが死んだか、止まったか、データベースを失った。または、
- フィードが黙っている：行は新しいが、フィードがその間メッセージを届けず、ping にも答えていない（何も受け取ったことのないフィードは開始時から数えます）。

2 つは別々に確かめられるので、生きている書き手が黙ったフィードを隠すことはありません。数えるのは、アプリケーションがいまも購読しているフィードの行だけです。どの役割も同じバイナリを動かすので、どの `subscribe` も登録していない名前の行（消したり名前を変えたりしたフィード）は無視されます。`health_feed_stale` は `feed_status_interval` より大きくなければなりません。そうでないと、2 回の書き込みの間にすべての行が古くなるからです。起動時にそれ以外は拒否されます。`CYBERTRAIN_HEALTH_FEEDS=0`（または `false`）はこの確認を止めます。しきい値より長く静かなのが正常なフィードや、別の方法でフィードを見ているデプロイのためです。テーブルが読めないとき、`/up` は 200 のままで、読めるようになるまで `WARN` の行を 1 つだけ出します。

`./<app> feeds status` は、運用する人のために行をフィードごとに 1 行で表示します：

```console
$ ./blog feeds status
trades  connected  web-1:4242  last activity 3s ago  restarts 0  updated 4s ago
```

<!-- list: points -->
- 行のキーはフィードの名前だけです。同じフィードを動かす 2 つのプロセスは互いの行を上書きします。各フィードを 1 つのプロセスで動かす理由がまた 1 つ増えます。
- きれいに止められた `feeds` のプロセス（TERM か INT：デプロイ、台数の削減）は、自分が書いた行を消します。わざと止めた役割は数えられなくなります。クラッシュしたプロセスや、フィードが何度も死んだ後で終了したプロセスは行を残し、それが古くなります。`/up` が報告するのはまさにそれです。
- 消したり名前を変えたりしたフィードの行は残りますが、`/up` はそれを無視し、`feeds status` は `(not registered)` と印を付けます。好きなときに消してください（`./<app> dbconsole` で `DELETE FROM cybertrain_feeds WHERE name = 'trades';`）。
- `status` はフィードの名前に使えません。`./<app> feeds status` がテーブルを表示するので、`subscribe("status", ...)` は ArgumentError を投げます。
- `/up` は何も再起動しません。Kamal がそれを見るのはデプロイ中の web の役割だけで、Docker はプロセスが終了したときにコンテナを再起動します。`feeds` のプロセスは、フィードが何度も死んだ後で終了します。その役割に再起動ポリシーを与えてください（[プロセスの役割](background-and-operations.md#process-roles)）。

設計：[docs/design.md](../design.md) D56。
