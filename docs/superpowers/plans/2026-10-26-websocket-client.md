# 外向き WebSocket クライアントと常駐購読 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `ws://` / `wss://` のデータフィードに常時つなぎ、届いたメッセージをアプリのブロックに渡す `Cybertrain::WebSocket` を足す。

**Architecture:** 二層。`WebSocket::Client`（同期: ハンドシェイク・フレーム・ping/pong・close）は D24 の `Cybertrain::Net`（有界のソケット層）と `HttpClient` の URL 解析・アドレス判定の上に作る。`WebSocket.subscribe` は購読ごとに 1 スレッドを起こし、再接続・沈黙検知・ping を受け持つ。起動は新しい `Cybertrain::Background` の登録表を通し、`application.rb` は `cybertrain/websocket` を require しない。

**Tech Stack:** Spinel 2026.10.26.7019 でコンパイルする Ruby。`Digest::SHA1`、`Base64`、`SecureRandom`。テストは `test/*.rb` + `.expected` スナップショット（`spin test`）。

**Spec:** `docs/superpowers/specs/2026-10-26-websocket-client-design.md`（各タスクの前に読むこと）

## Global Constraints

- `spikes/NOTES.md` の「Rules every framework file must follow」に従う。特に: 組み込みと同名のメソッドを作らない（規則 62、`stream_read` のような固有の名前）、スレッドはメソッドの引数をブロックが捕まえる形で起こす（規則 21）、最初の `Thread.new` の前に `SPINEL_WORKERS`（規則 22）、レジストリは定数か module の ivar で型の種を入れて空にする（規則 9 / 18 / 64）、rescue の梯子はブロックを取らないメソッドに置き clause で区別する（規則 32 / 45 / 47）、`k, v = s.split(...)` を使わない（規則 12）、バイト位置で処理する（`byteindex` / `byteslice`、規則 27 / 52）。
- どの待ちも有界。読み取りは `read_nonblock` → `wait_readable(limit)`。素の `readpartial` / `gets` を使わない。
- エラーメッセージは `host:port` だけを含み、URL のパス・クエリ・ヘッダ値を含まない。
- 非公開アドレスは既定で拒否（`allow_private:` の既定は `Cybertrain.config.http_allow_private`）。
- `cybertrain/websocket*.rb` は `require "cybertrain"` に含めず、`openssl` も require しない（wss は `cybertrain/net/tls` を別に require）。
- 既定値: `timeout` 5、`max_message` 1_048_576、`ping_interval` 15、`stale_after` 45、再接続の待ち `min(60, 2 ** (attempt - 1))` 秒に ±20 %、60 秒続いた接続で attempt を 0 に戻す。
- GUID: `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`。
- コミットは `script/gate --staged` を通す（pre-commit フック）。件名は末尾にピリオドを付けず、2 行目は空行。
- 公開 API には既存ファイルと同じく YARD コメントと `@api public` を付ける。
- 各テストファイルは `test/<name>.rb` と `test/<name>.rb.expected` の組。スナップショットは `script/regen-snapshot test/<name>.rb` で作り、差分を読んでからコミットする。出力にポート番号・時間を出さない。

## Review Focus

1. **フレームの途中での `receive` の時間切れ** — ヘッダだけ届いて本体が遅れても、バッファを消費せずに `nil` を返し、次の `receive` が同じフレームを最初から正しく読む（Task 4 の `test "receive resumes a frame split across waits"`）。
2. **ハンドシェイク応答と同じ読み取りで届いた最初のフレーム** — 101 の直後のバイトを捨てずにフレームとして読む（Task 4 の `test "a frame sent with the 101 is not lost"`）。
3. **`on_open` で送った購読の後、サーバが即座に close する** — ログが残り、待ってから再接続し、もう一度 `on_open` が走る（Task 5 の `test "on_open runs again after every reconnect"`）。
4. **`stop!` を接続試行中・再接続待ち中に呼ぶ** — 1 秒刻みで気づいて終わり、プロセスの終了を妨げない（Task 5 の `test "stop! ends a thread waiting to reconnect"`）。
5. **巨大な長さを名乗るフレーム** — 64 ビット長の最上位ビット、または `max_message` 超の長さはバッファに読み込む前に拒否する（Task 2 の `test "a 64-bit length with the top bit set is refused"` と Task 4 の `test "max_message is enforced before reading the payload"`）。

---

### Task 1: `Cybertrain::Background` の登録表と `Application#serve` への組み込み

`application.rb` が知らないサービス（後で WebSocket）を、require されたときに登録させて起動・停止する。Spinel でこの差し替えの形がコンパイルできることもここで確かめる（`Net.tls_connector` と同じ module の ivar / 定数の形）。

**Files:**
- Create: `cybertrain/background.rb`
- Modify: `cybertrain/application.rb`（require に `cybertrain/background` を足し、`serve` の `Scheduler.start!(@config)` の直後に `Background.start_all(@config)`、`Scheduler.stop!` の直後に `Background.stop_all`）
- Test: `test/background.rb`, `test/background.rb.expected`

**Interfaces:**
- Produces:
  - `class Cybertrain::Background::Service` — 既定は何もしない。`service_name -> String`（既定 `""`）、`service_start(config) -> Boolean`（既定 `false`）、`service_stop -> nil`。
  - `Cybertrain::Background::SERVICES` — `Array` の定数（`Service.new` で種を入れて空にする）。
  - `Background.register(service) -> nil`（同じ `service_name` の二重登録は `ArgumentError`）
  - `Background.start_all(config) -> Integer`（`config.worker` が偽なら 0 を返して何もしない。`service_start` が `true` を返した数）
  - `Background.stop_all -> nil`

- [ ] **Step 1: テストを書く** — `test/background.rb`: `Service` のサブクラス `ProbeService`（`service_start` で定数の配列に `"start"` を積み `true`、`service_stop` で `"stop"`）を登録し、
  - `test "start_all starts every registered service"`: `assert_equal 1, Background.start_all(Cybertrain::Config.new)`、配列が `["start"]`
  - `test "stop_all stops them"`: 配列の末尾が `"stop"`
  - `test "start_all does nothing when the worker is off"`: `config.worker = false` で `assert_equal 0, ...`、配列は変わらない
  - `test "a name registered twice is refused"`: `assert_raises(ArgumentError)`
  - 最後に `Cybertrain::Test.run!`
- [ ] **Step 2: 失敗を確かめる** — Run: `ruby -I. test/background.rb` / Expected: `cannot load such file -- cybertrain/background`
- [ ] **Step 3: `cybertrain/background.rb` を実装し、`application.rb` に組み込む**
- [ ] **Step 4: CRuby と Spinel で通す** — Run: `ruby -I. test/background.rb` → 4 件 ok。`script/regen-snapshot test/background.rb` → スナップショットが CRuby の出力と同じ。`spin test test/application.rb test/scheduler.rb` → 既存のスナップショットと一致。
  - Spinel でコンパイルできない場合は止めて報告する（spec 4.5 の退路: アプリが `WebSocket.start!` を呼ぶ形に切り替えるかを決める）。
- [ ] **Step 5: コミット** — `git add cybertrain/background.rb cybertrain/application.rb test/background.rb test/background.rb.expected && git commit`（件名例: `Background: a registry of services Application#serve starts and stops`）

### Task 2: フレームの符号化・復号 `cybertrain/websocket/frame.rb`

**Files:**
- Create: `cybertrain/websocket/frame.rb`
- Test: `test/websocket_frame.rb`, `test/websocket_frame.rb.expected`

**Interfaces:**
- Produces（すべて `module Cybertrain; module WebSocket` の中）:
  - 例外: `Error < StandardError`、その下に `TimeoutError`、`RefusedError`、`TLSError`、`BlockedAddressError`、`HandshakeError`、`ProtocolError`、`TooLargeError`、`ClosedError`。`ClosedError#close_code -> Integer`、`ClosedError#close_reason -> String`（`ClosedError.new(message, code, reason)`）。
  - `class Message` — `ws_opcode -> Symbol`（`:text` / `:binary`）、`ws_data -> String`。`Message.new(opcode_symbol, data)`。
  - `module Frame`: 定数 `OP_CONTINUATION = 0`、`OP_TEXT = 1`、`OP_BINARY = 2`、`OP_CLOSE = 8`、`OP_PING = 9`、`OP_PONG = 10`、`GUID`。
  - `Frame.accept_key(key) -> String` — `Base64.strict_encode64(Digest::SHA1.digest(key + GUID))`
  - `Frame.encode(opcode, payload, mask_key) -> String` — FIN 付きの 1 フレーム。`mask_key` が 4 バイトならマスクビットを立ててマスク、`""` ならマスクしない（受信器用）。長さは 125 以下 / 126+16 ビット / 127+64 ビット。
  - `class Frame::Header` — `frame_fin`、`frame_rsv`（0..7）、`frame_opcode`、`frame_masked`、`frame_length`、`frame_header_size`、`frame_mask_key`（マスクが無ければ `""`）。
  - `Frame.parse_header(bytes) -> Header` — `bytes` の先頭から読む。足りなければ `frame_header_size == 0` の Header を返す（nil を返さない）。64 ビット長の最上位ビットが立っていれば `ProtocolError`。
  - `Frame.unmask(payload, mask_key) -> String`
  - `Frame.check_header(header, assembling, from_server) -> nil` — spec 4.1 のプロトコル違反で `ProtocolError`: `from_server` かつマスク付き / `!from_server` かつマスク無し、RSV、未知の opcode、125 超の制御フレーム、FIN 無しの制御フレーム、`assembling` でない continuation、`assembling` 中の新しいデータフレーム。
  - `class Frame::Assembler` — `Assembler.new(max_message)`、`add(opcode, fin, payload) -> Boolean`（メッセージが完結したら true）、`assembling? -> Boolean`、`take_message -> Message`（完結したものを取り出してリセット）。合計が `max_message` を超えたら `TooLargeError`。
  - `Frame.close_payload(code, reason) -> String`、`Frame.close_code(payload) -> Integer`（空なら 1005、1 バイトなら `ProtocolError`）、`Frame.close_reason(payload) -> String`（2 バイト目以降、123 バイトまで、バイト 0..31 と 127 を落とす）。

- [ ] **Step 1: テストを書く** — `test/websocket_frame.rb`（`require "cybertrain/websocket/frame"` と `cybertrain/test` だけ）:
  - `test "accept_key matches RFC 6455"`: `assert_equal "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", Frame.accept_key("dGhlIHNhbXBsZSBub25jZQ==")`
  - `test "a masked Hello encodes as in RFC 6455 5.7"`: `Frame.encode(OP_TEXT, "Hello", "\x37\xfa\x21\x3d".b)` のバイト列が `"\x81\x85\x37\xfa\x21\x3d\x7f\x9f\x4d\x51\x58".b`
  - `test "an unmasked Hello"`: `"\x81\x05Hello".b`
  - `test "length encodings at 125, 126, 65535 and 65536"`: それぞれの 2 バイト目と拡張長、`parse_header` で往復して `frame_length` と `frame_header_size`（2 / 4 / 4 / 10、マスク付きは +4）
  - `test "parse_header asks for more bytes"`: 1 バイト、126 形式で 3 バイト、マスク付きで 5 バイトのとき `frame_header_size == 0`
  - `test "a 64-bit length with the top bit set is refused"`: `ProtocolError`
  - `test "unmask restores the payload"`
  - `test "check_header refuses"` を違反ごとに 1 件ずつ（マスク付きサーバフレーム、RSV、opcode 3、126 バイトの ping、FIN 無しの ping、浮いた continuation、組み立て中の text）。各 `assert_raises(Cybertrain::WebSocket::ProtocolError)`
  - `test "the assembler joins fragments"`: `add(OP_TEXT, false, "Hel")` → false、`add(OP_CONTINUATION, true, "lo")` → true、`take_message.ws_data == "Hello"`、`ws_opcode == :text`、`assembling?` が false に戻る
  - `test "the assembler enforces max_message across fragments"`: `Assembler.new(4)` で 3+2 バイト → `TooLargeError`
  - `test "close payloads"`: `close_code(close_payload(1001, "bye")) == 1001`、`close_reason == "bye"`、空は 1005、制御文字は落ち 200 バイトの理由は 123 バイトになる
- [ ] **Step 2: 失敗を確かめる** — Run: `ruby -I. test/websocket_frame.rb` / Expected: load error
- [ ] **Step 3: `frame.rb` を実装する** — マスクは `getbyte` / `setbyte` のループ（`Crypto.hex` と同じ書き方）。文字列は `String.new` / `.b` で binary にする。
- [ ] **Step 4: 通す** — Run: `ruby -I. test/websocket_frame.rb` → 全件 ok。`script/regen-snapshot test/websocket_frame.rb` → CRuby の出力と同じ。
- [ ] **Step 5: コミット**（件名例: `WebSocket: frame encoding and decoding (RFC 6455)`）

### Task 3: `HttpClient` から接続と URL 解析を共有できるように切り出す

振る舞いを変えないリファクタ。WebSocket が同じ経路でつなぐため。

**Files:**
- Modify: `cybertrain/http_client.rb`（`parse_url`、`exchange`、`allowed_addresses`）
- Modify: `cybertrain/net/socket.rb`（`Reader` に 3 メソッド追加）
- Test: `test/http_client.rb`（変更なしで通ること）、`test/net_reader.rb`, `test/net_reader.rb.expected`（新規。既に `Reader` のテストファイルがあればそこに足す）

**Interfaces:**
- Produces:
  - `HttpClient.parse_url_for(url, plain_scheme, tls_scheme) -> Target` — 例 `("ws://", "wss://")`。スキームが違えば `ArgumentError, "only #{plain_scheme} and #{tls_scheme} URLs are supported"`。`HttpClient.parse_url(url)` はこれを `("http://", "https://")` で呼ぶだけになる（既存のメッセージ `only http:// and https:// URLs are supported` は変わらない）。
  - `HttpClient.dial(target, timer, allow_private) -> Net::Stream` — 解決、`timer.wait_limit("resolving the host name")`、許可アドレスの絞り込み、接続、TLS。`exchange` はこれを使う。`allowed_addresses` はクラスメソッド `HttpClient.allowed_addresses(endpoint, label, allow_private)` にする。
  - `Net::Reader#reader_timer=(timer)` — 以後の読み取りの Timer を差し替える。
  - `Net::Reader#fill_to(count) -> Boolean` — 未消費が `count` バイト以上になるまで読む。ストリームの終わりなら false。
  - `Net::Reader#peek_bytes(count) -> String` — 消費せずに先頭 `count` バイト（`fill_to` の後で呼ぶ）。

- [ ] **Step 1: Reader のテストを書く** — 既存テストに `Net::Stream` の偽物（決まったチャンク列を返す）が無ければ、`test/net_reader.rb` に `FakeStream < Cybertrain::Net::Stream` を作る:
  - `test "fill_to buffers without consuming"`: チャンク `["ab", "cd"]` で `fill_to(3)` → true、`peek_bytes(3) == "abc"`、続く `read_exact(4) == "abcd"`
  - `test "fill_to is false at end of stream"`: `fill_to(10)` → false
  - `test "a timeout leaves the buffer intact"`: 2 回目の `stream_read` が `Net::TimeoutError` を投げる偽物で `fill_to(4)` が例外、`reader_timer=` 後に `peek_bytes(2) == "ab"` が残っている
- [ ] **Step 2: 失敗を確かめる** — Run: `ruby -I. test/net_reader.rb` / Expected: `NoMethodError`（`fill_to`）
- [ ] **Step 3: 実装する**（`Reader` の 3 メソッド、`HttpClient` の切り出し）
- [ ] **Step 4: 通す** — Run: `ruby -I. test/net_reader.rb`、`script/regen-snapshot test/net_reader.rb`、`spin test test/http_client.rb test/mailer.rb` → 既存スナップショットと一致（差分なし）
- [ ] **Step 5: コミット**（件名例: `HttpClient: share URL parsing and dialling; Net::Reader can peek`）

### Task 4: テスト用受信器と同期クライアント

**Files:**
- Create: `cybertrain/test/websocket_receiver.rb`
- Create: `cybertrain/websocket/client.rb`
- Test: `test/websocket_client.rb`, `test/websocket_client.rb.expected`

**Interfaces:**
- Consumes: Task 2 のすべて、Task 3 の `HttpClient.parse_url_for` / `HttpClient.dial` / `HttpClient.check_header` / `HttpClient.read_headers` / `HttpClient.status_code` / `Net::Reader#fill_to` / `#peek_bytes` / `#reader_timer=`
- Produces:
  - `class Cybertrain::Test::WebSocketReceiver < Receiver`（`Test::Receiver` の上、`HttpReceiver` と同じ方針。`Frame` だけを require し、残りのフレームワークを持ち込まない）
    - `WebSocketReceiver.new(max: 1, accept_window: 10.0, read_timeout: 5.0)`
    - `#url(path = "/") -> "ws://127.0.0.1:<port><path>"`
    - 台本（接続ごとに先頭から 1 つ消費する。台本が無い接続は既定の `ws_script_echo`）: `#ws_script(steps)` で `steps` は `Array` の `WsStep`。`WsStep.new(kind, data)` の `kind`: `"accept"`（正しい 101）、`"reply_raw"`（`data` をそのまま返す。誤った Accept や 101 以外の試験用）、`"send_text"`、`"send_binary"`、`"send_raw"`（任意のバイト、プロトコル違反用）、`"send_with_101"`（101 と同じ write で text フレームも送る）、`"expect"`（クライアントから 1 フレーム読んで記録する）、`"echo_until_close"`（受けたデータフレームを返し、ping に pong、close に close して終わる）、`"silent"`（`data` 秒黙る。`data` は秒数の文字列）、`"close"`（`data` のコードで close を送る）、`"drop"`（FIN 無しで切る）、`"split_frame"`（ヘッダを送り、0.3 秒置いて本体を送る）。
    - 記録: `#ws_received(wait = 5.0) -> Array of RecordedFrame`（`rec_opcode`、`rec_masked`、`rec_data`、マスクを外したもの）、`#ws_request_headers(index) -> Hash`（ハンドシェイクの要求ヘッダ、小文字）、`#ws_request_target(index) -> String`
  - `class Cybertrain::WebSocket::Client`
    - `Client.connect(url, headers: NO_HEADERS, timeout: 5, max_message: 1_048_576, allow_private: Cybertrain.config.http_allow_private) -> Client`
    - `#send_text(s) -> nil`、`#send_binary(s) -> nil`、`#send_ping(payload = "") -> nil`
    - `#receive(wait) -> Message`、時間切れは `nil`
    - `#close -> nil`（close 1000 を送り、相手の close を最大 `timeout` 待つ。2 回呼んでも安全）
    - `#ws_open? -> Boolean`、`#last_activity_at -> Float`（`Net::Timer.now`）、`#ws_label -> String`（`host:port`）
    - 予約ヘッダ: `HttpClient.check_header` に加え、`sec-websocket-` で始まる名前は `ArgumentError, "header #{name} is set by the client itself"`
    - `Net::*` の例外は `HttpClient#perform` と同じ対応で `WebSocket::*` に変換（`Net::LimitError` → `HandshakeError`。ハンドシェイク後のフレーム読み取りでの `Net::ProtocolError`（途中で切れた）→ `ClosedError`（1006））

- [ ] **Step 1: テストを書く** — `test/websocket_client.rb`（`cybertrain/websocket/client`、`cybertrain/net/tls`、`cybertrain/test/websocket_receiver`、`cybertrain/test` を require。`Cybertrain.config.http_allow_private = true` を先頭で。`test/http_client.rb` の `Outcome` と同じく、例外の種類を文字列で返す補助メソッドを置く）:
  - `test "connects and exchanges text and binary"`: `["accept", "echo_until_close"]`。`send_text("hi")` → `receive(5).ws_data == "hi"`、`ws_opcode == :text`、バイナリも同様。`close` 後、受信器の記録の最後が opcode 8
  - `test "the handshake sends the required headers"`: `upgrade == "websocket"`、`sec-websocket-version == "13"`、key が base64 で 16 バイト、`user-agent` が `cybertrain/` で始まる、`ws_request_target(0) == "/feed?x=1"`、`headers: { "Authorization" => "Bearer t" }` が届く
  - `test "client frames are masked"`: 記録の `rec_masked` がすべて true
  - `test "a wrong Sec-WebSocket-Accept is a HandshakeError"`、`test "a 200 is a HandshakeError naming the status"`（メッセージに `200` を含む）、`test "an extension in the answer is a HandshakeError"`
  - `test "a silent handshake times out"`: `["silent"/"3"]`、`timeout: 1` → `TimeoutError`
  - `test "a frame sent with the 101 is not lost"`: `["send_with_101"]` → 最初の `receive(5)` がそのテキスト
  - `test "receive resumes a frame split across waits"`: `["accept", "split_frame"]` → `receive(0.1)` が nil、続く `receive(5)` が完全なメッセージ
  - `test "receive returns nil when nothing arrives"`: `receive(0.2)` が nil、接続は開いたまま
  - `test "a ping is answered with a pong carrying its payload"`: 受信器から ping `"p1"` を送り、記録に opcode 10・データ `"p1"`
  - `test "a close from the server is a ClosedError with its code"`: `["accept", "close"/"1001"]` → `ClosedError`、`close_code == 1001`、受信器が close を受け取っている
  - `test "a dropped connection is a ClosedError 1006"`
  - `test "max_message is enforced before reading the payload"`: `max_message: 10` に 11 バイト → `TooLargeError`、受信器の記録に close 1009
  - `test "a masked server frame is a ProtocolError"`（`send_raw`）、記録に close 1002
  - `test "private addresses are refused unless allowed"`: `allow_private: false` で `BlockedAddressError`
  - `test "errors never contain the path or the query"`: `/secret?token=abc` に対する上の失敗の各メッセージに `secret` も `token` も含まれない
  - `test "reserved headers are refused"`: `Sec-WebSocket-Key`、`Upgrade` が `ArgumentError`
  - `test "a non-ws URL is refused"`: `http://...` が `ArgumentError`
  - `test "wss to a plain server fails the handshake"`: `wss://127.0.0.1:<受信器のポート>` → `TLSError`（`test/http_client.rb` の TLS のテストと同じ形）
- [ ] **Step 2: 失敗を確かめる** — Run: `ruby -I. test/websocket_client.rb` / Expected: load error
- [ ] **Step 3: 受信器を実装する** — 読み取りは `Receiver` の `bytes_ready?` / `cut_bytes` / `marker_ready?` / `cut_to` だけ。フレームは `Frame.parse_header` / `Frame.encode(…, "")` / `Frame.unmask`。
- [ ] **Step 4: クライアントを実装する** — `receive(wait)`: `Net::Timer.new(label, wait, wait)` を `reader_timer=` で入れ、`fill_to(2)` → `parse_header(peek_bytes(…))` → 長さが `max_message` を超えれば close 1009 と `TooLargeError` → `fill_to(header_size + length)` → `read_exact` で消費。`Net::TimeoutError` は rescue して `nil`（バッファは消費していない）。ping は pong を返してループ、pong は活動として記録してループ、close は応答して `ClosedError`。プロトコル違反は close 1002 を送ってから例外。
- [ ] **Step 5: 通す** — Run: `spin test test/websocket_client.rb`（TLS 層を含むので CRuby ではなくコンパイルしたバイナリでスナップショットを作る: `script/regen-snapshot test/websocket_client.rb`）。全件 ok で、出力にポートも時間も無いこと。
- [ ] **Step 6: コミット**（件名例: `WebSocket::Client: a synchronous client on the bounded Net layer`）

### Task 5: 常駐購読 `cybertrain/websocket.rb`

**Files:**
- Create: `cybertrain/websocket.rb`
- Test: `test/websocket_subscription.rb`, `test/websocket_subscription.rb.expected`

**Interfaces:**
- Consumes: Task 1 の `Background::Service` / `Background.register`、Task 4 の `Client` と受信器、Task 2 の例外
- Produces（`module Cybertrain::WebSocket`）:
  - `WebSocket.subscribe(name, url, headers: NO_HEADERS, timeout: 5, max_message: 1_048_576, ping_interval: 15, stale_after: 45, allow_private: Cybertrain.config.http_allow_private) -> Subscription`（spec 4.2 の `ArgumentError`。URL は `HttpClient.parse_url_for(url, "ws://", "wss://")` で検査）
  - `Subscription#on_open(&block) -> Subscription`、`#on_message(&block) -> Subscription`、`#sub_name -> String`
  - `class Connection` — `send_text(s)`、`send_binary(s)`、`close`、`last_opcode -> Symbol`
  - `class Status` — `connected? -> Boolean`、`last_message_at -> Integer`、`reconnects -> Integer`
  - `WebSocket.status(name) -> Status`（未知の名前は `ArgumentError`）
  - `WebSocket.start!(config = Cybertrain.config) -> Boolean`、`WebSocket.stop! -> nil`、`WebSocket.running? -> Boolean`
  - `WebSocket.retry_delay(attempt, jitter) -> Float` — `jitter` は 0.0..1.0 の乱数。`min(60, 2 ** (attempt - 1)) * (0.8 + 0.4 * jitter)`
  - テスト用の注入: `WebSocket.random_source=(proc)`（既定 `-> { rand }`）
  - ファイルの末尾で `Background.register(WebSocketService.new)`（`service_name` は `"websocket"`、`service_start` は `WebSocket.start!(config)`、`service_stop` は `WebSocket.stop!`）
  - ループは spec 4.2 の 1〜5、ログは spec 4.4 の文言どおり。待ちはすべて 1 秒刻みで `@running` と世代番号を見る。

- [ ] **Step 1: テストを書く** — `test/websocket_subscription.rb`（`Cybertrain.logger` を `StringIO` に向け、ログの行で確かめる。`random_source` を `-> { 0.5 }` にして待ちを揺らがせない。`test/scheduler.rb` と同じく本物のスレッドを使うテストは最後に置き、`await` は受信器の `await_count` 相当の有界ポーリングで書く）:
  - `test "retry_delay doubles up to 60 seconds"`: `retry_delay(1, 0.5) == 1.0`、`(2, 0.5) == 2.0`、`(7, 0.5) == 60.0`、`(20, 0.5) == 60.0`、`(1, 0.0) == 0.8`、`(1, 1.0) == 1.2`
  - `test "subscribe refuses bad arguments"`: 空の名前、二重の名前、`http://` の URL、`ping_interval: 0`、`stale_after: 15, ping_interval: 15` がそれぞれ `ArgumentError`
  - `test "start! refuses a subscription without on_message"`
  - `test "start! does nothing when the worker is off"`: `false`、ログに 1 行
  - `test "status of an unknown name is an ArgumentError"`
  - `test "messages reach on_message and status follows"`: 受信器が `"accept"` → `"send_text"/"a"` → `"send_text"/"b"` → `"echo_until_close"`。`on_message` が定数の配列に積み、`["a", "b"]` になる。`status.connected?` が true、`last_message_at > 0`
  - `test "on_open runs again after every reconnect"`: 受信器 `max: 2`。1 本目は `"accept"`、`"expect"`、`"close"/"1001"`、2 本目は `"accept"`、`"expect"`、`"echo_until_close"`。受信器が両方の接続で購読メッセージを受け取る。`reconnects == 1`。ログに `WebSocket "feed" disconnected: Cybertrain::WebSocket::ClosedError:` と `(retry in 1s)`
  - `test "an exception in on_message keeps the connection"`: 1 件目で raise、2 件目が届く。ログに `on_message failed: RuntimeError:`、`reconnects == 0`
  - `test "a silent feed is pinged, then reconnected"`: `ping_interval: 1, stale_after: 2`、受信器 1 本目は `"accept"`、`"expect"`（ping が来る: opcode 9）、`"silent"/"5"`。ログに `silent for 2s; reconnecting`、2 本目の接続が来る
  - `test "stop! ends a thread waiting to reconnect"`: つながらないポート（受信器を start して即 stop した後のポート）に購読し、`start!` → 最初の失敗のログを待つ → `stop!` → 2 秒以内に `running?` が false でスレッドが終わる（`thread.join(2)` が nil でない）
  - `test "the service is registered with Background"`: `Background::SERVICES` に `service_name == "websocket"` がある
- [ ] **Step 2: 失敗を確かめる** — Run: `ruby -I. test/websocket_subscription.rb` / Expected: load error
- [ ] **Step 3: 実装する** — 購読ごとのスレッドは `def self.spawn_feed(sub, generation)` の中の `Thread.new { run_feed(sub, generation) }`（規則 21）。`on_open` / `on_message` の呼び出しと rescue は、ブロックを取らない専用のメソッド（`Scheduler.run_task` と同じ形）。`Status` の書き込みと読み出しは `Mutex` で守る。
- [ ] **Step 4: 通す** — Run: `ruby -I. test/websocket_subscription.rb`、続けて `script/regen-snapshot test/websocket_subscription.rb`（コンパイルしたバイナリで）→ 全件 ok。`spin test test/background.rb test/application.rb` も一致。
- [ ] **Step 5: コミット**（件名例: `WebSocket.subscribe: long-lived feeds with reconnect, pings and staleness`）

### Task 6: ドキュメント

**Files:**
- Modify: `README.md`（冒頭の「Not built: ... WebSockets/ActionCable」を「a WebSocket server (ActionCable)」に、Rails との対応表に `ActionCable client, faye-websocket, websocket-client-simple` の行、「Outbound HTTP」の後に「Consuming WebSocket feeds」の節）
- Modify: `docs/design.md`（D33 を足す。2.3 節と 8 節の WebSocket を「WebSocket サーバ（ActionCable）」に絞り、D33 で外向きクライアントが入ったことを書く）
- Modify: `docs/api/stubs/*.rb`（公開 API に YARD のスタブが要る仕組みなら同じ形で足す。`script/api-docs` が通ること）

**Interfaces:**
- Consumes: Task 1〜5 の公開 API 名（そのまま書く）

- [ ] **Step 1: README の節を書く** — 中身: spec 1 節の例、`require` の要否、待ちと再接続（既定値と式）、沈黙検知（ping と `stale_after`）、ログの行（spec 4.4 の表）、`status`、制限（spec 2 節: 拡張・サブプロトコル無し、UTF-8 を検証しない、`Connection` はコールバックの中だけ、動作中の追加不可、サーバ側は無い）、OS ワーカーの注意（spec 4.3）、`CYBERTRAIN_WORKER=0` で動かない、テスト（`Test::WebSocketReceiver` の例を 10 行程度）。
- [ ] **Step 2: design.md に D33 を書く** — 既存の D24 / D27 の書式（背景・決定・却下・後回し・帰結）。決定の要点は spec 3〜4 節、`Background` 登録表の理由（libssl を持ち込まない、`Net.tls_connector` と同じ形）を含める。
- [ ] **Step 3: 確かめる** — Run: `script/gate` → すべて ok。`script/api-docs` があれば実行してエラーなし。README の例のコードが Task 5 の API 名と一致していることを目で確かめる。
- [ ] **Step 4: コミット**（件名例: `docs: Consuming WebSocket feeds (README), D33 in design.md`）
