# MySQL アダプタ(第1段)実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** cybertrain のアプリが、ビルド時に MySQL 8.0 以上を選べるようにする。対象はモデル、マイグレーション、`cybertrain test`、フレームワークのサービスで、すべて SQLite と同じ結果で動かす。SQLite の挙動は変えない。

**Architecture:** 3層に分ける。

- **Driver**: `DB::Connection` の実装で、adapter ごとに1つ。
- **Dialect**: `DB::Dialect` と生成器の `Generator::Dialect`。
- **呼び出し側**: Relation、モデル、Migrator、サービス。

adapter はエントリファイルで決める。SQLite は `require "cybertrain"`、MySQL は `require "cybertrain/mysql"` で、これがビルド時に1つだけ決まる。同じ定数名を、選ばれた adapter のファイルだけが定義する。MySQL の Driver は、クライアントプロトコルを `Cybertrain::Net` の上に Ruby で実装する。これで、待っているあいだも OS ワーカーを止めない。

**Tech Stack:** Spinel(ピンしているビルド)、`Cybertrain::Net` と `cybertrain/net/tls`、Spinel の `digest`、MySQL 8.0(テストと CI では Docker の `mysql:8.0`)。

**Spec:** `docs/superpowers/specs/2026-11-27-mysql-adapter-design.md`(承認済み)。実装者は必ずこの設計書も読むこと。

## Global Constraints

- 受け入れの条件は、コンパイルしたプログラムで通ること(`spin test test/<name>.rb`、`script/test-mysql test/mysql/<name>.rb`)。CRuby で通るだけでは受け入れない。
- CLAUDE.md に従う。書き込む作業は1つずつ順番に進める。各タスクの最後に、`script/gate` と、そのタスクが触った箇所のテストだけを動かす。スイート全体は CI に任せる。
- SQLite のバイト不変:
  - 既存の `test/*.rb.expected`、`examples/blog/gen/`、`test/fixtures` の生成物は差分ゼロにする。
  - 差分が出たタスクは不合格。例外は、タスクに「差分が出てよい」と明記したものだけ。
- SQLite のプログラムに MySQL のコードが入らないこと。逆も同じ。
- 実行時に adapter で分岐しない。`if adapter == ...` を書かない。
- MySQL 8.0 以上。`utf8mb4` / `utf8mb4_0900_bin` を使う。
- 接続時のセッション設定:
  - `time_zone = '+00:00'`
  - `sql_mode = 'STRICT_ALL_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO,ONLY_FULL_GROUP_BY'`
  - 分離レベルは REPEATABLE READ(既定のまま)
- TLS:
  - `ssl_mode` は `verify`(既定)と `disabled` の2つ。
  - `disabled` は、接続先が `127.0.0.1` / `::1` / `localhost` / RFC1918 / fc00::/7 のときだけ受け付ける。
  - CA は `SSL_CERT_FILE` / `SSL_CERT_DIR` で渡す。`Net` と openssl のバインディングには手を入れない。
- `DROP DATABASE` / `CREATE DATABASE` を実行するのは `db create` / `db drop` だけ。テストの bundle では実行しない。
- `Connection#execute` の戻り値の契約は `Array<Hash<String, Integer | Float | String | nil>>`。`execute_models` は datetime を UTC のエポックマイクロ秒(Integer)で返す(D42)。
- Spinel の規則は `spikes/NOTES.md` に従う。新しい挙動を見つけたら、CONTRIBUTING.md の手順で記録する。
- 決定は `docs/design.md` の D96 として最後のタスクで書く。各タスクは、決めたことをコミットメッセージに残す。

## Review Focus

1. **接続がサーバー側で切れる。** 原因には `wait_timeout`、フェイルオーバー、`KILL` がある。
   - プールから出した接続が死んでいたら、黙って開き直して1回だけ実行し直す。
   - トランザクションの途中で切れたら、`DB::ConnectionLost` を投げて巻き戻ったものとして扱う。実行し直してはならない。
   - Task 8 のテスト `pool_reconnects_after_kill` / `transaction_lost_on_kill` で確認する。
2. **16MB を超える行やパケット。** MySQL のパケットは `0xFFFFFF` ごとに分割される。17MB の BLOB が往復でバイト一致すること。Task 4 の `split_packet_roundtrip`(単体)と Task 9 の `blob_17mb_roundtrip`(結合)で確認する。
3. **4バイトの UTF-8、NUL を含む文字列、不正な UTF-8 の BLOB。** 絵文字が `string` / `text` で往復すること。NUL 入りのデータが BLOB で往復すること。Task 9 の `utf8mb4_and_nul_roundtrip` で確認する。
4. **サーバーの既定タイムゾーンが UTC でない。** `--default-time-zone=+09:00` で起動したサーバーでも、datetime がマイクロ秒まで UTC で往復すること。Task 7 の `datetime_utc_on_non_utc_server` で確認する。`script/mysql-dev` は、このテスト用に `+09:00` で起動する。
5. **遅いクエリが、他のグリーンスレッドを止めない。** `SELECT SLEEP(1)` の実行中も、同じワーカーの別スレッドが動き続けること。Task 7 の `slow_query_does_not_block_worker` を `SPINEL_WORKERS=1` で確認する。同じ Task の `statement_cache_evicts` では、異なる SQL を 2,000 本流しても `max_prepared_stmt_count` に当たらないことを確認する。

---

## ファイル構成(決定事項)

| パス | 役割 |
| --- | --- |
| `cybertrain/db.rb` | adapter に依存しない `DB` モジュール(pool、transaction、with)。adapter を require しない |
| `cybertrain/db/error.rb` | `DB::Error` と、そのサブクラス `UniqueViolation`、`ForeignKeyViolation`、`Deadlock`、`LockTimeout`、`ConnectionLost` |
| `cybertrain/db/sqlite.rb` | SQLite の adapter のエントリ。`sqlite_ffi`、`sqlite/connection`、`sqlite/dialect`、`sqlite_ddl` を require する |
| `cybertrain/db/sqlite/connection.rb` | 今の `db/connection.rb` をそのまま移す |
| `cybertrain/db/sqlite/dialect.rb` | `DB::Dialect` と `DB::Adapter` の SQLite 実装 |
| `cybertrain/db/mysql.rb` | MySQL の adapter のエントリ |
| `cybertrain/db/mysql/{wire,packet,url,handshake,auth,protocol,result,statement_cache,connection,dialect,ddl,schema}.rb` | MySQL の Driver と Dialect |
| `cybertrain/core.rb` | `require "cybertrain/db/sqlite"` と `require "cybertrain/core/common"` |
| `cybertrain/core/common.rb` | 今の `core.rb` の中身(adapter 以外) |
| `cybertrain/core/mysql.rb` | `require "cybertrain/db/mysql"` と `require "cybertrain/core/common"` |
| `cybertrain/mysql.rb` | `cybertrain.rb` の MySQL 版。`core/mysql` と各サブシステムを require する |
| `cybertrain/generator/dialect.rb` | 生成器(CRuby)側の Dialect。`SqliteGen` と `MysqlGen` |
| `script/check-db-adapter` | adapter のファイルを require してよいのは `core.rb` と `core/mysql.rb` と adapter のテストだけ、を確かめるスクリプト。gate に入れる |
| `script/mysql-dev` | Docker で `mysql:8.0` を起動し、`CYBERTRAIN_TEST_MYSQL_URL` を表示する |
| `script/test-mysql` | `test/mysql/*.rb` をコンパイルして実行し、`.expected` と照合する。URL がなければ exit 2 |
| `test/mysql/*.rb` | MySQL の結合テスト。`spin test` の対象(`test/*.rb`)には含めない |

---

### Task 1: adapter のエントリを分ける(挙動は変えない)

**Files:**
- Create: `cybertrain/db/sqlite.rb`、`cybertrain/db/sqlite/connection.rb`(`git mv cybertrain/db/connection.rb`)、`cybertrain/core/common.rb`、`cybertrain/core/mysql.rb`、`cybertrain/mysql.rb`、`cybertrain/db/mysql.rb`(この時点では空の module だけ)、`script/check-db-adapter`
- Modify: `cybertrain/db.rb`(`sqlite_ffi` と `connection` の require を外す)、`cybertrain/core.rb`、`cybertrain/db/error.rb`
- Modify: サブシステムのファイル(`cybertrain/jobs.rb` など)で `require "cybertrain/core"` しているものを、`require "cybertrain/core/common"` に変える。対象は `grep -rln 'require "cybertrain/core"' cybertrain` で列挙する
- Modify: `cybertrain/test/bundle.rb`。`require "cybertrain"` を外し、エントリは gen/tests.rb が先に require する(Task 3 で生成器を対応させる)
- Modify: `script/gate`(`check-db-adapter` を追加)、`script/check-core-closure`(`core/common.rb` を閉包の根にする)

**Interfaces:**
- Produces:
  - `DB::Error` のサブクラス:
    - `UniqueViolation < Error`
    - `ForeignKeyViolation < Error`
    - `Deadlock < Error`
    - `LockTimeout < Error`
    - `ConnectionLost < Error`
  - SQLite の Connection が、制約違反でこれらを投げる。SQLite のエラー番号を見て判別する。メッセージは今のまま変えない。
  - adapter を決めるのはエントリの require だけ。

- [ ] **Step 1:** `test/db_error_classes.rb` を書く。SQLite の `:memory:` で次を確かめる。
  - UNIQUE 違反で `e.is_a?(DB::UniqueViolation)` が真になり、`e.message` が今の文言と同じであること。
  - 外部キー違反で `DB::ForeignKeyViolation` になること。
- [ ] **Step 2:** `spin test test/db_error_classes.rb` を実行し、FAIL することを確かめる(定数がない)。
- [ ] **Step 3:** ファイルを分け、require を付け替え、サブクラスを足す。
- [ ] **Step 4:** `script/check-db-adapter` を書く。`require "cybertrain/db/sqlite"` / `"cybertrain/db/mysql"` が許可した3か所以外にあれば、そのファイル名を出して exit 1 する。
- [ ] **Step 5:** 次を実行し、すべて PASS または差分ゼロであることを確かめる。
  - `spin test test/db_error_classes.rb`
  - `spin test test/db_sqlite.rb`
  - `spin test test/db_integration.rb`
  - `spin test test/jobs.rb`
  - `script/gate`
  - `git status --short examples/blog/gen test/fixtures` が空
- [ ] **Step 6:** コミットする(`db: split the adapter entry from the core; DB::Error subclasses`)。

### Task 2: SQLite 固有の SQL を `DB::Dialect` に集める(挙動は変えない)

**Files:**
- Create: `cybertrain/db/sqlite/dialect.rb`
- Modify(SQLite 固有の SQL を Dialect 呼び出しに置き換える):
  - `cybertrain/relation.rb`(`quote_ident`)、`cybertrain/relation/aggregates.rb`
  - `cybertrain/model.rb`、`cybertrain/model/bulk_writes.rb`
  - `cybertrain/middleware/health_check.rb`、`cybertrain/console/helpers.rb`
  - `cybertrain/test/database.rb`、`cybertrain/test/jobs.rb`、`cybertrain/test/broadcasts.rb`
  - `cybertrain/cache.rb`、`cybertrain/job/store.rb`、`cybertrain/lease.rb`、`cybertrain/stream.rb`
  - `cybertrain/scheduler/timetable.rb`、`cybertrain/websocket/feed_table.rb`、`cybertrain/rate_limit.rb`
  - `cybertrain/db/migrator.rb`、`cybertrain/db/schema_dumper.rb`

**Interfaces:**
- Produces: module `Cybertrain::DB::Dialect`。どのメソッドも、adapter ごとに戻り値の型が1つ。

```ruby
DB::Adapter.name                      # => "sqlite" | "mysql"
DB::Adapter.connect_target(config)    # => String (sqlite: config.database_path, mysql: config.database_url)
DB::Dialect.quote_ident(name)         # => String
DB::Dialect.upsert_tail(conflict_cols, update_cols) # => String  " ON CONFLICT(...) DO UPDATE SET ..." | " ON DUPLICATE KEY UPDATE ..."
DB::Dialect.returning?                # => bool
DB::Dialect.table_names(conn)         # => Array<String>  利用者のテーブルとフレームワークのテーブル。内部テーブルは除く
DB::Dialect.table_exists?(conn, name) # => bool
DB::Dialect.column_names(conn, table) # => Array<String>
DB::Dialect.health_query              # => String  1行返す軽い SELECT
DB::Dialect.foreign_keys_off(conn); DB::Dialect.foreign_keys_on(conn)  # => nil
DB::Dialect.reset_sequences(conn, tables) # => nil
DB::Dialect.foreign_key_violation(conn)   # => String  ""(違反なし)| 最初の違反の説明
DB::Dialect.transactional_ddl?        # => bool
DB::Dialect.ddl_statements(op)        # => Array<String>  今の SqliteDDL.statements の入口
DB::Dialect.now_epoch_usec_sql        # => String  サービスが使う「今」の式
```

  - サービスの SQL のうち上の操作で表せないものは、そのサービスのファイルに Dialect のメソッドを1つ足して閉じ込める。名前は `<service>_<operation>`(例: `job_claim_sql`、`cache_increment(conn, key, by, expires)`)とし、ここに一覧を追記する。
  - メソッドを増やすときは、どれも SQLite と MySQL の両方で実装すること。

- [ ] **Step 1:** `test/db_dialect_sqlite.rb` を書く。上の各メソッドについて、SQLite で今の SQL と同じ文字列または同じ結果になることを照合する。例:
  - `quote_ident("a`b") == "`a``b`"`
  - `table_names` が `sqlite_sequence` を含まないこと
- [ ] **Step 2:** `spin test test/db_dialect_sqlite.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** `cybertrain/db/sqlite/dialect.rb` を実装し、上の呼び出し側を Dialect 経由に置き換える。SQLite のテーブル再作成(`run_rebuild`)は `ddl_statements` の内側に閉じ込める。
- [ ] **Step 4:** 確認として、次のコマンドを実行する。`.expected` に差分が出ないこと。
  - `grep -rn "PRAGMA\|sqlite_master\|sqlite_sequence\|ON CONFLICT\|RETURNING" cybertrain --include=*.rb | grep -v "^cybertrain/db/sqlite\|^cybertrain/cli\|^cybertrain/db/normalizer\|^cybertrain/db/cli"` の結果が空(コメント行だけなら可)
  - `spin test` で次のテストを実行する。
    - `test/db_dialect_sqlite.rb`、`test/cache.rb`、`test/jobs.rb`、`test/lease.rb`
    - `test/stream.rb`、`test/test_database.rb`、`test/db_cli.rb`
    - `test/migrator.rb`、`test/migration_rebuild.rb`、`test/schema_dumper.rb`
  - `script/gate`
- [ ] **Step 5:** コミットする。

### Task 3: 生成器が adapter を知る

**Files:**
- Create: `cybertrain/generator/dialect.rb`、`test/gen_dialect.rb`
- Modify: `cybertrain/generator/models_emitter.rb`、`cybertrain/generator/test_data_emitter.rb`、gen/tests.rb を出す emitter(`grep -rln "tests.rb" cybertrain/generator`)、`cybertrain/cli/authentication_tests.rb`

**Interfaces:**
- Produces:
  - `Generator::Dialect.detect(root) -> String` は `"sqlite" | "mysql"` を返す。アプリの `bin/<name>.rb` のうち、最初の `require "cybertrain..."` の行を読んで決める。
    - `require "cybertrain"` は sqlite、`require "cybertrain/mysql"` は mysql。
    - それ以外の行なら gen を止める。メッセージは `bin/<name>.rb: the first require must be "cybertrain" or "cybertrain/mysql"`。
  - `Generator::Dialect.for(name)` は `quote_ident(name) -> String`、`entry -> String`(`"cybertrain"` / `"cybertrain/mysql"`)、`name -> String` を持つオブジェクトを返す。
  - gen/tests.rb の先頭行は `require "<entry>"`。
  - `authentication_tests.rb` の外部キーの検査:
    - SQLite 向けは今の文言の照合のまま変えない。
    - MySQL 向けは `assert_raises(Cybertrain::DB::ForeignKeyViolation)` を出す。

- [ ] **Step 1:** `test/gen_dialect.rb` を書く。一時ディレクトリにアプリを2つ作り、次を照合する。
  - SQLite の場合、models_emitter の出力が今の `"x"` クォートのままで、`examples/blog/gen` と一致すること。
  - MySQL の場合、`` `x` `` クォートになり、gen/tests.rb の1行目が `require "cybertrain/mysql"` であること。
  - 不正な require 行で、上のメッセージを出して止まること。
- [ ] **Step 2:** `ruby -I. test/gen_dialect.rb` を実行し、FAIL することを確かめる(生成器は CRuby で動く)。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** 次を確かめる。
  - `ruby -I. test/gen_dialect.rb` が PASS すること。
  - `examples/blog` で gen を実行し直しても、`git status --short examples/blog/gen test/fixtures` が空であること。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 4: MySQL のワイヤ形式とパケット

**Files:**
- Create: `cybertrain/db/mysql/wire.rb`、`cybertrain/db/mysql/packet.rb`、`test/mysql_wire.rb`

**Interfaces:**
- Produces:
  - `MySQL::Wire`:
    - `lenenc_int(Integer) -> String`
    - `read_lenenc_int(String, pos) -> [Integer, Integer]`(値、次の位置)
    - `lenenc_str(String) -> String`
    - `read_lenenc_str(String, pos) -> [String, Integer]`
    - `int_le(Integer, bytes) -> String`
    - `read_int_le(String, pos, bytes) -> Integer`
    - `null_str(String, pos) -> [String, Integer]`
    - lenenc の NULL(0xFB)には `read_lenenc_str_or_nil` を使う。
  - `MySQL::PacketIO.new(stream)`:
    - `stream` は `Net` の TCP または TLS ストリーム。
    - `read -> String`(ペイロード)。`0xFFFFFF` ごとに分割されたものは結合して返す。
    - `write(payload)`。`0xFFFFFF` ごとに分割し、ちょうど `0xFFFFFF` で終わる場合は空のパケットを1つ足す。
    - `reset_sequence`
    - シーケンス番号が合わなければ `DB::ConnectionLost` を投げる。
    - 待ちはすべて `Net` の上限付きの待ちで行う。

- [ ] **Step 1:** `test/mysql_wire.rb` を書く。
  - lenenc の各境界値が往復すること: 250、251、0xFFFF、0x10000、0xFFFFFF、0x1000000。
  - `split_packet_roundtrip`: 文字列 IO を模したストリームで、長さ `0xFFFFFF`、`0xFFFFFF+1`、`2*0xFFFFFF+5` のペイロードが往復すること。ヘッダのシーケンス番号が 0,1,2… と進むこと。
  - シーケンス番号のずれで `ConnectionLost` になること。
- [ ] **Step 2:** `spin test test/mysql_wire.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** `spin test test/mysql_wire.rb` を実行し、PASS することを確かめる。`script/gate` も通ること。
- [ ] **Step 5:** コミットする。

### Task 5: URL、ハンドシェイク、認証、TLS への切り替え

**Files:**
- Create: `cybertrain/db/mysql/url.rb`、`cybertrain/db/mysql/handshake.rb`、`cybertrain/db/mysql/auth.rb`、`test/mysql_auth.rb`

**Interfaces:**
- Produces:
  - `MySQL::Url.parse(String) -> Url`
    - 属性は `host`、`port`(既定 3306)、`user`、`password`、`database`、`ssl_mode`(`"verify"` / `"disabled"`)、`connect_timeout`、`read_timeout`、`write_timeout`(秒、既定 5 / 30 / 30)。
    - `user` と `password` はパーセントデコードする。
    - 不正な URL、未知の `ssl_mode`、公開アドレスへの `disabled` は `ArgumentError` にする。メッセージにパスワードを含めない。
  - `MySQL::Handshake.parse(payload) -> Handshake`。属性は `server_version`、`connection_id`、`scramble`(20 バイト)、`capabilities`、`auth_plugin`。
  - `MySQL::Auth.native_password(password, scramble) -> String`。`SHA1(pw) XOR SHA1(scramble + SHA1(SHA1(pw)))` を計算する。
  - `MySQL::Auth.caching_sha2(password, scramble) -> String`。`SHA256(pw) XOR SHA256(SHA256(SHA256(pw)) + scramble)` を計算する。
  - 空のパスワードは、どちらでも空文字列を返す。
  - `MySQL::Auth.handshake(io, url, handshake, tls_wrap) -> nil`
    - クライアントの capability: `CLIENT_PROTOCOL_41 | SECURE_CONNECTION | PLUGIN_AUTH | PLUGIN_AUTH_LENENC_CLIENT_DATA | CONNECT_WITH_DB | MULTI_STATEMENTS | MULTI_RESULTS | PS_MULTI_RESULTS | FOUND_ROWS | TRANSACTIONS | DEPRECATE_EOF`。`verify` のときだけ `SSL` も立てる。
    - 文字セットは 255(`utf8mb4_0900_ai_ci`、接続の文字セット)。照合順序はセッション設定とカラムで `utf8mb4_0900_bin` にする。
    - SSL Request を送ってから `tls_wrap` を呼び、TLS 上で HandshakeResponse を送る。
    - auth switch request(0xFE)を受けたら、指定されたプラグインでやり直す。
    - `caching_sha2` の応答:
      - `0x01 0x03` は高速認証の成功。
      - `0x01 0x04` はフル認証の要求。TLS 上なら、パスワードと NUL を平文で送る。TLS なしなら `DB::Error` を投げる。メッセージは `caching_sha2_password full authentication needs TLS (ssl_mode=verify)`。
  - SHA1 が Spinel の `digest` にない場合は、`cybertrain/db/mysql/sha1.rb` に純 Ruby で実装する(FIPS 180-4)。

- [ ] **Step 1:** `test/mysql_auth.rb` を書く。
  - 既知のテストベクタで照合する。パスワード `"secret"`、scramble `"0123456789abcdefghij"` の `native_password` と `caching_sha2` の期待値は、実装前に CRuby の `Digest` で算出して、テストに固定値で書く。
  - 記録したハンドシェイクのパケットを parse した結果を照合する。パケットは Task 7 の `script/mysql-dev` のサーバーから一度取り、16 進でテストに埋める。
  - URL の各エラーと、パスワードがメッセージに含まれないことを確かめる。
  - `disabled` が `10.0.0.5` では通り、`8.8.8.8` では拒否されることを確かめる。
- [ ] **Step 2:** `spin test test/mysql_auth.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** `spin test test/mysql_auth.rb` を実行し、PASS することを確かめる。`script/gate` も通ること。
- [ ] **Step 5:** コミットする。

### Task 6: テキストプロトコル、バイナリプロトコル、結果、エラー

**Files:**
- Create: `cybertrain/db/mysql/protocol.rb`、`cybertrain/db/mysql/result.rb`、`test/mysql_protocol.rb`

**Interfaces:**
- Produces:
  - `MySQL::Result`:
    - `names : Array<String>`
    - `types : Array<Integer>`(MySQL のカラム型)
    - `rows : Array<Array<Integer | Float | String | nil>>`
    - `affected_rows : Integer`
    - `last_insert_id : Integer`
    - `datetime_columns : Array<bool>`
  - `MySQL::Protocol.new(io)`:
    - `query(sql) -> Result`。COM_QUERY で送る。multi-statements の場合は最後の結果を返し、途中の ERR で止まる。
    - `prepare(sql) -> Integer`(statement id)。COM_STMT_PREPARE で送る。
    - `param_count(id) -> Integer`
    - `execute(id, binds) -> Result`。COM_STMT_EXECUTE、binary protocol で送る。bind の型は次のとおり。
      - `Integer` → LONGLONG
      - `Float` → DOUBLE
      - `String` → VAR_STRING(バイト列のまま)
      - `nil` → NULL ビット
      - `DB::Blob` → BLOB
    - `close_statement(id) -> nil`
    - `ping -> bool`
    - `quit -> nil`
  - 結果の値の変換:
    - TINY / SHORT / LONG / LONGLONG / INT24 / YEAR → Integer
    - FLOAT / DOUBLE → Float
    - NEWDECIMAL → Float(D73)
    - DATE → `"YYYY-MM-DD"`
    - DATETIME / TIMESTAMP → `"YYYY-MM-DD HH:MM:SS.ffffff"`。今の SQLite の `execute` と同じ形式。Task 7 で `execute_models` 用のエポックマイクロ秒に変える。
    - JSON / BLOB / 文字列 → String
  - ERR パケットの変換:
    - 1062 → `UniqueViolation`
    - 1451、1452、1216、1217 → `ForeignKeyViolation`
    - 1213 → `Deadlock`
    - 1205 → `LockTimeout`
    - EOF、2006 相当、2013 相当 → `ConnectionLost`
    - それ以外 → `DB::Error`
    - メッセージは `"#{server_message} (MySQL #{code}, #{sqlstate})"` にする。SQL は付けない。今の SQLite と同じ扱い。

- [ ] **Step 1:** `test/mysql_protocol.rb` を書く。記録したパケット列(16 進)を流すダミーのストリームで、次を照合する。
  - 結果セットの読み取り。カラム型ごとに1つずつ用意する(NULL ビットマップの境界として、カラム数 7、8、9 を含める)。
  - OK パケットの affected_rows / last_insert_id。
  - 各エラー番号から例外クラスへの対応。
  - multi-statements の2つ目でエラーが出た場合。
  - パケット列は `script/mysql-dev` のサーバーに対して取得する。取得方法は、テストの冒頭のコメントに書く。
- [ ] **Step 2:** `spin test test/mysql_protocol.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** `spin test test/mysql_protocol.rb` を実行し、PASS することを確かめる。`script/gate` も通ること。
- [ ] **Step 5:** コミットする。

### Task 7: `DB::Connection`(MySQL)と、MySQL のテスト環境

**Files:**
- Create: `cybertrain/db/mysql/connection.rb`、`cybertrain/db/mysql/statement_cache.rb`、`script/mysql-dev`、`script/test-mysql`、`test/mysql/connection.rb` と `.expected`
- Modify: `cybertrain/db/mysql.rb`、`.github/workflows/ci.yml`(ジョブ `mysql-tests` を追加。`services: mysql: image: mysql:8.0`、`--default-time-zone=+09:00`、`script/test-mysql` を実行)、`script/gate`(`test/mysql/*.rb` に `.expected` があることを確かめる)、CONTRIBUTING.md(MySQL のテストの動かし方)

**Interfaces:**
- Consumes: Task 4〜6
- Produces: `DB::Connection.new(target : String, create: true)`。`target` は MySQL の URL。
  - 公開するメソッドは、今の SQLite の Connection と同じ名前と同じ戻り値の型にする: `execute`、`execute_models`、`exec_script`、`changes`、`last_insert_id`、`variable_limit`(65535)、`statements_run`、`in_transaction?`、`transaction`、`begin!(immediate: false)`、`commit!`、`rollback!`、`abandon_transaction!`、`close`、`closed?`。
  - SQLite 専用のメソッド(`journal_mode` など)は持たない。呼び出し側は Task 2 で Dialect に移してある。
  - 接続直後に、Global Constraints のセッション設定を1回の `exec_script` で行う。
  - `execute_models` は、datetime のカラムをエポックマイクロ秒(Integer)で返す。
  - `begin!(immediate:)` は、どちらでも `BEGIN` を送る。
  - transaction-gone の扱いは SQLite の Connection と同じにする(`refuse_if_transaction_gone` の意味を移植する)。
  - `MySQL::StatementCache`:
    - 接続ごとに SQL をキーにして保持する。上限は 256。
    - 溢れたら一番古いものを `close_statement` する。
- `script/mysql-dev`:
  - `docker run -d --name cybertrain-mysql -e MYSQL_ROOT_PASSWORD=cybertrain -e MYSQL_DATABASE=cybertrain_test -p 33306:3306 mysql:8.0 --default-time-zone=+09:00 --character-set-server=utf8mb4 --collation-server=utf8mb4_0900_bin` を実行する。
  - 起動を待ってから `CYBERTRAIN_TEST_MYSQL_URL=mysql://root:cybertrain@127.0.0.1:33306/cybertrain_test?ssl_mode=disabled` を表示する。
- `script/test-mysql [files...]`:
  - URL がなければ `CYBERTRAIN_TEST_MYSQL_URL is not set (script/mysql-dev starts a server)` を出して exit 2 する。
  - 引数がなければ `test/mysql/*.rb` をすべて対象にする。
  - 1つずつ `spin` でコンパイルして実行し、`.expected` と照合する。表示の形式は `spin test` と同じにする。

- [ ] **Step 1:** `test/mysql/connection.rb` を書く。各テストの名前と照合内容は次のとおり。
  - `crud_roundtrip`: INSERT / SELECT / UPDATE / DELETE が成功すること。`changes` と `last_insert_id` も確かめる。
  - `types_roundtrip`: 型の表の各型を1行ずつ照合する。
  - `datetime_utc_on_non_utc_server`: `2026-03-01 12:34:56.123456` を入れて、`execute_models` が `1772368496123456` を返すこと。
  - `transaction_rollback`
  - `unique_violation_class`
  - `slow_query_does_not_block_worker`: スレッド A が `SELECT SLEEP(1)` を実行するあいだ、スレッド B が 0.05 秒間隔で数えて、10 以上になること。`SPINEL_WORKERS=1` で実行する。
  - `statement_cache_evicts`: 異なる SQL を 2,000 本流しても、`SHOW SESSION STATUS LIKE 'Prepared_stmt_count'` が 256 以下であること。
- [ ] **Step 2:** `script/mysql-dev` を実行し、表示された URL で `script/test-mysql test/mysql/connection.rb` を実行する。FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** `script/test-mysql test/mysql/connection.rb` を実行し、PASS することを確かめる。`script/gate` も通ること。
- [ ] **Step 5:** コミットする。

### Task 8: プール、設定、起動

**Files:**
- Modify: `cybertrain/db/pool.rb`、`cybertrain/config.rb`(`database_url` を追加。`DATABASE_URL` から読み、環境ごとの既定値は空)、`cybertrain/application.rb`(起動時に `DB.connect(DB::Adapter.connect_target(config), size:)` を呼ぶ)、`cybertrain/db/mysql/dialect.rb`(`DB::Adapter` の部分)
- Test: `test/mysql/pool.rb`、`test/config_settings.rb` の既存の照合(SQLite の既定値が変わらないこと)

**Interfaces:**
- Produces:
  - MySQL のアプリで `database_url` が空のときは、起動を止める。メッセージは `DATABASE_URL is not set (mysql://user:password@host:3306/name)`。
  - `Pool#with` は、接続を渡す前に生死を確かめない。ping でクエリ1本分の往復を増やさないため。
    - 実行中に `ConnectionLost` が出て、トランザクションの外かつ最初の1文だったときだけ、接続を開き直して1回だけ実行し直す。
    - トランザクションの中なら、開き直さずに `ConnectionLost` を投げる。その接続は捨てる。

- [ ] **Step 1:** `test/mysql/pool.rb` を書く。
  - `pool_reconnects_after_kill`: 別の接続から `KILL <connection_id>` したあと、次の `DB.with { execute }` が成功すること。
  - `transaction_lost_on_kill`: `DB.transaction` の中で KILL されたら `ConnectionLost` になり、その行が残っていないこと。
  - `missing_database_url`: 上のメッセージが出ること。
- [ ] **Step 2:** `script/test-mysql test/mysql/pool.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** 次を確かめる。
  - `script/test-mysql test/mysql/pool.rb` が PASS すること。
  - `spin test test/db_integration.rb test/config_settings.rb test/config_validation.rb` に差分が出ないこと。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 9: MySQL の Dialect(実行時)とモデルのパリティ

**Files:**
- Create: `cybertrain/db/mysql/dialect.rb`(Task 2 で決めたメソッドをすべて実装する)、`test/mysql/models.rb`、`test/mysql/relation.rb`、`test/mysql/bulk_writes.rb`
- Modify: `cybertrain/model/bulk_writes.rb`(`returning?` が偽のときの経路)

**Interfaces:**
- Produces:
  - `RETURNING` の代わり:
    - `insert_all` / `upsert_all` に `returning:` を指定した場合は、同じトランザクションの中で書き込み、そのあと SELECT する。トランザクションの外で呼ばれたら、1つ張る。
    - SELECT の条件は、次のどちらかにする。戻り値の行の順序は、入力の順序にする。
      - 主キーが AUTO_INCREMENT で、すべて新しく挿入された場合: `last_insert_id` から連続した id の範囲。`innodb_autoinc_lock_mode=2` でも、1つの INSERT 文で入れた id は連続する。
      - それ以外の場合: 衝突したキーの組で探す。
  - `upsert_tail` は、行エイリアスの構文(`AS new ON DUPLICATE KEY UPDATE c = new.c`)を使う。

- [ ] **Step 1:** 3つのテストを書く。どれも、出力に SQL の文字列を含まない既存の SQLite のテストと同じ操作をして、同じ行を出す。同じ `.expected` にするため、対応する SQLite のテストの `.expected` をコピーして作る。差分が出てよいのは、設計書の3つの例外(JSON の正規化、`LIKE`、エラーメッセージの文言)だけ。差分を出した箇所には、どの例外かをコメントで書く。
  - `test/mysql/models.rb`: CRUD、バリデーション(uniqueness で `"a"` と `"a "` が別の値として扱われること、`"A"` と `"a"` が別の値として扱われること)、関連と includes(ネストを含む)、`has_many :through`、polymorphic、暗号化カラム、decimal、json、date、datetime。
  - `blob_17mb_roundtrip`
  - `utf8mb4_and_nul_roundtrip`
  - `test/mysql/relation.rb`: where / order / limit / 集計 / pluck / `LIKE` が大文字小文字を区別すること。
  - `test/mysql/bulk_writes.rb`: `insert_all` / `upsert_all` / `returning:` の戻り値が SQLite と同じであること。
- [ ] **Step 2:** `script/test-mysql test/mysql/models.rb test/mysql/relation.rb test/mysql/bulk_writes.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** 次を確かめる。
  - 同じコマンドで PASS すること。
  - `spin test test/bulk_writes.rb`で SQLite に差分が出ないこと。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 10: MySQL の DDL、Migrator、SchemaDumper

**Files:**
- Create: `cybertrain/db/mysql/ddl.rb`、`cybertrain/db/mysql/schema.rb`、`test/mysql/migrations.rb`
- Modify: `cybertrain/db/migrator.rb`(`transactional_ddl?` が偽のときの失敗報告)、`cybertrain/db/schema_dumper.rb`(Dialect から読む)

**Interfaces:**
- Produces:
  - 型の対応は、設計書の型の表のとおり。
  - `CREATE TABLE` に必ず `ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_bin` を付ける。
  - `id` は `BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY`。`references` も BIGINT にする。
  - MySQL では、1つのマイグレーションの途中で失敗した場合、次のように報告する。
    - 表示: `migration <version> failed at statement <n> of <m>; statements 1..<n-1> were applied and cannot be rolled back (MySQL DDL commits implicitly): <message>`
    - `schema_migrations` には記録しない。
  - `SchemaDumper` は、同じマイグレーションから SQLite と同じ `db/schema.rb` を出す。式インデックスなど、どうしても差が出る項目は、`test/mysql/migrations.rb` の冒頭のコメントに列挙する。

- [ ] **Step 1:** `test/mysql/migrations.rb` を書く。
  - `examples/blog/db/migrate` を MySQL に適用し、ダンプした `schema.rb` が `examples/blog/db/schema.rb` と一致すること。
  - `rollback` と `status` の出力を照合する。
  - 2文目で失敗するマイグレーションで、上のメッセージが出ること。`schema_migrations` に記録されないこと。
  - add / remove / rename column、index(unique、where 付きは MySQL にないので拒否のメッセージ)、外部キー(`on_delete`)を確かめる。
- [ ] **Step 2:** `script/test-mysql test/mysql/migrations.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。部分インデックス(`where:`)は MySQL では gen の段階で止める。メッセージは `partial indexes (where:) are not supported on MySQL`。
- [ ] **Step 4:** 次を確かめる。
  - `script/test-mysql test/mysql/migrations.rb` が PASS すること。
  - `spin test test/migrator.rb test/migration_rebuild.rb test/schema_dumper.rb test/schema.rb` に差分が出ないこと。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 11: `Test::Database` と `cybertrain test` を MySQL で

**Files:**
- Modify: `cybertrain/test/database.rb`、`cybertrain/test/bundle.rb`
- Test: `test/mysql/test_database.rb`

**Interfaces:**
- Produces:
  - 中身を消してよいかの確認(MySQL)。次をすべて満たしたときだけ消す。満たさなければ `Bundle::Refused` を投げる。
    1. `env == "test"`
    2. URL のデータベース名が `_test` で終わる
    3. テーブル `cybertrain_test_marker` がある、またはデータベースが空である。空の場合は、目印のテーブルをここで作る。
  - 拒否のメッセージは、SQLite の拒否と同じ書き方にする。データベース名は出すが、パスワードは出さない。
  - 行の消去は、`foreign_keys_off`、各テーブルの `DELETE`、`reset_sequences`(`ALTER TABLE … AUTO_INCREMENT = 1`)、フィクスチャの挿入、`foreign_keys_on`、`foreign_key_violation` による確認、の順に行う。
  - MySQL では DDL が暗黙にコミットするので、DDL を同じトランザクションに入れない。

- [ ] **Step 1:** `test/mysql/test_database.rb` を書く。
  - 名前が `_test` で終わらないデータベースを拒否すること。
  - 目印がなくテーブルがあるデータベースを拒否すること。
  - 空のデータベースには目印を作ってから進めること。
  - 消去とフィクスチャの読み込みのあとで、id が 1 から振り直されていること。
  - フィクスチャの外部キー違反が報告されること。
- [ ] **Step 2:** `script/test-mysql test/mysql/test_database.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** 次を確かめる。
  - 同じコマンドで PASS すること。
  - `spin test test/test_database.rb` に差分が出ないこと。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 12: フレームワークのサービスを MySQL で(1台・1プロセスで正しく)

**Files:**
- Modify: Task 2 で Dialect に移したサービスの操作の MySQL 実装(`cybertrain/db/mysql/dialect.rb`)
- Test: `test/mysql/jobs.rb`、`test/mysql/cache.rb`、`test/mysql/stream.rb`、`test/mysql/lease.rb`、`test/mysql/timetable.rb`。それぞれ、対応する SQLite のテストと同じ操作をして、同じ `.expected` になること。

**Interfaces:**
- Produces:
  - ジョブの取り出しは `SELECT … FOR UPDATE` を使う。`SKIP LOCKED` は第2段で扱うので、ここでは使わない。
  - `cache_increment` には `INSERT … ON DUPLICATE KEY UPDATE value = LAST_INSERT_ID(value + ?)` を使い、`last_insert_id` を読む。
  - リースの `acquire` は1文の upsert で行い、`changes` で取れたかどうかを判定する。
  - `CLIENT_FOUND_ROWS` を立てたので、`changes` は「条件に合った行の数」を返す。
  - 時刻の式は `now_epoch_usec_sql` に揃える。

- [ ] **Step 1:** テストを書く。各ファイルには次を必ず含める。
  - `enqueue_joins_transaction`: ジョブの登録が、ロールバックで消え、コミットで残ること。
  - `broadcast_joins_transaction`: 配信の登録も同じであること。
  - `cache_write_rolls_back`
  - `increment_is_atomic`: 2 スレッドで各 500 回 increment して、合計が 1000 になること。
- [ ] **Step 2:** `script/test-mysql test/mysql/{jobs,cache,stream,lease,timetable}.rb` を実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** 次を確かめる。
  - 同じコマンドで PASS すること。
  - `spin test test/jobs.rb test/cache.rb test/lease.rb test/stream.rb` に差分が出ないこと。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 13: CLI(`new --database=mysql`、`db` コマンド、dbconsole)

**Files:**
- Modify: `cybertrain/cli/new*.rb`(`grep -rln "def self.run" cybertrain/cli | xargs grep -l new`)、`cybertrain/db/cli.rb`、`cybertrain/console/helpers.rb`
- Test: `test/cli_new_mysql.rb`(CRuby)、`test/mysql/db_cli.rb`

**Interfaces:**
- Produces:
  - `cybertrain new NAME --database=mysql` を追加する。
    - `bin/NAME.rb` の先頭を `require "cybertrain/mysql"` にする。
    - `config/app.rb` に `DATABASE_URL` の説明コメントを入れる。
    - `.env.example` に `DATABASE_URL=mysql://root@127.0.0.1:3306/NAME_development` を入れる。
  - `db create` / `db drop` は `CREATE DATABASE` / `DROP DATABASE` を実行する。`drop` は、データベース名が `_production` で終わるものを拒否する。
  - `db migrate` / `rollback` / `status` / `schema:load` / `seed` は、Dialect を経由して動く。
  - `db backup` / `db vacuum` / `db normalize` は、MySQL では exit 2 で止める。メッセージは `db backup is SQLite-only; use mysqldump or your provider's snapshots`(vacuum と normalize も同じ形)。
  - `dbconsole` は、`mysql` クライアントを `--host --port --user --database` と `MYSQL_PWD` で exec する。パスワードはコマンドラインに出さない。

- [ ] **Step 1:** テストを書く。
  - `test/cli_new_mysql.rb`: 生成されたファイルの内容を照合する。
  - `test/mysql/db_cli.rb`: create → migrate → status → rollback → drop の出力と、backup の拒否を照合する。
- [ ] **Step 2:** 2つのテストを実行し、FAIL することを確かめる。
- [ ] **Step 3:** 実装する。
- [ ] **Step 4:** 次を確かめる。
  - 2つのテストが PASS すること。
  - `spin test test/db_cli.rb test/db_cli_backup.rb` に差分が出ないこと。
  - `script/gate` が通ること。
- [ ] **Step 5:** コミットする。

### Task 14: `examples/blog` を MySQL で通し、文書を書く

**Files:**
- Create: `test/fixtures/mysql_blog/`(`examples/blog` のコピーではない。`script/test-mysql --blog` が一時ディレクトリに blog を複製し、`bin/blog.rb` の先頭を `require "cybertrain/mysql"` に書き換えて、`cybertrain test` を実行する)
- Modify:
  - `script/test-mysql`(`--blog`)、`.github/workflows/ci.yml`(`mysql-tests` で `--blog` も実行する)
  - `docs/design.md`(D96。決定と、却下した案を書く。却下した案は、libmysqlclient + `offload: true`、実行時の adapter 選択、`required` の TLS モード、`utf8mb4_bin`、テストの bundle での `DROP DATABASE`)
  - `docs/compatibility.md`(JSON の正規化、`LIKE`、エラーメッセージの文言、DDL が巻き戻らないこと、部分インデックスがないこと)
  - `docs/guide/models.md` と `docs/guide/configuration.md`(MySQL の節。`DATABASE_URL`、TLS と `SSL_CERT_FILE`、RDS の CA の例、**複数台構成のジョブ・ストリーム・リースの保証は第2段まで未保証** と明記)
  - README の Status、`site/` とその4つの翻訳(CONTRIBUTING.md の i18n の手順に従う)

- [ ] **Step 1:** `script/test-mysql --blog` を実行し、FAIL か、まだ動かないことを確かめる。
- [ ] **Step 2:** 足りない部分を直す。ここで見つかった問題は、担当するタスクのテストに再現ケースを足してから直す。
- [ ] **Step 3:** 次を確かめる。
  - `script/test-mysql --blog` で、blog の全テストが PASS すること。
  - `script/test-mysql` で、すべて PASS すること。
  - `script/gate` が通ること(文書の i18n のチェックを含む)。
- [ ] **Step 4:** コミットして push し、CI の `mysql-tests` ジョブが緑になることを確かめる。

---

## 実行の順序

すべてのタスクがワーキングツリーに書き込むので、1つずつ順番に進める(CLAUDE.md)。依存関係は次のとおり。

- 1 → 2 → 3(SQLite の分割。どれも挙動は変えない)
- 4 → 5 → 6 → 7 → 8(Driver)
- 9 → 10 → 11 → 12 → 13 → 14

4〜6 はサーバーがなくても進められる。ただし、記録するパケットを取るために、Task 7 の `script/mysql-dev` だけは先に作ってよい。
