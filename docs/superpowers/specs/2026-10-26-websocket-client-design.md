# 外向き WebSocket クライアントと常駐購読（データ収集）

2026-10-26。ブランチ `claude/websocket-client`。前提となる決定は docs/design.md の
D24（外向き HTTP クライアント、`Cybertrain::Net`）、D27（同じソケット層の上のメーラー）、
D28（`Scheduler` / `Job`）、D32（テスト用のプロセス内受信器）。

## 1. 目的

サーバが動いている間、外部の WebSocket（`ws://` / `wss://`）のデータフィード
（相場のティック、IoT のテレメトリ、イベントストリームなど）に常時つなぎ、届いた
メッセージをアプリのブロックに渡す。切れたら自動で再接続し、購読メッセージを送り直す。

```ruby
# config/app.rb（または bin/<app>.rb が Main.run の前に require するファイル）
require "cybertrain/websocket"
require "cybertrain/net/tls"   # wss:// のときだけ

Cybertrain::WebSocket.subscribe("trades", ENV["FEED_URL"],
    headers: { "Authorization" => "Bearer #{ENV["FEED_TOKEN"]}" },
    stale_after: 30)
  .on_open    { |conn| conn.send_text(JSON.generate({ "op" => "subscribe", "channel" => "trades" })) }
  .on_message { |conn, text| Cybertrain::DB.with { |c| c.execute("INSERT INTO trades(raw) VALUES (?)", [text]) } }
```

成功の基準:

- フィードが FIN を送らずに黙っても、`stale_after` 秒以内に気づいて再接続する。
- 再接続のたびに `on_open` が走り、購読が復元される。
- 1 件のメッセージの処理で例外が出ても、接続は切れない。
- どの待ちも有界で、停止したピアがサーバ（`SPINEL_WORKERS=1` の OS ワーカー）を
  握り続けない。
- 非公開アドレスは既定で拒否、エラーメッセージはホストとポートだけを含む（D24 と同じ）。

## 2. スコープ外

- WebSocket サーバ（ActionCable 相当）。サーバ側は引き続き非目標。
- 拡張（`permessage-deflate`）とサブプロトコルの交渉。要求ヘッダに載せず、サーバが
  `Sec-WebSocket-Extensions` / `Sec-WebSocket-Protocol` を返したらハンドシェイク失敗。
- プロキシ、リダイレクトの追従、Cookie。
- 受信メッセージの永続化（テーブルへの自動保存、`Job` への投入）。必要ならアプリが
  `on_message` の中で行う。
- テキストフレームの UTF-8 検証。バイト列のまま渡す（RFC 6455 8.1 からの逸脱として
  README に書く）。
- 購読の外（リクエスト処理のスレッドなど）からの送信。`Connection` はコールバックの中で
  だけ有効。
- 動作中の購読の追加・削除。`subscribe` はサーバ起動前に呼ぶ（`Scheduler.every` と同じ）。
- `wss` の端から端までのテスト（D24 と同じく証明書を作れない）。

## 3. 構成

二層にする。`HttpClient` と `Scheduler` の関係と同じ形。

| ファイル | 役割 |
| --- | --- |
| `cybertrain/websocket/frame.rb` | フレームの符号化と復号、Accept キーの計算。ソケットに触れない純粋な関数で、CRuby でも動く |
| `cybertrain/websocket/client.rb` | `WebSocket::Client`: 同期クライアント。ハンドシェイク、送受信、ping / pong、close。`Net::*` の上 |
| `cybertrain/websocket.rb` | `WebSocket.subscribe`、`Subscription`、`Connection`、`Status`、購読ごとのスレッド、`start!` / `stop!` / `status` |
| `cybertrain/test/websocket_receiver.rb` | テスト用のプロセス内 WebSocket サーバ（127.0.0.1）。`Test::Receiver` の上 |
| `cybertrain/application.rb` | `serve` で登録済みのバックグラウンドサービスを起動・停止する（4.5 節） |

`cybertrain/websocket` は `require "cybertrain"` に含めない（`http_client` と同じ）。
`wss` には `require "cybertrain/net/tls"` が別に要る。

## 4. 詳細

### 4.1 同期クライアント `WebSocket::Client`

```ruby
client = Cybertrain::WebSocket::Client.connect(url,
  headers: {}, timeout: 5, max_message: 1_048_576,
  allow_private: Cybertrain.config.http_allow_private)
client.send_text(s)       # / send_binary(s)
msg = client.receive(10)  # 最大 10 秒待つ。完結したデータメッセージか、nil（時間切れ）
msg.ws_opcode             # :text / :binary
msg.ws_data               # バイト列の String
client.close              # close 1000 を送り、相手の close を timeout まで待って切る
```

- URL: `ws` / `wss` だけ。`HttpClient` の URL 解析と非公開アドレスの判定・全アドレスへの
  接続試行（`allowed_addresses` 相当）を共用する。必要なら `HttpClient` から共有の
  メソッドに切り出す（重複させない）。不正な URL は `ArgumentError`（URL を繰り返さない）。
- ハンドシェイク: `GET <path?query> HTTP/1.1`、`Host`、`Upgrade: websocket`、
  `Connection: Upgrade`、`Sec-WebSocket-Key`（16 バイトの乱数の base64）、
  `Sec-WebSocket-Version: 13`、`User-Agent: cybertrain/<version>`、加えて `headers:`。
  `Host` / `Upgrade` / `Connection` / `Sec-WebSocket-*` / `Content-Length` /
  `Transfer-Encoding` はクライアントのもので、`headers:` に入れると `ArgumentError`。
  ヘッダ値の CR/LF も `ArgumentError`（`HttpClient.check_header` を共用）。
- 応答: ステータス行とヘッダは `HttpClient` と同じ上限（64 KiB・100 行）で読む。
  101 以外、`Upgrade` が `websocket` でない、`Connection` に `upgrade` が無い、
  `Sec-WebSocket-Accept` が `base64(SHA-1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))`
  と違う、拡張・サブプロトコルが返った、のいずれかで `HandshakeError`（ステータスを含む）。
  SHA-1 は `Digest::SHA1.digest`（Spinel 2026.10.26.7019 でコンパイルし、RFC 6455 の
  例の値 `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=` と一致することを確かめた）。
  101 の後に `Reader` に残っているバイトはフレームの先頭として扱う。
- 待ち: 接続・TLS の各段・ハンドシェイクは `Net::Timer.new(label, timeout, timeout * 3)`。
  `receive(wait)` は 1 回の呼び出しごとに `wait` 秒の Timer を作り、時間切れなら
  `nil` を返す（例外にしない）。フレームの途中で時間切れになった場合は、次の
  `receive` で続きから読む（`Reader` のバッファを保つ）。
- 送信: 常にマスクする（マスクキーは `SecureRandom.random_bytes(4)`）。テキストも
  バイナリも 1 フレームで送る（分割しない）。送信は `timeout` で有界。
- 受信フレームの扱い:
  - 長さは 7 ビット / 16 ビット / 64 ビットの 3 形式。64 ビットの最上位ビットが立っていれば
    `ProtocolError`。
  - 分割メッセージ（continuation）は組み立てる。組み立て中の合計が `max_message` を
    超えたら close 1009 を送り `TooLargeError`。
  - ping: 同じペイロードで pong を返し、`receive` は待ちを続ける。
  - pong: 読み捨てる（活動として数える。4.2 節）。
  - close: 届いたコードを返す close を送り、接続を閉じて `ClosedError`（コードと理由を
    持つ。理由はサーバ由来なので 123 バイトに切り詰め、制御文字を落とす）。
  - プロトコル違反で close 1002 を送り `ProtocolError`: マスクされたサーバフレーム、
    RSV ビット、未知の opcode、125 バイトを超える制御フレーム、FIN の無い制御フレーム、
    組み立て中でない continuation、組み立て中の新しいデータフレーム。
  - ストリームの終わり（close フレーム無し）は `ClosedError`（コード 1006）。
- `last_activity_at`: 何かのフレームを受け取った最後の時刻（`Net::Timer.now` の単調時刻）。
- `send_ping(payload = "")`: ランナーが使う。公開 API。
- エラー: すべて `WebSocket::Error` の下。`TimeoutError`、`RefusedError`、`TLSError`、
  `BlockedAddressError`、`HandshakeError`、`ProtocolError`、`TooLargeError`、
  `ClosedError`。`Net::*` の例外は `HttpClient` と同じ対応で変換する。メッセージは
  `host:port` だけを含み、パスとクエリは含まない。

### 4.2 常駐購読 `WebSocket.subscribe`

```ruby
sub = Cybertrain::WebSocket.subscribe(name, url,
  headers: {}, timeout: 5, max_message: 1_048_576,
  ping_interval: 15, stale_after: 45,
  allow_private: Cybertrain.config.http_allow_private)
sub.on_open    { |conn| ... }        # self を返す
sub.on_message { |conn, data| ... }  # self を返す
```

- 登録時の検査（`ArgumentError`）: 空の名前、登録済みの名前、`ws` / `wss` 以外の URL、
  `ping_interval < 1`、`stale_after <= ping_interval`、`on_message` 無しでの `start!`
  （`start!` が名前を挙げて `ArgumentError`）。
- 登録は定数の配列（`Scheduler::TASKS` と同じ、NOTES 規則 9 / 64）。ブロックは
  引数を受け取るだけで `self` に触れない（`instance_eval` が無い）。
- `Connection`: `send_text(s)`、`send_binary(s)`、`close`、`last_opcode`
  （直前に `on_message` に渡したメッセージの `:text` / `:binary`）。コールバックの中で
  だけ使う。
- ループ（購読ごとに 1 スレッド、メソッド経由で起こす: NOTES 規則 21）:
  1. `Client.connect`。成功したら `on_open` を呼ぶ。`on_open` が例外を投げたら
     `[ERROR]` を出し、接続を閉じて再接続へ（購読できていない接続には意味が無い）。
  2. `receive(1)` を繰り返す（1 秒ごとに停止要求と時間を見る）。メッセージが来たら
     `on_message`。例外は `[ERROR] WebSocket "name" on_message failed: Class: message`
     を出して接続を保つ。
  3. 最後の活動から `ping_interval` 秒経ったら ping を送る（送った後は次の
     `ping_interval` まで送らない）。
  4. 最後の活動から `stale_after` 秒経ったら、黙ったとみなして閉じ、再接続へ。
  5. どのエラーでも `[WARN] WebSocket "name" disconnected: Class: message (retry in Ns)`
     を出し、待ってから 1 へ。
- 再接続の待ち: `delay(attempt) = min(60, 2 ** (attempt - 1))` 秒に ±20 % の揺らぎ。
  1 回目の失敗の後が 1 秒。接続が 60 秒続いたら attempt を 0 に戻す。待ちは 1 秒刻みで
  停止要求を見る。揺らぎの乱数と時刻は注入できるようにし、テストは眠らない。
- `start!(config)`: `config.worker` が偽なら何もしない（ログを 1 行）。登録が無ければ
  何もしない。購読ごとにスレッドを起こし、`WebSocket started: trades (wss://host:port)`
  を出す（パスは出さない）。`stop!`: 停止を要求し、接続中なら close 1000 を送る。
  各スレッドは 1 秒以内に気づいて終わる。世代番号で古いループを止める
  （`Scheduler` と同じ）。
- `WebSocket.status(name)` → `Status`: `connected?`、`last_message_at`（エポック秒、
  0 は未受信）、`reconnects`（再接続の回数）。ロックで守る。未知の名前は
  `ArgumentError`。`/up` には自動で組み込まない（アプリが自分のヘルスチェックで使う）。

### 4.3 スレッドと OS ワーカー

待ちは `wait_readable` なので、待っている間は OS ワーカーを握らない。ただし
`on_message` の中の SQLite 呼び出しは `Scheduler` のタスクと同じく、戻るまで OS
ワーカーを握る。高頻度のフィードでは軽い INSERT にするか、メモリに溜めて
`Scheduler` のタスクでまとめて書く。README にこの注意を書く。

### 4.4 ログ

| 時 | レベル | 行 |
| --- | --- | --- |
| 起動 | INFO | `WebSocket started: trades (wss://feed.example.com:443)` |
| 接続 | INFO | `WebSocket "trades" connected to feed.example.com:443` |
| 切断 | WARN | `WebSocket "trades" disconnected: Cybertrain::WebSocket::ClosedError: feed.example.com:443: closed by the server (1001) (retry in 2s)` |
| 沈黙 | WARN | `WebSocket "trades" silent for 45s; reconnecting` |
| コールバックの例外 | ERROR | `WebSocket "trades" on_message failed: KeyError: ...` |

### 4.5 起動への組み込み

`application.rb` は `cybertrain/websocket` を require しない（libssl を含め、使わない
アプリに余計なものを持ち込まない）。代わりに `Net.tls_connector` と同じ差し替えの形を
とる: `cybertrain/background.rb` に何もしない既定の `Background::Service`
（`service_start(config)` / `service_stop`）の登録表を置き、`Application#serve` は
`Scheduler.start!` の後に登録表のサービスを起動し、終了時に停止する。
`cybertrain/websocket.rb` は require されたときに自分を登録する。
`Test::Client` は起動しない。この形が Spinel でコンパイルできることは計画の最初の
タスクで確かめる（できなければ、`config/app.rb` からアプリが `WebSocket.start!` を
呼ぶ形に退く）。

## 5. テスト

すべて `test/*.rb` と `.expected` のスナップショット（`spin test`）。

- `test/websocket_frame.rb`: RFC 6455 の例の Accept キーとマスク済みフレーム
  （`Hello`）、長さの 3 形式の境界（125 / 126 / 65535 / 65536）、分割の組み立て、
  4.1 節のプロトコル違反すべての拒否、close のコードと理由の解析。
- `test/websocket_client.rb`（`Test::WebSocketReceiver` 相手）: ハンドシェイク成功、
  違う Accept・101 以外・拡張を返す応答の失敗、ハンドシェイクの時間切れ、テキストと
  バイナリの送受信、受信側でのマスクの確認、ping への pong、close への close、
  `max_message` 超過で 1009、`receive` の時間切れが `nil`、`allow_private: false` で
  127.0.0.1 が拒否、エラーメッセージにパスとクエリが含まれないこと、`wss` で TLS 層が
  無いときの `TLSError`、平文で答えるサーバへの `wss` がハンドシェイク失敗になること。
- `test/websocket_subscription.rb`: 再接続のたびに `on_open` が走る、`on_message` の
  例外で接続が保たれる、`stale_after` を超えた沈黙で再接続する、`ping_interval` で
  ping が届く、待ち時間の計算（注入した乱数）、`status`、`stop!` でスレッドが終わる、
  `worker` が偽なら起動しない、登録時の `ArgumentError`。
- `test/websocket_receiver.rb` の受信器は `HttpReceiver` / `SmtpReceiver` と同じ方針
  （有界の accept と読み取り、メソッド経由のスレッド）。台本を渡せる: ハンドシェイクの
  応答の差し替え、送るフレームの列、受け取ったフレームの記録、指定時点での切断・沈黙。

## 6. ドキュメント

- README: 「Consuming WebSocket feeds」の節（上の例、待ちと再接続、制限、OS ワーカーの
  注意、テストの書き方）。冒頭の「Not built: ... WebSockets/ActionCable」を
  「WebSocket サーバ（ActionCable）」に直す。Rails との対応表に行を足す。
- docs/design.md: D33 として本 spec の決定を記録し、2.3 節と 8 節の WebSocket を
  「サーバ側」に絞る。
- docs/api のスタブとヤードのタグ（`@api public`）を既存のファイルと揃える。
