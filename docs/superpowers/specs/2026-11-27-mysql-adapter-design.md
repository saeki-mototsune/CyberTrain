# MySQL アダプタ(スケールに向けたロードマップの第1段)設計

2026-11-27

## 目的と理由

cybertrain で、規模が大きくなるサービスを作れるようにする。今のデータベース層は SQLite 専用で、D74 により「1つのファイルを全サービスで共有する」設計になっている。このため、次の2つができない。

- アプリのバイナリを複数のホストで動かすこと
- リードレプリカで読み込みを分散すること

最初の対象は MySQL にする。PostgreSQL にも将来対応するので、それを前提に境界を切る。

## ロードマップ(この文書が詳しく扱うのは 1 だけ)

1. **MySQL ドライバとアダプタ層**(この文書)。モデル、Relation、マイグレーション、スキーマ、`db` コマンド、テスト時のデータベース分離が MySQL 8.0 以上で動くこと。
2. **フレームワークのサービスの保証を MySQL 向けに詰める。** 対象はジョブ、キャッシュ、ストリーム、リース、スケジューラ、フィード状態。1 で正しく動くようにしたものについて、D74 の保証表を MySQL 向けに決め直し、複数台・高負荷で成り立たせる。例:
   - ジョブの取り出しは `FOR UPDATE SKIP LOCKED` を使う
   - 書き込みが並行するので「id の順番＝コミットの順番」が成り立たなくなる。ストリームの配信順を別の方法で決める
3. **レプリカの設定と明示的な読み込み指定。** `DB.reading { }` など、どこをレプリカで読むかをコードに書く形。
4. **自動振り分け。** GET/HEAD はレプリカで読む。書き込みの直後は、そのユーザーの読み込みをプライマリに送る。3 で作った仕組みの上に作り、3 の明示指定で上書きできるようにする。
5. **運用まわり。** `db backup` 相当、dbconsole、CI での MySQL テスト行列。

3 と 4 の進め方(明示指定を先に作り、その上に自動振り分けを作る)は、依頼者が決めたもの。

## 1 のゴール

- アプリが、ビルド時に SQLite か MySQL のどちらかを選べる。
- フレームワーク自身が、MySQL のクライアントプロトコルを Ruby で実装する。
  - ソケットは既存の `Cybertrain::Net` を使う。待ち時間はすべて上限付きで、ノンブロッキング I/O にする。
  - TLS は `cybertrain/net/tls` を使う。
- モデルの次の機能が MySQL で SQLite と同じ結果を返す。
  - CRUD、Relation、関連と `includes`(ネストを含む)、`has_many :through`、polymorphic
  - 集計、`insert_all` / `upsert_all`
  - バリデーション(uniqueness を含む)、トランザクション
  - 暗号化カラム、BLOB、decimal、json、date、datetime(マイクロ秒)
- マイグレーションとスキーマが MySQL で動く。
  - `create_table`、`add_column`、`remove_column`、`rename_column`、index、外部キー、references
  - `db/schema.rb` のダンプとロード
- `db create / drop / migrate / rollback / status / schema:load / seed` が MySQL で動く。
- `cybertrain test` のテストごとのデータベース分離(D82 の「全行を消してフィクスチャを入れる」方式)が MySQL で動く。消してよいかの確認(D82/D83 のガードの MySQL 版、私の判断)は次のとおり。
  - 環境が `test` であること。
  - データベース名が `_test` で終わること。
  - そのデータベースに、bundle が最初に作る目印のテーブル(SQLite の `application_id` に当たるもの)があること。目印がない場合は、データベースが空のときだけ作る。テーブルが既にあって目印がない場合は拒否する。
  - `DROP DATABASE` / `CREATE DATABASE` はしない。マネージドの MySQL では権限がないことが多いので、既存のデータベースの中身を消して、マイグレーションし直す。データベースは利用者が用意する。
  - 接続先はアプリの `test` 環境の設定から取る(`DATABASE_URL` と同じ形)。フレームワーク自身の結合テストは `CYBERTRAIN_TEST_MYSQL_URL` を使う。
- フレームワークのサービス(ジョブ、キャッシュと `rate_limit`、ストリーム、リース、スケジューラ、フィード状態)の SQL が MySQL で**正しく**動く。依頼者の判断で 1 に含める。
  - 「正しく」とは、1台・1プロセスで既存のテストが同じ結果になること。ジョブとストリームの登録がモデルの書き込みと同じコミットに入る保証(D74)も含む。
  - 各サービスの SQL は Dialect の操作を呼ぶ形に直す。upsert、`RETURNING` の代わり、行のロック、範囲の削除などがある。
  - 複数のプロセスや複数のホストでの保証は 2 で扱う。例として、ジョブの取り出しの競合(`SKIP LOCKED`)、ストリームの id 順とコミット順のずれ、リースの時計がある。1 では、MySQL で複数台構成にしたときに保証されないことを guide に明記する。
- SQLite の挙動は1バイトも変えない。既存のスナップショット、`examples/blog/gen/`、`test/fixtures` の生成物はそのままにする。

## 非ゴール(1 の範囲では作らない)

- サービスの複数プロセス・複数ホストでの保証(上の 2)。
- レプリカ(3 と 4)。ただし 1 の `Pool` と接続設定は、「同じ adapter で接続先が複数ある」ことを後から足せる形にしておく。
- PostgreSQL のドライバ。Dialect の境界だけは PostgreSQL を想定して切る(後述)。
- MariaDB、Vitess / PlanetScale(外部キーなし)の動作保証。プロトコルは MySQL 8.0 に合わせる。Aurora MySQL と RDS は MySQL 8.0 互換として扱う。
- Unix ドメインソケット接続。`Net` にないので、TCP だけにする。
- TLS なしの `caching_sha2_password` のフル認証(RSA 公開鍵で暗号化する経路)。メッセージを出して拒否し、TLS を使うよう案内する。
- 同じバイナリのまま、設定で adapter を切り替えること。

## アンチゴール(技術的に動いても失敗とみなすもの)

- ネットワーク待ちのあいだ OS ワーカーを占有すること。NOTES rule 80 にあるとおり、FFI の C 関数呼び出しはワーカーを占有し、その上の他のグリーンスレッドが全部止まる。MySQL ドライバは、待ちをすべて `Net` の `wait_readable` / `wait_writable` で行う。
- SQLite アプリのバイナリに MySQL のコードが入ること、またはその逆。
- SQLite の挙動、生成コード、スナップショットが変わること。
- 実行時に adapter を動的に選ぶこと。メソッドごとに戻り値の型が1つというSpinelの規則(rule 34 など)を壊し、ホットパスに分岐を増やすので避ける。

## 制約

- フレームワークは Spinel でコンパイルする。`spikes/NOTES.md` の規則に従う。
- 受け入れ条件は、該当するテストをコンパイルした状態で通すこと(`spin test`)。CRuby で通っただけでは受け入れにならない(CONTRIBUTING.md)。
- 決定は `docs/design.md` に新しい D 番号で記録する(今の最新は D95)。Rails との意味の違いが増える場合は `docs/compatibility.md` にも書く。
- `Connection#execute` の戻り値の契約は変えない。戻り値は `Array<Hash<String, Integer | Float | String | nil>>`。`execute_models` では、datetime を UTC のエポックマイクロ秒(Integer)で返す(D42)。

## 検討した作り方

**MySQL との話し方** — 依頼者が A を選んだ。

- **A. プロトコルを Ruby で自前実装する(採用)。** `Net` の上に作るので、I/O がグリーンスレッドを止めない。
  - 既存の HTTP クライアントや SMTP と同じく、外部ライブラリに頼らない方針に沿う。
  - PostgreSQL のプロトコルでも、ソケット、TLS、バッファ、認証まわりをそのまま使える。
  - 作業は一番大きい。認証、TLS への切り替え、binary protocol の prepared statement を書く必要がある。
- B. libmysqlclient を FFI で呼ぶ。早く作れる。しかし rule 80 により、クエリ1本ごとにネットワーク往復のあいだワーカーを占有する。ピンしているビルドの `ffi_func … offload: true` を使えば、呼び出しはプールスレッドで動き、ワーカーは止まらない(docs/spinel-feedback.md の rule 80 の行で確認済み)。ただし文ごとにスレッドの受け渡しが入る(D92 で SQLite への適用を見送った理由と同じ)。また本番ホストに libmysqlclient(GPLv2、FOSS 例外付き)が必要になる。依頼者に再確認したうえで不採用とした。
- C. B から始めて A に置き換える。ドライバを2回作ることになるので不採用。

**層の分け方** — 依頼者が3層を選んだ。

- **Driver**: 接続、パケットの送受信、bind、結果を型に変換する部分、エラー。データベースごとに1つ。
- **Dialect**: SQL 方言の違いを吸収する部分。後述の差分表をすべてここに置く。
- **呼び出し側**: `Relation`、生成モデル、`bulk_writes`、Migrator、SchemaDumper、`Test::Database`、そして 2 でサービス。生の方言 SQL を直接書かず、Dialect の操作を呼ぶ。

**adapter を決めるタイミング** — 私の判断(依頼者には提示済み): ビルド時。

- cybertrain はもともとビルド時にコードを生成するので、生成されるコード(models_emitter が出す SQL 文字列など)はその時点で方言が決まる。
- 実行時は、`Cybertrain::DB::Connection` と `Cybertrain::DB::Dialect` という同じ定数名を、選んだ adapter の実装ファイルが定義する。
  - SQLite のアプリは `cybertrain/db/sqlite/*` だけを require する。
  - MySQL のアプリは `cybertrain/db/mysql/*` だけを require する。
  - 呼び出し側は定数名だけを知っていて、実行時の分岐は持たない。
- 生成器は CRuby の CLI なので、両方の Dialect を同時に持ってよい。

## Dialect の差分表(PostgreSQL の列は境界の確認用で、1 では実装しない)

| 項目 | SQLite(現状) | MySQL | PostgreSQL(将来) |
| --- | --- | --- | --- |
| 識別子のクォート | `"x"`(生成器)、`` `x` ``(Relation) | `` `x` `` | `"x"` |
| プレースホルダ | `?` | `?` | `$1, $2…` |
| 挿入した行の id | `last_insert_rowid` | OK パケットの last_insert_id | `RETURNING id` |
| `RETURNING` | あり(bulk_writes、cache) | **なし**。代替は Dialect で決める(下記) | あり |
| upsert | `ON CONFLICT … DO UPDATE` | `ON DUPLICATE KEY UPDATE`(8.0.19 以降の行エイリアス) | `ON CONFLICT` |
| DDL のトランザクション | 巻き戻る | **巻き戻らない**(暗黙コミット) | 巻き戻る |
| カラム変更 | テーブル再作成(sqlite_ddl) | `ALTER TABLE` | `ALTER TABLE` |
| 型 | 型アフィニティ | 型を厳格に扱う(後述) | 型を厳格に扱う |
| スキーマの読み取り | `sqlite_master`、`PRAGMA` | `information_schema` | `information_schema`、`pg_catalog` |
| 連番のリセット(テスト) | `sqlite_sequence` | `ALTER TABLE … AUTO_INCREMENT = 1` か `TRUNCATE` | `ALTER SEQUENCE … RESTART` |
| 外部キーの一時停止 | `PRAGMA foreign_keys` | `SET FOREIGN_KEY_CHECKS` | `SET session_replication_role` / `DEFERRABLE` |
| bind 変数の上限 | `variable_limit` | 65535 | 65535 |

`RETURNING` の代わりは、`bulk_writes` の `returning:` と `Cache.increment` で必要になる。MySQL では次のどちらかになる。

- 書き込みのあとに同じトランザクション内で SELECT する。
- `LAST_INSERT_ID(expr)` を使う(increment の場合)。

どちらにするかは builder に任せる。ただし `returning:` の戻り値の契約は SQLite と同じにすること。

## 型の対応(私の判断)

| cybertrain の型 | MySQL のカラム | 読み出し |
| --- | --- | --- |
| `string` | `VARCHAR(255)`(`limit:` で変える) | String |
| `text` | `MEDIUMTEXT` | String |
| `integer` / `bigint` / id | `INT` / `BIGINT`。id は `BIGINT AUTO_INCREMENT` | Integer |
| `boolean` | `TINYINT(1)` | Integer(今と同じく 0/1) |
| `decimal` | `DECIMAL(p,s)` | Float(D73) |
| `float` | `DOUBLE` | Float |
| `date` | `DATE` | String(今の SQLite と同じ形式) |
| `datetime` | `DATETIME(6)`。値は UTC で入れる | `execute_models` ではエポックマイクロ秒、`execute` では今の SQLite と同じ文字列形式 |
| `json` | `JSON` | String(Cast がこれまでどおり Hash にする) |
| `binary` | `LONGBLOB` | `DB::Blob` |

文字コードは `utf8mb4` にする。照合順序は **`utf8mb4_0900_bin`** を既定にする(私の判断)。大文字小文字を区別し、NO PAD なので末尾の空白も区別する(`utf8mb4_bin` は PAD SPACE で `'a' = 'a '` が真になるので不採用)。理由は、uniqueness 検証や `where(email: …)` の結果を SQLite と揃えるため。その代わり `LIKE` も大文字小文字を区別する(SQLite の `LIKE` は ASCII の大文字小文字を区別しない)。この違いは compatibility.md に書く。

接続時のセッション設定(私の判断):

- `time_zone = '+00:00'`
- `sql_mode` に `STRICT_ALL_TABLES`、`NO_ZERO_DATE`、`NO_ZERO_IN_DATE`、`ERROR_FOR_DIVISION_BY_ZERO`、`ONLY_FULL_GROUP_BY` を入れる。`ANSI_QUOTES` は入れない。
- トランザクション分離レベルは MySQL の既定の REPEATABLE READ のままにする。

## Driver(MySQL)の要件

- **接続**: `Net` の TCP 接続を使い、接続時の名前解決は1回だけにする。サーバーの SSL 要求を受けて TLS に切り替える。
  - TLS は既存の `cybertrain/net/tls` をそのまま使う。証明書とホスト名は常に検証する(私の判断)。
    - `ssl_mode` は `verify`(既定)と `disabled` の2つにする。`disabled` は、接続先が `127.0.0.1` / `localhost` / プライベートアドレスのときだけ受け付ける。
    - MySQL 本家の `required`(暗号化するが検証しない)は作らない。暗号化だけして相手を確かめない接続は、スケールする本番では中間者攻撃に弱いため。
    - CA は、既存の仕組みどおり `SSL_CERT_FILE` / `SSL_CERT_DIR` で渡す(RDS の CA バンドルなど)。openssl バインディングと `Net` には手を入れない。guide に手順を書く。
- **認証**: `caching_sha2_password` の高速経路、TLS 上のフル認証、`mysql_native_password`。auth switch request にも対応する。
- **クエリ**:
  - bind のあるものは COM_STMT_PREPARE / EXECUTE(binary protocol)で送る。prepared statement は接続ごとに SQL 文字列をキーにしてキャッシュする。上限を設け、溢れたら閉じる。
  - bind のないスクリプト(`exec_script`)は COM_QUERY と multi-statements で送る。
  - 結果セットは型付きで読む。`execute` / `execute_models` の契約どおりの Hash にする。
- **トランザクション**: `begin!` / `commit!` / `rollback!` / `in_transaction?` を、今の `Connection` と同じ意味で提供する。`begin!(immediate: true)` は MySQL では普通の `BEGIN` とし、Dialect に注記を残す。
- **`changes`**: OK パケットの affected rows を返す。接続時に `CLIENT_FOUND_ROWS` を立てて、UPDATE で値が変わらなかった行も数える。SQLite の `changes` と意味を揃えるため。
- **エラー**: サーバーのエラー番号を、既存の `DB::Error` の体系に対応させる。最低限、次を区別する。
  - 一意制約違反(1062)
  - 外部キー違反(1451、1452)
  - デッドロック(1213)とロック待ちタイムアウト(1205)
  - 接続断(2006 / 2013 相当、読み書きの EOF)
- **再接続**: 接続断は `Pool` に返したときに検出して開き直す。今の `Pool#reopen` と同じ考え方。トランザクションの途中で切れた場合は、今の「transaction gone」の扱い(`refuse_if_transaction_gone`)に合わせる。
- **エラーの型**: 今の `DB::Error` は1つのクラスなので、その下にサブクラスを足す(`DB::UniqueViolation`、`DB::ForeignKeyViolation`、`DB::Deadlock`、`DB::ConnectionLost` など。名前は builder が決める)。SQLite の Driver も同じサブクラスを投げるが、メッセージの文言は今のまま変えない。MySQL のメッセージはサーバーの文言のままにする。生成器が出すテストでメッセージを照合している箇所(`authentication_tests.rb` の `"FOREIGN KEY constraint failed"` など)は、MySQL アプリ向けにだけクラスで照合する形を出す。SQLite アプリの生成物は変えない。
- **タイムアウト**: connect、read、write に上限を付ける。`Config` で変更できるようにする。
- **ファイル**: `cybertrain/db/mysql/` に置き、packet、auth、protocol、connection、dialect に分ける。認証に必要な SHA1 / SHA256 は、既にリンクされている openssl パッケージから使う。

## Migrator とスキーマ

- MySQL では `ALTER TABLE` を直接使う。SQLite 用のテーブル再作成(`run_rebuild`)は SQLite の Dialect の中に閉じ込める。
- DDL は巻き戻らない。このため、1つのマイグレーションの途中で失敗すると、前半の変更が残る。
  - Migrator は、失敗した文と、それまでに適用済みの文を表示する。`schema_migrations` にはそのバージョンを記録しない。
  - この違いは design.md と guide に書く。Rails の MySQL アダプタと同じ挙動。
- SchemaDumper は `information_schema` から `db/schema.rb` を作る。同じマイグレーションからは、SQLite と同じ `schema.rb` が出ることを目標にする。どうしても差が出る項目(式インデックスなど)は、差分として列挙する。

## 設定

- ビルド時の adapter 選択は、アプリの設定に `database_adapter`(`sqlite` / `mysql`)として持つ。置き場所は既存の `Config` と生成器の流れに合わせて builder が決める。`cybertrain new --database=mysql` で設定済みのアプリを作れるようにする。
- 実行時の接続先は `DATABASE_URL`(`mysql://user:pass@host:3306/db?ssl_mode=required`)か、個別の設定項目から取る。パスワードはバイナリに入れない。
- `database_path` は SQLite 専用のまま残す。

## テストと受け入れ

- **プロトコルの単体テスト**: サーバーなしで動かす。記録したパケット列と、ハンドシェイク・認証・結果セット・エラーの組み立てを照合する。
- **結合テスト**: `CYBERTRAIN_TEST_MYSQL_URL` が設定されているときだけ実際のサーバーに対して動かし、ないときはスキップして理由を出す。
  - モデル、Relation、関連、bulk_writes、マイグレーション、SchemaDumper、`Test::Database` のテストのうち、出力に SQL 文字列を含まないものは、SQLite と MySQL で同じ `.expected` になることを確認する。
  - ただし、この設計書が意図して選んだ違いがあるテストは、MySQL 用の `.expected` を別に持つ。別にしたものと理由は、テストの横に列挙する。違いは次のとおり。
    - JSON カラムは MySQL が正規化するので、キーの順序や空白が変わる。読み出し側で SQLite に合わせることはしない。
    - `LIKE` が大文字小文字を区別する。
    - エラーメッセージの文言。
- **CI**: MySQL 8.0 のサービスコンテナを使うジョブを1つ足す。
- **パリティ**: `examples/blog` を MySQL でビルドし、`cybertrain test` が通ること。ジョブ、ストリーム、キャッシュ、`rate_limit`、認証を含む。サービスのテスト(`test/jobs.rb` など)も MySQL で通ること。
- **SQLite の回帰**: 既存のゲートとスナップショットが変わらないこと。

## builder に任せること

- Dialect のメソッドの粒度と名前。生成器側の Dialect と実行時の Dialect の分け方。
- `RETURNING` の代替方法。
- prepared statement キャッシュの上限値と、溢れたときの方針。
- パケット単体テストのデータの作り方。
- サービスの SQL を Dialect に移すときの、操作の切り方。
