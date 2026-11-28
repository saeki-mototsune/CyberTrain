---
source_sha256: ebea5fd4f6551f5a27f619315ce4c4c6037bfe519fe8ce4bc13323c83c30a561
---
# モデルとデータベース

スキャフォールドを超えてモデルが行うこと：マイグレーション、カラムの型、クエリ、関連付け、バリデーション、暗号化されたカラム、ページ分け、トランザクション、Spinel のもとでカラム名と `order` 句が従う規則、Rails が作ったデータベースの引き継ぎ、そして MySQL で変わることです。

## マイグレーション

`db/migrate/<version>_<name>.rb` のマイグレーションは `Cybertrain::Migration::Base` のサブクラスです。その `change` はスキーマの操作（`create_table`、`add_column`、`add_index`、`rename_column`、`add_reference`、`remove_column`、`remove_index`、`drop_table`、それに[テーブルを変える](#changing-a-table)の操作）を記録します。`cybertrain db migrate` は未適用の各バージョンをそれぞれのトランザクションで適用し、データベースから `db/schema.rb` を書き直します。`cybertrain db rollback [N]` は `change` の逆を実行します。`create_table`、`add_column`、`add_index`、`rename_column` は自分で逆になります。`add_reference`、`remove_column`、`remove_index`、`drop_table` を含む `change` は、`version N is irreversible: no automatic inverse for <operation>` でロールバックを止めるので、それらには `up` と `down` を書いてください。

安全に行うためにデータの手順を必要とするスキーマの変更には、`execute(sql, binds =
[])` を使います。これはマイグレーション内の書かれた位置で、マイグレーター自身の接続で、そのバージョンのスキーマ操作と同じトランザクションの中で実行されます。そのため、その前に追加したカラムは実行時には存在しており、失敗するとバージョン全体が取り消されます：

```ruby
class AddRetentionDaysToBackups < Cybertrain::Migration::Base
  def change
    add_column "backups", "retention_days", :integer, null: false, default: "90"
    execute "UPDATE backups SET retention_days = ?", [0]   # 既存の行は「無期限」のまま
  end

  def down
    remove_column "backups", "retention_days"
  end
end
```

バインドがない場合、SQL は `;` で区切った複数の文でもかまいません。バインドがある場合は、`?` プレースホルダーを持つ 1 つの文です。`execute` には逆操作がありません：SQL を実行する `change` を、独自の `down` なしでロールバックしようとすると、何かを元に戻す前に `version N is irreversible: it executes SQL in change; write down` で停止します。データの文が `db/schema.rb` に現れることはありません。このファイルはデータベースからダンプされるためです。マイグレーションの記録時には何も実行されないので、文はそのバージョンの `migrate` ごとにちょうど 1 回実行されます。

### インデックスと外部キー

`add_index` は部分インデックスのための `where:` を受け付けます。`t.references` は `on_delete:` と `index: false` を受け付け、`add_reference` は `on_delete:` を受け付けて、インデックスを必ず追加します：

```ruby
create_table "comments" do |t|
  t.references :article, on_delete: :cascade   # ON DELETE CASCADE
  t.references :author, null: true, on_delete: :nullify, index: false
  t.text "body"
  t.timestamps
end
add_index "comments", ["body"], where: "body IS NOT NULL"
```

`on_delete:` は `:cascade`、`:nullify`（カラムは NULL を許す必要があります）、`:restrict` のいずれかです。指定しなければ `ON DELETE` 句は書かれません（SQLite の `NO ACTION`）。どちらを使うかは [`dependent:` か `on_delete:` か](#dependent-or-on_delete)にあります。式インデックス（`LOWER(email)`）にはマイグレーションのヘルパーがありません。`execute "CREATE UNIQUE INDEX index_users_on_lower_email ON users (LOWER(email))"` で作ってください。`db/schema.rb` はそれを `s.add_index "users", "LOWER(email)", unique: true, name: "index_users_on_lower_email"` として書き戻し、部分インデックスの `where:` もダンプに残ります。

### テーブルを変える

```ruby
class TidyPosts < Cybertrain::Migration::Base
  def up
    rename_table :posts, :articles
    change_column :articles, :views, :bigint, null: false, default: "0"
    change_column_default :articles, :state, from: nil, to: "'draft'"
    change_column_null :articles, :title, false, "untitled"
    remove_reference :articles, :legacy_owner
    remove_foreign_key :articles, :authors
  end

  def down
    # write the reverse of each step
  end
end
```

- `rename_table` は `ALTER TABLE ... RENAME TO` で、そのテーブルを指す外部キーもついてきます。インデックスの名前はそのままです（Rails は新しいテーブル名に合わせて付け直します）。
- 残りの五つは、SQLite に `ALTER COLUMN` がないのでテーブルを作り直します：変更後の定義から新しいテーブルを作り、行をコピーし、古いテーブルを削除して新しいテーブルの名前を変え、インデックス、トリガー、`AUTOINCREMENT` の最大値を戻します。そのテーブルを名指しする他のテーブルのビューやトリガーはそのまま動きます。
- `change_column` はカラムを宣言し直します：渡さなかったオプション（デフォルト値、`null: false`）は Rails と同じく消えます。
- `change_column_default` には `to:`（SQL のリテラルのテキスト。`nil` でデフォルトを外す）が必要です。`from:` は前のデフォルトを示し、ロールバックできるようにします。
- `change_column_null` の四番目の引数は、`NOT NULL` を付ける前に NULL のセルへ書き込む値です。カラムのデフォルトにはなりません。
- `remove_foreign_key :articles, :authors` は外部キーを削除し、カラムとそのインデックスは残します（`author_id` 以外のカラムなら `column:` で指定します）。

`rename_table` と、`from:` 付きの `change_column_default` は `change` の中で自動的に逆になります。`change_column_null` も同じですが、`null: true` をロールバックするには、その後 NULL になったセルのために四番目の引数が要ります。`change_column`、`remove_reference`、`remove_foreign_key` は `change` の中では元に戻せません：`up` と `down` を書いてください。

<details><summary>作り直しが拒むもの、その間の外部キー — CHECK、COLLATE、生成カラムなど</summary>

作り直しは、`db/schema.rb` が表せる内容からテーブルを宣言します。テーブルに手を付ける前にその `CREATE TABLE` のテキストを読み、スキーマが表せないものを含むテーブルを拒み（`rebuilding posts would drop a CHECK constraint: rewrite the migration with execute`）、バージョンはロールバックされます。対象は、`CHECK` 制約とインラインの `UNIQUE` 制約（ユニークインデックスなら問題ありません）、`COLLATE`、生成カラム、`ON UPDATE`、`ON DELETE SET DEFAULT`、`DEFERRABLE`、`id` 以外のカラムへの外部キー、型のないカラム、`id` 以外の主キー、`WITHOUT ROWID` か `STRICT` のテーブルです。この検査は SQL のテキストからこれらの語を探すもので、パーサーではありません：手書きのテーブルを作り直す前には、ダンプしたスキーマを読んでください。ただの `id INTEGER PRIMARY KEY` は `AUTOINCREMENT` 付きで戻り、行も id もすべて残ります。型の正確な書き方は正規化されます（`datetime(6)` は `DATETIME` になります）。

作り直しを含むバージョンは `PRAGMA foreign_keys` を切って実行され（トランザクションの中では切れないので、マイグレーターがバージョンの前後で切り替えます）、コミットの前に `PRAGMA foreign_key_check` を実行します：違反があればバージョンはロールバックされ、その行が示されます。検査はデータベース全体が対象なので、別のテーブルに前からある違反でもバージョンは止まります。Rails と同じです。

</details>

### データの手順を両方向に：`reversible`

```ruby
class BackfillSlugs < Cybertrain::Migration::Base
  def change
    add_column "posts", "slug", :string
    reversible do |dir|
      dir.up { execute "UPDATE posts SET slug = lower(title)" }
      dir.down { execute "UPDATE posts SET slug = NULL" }
    end
  end
end
```

`dir.up` の文はマイグレーション時に、`dir.down` の文はロールバック時に、それぞれ書いた順に実行されます。ブロックの中に書けるのは `execute` だけです。ないもの：`create_join_table`、`change_table`、`rename_index`、`add_timestamps`。

`cybertrain db status` は各バージョンを一覧します。`schema_migrations` にあって `db/migrate` にファイルのないバージョン（別のツールがマイグレーションしたデータベース）は `applied (no file)` と表示され、マイグレーターはそれを実行もロールバックもしません。`cybertrain db schema` はマイグレーションせずにデータベースから `db/schema.rb` を書きます（[Rails が作ったデータベースを引き継ぐ](#taking-over-a-database-rails-created)）。

## カラムの型

| スキーマ DSL | SQL | Ruby の属性 |
| --- | --- | --- |
| `t.string`, `t.text` | `VARCHAR(n)` / `VARCHAR`, `TEXT` | String |
| `t.integer`, `t.bigint`, `t.references` | `INTEGER`, `BIGINT` | Integer |
| `t.float` | `REAL` | Float |
| `t.decimal :price, precision: 18, scale: 8` | `DECIMAL(18,8)` | Float。保存時に scale に丸められ、有効数字 15 桁まで正確 |
| `t.boolean` | `BOOLEAN` | true / false |
| `t.datetime` | `DATETIME` | Time（UTC、マイクロ秒） |
| `t.date` | `DATE` | Date |
| `t.json :meta, default: "{}"` | `JSON` | String のキーを持つ Hash |
| `t.binary` | `BLOB` | バイト列の String（[バイナリのカラム](#binary-columns)） |

NULL を許すカラムの属性は nil にもなります。`new`、`update`、`write_attribute` は渡された値を変換します（整数のカラムへの `"42"` は `42`、日付のカラムへの `"2026-10-05"` は Date）。素の writer の `post.price = ...` は変換しません。SQLite の INTEGER は 64 ビットなので、`t.bigint` は別名の整数カラムです。`t.datetime :x, precision: 6` は受け付けられ、どの datetime もマイクロ秒を保ちます。

### decimal は Float

Rails は `decimal` カラムを BigDecimal として読みますが、ここでは `DECIMAL(p,s)` カラムに入った Float で、次の契約に従います（`docs/design.md` D73）：

- **有効数字 15 桁まで正確です。** `precision:` が 15 以下なら、宣言した精度に収まる、小数部が `scale:` 桁の値はすべて、そのまま保存され、そのまま読み出されます。15 桁を超えると最も近い Float になります：`decimal(18,8)` が正確なのは 9,999,999.99999999 までで、宣言した整数部 10 桁までではありません。
- **保存されるところで scale に丸められます**（`save`、`update`、`update_columns`、`update_all`、一括書き込み）。十進の桁の上で、0 から遠い方への四捨五入です：scale 2 での 1.005 は、Rails が保存するのと同じ 1.01 で、CRuby でも Spinel でも同じです。
- **範囲外はバリデーションエラーです。** precision のある decimal カラムに対して `spin run gen` は `numericality` のバリデーションを書くので、精度を超える値、Infinity、NaN に対して `save` は保存せずに false を返します。
- **合計は Float の合計です。** 合計は端で `Cybertrain::Cast.round_scale(total, 2)` で丸めてください。`total.round(2)` ではありません。

金額は整数カラムに最小単位で持ってください（`price_cents`）：Integer の演算と `sum_int` は正確です。フォームの項目は `(Cybertrain::Cast.round_scale(params[:price], 2) * 100).round` で読み、`number_to_currency(price_cents / 100.0)` で表示します。

### JSON のカラム

`json` カラムはオブジェクトを持ち、`Hash` として読まれ（テキストが JSON のオブジェクトでなければ、NOT NULL のカラムでは `{}`、NULL を許すカラムでは nil）、`JSON.generate` で書かれます。値は Spinel のもとでパースした JSON の値すべてと同じく箱に入っているので、`Cybertrain::Cast` を通して読みます：

```ruby
event.meta = { "attempts" => 2, "tags" => ["a", "b"] }
event.save
Cybertrain::Cast.int(event.meta["attempts"])   # => 2
Cybertrain::Cast.array(event.meta["tags"])     # => ["a", "b"]
```

正しい JSON でないテキストを代入すると `{}` になります。ルートの Array には対応していません：`text` カラムに保存して `Cast.array` で読んでください。json カラムへの `where` は `ArgumentError` を出し、`pluck` は保存されたテキストを返します。

### 日時と `db normalize`

datetime は Rails が SQLite に保存するのと同じ形、`2026-10-05 09:00:00.000000`（UTC、空白、小数六桁）で保存され、`T` でも空白でも、どの小数でも、`Z` でもオフセットでも読めます。JSON（`as_json`、`to_json`）は Rails の表示用の形、`2026-10-05T09:00:00.000Z` を書きます。手書きの SQL では、`Cybertrain::Cast.sql_datetime(time)` が保存用のテキストを、`Cast.iso8601(time)` が表示用のテキストを返します。

CyberTrain 0.4 は `2026-10-05T09:00:00Z` を保存していて、これは日付に関係なく Rails の形の値すべてより後ろに並びます。更新のあとで一度、古いセルを書き直してください：

```console
$ cybertrain db normalize
normalized articles.created_at: 12 rows (0 unreadable left alone)
normalized articles.updated_at: 12 rows (0 unreadable left alone)
done
```

このコマンドは、すべてのテーブルのすべての `DATETIME` カラム（`datetime(6)` を含む）のうち、まだ保存用の形でないセルを、一つのトランザクションの中で行ごとに書き直します。二回実行しても問題ありません。時刻として読めないセル（` UTC` のような余分なテキスト付き）はそのまま残され、数えられます。`WITHOUT ROWID` のテーブルと、`_rowid_` という名前のカラムを持つテーブルは飛ばされ、古いセルがまだ残っていれば `skipped t.c: without rowid (N rows still need normalization)`（または `declares _rowid_`）と表示して終了コード 1 で終わります。その行を手で直してからもう一度実行してください。SQLite 3.37.0 以降が必要です：CyberTrain はシステムの libsqlite3 をリンクし（`sqlite3 --version` で分かります）、それより古いと何も読む前に `db normalize failed: ...` で止まります。本番では `migrate` と新しいバイナリの起動の間に `./<app> db normalize` を実行します（[更新のデプロイ](../deploy.en.md#upgrading-the-framework)）。

### 日付

`date` カラムは `Date`（`Date.new(2026, 10, 5)`）で、`2026-10-05` として保存されます。`where(day: date)` はそのテキストでバインドします。代入するテキストは `YYYY-MM-DD` でなければならず、それ以外（や空）は nil として読み戻されます。NOT NULL の日付カラムには存在のバリデーションが生成されるので、データベースが行を拒む代わりに、`save` が「can't be blank」付きで false を返します。デフォルトのあるカラムはそのデフォルトから始まります。`Cybertrain::Cast.date_or_nil(params[:from])` は日付のパラメーターを同じように読みます。

### 時刻のパース

`Time.iso8601(text)`、`Time.rfc2822(text)`、`Time.strptime(text, format)` が Ruby の名前のまま使え、読めないテキストにはそれぞれ `ArgumentError` を出します。`strptime` が受け付けるのは `%Y %m %d %H %M %S %L %z %Z %b %B %a %A %j %s %%` です（`%Z` は `UTC`、`GMT`、`Z` のみ）。ミリ秒のエポックは `Time.at(ms / 1000.0)` で Time になります。

### 時刻とタイムゾーン

Time は常に UTC の瞬間です：カラムから読んだもの、`Time.current`、以下のすべてのメソッドは UTC の `Time` を返し、TimeWithZone はありません。そのため `time.hour` は UTC の時で、Rails ならゾーンの時を返すところです。ゾーン（`c.time_zone`、[タイムゾーン](configuration.md#time-zones)）が決めるのはカレンダーです：日、週、月、年がどこで始まるか、`Date.current`、そして `l` と `time_tag` が何を表示するか。

```ruby
Time.current                         # => 時計の UTC の Time（テストでは travel_to に従う）
5.minutes                            # => 300、Integer の秒
2.weeks.ago                          # => Time.current の 14 日前の Time
3.days.from_now                      # => Time
Time.current.months_ago(1)           # => カレンダーで 1 か月前（1.month.ago ではない）
Time.current.beginning_of_day        # => Time.zone での真夜中を UTC の Time で
Time.utc(2026, 1, 31).advance(months: 1)   # => 2026-02-28 00:00:00 UTC
Date.current                         # => Time.zone での今日
Time.current.in_time_zone.hour       # => Time.zone での時
```

- 期間：`seconds`、`minutes`、`hours`、`days`、`weeks` とその単数形は Integer の秒です（`5.minutes == 300`。Rails は Duration を返します）。`ago` と `from_now` は時計の上の Time を返します。1 か月には秒での長さがないので、`1.month` と `1.year` は定義されていません：実行されたときに `NoMethodError` を発生させます。
- Time のメソッド：`beginning_of_day` / `end_of_day`、`_week`（月曜始まり）、`_month`、`_year`。`advance(years:, months:, weeks:, days:, hours:, minutes:, seconds:)` は Integer を取ります（年から日までは壁時計の日付をゾーンのカレンダーで動かし、1 月 31 日に 1 か月足すと 2 月の末日になります。そのあと時から秒までを経過時間として足します）。`months_ago`、`months_since`、`years_ago`、`years_since`、`yesterday`、`tomorrow`。夏時間で飛ばされる壁時計の時刻は先へ進み、2 回ある時刻は早いほうの瞬間になります。
- `Time.zone` は設定した `Cybertrain::TimeZone` で、その名前は `Time.zone.zone_name` です。`time.in_time_zone`（または `in_time_zone("Europe/London")`）は `Cybertrain::ZonedTime` を返します。これは `year`、`month`、`day`、`hour`、`min`、`sec`、`wday`、`yday`、`utc_offset`、`zone`（略称）、`to_time`、`to_date` を持つ値で、演算はできず、保存もされません。`Time.find_zone!(name)` は未知の名前に `ArgumentError` を発生させます。
- ゾーンにかかわらず、カラムには UTC のテキストが入ったままです。

## 条件と検索

生成されるリレーションのクエリメソッドはクラスメソッドでもあるので（`or`、`not`、`page`、`to_sql`、`update_all_sql` と、Array のような `to_a`、`each`、`size`、`empty?` を除く）、Rails の書き方がそのまま動きます：`Article.where.not(body: nil)`、`Article.find_each { }`、`Article.pluck(:id, :title)`、`Article.pluck_int(:id)`。

| Rails | CyberTrain |
| --- | --- |
| `where(views: 1..10)`, `where(views: 10..)` | 同じ。ただし端は Integer のみ |
| `where(created_at: from..to)` | `where_between(:created_at, from, to)`（`...` には `exclude_end: true`、開いた端は nil） |
| `where("views > ?", 10)` | 同じ |
| `where.not(state: "draft")`, `a.or(b)` | 同じ |
| `order(created_at: :desc)` | 同じ |
| `distinct`, `none`, `ids` | 同じ |
| `find_by!`, `find_or_create_by`, `find_or_initialize_by` | 同じ |
| `update_all`, `destroy_all`, `find_each(batch_size: 500)` | `update_all`, `destroy_all`, `find_each(batch: 500)` |
| `create!`, `record.update_columns(views: 0)` | 同じ |

- `where` の Hash の中の Range は Integer の端を取ります。固定している Spinel でコンパイルすると、Time や Date の Range は作る時点で `TypeError` になり、Float の Range は Range として認識されません（縮小したプログラムでの結果です。spikes/NOTES.md のルール 86）。そのため、そうした端は `where_between` を通します。その Time と Date の端は、保存されたテキストとして比べられます（テキストの順は時刻の順と同じです）。String の Range は同じプログラムでは認識されますが、`where` は Integer の端のために書かれているので、String の端も `where_between` に渡してください。
- String の条件は括弧で囲まれるので、その中の `OR` は中に留まります。バインドはスカラーです：`where("id IN (?)", ids)` は例外を出します。`where(id: ids)` と書いてください。
- `a.or(b)` は `((a) OR (b))` です。二つは並び順、limit、offset、`distinct` がそろっている必要があります。
- json か暗号化されたカラムへの `where` は `ArgumentError` を出します。
- `distinct` にすると、カラムを読むメソッドは各値を一度だけ返し、集計は重複のない入力を読みます（`SUM(DISTINCT x)`）。`count` と `to_a` は変わりません。どの行にもそれぞれの id があるからです。
- `update_all(hash)` は `save` が保存するのと同じく変換と丸めを行い（ただし数値、真偽値、日付、json のカラムでは `""` は NULL になります。`save` なら 0 / false / `{}` を保存します）、`updated_at` には触れず、コールバックも実行しません。`destroy_all` は各レコードを、コールバックと `dependent:` も含めて destroy します。
- `update_all_sql(sql, binds = [])` は SQL の `SET` リストで列を設定します。行から計算する値に使います（`User.where(id: id).update_all_sql("failed_attempts = failed_attempts + ?", [1])`）。どの式も元の行を読み、`?` はバインドを順に取り、`update_all` と同じくモデルを読み込まず、コールバックも実行しません。
- `find_each` は id の順に一括で読み進め、Rails と同じく、リレーションの並び順、limit、offset は使いません。
- 絞り込んだリレーションの `find_or_create_by` は、渡された Hash だけからレコードを作ります。Rails はリレーションの等値条件も使います。新しいレコードに要る属性はすべて渡してください。
- `update_columns` は値を代入してから、そのカラムだけの UPDATE を一回実行します：バリデーションもコールバックもなく、`updated_at` も変わりません。

## スコープ

```ruby
# app/models/article.rb
class Article
  scope :recent, -> { order(created_at: :desc) }
  scope :since, ->(time) { where("created_at > ?", time) }
end

Article.recent.since(Time.now - 86_400).limit(5).to_a
```

ジェネレーターは各 `scope` の行をテキストとして読み、ラムダの引数と本体をモデルのリレーションのメソッド（`def since(time) = (where("created_at > ?", time))`）と、それに委ねるクラスメソッドにコピーします。そのためスコープは普通のクエリと同じようにつなげられます。生成時には何も評価されません：リレーションにないものを名指しする本体は、Spinel が `gen/models` をコンパイルするときに、生成された行で失敗します。

スコープはクラスの直下の一行です：普通の引数かデフォルト値付きの位置引数を取る `->` のラムダで、閉じ `}` のあとには何も書かず（コメントも不可）、デフォルト値に括弧やカンマを含めません。カラム、別のスコープ、クエリメソッド（`where`、`count`、`first`）、`Object` のメソッド（`hash`、`then`、`raise`）と同じ名前のスコープは、ファイル、行、理由を示してジェネレーターを止めます。

## `where` を超えるクエリ

上の条件のほかに、たいていのアプリケーションが必要とするカウンター、統計、検索ボックスは、クエリビルダーではなく型付きのメソッドとして用意されています（`docs/design.md` D22、D44、D45）。どれも SQL のカラム名を受け取り、検査してクォートし（それ以外は `ArgumentError`）、すべての値をバインドします：

```ruby
# INSERT ... ON CONFLICT (project_id, key) DO UPDATE SET ...; 書き込んだ行数を返す
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "calls + excluded.calls", max_ms: "MAX(max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
Article.where(id: article.id).increment(:views)          # UPDATE ... SET views = views + 1 (by: n for another step)
Comment.where(article_id: article.id).pluck_int(:id)      # => [3, 7]   （pluck_str、pluck_float もある）
Comment.all.count_by(:article_id)                         # => {"1" => 2, "4" => 1}
Comment.all.count_by_sql("strftime('%Y-%m-%dT%H', created_at)")  # 1 時間ごとの集計
Stat.where(project_id: 1).sum_int(:calls)                 # sum_float もある
Article.where_like(:title, params[:q].to_s)               # `title` LIKE '%...%' ESCAPE '\'
```

- どれも型付きです。Spinel のメソッドは戻り値の型がひとつだからです：`pluck_str` / `pluck_int` / `pluck_float` は 1 カラムだけを読み、`sum_int` / `sum_float` は 1 カラムを合計し、`count_by` は `Hash{String => Integer}` を返します。
- `upsert` の `update` の値と `count_by_sql` の式は、`order_sql` と同じく SQL テキストです：決してリクエストのデータから組み立てないでください。空の `update` は `DO NOTHING` です。`upsert` と `increment` はモデルを読み込まず、バリデーションもコールバックも実行せず、タイムスタンプも埋めません。`upsert` は各値を `save` が保存するのと同じく変換します。
- `count_by` のキーは String（`Cast.str` を通したもの）で、昇順です。NULL と `""` はキー `""` を共有します。`limit` / `offset` がある場合、`count_by`、`sum_*`、`increment` は、`count` や `delete_all`（サブセレクトを通して）と同じく、その範囲に対して働きます。
- `where_like` はテキスト中の `\`、`%`、`_` をエスケープしてくれ、部分文字列の一致です（SQLite の LIKE と同じく、ASCII については大文字小文字を区別しません）。前方一致の検索では自分でパターンを書きます：`Article.all.where_sql("title LIKE ? ESCAPE '\\'", [Cybertrain::Cast.like_escape(q) + "%"])`。
- 手書きの SQL には、`Cybertrain::Cast.binds(a, b, c)` が `execute` の受け取るバインドの Array を組み立てます（Time は保存用の datetime の形、Date は `YYYY-MM-DD`、真偽値は 1/0）：`Cybertrain::DB.with { |c| c.execute(sql, Cybertrain::Cast.binds(id, since)) }`。
- `Cybertrain::Cast.hash(v)` / `Cast.array(v)` は、パースした JSON の値を Hash / Array に絞り込みます。そうでない場合は新しい空のものを返します。返すのは `v` そのものではなく、型付きの浅いコピーです。`Cast.empty_hash` / `Cast.empty_array` は、型の種となる空のコンテナーです。

### 複数のカラム：`pluck` と `pick`

```ruby
Reading.order(:id).pluck(:observed_at, :value)   # => [[2026-10-01 09:00:00 UTC, 1.0], ...]
Reading.order(:id).pick(:id, :value)             # => [1, 1.0], or nil
```

`pluck` は二つ以上のカラムを取り、行ごとに一つの Array を返します。各セルはカラムの型で変換されます：Integer、Float（float と decimal）、`true` / `false`、UTC の Time、Date、String（string、text、json、binary のカラムは保存されたテキストかバイト列を、暗号化されたカラムはその暗号文を返します）、または nil です。カラムが一つだと、`pluck_str` / `pluck_int` / `pluck_float` / `ids` を示して `ArgumentError` を出します：Rails はカラムが一つなら平らな Array を、複数なら入れ子の Array を返しますが、一つのメソッドが両方を返すことはできません。`pick` は最初の行（`LIMIT 1`）か nil です。受け付けるのはカラム名だけで、式は `DB.with` を通します。

### 集計

| Rails | CyberTrain |
| --- | --- |
| `minimum(:views)`, `maximum(:views)` | `minimum_int`, `maximum_int`（`Integer` か nil） |
| float か decimal の `maximum(:price)` | `minimum_float`, `maximum_float` |
| `maximum(:created_at)` | `minimum_time`, `maximum_time`（UTC の Time か nil） |
| `average(:value)` | `average(:value)`（Float か nil） |
| `group(:kind).sum(:value)` | `sum_float_by(:kind, :value)`（`sum_int_by` もある） |
| `group(:kind).maximum(:created_at)` | `maximum_time_by(:kind, :created_at)`。上の各メソッドに `_by` がある |
| `sum("price * quantity")` | `sum_float_sql("price * quantity")`。`minimum_float_sql`、`maximum_float_sql`、`average_sql` もある |
| `group(:kind).having("SUM(value) > ?", 2)` | `having_sql("SUM(value) > ?", [2.0]).sum_float_by(:kind, :value)` |

- 名前が型を持つのは `pluck_int` と同じ理由です：Rails の `maximum` は、あるカラムでは Integer を、別のカラムでは Time を返します。
- `_by` のメソッドは、グループのカラムの値をテキストにしたものをキーとする `Hash{String => T}` を、`count_by` と同じく昇順で返します。NULL と `""` はキー `""` を共有します。
- `having_sql` はグループ化したメソッドに効きます。それを持つリレーションでほかのメソッドを呼ぶと例外になり、limit や offset のあるグループ化したメソッドも同じです。
- `_sql` の式と `having_sql` は、`order_sql` と同じく信頼できる SQL です。
- `distinct` のもとでは集計は重複のない入力を読みます（`AVG(DISTINCT x)`）。さらに limit があると、範囲は最初の n 個の重複のない値です。
- 式とグループの両方にわたる集計や、二つのテーブルにわたる集計は `DB.with` で書きます。

## 一括書き込み

```ruby
Article.insert_all([{ title: "One", body: "..." }, { title: "Two", body: "..." }]).size  # => 2
Article.insert_all!(rows)                                 # a duplicate raises
Article.upsert_all([{ id: 1, title: "Renamed" }])         # body keeps its value
Article.upsert_all(rows, unique_by: [:slug], update_only: [:title], returning: [:id, :title])
```

`insert_all` は多数の行を、`ON CONFLICT DO NOTHING` 付きの複数行の `INSERT` 文で書き、既存の行とぶつかる行は飛ばします。`insert_all!` は代わりに例外を出し、`upsert_all` はぶつかった行を `ON CONFLICT (unique_by) DO UPDATE` で更新します。結果は `RETURNING` の行（デフォルトでは `[{"id" => 3}, ...]`）を型で変換したもので、`.size` が書かれた行の数です。

- どの行も同じキーを持ちます。そうでなければ何も書く前に `ArgumentError` です。未知のカラムや、キーのない行（`[{}]`）も同じように例外を出します。どの行も指定しないカラムはテーブルの DEFAULT になります。
- 値は `save` と同じ変換を受けます（Time は保存用の形、Hash は JSON、decimal はその scale に丸め、Date はテキスト）。
- `upsert_all` は、行が持つカラムのうち `id`、`unique_by` のカラム、`created_at` を除いたものを更新します。`update_only:` はその一覧を絞り、そこにあっても行が持たない名前は飛ばされます。
- `returning:`、`unique_by:`、`update_only:` は Array か一つの名前（`returning: :id`）を取ります。`false` は「なし」で、それ以外の値は `ArgumentError` です。
- テーブルに `created_at` / `updated_at` があって行がそれを持たないとき、`record_timestamps: false` でなければ、呼び出し全体で一つの `now` が入ります。
- 文は SQLite のバインドの上限に合わせて分けられ、一つのトランザクション（すでに開いているものがあればそれに合流）で実行されるので、失敗すると呼び出しの分は何も残りません。自分で開いたトランザクションの中では、そのロールバックが決めます。
- バリデーションもコールバックも暗号化も行われません：行に暗号化されたカラムがあると `ArgumentError` です。Rails と同じく、飛ばした重複も id を一つ使います。
- `RETURNING` には SQLite 3.35.0 以降（CyberTrain がリンクするシステムのライブラリ）が必要です。それより古いと、その文は SQLite 自身の構文エラーで拒まれます（`Cybertrain::DB::Error`）。

## 関連付け

外部キーがあれば、コードを一行も書かずに両側に関連付けができます（`t.references :article` で `Comment#article` と `Article#comments`）。モデルのファイルで宣言することもでき、名前を変えたりオプションを足したりできます：

```ruby
# app/models/article.rb
class Article
  has_many :comments, dependent: :destroy
  has_one :cover, class_name: "Image", foreign_key: :article_id
end

# app/models/comment.rb
class Comment
  belongs_to :article
  belongs_to :author, class_name: "User", optional: true, counter_cache: true
end
```

- `has_many` は子のリレーションを返すので、つなげられます：`@article.comments.where(approved: true).count`、`@article.comments.find(params[:id])`。Array が要るなら `.to_a` を付けます。テンプレートはそのまま Array として繰り返します。
- `has_one` は子を一つ読み（複数あれば id で最初のもの）、なければ nil です。外部キーが作るはずの `has_many` の代わりになります。
- `belongs_to` は親を読み、外部キーが変わるか `reload` するまで覚えています。
- `optional: true` のない宣言した `belongs_to` は、キーが nil、空、0 の間レコードを無効にするので（`article_id` に「can't be blank」。生成される `validates_foreign_key :article_id`）、データベースが行を拒む前に `save` が false を返します。外部キーだけから来る関連付けはバリデーションを足しません。
- オプションはリテラルです：`class_name:`（String か Symbol）、`foreign_key:`、`dependent:`（`has_many` と `has_one`）、`optional:` と `counter_cache:`（`belongs_to`）。どのマクロもクラスの直下で一行に単独で書き、末尾にコメントを付けません。存在しないモデル、カラム、オプションはファイルと行を示してジェネレーターを止めます。
- ないもの：`has_many` のスコープのラムダ（返されたリレーションにつなげてください）、`inverse_of`、`dependent: :restrict_with_error`。

### through の関連付け

```ruby
# app/models/post.rb
class Post
  has_many :taggings
  has_many :tags, through: :taggings                 # Tagging ごとの tag
  has_many :labels, through: :taggings, source: :tag
  belongs_to :author
  has_many :co_posts, through: :author, source: :posts
end
```

`through:` は同じモデルの別の関連付け（宣言したものでも外部キーから来たものでもよい `has_many`、`has_one`、`belongs_to`）を名指し、リーダーはそのモデルの関連付けがたどり着くレコードを返します。その関連付けは `source:` で名指し、なければリーダーの名前の単数形か複数形です（Tagging の `tag` か `tags`）。リーダーはサブクエリを持つ、ターゲットの上の一つのリレーションです（`tags.id IN (SELECT tag_id FROM taggings WHERE post_id = ?)`）。そのためほかのリレーションと同じようにつなげられ（`@post.tags.where(name: "ruby").order(:name)`、`.count`）、二つの tagging が同じタグにたどり着いても、各タグを一度だけ返します。結合する Rails なら繰り返します。`includes(:tags)` は中間の行を、続いてターゲットを読み込み、クエリは二回増えます。一段だけです：経由する関連付けもその source も through であってはいけません。`dependent:`、`class_name:`、`foreign_key:` は取らず（キーとクラスは二つの関連付けから来ます）、読み取り専用です：`@post.tags << tag` はないので、中間のレコードを作り（`Tagging.create(post_id: @post.id, tag_id: tag.id)`）、外すときはそれを destroy してください。`has_one :through` はありません。

### `dependent:` か `on_delete:` か

`dependent:` は `destroy` の中で、親の DELETE の前に、同じトランザクションで実行されます：`:destroy` は子を一つずつ読み込んで destroy し（そのコールバックと子自身の `dependent:` も実行されます）、`:delete_all` は DELETE を一回、`:nullify` はキーを NULL にする UPDATE を一回実行します。外部キーの `on_delete:`（[インデックスと外部キー](#indexes-and-foreign-keys)）は、誰が行を削除しても SQLite に任せます。子にコールバック、カウンター、自分の子があるときは `dependent: :destroy` を、速さが欲しいときや別のプログラムもデータベースに書くときは `on_delete: :cascade` を使ってください。どちらもなければ、外部キーはまだ子のある親の削除を拒みます。

### カウンターキャッシュ

`belongs_to :post, counter_cache: true` は `posts.comments_count`（または `<has_many の名前>_count`）を合わせ続けます：子が作られたら +1、destroy されたら -1、子が別の親に移ったら両側を、それぞれ子自身のトランザクションの中で更新します。カラムは存在している必要があります（`default: "0"` の整数）。親自身の `save` は、その値が古いかもしれないので、それを UPDATE に含めません。`dependent: :destroy` で destroy される親は、消える前に子の数だけ自分を減らしますが、害はありません。

### ポリモーフィック関連付け

ポリモーフィックな `belongs_to` は、いくつかのモデルのどれかのレコードを指します：

```ruby
# a migration's change (db/schema.rb spells it the same way)
create_table "comments" do |t|
  t.text "body", null: false
  t.references :commentable, polymorphic: true
  t.timestamps
end

# app/models/comment.rb
class Comment
  belongs_to :commentable, polymorphic: true
end

# app/models/post.rb
class Post
  has_many :comments, as: :commentable, dependent: :destroy
end

# app/models/photo.rb
class Photo
  has_one :comment, as: :commentable
end
```

```ruby
comment = Comment.create(body: "Nice", commentable: post)
comment.commentable_type             # => "Post"
case comment.commentable
when Post then comment.commentable.title
when Photo then comment.commentable.url
end
Comment.includes(:commentable).to_a  # one query per type found
```

- `t.references :commentable, polymorphic: true`（マイグレーションでは `add_reference ..., polymorphic: true`）は、文字列の `commentable_type`、続いて `commentable_id` を足し（`null: true` でなければ NOT NULL）、両方に `index_comments_on_commentable` という名前のインデックスを一つ作ります。Rails が作るのと同じカラムとインデックスなので、Rails が作ったデータベースはそのまま読めます。外部キーはありません（`on_delete:` は拒まれます）。`remove_reference ..., polymorphic: true` はインデックスと両方のカラムを落とします。
- 型のカラムには、Rails が保存するのと同じく親のクラス名（`"Post"`）が入ります。ライター `comment.commentable = post`（と `Comment.new(commentable: post)`）は両方のカラムを設定し、nil は両方を消します。親は先に保存してください。保存前の親の id は 0 です。
- リーダーは、Comment に向けて `has_many` か `has_one ..., as: :commentable` を宣言したモデルのどれかのレコードを返し、型が空か行がなければ nil を返し、それ以外の型には `ArgumentError` を上げます。Spinel のもとではリーダーの型がそれらのモデルの和なので、返せるのはそれらだけで、どのモデルも応えないポリモーフィックな `belongs_to` はジェネレーターを止めます。どのモデルにもあるメソッド（`id` や共通のカラム）は値にそのまま呼べます。それ以外は `case` で絞ってください。
- `optional: true` がなければ両方のカラムを検証します（`commentable_type` と `commentable_id` に「can't be blank」）。
- `as:` 付きの `has_many` と `has_one` は、型がこのモデルの名前でキーがこのレコードの id である子を読みます。`dependent:` はそれらだけに働きます（`:nullify` は両方のカラムを NULL にするので、両方とも NULL を許す必要があります）。`includes` はどちら側も先読みします。
- ないもの：`polymorphic: true` と一緒の `class_name:`、`foreign_key:`、`foreign_type:`、`counter_cache:`、`as:` と一緒の `foreign_key:`、型のカラムの名前空間付きクラス名（`Admin::Post`）、フィクスチャでの親のラベル（`commentable: one (Post)`。二つのカラムを設定してください）。

### `includes` で先読みする

```ruby
@articles = Article.recent.includes(:comments).to_a   # two queries
```

```erb
<% @articles.each do |article| %>
  <%= article.title %> (<%= article.comments.size %>)
<% end %>
```

`includes(*names)`（と同じものの `preload`）は、レコードを読み込むときに関連付けごとにクエリを一回足します（`has_many` と `has_one` なら `Comment.where(article_id: ids)`、`belongs_to` なら id で親を、[through の関連付け](#through-associations)なら二回）。そのため `article.comments` や `comment.article` を回すループは、自分ではクエリを実行しません。子のないレコードは空の一覧を、親のないレコードは nil を受け取り、それ以上のクエリはありません。先読みした `has_many` では、`to_a`、`each`、`first`、`last`、`size`、`empty?` がメモリから答え（子は id の順）、`count` と `exists?` はクエリを実行し、つなぐメソッド（`where`、`order` など）は先読みを捨てて普通にクエリします。先読みした子には親が設定されません（`comment.article` は読みに行きます。下のように一緒に先読みもできます）。`eager_load` と `joins` はありません。

ネストした関連付けは Rails の Hash と Array の形で、何段でも書けます：

```ruby
Article.includes(comments: :author)                        # クエリ三回
Article.includes(comments: [:author, :likes])              # 四回
Article.includes(:author, comments: { author: :profile })  # 五回
Comment.preload(article: { author: :profile })             # 四回
```

段ごとに、その上のレコードの数によらずクエリが一回増えます（SQLite が一つの文に束縛できる数より id が多い段では、id のかたまりごとに一回）。すべての記事のコメント、次にそのコメントすべての著者、という具合です。読み込むものがない段（コメントがない、親がすべて nil）はクエリを実行しません。同じリレーションへの二度目の `includes` は一度目に足されます。その段のモデルの関連付けでない名前は、`includes` を呼んだときに、どのクエリよりも前に `ArgumentError`（`unknown association nope for Comment`）になります。検査は実行時で、ジェネレーターは行いません（`docs/design.md` D95）。ポリモーフィックな `belongs_to` の下では親の型ごとにクエリが一回増え、その下の名前は `as:` で宣言したすべての型の関連付けでなければなりません。[through の関連付け](#through-associations)もほかと同じようにネストでき、その段はクエリ二回です。

## バリデーション

```ruby
class Article
  validates :title, presence: true, length: { minimum: 3, maximum: 120 }, uniqueness: true
  validates :state, inclusion: { in: ["draft", "published"] }, allow_nil: true
  validates :slug, format: { with: /\A[a-z0-9-]+\z/ }, exclusion: { in: ["new", "edit"] }
  validates :views, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :email, uniqueness: { scope: :account_id, case_sensitive: false }, on: :create
  validates :summary, presence: true, if: :published?

  def published? = state == "published"
end
```

メッセージは Rails のデフォルトで、リクエストのロケールの同梱の辞書から来ます：英語では「can't be blank」、「is too short (minimum is 3 characters)」、「is the wrong length (should be 5 characters)」、「is not included in the list」、「is reserved」、「is invalid」、「is not a number」、「must be an integer」、「must be greater than or equal to 0」、「has already been taken」、日本語では「を入力してください」などです。上限 1 は「1 character」になります。`message:` は行の上でもルールの Hash の中でも、メッセージを置き換えます。`config/locales/` で、すべてのモデルについて、または 1 つのモデルについて置き換えることもできます（[モデルとバリデーションメッセージ](i18n.md#models-and-validation-messages)）。`errors.full_messages` は各属性を `Post.human_attribute_name(:title)`（「Title」。`author_id` は「Author」）で呼び、`:base` のメッセージは単独で書きます。

- `length` は `minimum`、`maximum`、`is`、`in`（Integer の Range）を取ります。
- `inclusion` と `exclusion` は Array か Integer の Range を取ります（それ以外の Range は `in: takes a Range of Integers only` で拒否されます）。Rails と同じく、`1...5` は float カラムの 4.5 を通します。
- `numericality` はまず String をパースします（`"12"` は通ります）。Float は Rails と同じく `only_integer` に通りません。
- `uniqueness` は、その値を持つ別の行があるかをデータベースに問い合わせます（`case_sensitive: false` なら `LOWER(col) = LOWER(?)`、nil なら `IS NULL`）。`scope:` で範囲を絞ります。暗号化されたカラムには使えません。
- `allow_nil:` と `allow_blank:` は、その行のすべてのルール（`presence` も含む）で nil や空の値を飛ばします。`on: :create` か `on: :update`（Symbol 一つ）は、新しいレコードか保存済みのレコードのときだけその行を実行します。
- 未知のオプションや種類の違う値は、モデルの読み込み時に `ArgumentError` を出します。

### 独自のバリデーションと条件

```ruby
class Booking
  validate :ends_after_start, on: :update, unless: :imported?

  def ends_after_start
    errors.add(:ends_on, "must be after the start") if ends_on < starts_on
  end

  def imported? = source == "import"
end
```

`validate :method` の行は `validates` のルールのあとに順に実行されます。`if:` と `unless:`（どちらの行でも）は、モデルのメソッド、カラム、関連付けを名指しする Symbol を取ります。ジェネレーターは `send` を使わず、それを呼ぶ `case` の表を書き、この三つのどれでもない名前は拒否します。ラムダ、`:if => :x`、`"if": :x` は、メソッドを名指しするよう告げるメッセージでジェネレーターを止めます。モデルのファイルが定義していない `validate` の名前も同じです。`validates_with`、`validates_each`、`confirmation`、`acceptance`、`valid?(context)` はありません。

## 暗号化されたカラム

```ruby
# app/models/account.rb
class Account
  encrypts :api_key
end
```

`encrypts` は string か text のカラムを名指しします（保存される暗号文はテキストより長いので text がよいでしょう）。生成されるモデルは行を書くときに値を暗号化し、読むときに復号するので、`account.api_key` はテキストで、テーブルには `1:` に続いて、ランダムな nonce、AES-256-GCM の暗号文、そのタグを Base64 にしたものが入ります。同じ値を二回保存しても異なる暗号文になるので、このカラムは検索できません：

- `where`、`where_like`、`where_between`、`update_all`、`increment`、`upsert`、`uniqueness`、一括書き込みはこのカラムを拒みます（`ArgumentError`）。`pluck` は暗号文を返します。
- `to_json` と `as_json` は、Rails と同じく復号したテキストを含みます。ページに出すものからはこのカラムを外してください。
- 保存された値が空なら `""` と読まれるので、`default: "''"` で追加した NOT NULL のカラムは、行が保存し直される前でも読めます。
- ないもの：`deterministic: true`、Rails の `ActiveRecord::Encryption` の暗号文を読むこと（鍵の導出と形式が違います）。

### 鍵と入れ替え

`encrypts` のあるモデルがあると、`CYBERTRAIN_ENCRYPTION_KEY` が 64 文字の 16 進数でなければ起動に失敗します（`cybertrain secret --hex` で作ります。[環境変数](configuration.md#configuration-and-environment-variables)）。鍵は `CYBERTRAIN_SECRET_KEY_BASE` から導かれないので、セッションの秘密鍵を変えてもデータは読めます。暗号化の鍵をなくすとデータは失われます。入れ替えるには、新しい鍵を `CYBERTRAIN_ENCRYPTION_KEY` に、古い鍵を `CYBERTRAIN_ENCRYPTION_KEY_PREVIOUS`（カンマ区切り。読むときだけ試されます）に入れてから、すべてのレコードを書き直します：

```ruby
Account.find_each { |account| account.update_columns(api_key: account.api_key) }
```

`encrypts` のないアプリケーションのコードも、鍵を設定すれば `Cybertrain::Crypto.encrypt(text)` / `Crypto.decrypt(payload)` を自分で呼べます：その場合、起動時に鍵は求められず、鍵なしで呼ぶと `Cybertrain::Encryptor::Error` になります。

### すでにテキストのあるカラムを暗号化する

`encrypts` を足す前に書かれた行は平文を持っていて、それを読むと `Cybertrain::Encryptor::Error` になります。アプリケーションのコマンド（`./<app> encrypt_api_keys`）から、SQL で一度だけ暗号化してください：

```ruby
# bin/<app>.rb
Cybertrain::Main.command("encrypt_api_keys", "encrypt accounts.api_key written before encrypts") do |_argv|
  Cybertrain::DB.transaction do |c|
    c.execute("SELECT id, api_key FROM accounts WHERE api_key IS NOT NULL AND api_key NOT LIKE '1:%'").each do |row|
      payload = Cybertrain::Crypto.encrypt(Cybertrain::Cast.str(row["api_key"]))
      c.execute("UPDATE accounts SET api_key = ? WHERE id = ?", [payload, Cybertrain::Cast.int(row["id"])])
    end
  end
  0
end
```

`NOT LIKE '1:%'` は、二回目の実行で暗号文をもう一度暗号化しないためのものです。平文が `1:` で始まりうるなら外してください。Rails が暗号化した値は、まず Rails のアプリケーションで復号し、それからここで同じように暗号化します。

## ページネーション

一覧ページは `?page=N` からページ番号を読み、リレーションの範囲を絞り、リンクをレンダリングします：

```ruby
# app/controllers/articles_controller.rb
def index
  @articles = Article.all.order("created_at DESC")
  @page = @articles.page(params.page_number, per: 20)
end
```

```erb
<%# app/views/articles/index.html.erb %>
<% @articles.each do |article| %>
  <p><%= link_to article.title, article %></p>
<% end %>
<%= paginate @page, articles_path %>
```

`params.page_number` は 1 から始まる `page` パラメーターです。ない場合や数値でない場合は 1 で、`1..max_page`（`config.max_page`。デフォルトは 10000、`CYBERTRAIN_MAX_PAGE`）に収められます。上限のないテキストを `String#to_i` に渡すことは決してありません。Spinel では 2**63-1 を超えると `RangeError` を出すためです。`params.int(:per, default: 20,
min: 1, max: 100)` は、任意のキーに対する同じ上限付きの読み取りです（省略可能な `-` と最大 18 桁の数字。それ以外はデフォルト値。`min..max` に収められます）。

`relation.page(n, per: 50)` はリレーションに `LIMIT per OFFSET (n - 1) * per` を設定し（それ以前の `limit`/`offset` を置き換えるので、最後に呼んでください）、`n` を同じ方法で収めるので、オフセットが `(max_page - 1) * per` を超えることはありません。そして `Cybertrain::Page` を返します：`number`、`per`、`row_offset`、`next?`（範囲に対する 1 回の `SELECT 1 ... LIMIT per + 1` で問い合わせ、`COUNT(*)` は使いません）、`prev?`、`next_number`、`prev_number`。行はリレーションに残るので、`@articles.each` は型付きの `Article` を渡します。1..1000 の範囲外の `per` は `ArgumentError` です。

`paginate @page, path` は `<nav class="pager">` をレンダリングし、「Newer」のリンク（`rel="prev"`）、「Page N」、「Older」のリンク（`rel="next"`）を含めます。該当するページがなければ、それぞれ省かれます。リンクは現在のクエリ文字列を保ったまま `page` を置き換え（1 ページ目では取り除きます）、再エンコードしてエスケープするので、検索やフィルターはページをめくっても残ります。独自のクエリ文字列を持つパス（`"/search?q=x"`）では、代わりにそちらを使います。

オフセットによるページネーションのみです：非常に大きなテーブル向けのキーセットページネーション（`after: id`）はまだ作られていません。スキャフォールドの index ビューはすべてのレコードを一覧します。ページ分けするには上の 3 行を追加してください。

## トランザクション

`Cybertrain::DB.transaction { |c| ... }`（または `Article.transaction`。Rails の名前で呼ぶ同じもの）は、接続を借りて `BEGIN` を実行し、接続をブロックに渡し、ブロックが戻れば `COMMIT` し、例外を出せばロールバックして例外を出し直します。`immediate: true` は `BEGIN IMMEDIATE` を実行し、最初に SQLite の書き込みロックを取ります：読んでから書くトランザクションに使ってください。そうすれば、同時に書き込む者がいても、最初の書き込みで「database is locked」で失敗するのではなく、`BEGIN` で待つことになります。ブロックの実行中、そのスレッドでプールを通るものすべて（`save`、`update`、`destroy`、Relation のクエリ、`DB.with`）はトランザクションの接続を使うので、トランザクションの一部になります：

```ruby
Article.transaction(immediate: true) do |c|
  article.save!
  c.execute("UPDATE authors SET articles_count = articles_count + 1 WHERE id = ?", [article.author_id])
end
```

Rails の `transaction` と異なる点と、避けるべきこと：

- ブロックの値ではなく nil を返します。
- 抜けるには例外を出します。例外はロールバックの後に出し直されます（Rails では `raise ActiveRecord::Rollback` で抜けます）。
- ブロックの中でネストした `DB.transaction` は外側のものに合流します：コミットするのは最も外側だけで、どこで例外が出てもすべてロールバックされ、セーブポイントはありません（`requires_new: true` はありません）。
- Spinel では、渡された `c` に対して `c.transaction { }` は呼べません：`DB.transaction` をネストするか、下のブロックを使わない形を使ってください。
- `DB.with` のブロック（これはトランザクションではありません）の中で呼んだ `DB.transaction` は、2 つ目の接続を借ります：接続が 1 つだけのプール（`:memory:` も含む）では、そのまま永遠に待ち続けます。先にトランザクションを開き、その中で処理を行ってください。
- ブロックの中でデータベースのエラーを rescue して処理を続けないでください。「database or disk is full」や I/O エラー、ロック待ちのタイムアウトの後、SQLite はトランザクション全体を自分でロールバックすることがあります。そうなると、ブロック内のその後の文は単独でコミットされる代わりに `Cybertrain::DB::Error`（「the enclosing transaction is no longer open」）を出し、ブロックの終わりでトランザクションも例外を出します。エラーはブロックの外に出し、必要ならトランザクション全体をやり直してください。`c.exec_script("BEGIN")` で開いたトランザクションも、`COMMIT`、`END`、`ROLLBACK` で終えるまで同じ扱いになります。このときの `ROLLBACK` は、SQLite がすでにトランザクションをロールバックしているので、何もせずに成功します。

`rescue` を普通のメソッドに置いておく必要があるコードは、ブロックを使わない形 `c.begin!(immediate: true)` ... `c.commit!` を使い、rescue で `c.rollback!` を呼びます。

## カラム名

カラム名は ASCII の識別子（`[A-Za-z_][A-Za-z0-9_]*`）でなければなりません。Rails ではどんな名前でもかまいません。`spin run gen` は ASCII 以外のカラム名（`名前`、`prénom`）を持つスキーマを拒否します。初期のジェネレーターは、CRuby の下で動いていたときにこれを受け付けていました。カラム名を変えてください（`first-name` のような名前は、もともとメソッド名になれませんでした）。

生成されたクラスやフレームワークがレコードに対して呼ぶメソッド（`errors`、`save`、`attributes`、`hash`、`to_s`、`to_ary`、`raise` など）や Ruby のキーワード（`end`、`class`、`begin`）と同じ名前のカラムは、`<column>_column`（`hash_column`：リーダー、ライター、インスタンス変数）として生成され、生成ファイルに注記が付きます。その 2 つの名前は次のように使います：

- SQL の名前は `read_attribute`、params、`attributes["hash"]` で引き続き使えます。
- テンプレートからはどちらの名前でも参照できます（`post.hash`、`post.hash_column`）。ただし `errors` と `to_param` はテンプレートがモデルのメソッドとして解決するので、そこでは `post.errors_column` を使ってください。
- クエリ API（`where`、`order`、`find_by`）は常に SQL のカラム名を受け取ります（`Post.where(hash: 1)`）。Ruby の名前はリーダーとライター、テンプレートの名前としてだけ使われます。

その他の Object のメソッド（`display`、`tap`、`methods`）と同じ名前のカラムは、注記付きでその名前のまま生成されます。`cybertrain generate scaffold` はキーワードと予約名を拒否し（名前を変えたリーダーを呼ばなければならなくなるため）、覆い隠す名前はジェネレーターと同じく注記付きで受け付けます。

戻り値の型が 1 つのフレームワークのメソッドと同じ名前のカラムは、リーダーがその型を返すなら自分の名前のまま残り、そうでなければ拒否されます。`request_id`（`Cybertrain::Request#request_id`）と `release`（`Cybertrain::Config#release`）は String を返すので、その名前の string、text、binary のカラムは（null を許すかどうかにかかわらず）受け付けられ、それ以外の型は `spin run gen` を止めます。`t.references :request` からの Integer の `request_id` には、代わりに参照の名前を変える助言が出ます：`t.integer "source_request_id"` と `s.add_foreign_key "audit_entries", "requests", column: "source_request_id"`（`belongs_to` は `source_request` と読めます）。

`handle` は型の違うフレームワークのメソッドの名前なので、`handle` というカラムは上の予約された名前と同じく `handle_column` として読みます（アプリケーションは `user.handle_column` を呼び、クエリは `"handle"` のままです）。

`cybertrain generate scaffold` は、何かを書く前にこれらの名前を検査します。`request_id` や `release` という string や text のフィールド、または型なしのものは受け付け、それ以外の型は拒否します（終了ステータス 1）。カラムや `belongs_to` のリーダーがこれらの名前になる `references` のフィールドと、`handle` というフィールドも拒否します。

<details><summary>正確なメッセージ — これらの名前に対して gen とスキャフォールドのジェネレーターが表示するもの</summary>

- `spin run gen`、`release` という boolean のカラム：
  `table audit_entries: column "release" is boolean, so model AuditEntry's reader release would answer true or false or nil, but the framework's Cybertrain::Config#release answers String, and a method name answers one type across the program (spikes/NOTES.md rules 10, 34); rename the column`
- `generate scaffold`、`request_id:integer`：
  `'request_id:integer' would give the model a reader request_id answering Integer or nil, but the framework's Cybertrain::Request#request_id answers String, and one method name answers one type in the program; pick another field name, or make it a string or text field`
- `generate scaffold`、`request:references`：
  `'request:references' adds the column request_id, an Integer, but the framework's Cybertrain::Request#request_id answers String, and one method name answers one type in the program; name the reference differently: the scaffold cannot point another name at requests, so add an integer field such as source_request_id:integer and write the foreign key and belongs_to :source_request, class_name: "Request", foreign_key: :source_request_id by hand`
- `generate scaffold`、`handle` というフィールド：
  `'handle' names framework methods that answer different types (Cybertrain::ErrorReporter#handle (its block's value), Cybertrain::Server#handle (a Response) and the jobs subsystem's handle (nil)), and a model reader of that name would be one more; pick another field`

</details>

名前と型の表は `Cybertrain::Ident::FRAMEWORK_METHOD_TYPES` です。検査されないもの：gen が `release_id` のような外部キーから導く `belongs_to` と、`release` や `request_id` という名前のスコープ。

素の名前がすでにカラム、別の関連付け、`Model` のメソッドに使われている関連付け（Rails では関連付けが `errors` を覆い隠せます）は、生成ファイルにコメントを付けて代わりの名前で出力されます：`has_many` なら `<table>_as_<column stem>`（`comments_as_article`）、`belongs_to` なら `<stem>_as_<column>`（`author_as_author_id`）。

## バイナリのカラム

`t.binary` は、テキストではないバイト列（サムネイル、圧縮したスナップショット、鍵）のための `BLOB` のカラムを作ります。属性は、NUL バイトや 127 を超えるバイトも含めて、保存したバイト列そのままの String です。`NULL` なら `nil` です（`null: false` と宣言しなければカラムは NULL 可なので、カラムを追加する前に保存した写真にはサムネイルがありません。`bytesize` の前に `nil` を確かめてください）：

```ruby
# db/migrate/20261105090000_add_thumbnail_to_photos.rb
class AddThumbnailToPhotos < Cybertrain::Migration::Base
  def change
    add_column "photos", "thumbnail", :binary
  end
end
```

```ruby
photo.thumbnail = File.binread("thumb.webp")
photo.save
Photo.find(photo.id).thumbnail.bytesize   # 同じバイト列が戻る
```

- 生成されたモデルは、保存時にバイナリのカラムを BLOB としてバインドします。ほかの String は従来どおり TEXT としてバインドされ、TEXT は NUL バイトで止まります。生の SQL では、バイト列を `Cybertrain::DB::Blob.new(bytes)` で包むと BLOB としてバインドされます（`c.execute("INSERT INTO photos (thumbnail) VALUES (?)", [Cybertrain::DB::Blob.new(bytes)])`）。
- `Photo.where(thumbnail: bytes)` もバイト列を BLOB として bind します（TEXT の bind は保存された BLOB と等しくなりません）。
- 生の SQL で読んだ BLOB のセルは、そのバイト列の String です。`Cybertrain::Cast.binary(value)` で絞り込めます（`NULL` なら `""`）。
- `db/schema.rb` はこのカラムを `t.binary` として書き戻し、コンソールはバイナリの値を `<N bytes>` と表示します。
- 大きなファイルはデータベースに入れないでください：アップロード（[カバー画像を追加する](advanced-tutorial.md#attachments)）は `storage/uploads/` の下のファイルですが、BLOB は行と一緒に丸ごとメモリーに読み込まれ、バックアップと WAL を大きくします。

## 並び順

Rails の `order` は任意の SQL を受け取りますが（`order("lower(title)")`、`order("posts.title")`、`order(params[:sort])`）、ここでの `order` は `column [ASC|DESC]` のリスト（各カラムはクォートされます）だけを受け取り、それ以外には `ArgumentError` を出します：文字列は開発者のものなので、500 になります。

リクエストのデータはまず許可リストを通す必要があります。形式の正しい項目でも、存在しないカラム（SQLite からの 500）や、クライアントに並べ替えさせてはならないカラムを指しうるためです：

```ruby
SORTS = { "title" => "title", "newest" => "created_at DESC" }
Post.order(SORTS.fetch(params[:sort].to_s, "id"))
```

ORDER BY の生のテキストは `order_sql`（`Post.order_sql("lower(title)")`。relation にもあります）を通しますが、これにリクエストのデータを渡してはなりません。

## Rails が作ったデータベースを引き継ぐ

Rails 8 のアプリケーションが作った SQLite のファイルは、そのまま読めます：

1. アプリケーションのデータベースのパスにコピーします。デフォルトは `storage/development.sqlite3` です（`storage/<env>.sqlite3`、または `CYBERTRAIN_DATABASE` が指す場所）。
2. `cybertrain db schema`（ビルドしたバイナリなら `./<app> db schema`）を実行します。`db migrate` が使うのと同じダンパーでデータベースから `db/schema.rb` を書き、`wrote .../db/schema.rb from <path>` と表示し、ほかには何もしません。そのあと `cybertrain db migrate` は適用するものを見つけず、モデルを生成します。
3. Rails の `db/migrate/*.rb` はコピーしません：新しいマイグレーションはここから始めます。`schema_migrations`（どちらでも同じテーブル）にすでにある Rails のバージョンにはここにファイルがないので、マイグレーターはそれを実行もロールバックもせず、`db status` は `applied (no file)` と一覧します。
4. 変換が要らないもの：日時（Rails の形が保存用の形です）、真偽値（`1` / `0`、古い `t` / `f`）、decimal（Rails は REAL の値を書くので Float として読めます）、json（TEXT で、Hash として読めます）、Rails が書く型名（`datetime(6)`、`decimal(18,8)`、`varchar`、`bigint`、`json`）。部分インデックス、式インデックス、`ON DELETE` の動作もダンプされます。
5. 制限：主キーが `id` カラムでないテーブル（結合テーブル）は `create_table "articles_tags", id: false` としてダンプされ、モデルはありません（`spin run gen` が `skipped articles_tags: no id column, so no model (reach it with Cybertrain::DB.with)` と表示します）。整数でない `id` 主キー（Rails の `id: :uuid` や `id: :string`）も同じようにダンプされ、`id` は PRIMARY KEY のない普通のカラムとして残ります。`ar_internal_metadata` はそのままにします。スキーマが表せないものを `CREATE TABLE` に含むテーブルは、作り直すヘルパーでは変えられません（[テーブルを変える](#changing-a-table)）。Rails が暗号化したカラムは暗号化し直します（[すでにテキストのあるカラムを暗号化する](#encrypting-a-column-that-already-holds-text)）。

そのうえで、Rails のモデルにあったバリデーション、関連付け、スコープを、このページの形で `app/models/*.rb` に書きます。

## MySQL

`require "cybertrain/mysql"` でビルドしたアプリケーション（[設定の「MySQL」](configuration.md#mysql)）は、同じモデル、マイグレーション、クエリを MySQL 8.0 で動かし、SQLite と同じ答えを返します。違いと、それを固定するテストは `docs/compatibility.md` にあります。モデルのコードが出会うのは次のことです：

- **カラムの型。** `string` は `VARCHAR(255)`（`limit:` で変わる）、`text` は `MEDIUMTEXT`、`integer` は `INT`（`id` と整数の `*_id` はすべて `BIGINT`）、`boolean` は `TINYINT(1)`、`decimal` は `DECIMAL(p,s)`、`float` は `DOUBLE`、`date` は `DATE`、`datetime` は UTC の `DATETIME(6)`、`json` は `JSON`、`binary` は `LONGBLOB` です。属性は SQLite と同じように読めます。
- **比較は厳密です。** テーブルは `utf8mb4` とバイナリの照合順序 `utf8mb4_0900_bin` を使うので、`where`、`uniqueness`、一意インデックスは、SQLite と同じく `"A"` と `"a"`、`"a"` と `"a "` を区別します。そのため `LIKE` と `where_like` も大文字と小文字を区別します（SQLite の LIKE は ASCII の大文字小文字を区別しません）。検索ボックスには、小文字にしたパターンと `LOWER(title) LIKE ?` を比べてください。
- **JSON は正規化されます。** サーバーは `{"k":[1,2]}` を `{"k": [1, 2]}` として保存します。属性が読む Hash は同じですが、保存されたテキスト（`execute`、ダンプ、`ORDER BY`）は違います。
- **範囲外の decimal は拒否されます。** 接続の厳格な `sql_mode` は、カラムの精度を超える値を拒否します（`Out of range value for column 'price'`、エラー 1264）。SQLite は Float を保存します。これは、`save` が実行するバリデーションを飛ばす `update_columns`、`update_all`、一括書き込みにも及びます（[decimal は Float](#decimals-are-floats)）。
- **エラー。** 制約の違反は、どちらでも同じクラスを投げます（`Cybertrain::DB::UniqueViolation`、`ForeignKeyViolation`。MySQL ではさらに `Deadlock`、`LockTimeout`、`ConnectionLost`）。メッセージはサーバーのもの（`Duplicate entry 'x' for key ... (MySQL 1062, 23000)`）なので、文言ではなくクラスで照合してください。
- **`upsert` の `update:`。** 新しい行はどちらでも `excluded` ですが、MySQL ではテーブルを付けないカラム名はあいまいです（エラー 1052）。テーブル自身のカラムには名前を付け、SQLite の 2 引数の `MAX` / `MIN` には `GREATEST` / `LEAST` を使います：

```ruby
# MySQL：INSERT ... AS excluded ON DUPLICATE KEY UPDATE ...
Stat.upsert({ project_id: project.id, key: path, calls: 1, max_ms: ms, seen_at: Time.now },
            conflict: [:project_id, :key],
            update: { calls: "stats.calls + excluded.calls", max_ms: "GREATEST(stats.max_ms, excluded.max_ms)",
                      seen_at: "excluded.seen_at" })
```

- **`returning:`。** MySQL には `RETURNING` がありません。`insert_all` と `upsert_all` は同じトランザクションの中で行を読み戻し、SQLite が返すのと同じ行を返します。（主キー以外の）一意インデックスがあるテーブルでは、`insert_all(..., returning:)` は、行がそのようなインデックスの 1 つのカラムをすべて含んでいる必要があり、そうでなければ書く前に `Cybertrain::DB::Error` を投げます。そうでないと、飛ばした重複を見分けられないからです。
- **マイグレーションは巻き戻りません。** MySQL の DDL は実行するたびにコミットされるので、途中で失敗したマイグレーションは、失敗した文より前に実行したものを残します：`migration V failed at statement 2 of 3; statements 1..1 were applied and cannot be rolled back (MySQL DDL commits implicitly): ...`。バージョンは記録されません。もう一度 `db migrate` を実行する前に、適用された部分を元に戻して（または手で終わらせて）ください。Rails の MySQL アダプターも同じです。できるところでは、1 つのマイグレーションに 1 つの変更にしてください。
- **部分インデックスはありません。** `add_index ..., where:` は、何かを書く前に、ファイルと行を示して `spin run gen` を止めます（`partial indexes (where:) are not supported on MySQL`）。カラム全体にインデックスを張るか、条件を生成カラムに入れてください。
- **スキーマ。** `db/schema.rb` は `information_schema` からダンプされ、同じマイグレーションからは SQLite と同じファイルができます。`db normalize`、`db backup`、`db vacuum` は SQLite のものです。

## アップグレード

モデルとデータベースについてリリースが変えることは、[アップグレード](upgrading.md#notes-by-version) にバージョンごとに載っています。
